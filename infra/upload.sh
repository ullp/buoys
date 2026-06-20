#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Upload script for Buoys media files to S3
# Run this AFTER terraform apply has completed.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "  Uploading Media Files to S3"
echo "========================================"

# Get bucket name from terraform output (via Docker)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_BASE="docker run --rm \
    -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-} \
    -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-} \
    -e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-eu-west-1} \
    -v ${SCRIPT_DIR}:/workspace \
    -w /workspace"
DOCKER_TERRAFORM="${DOCKER_BASE} hashicorp/terraform:1.9"

BUCKET_NAME=$(${DOCKER_TERRAFORM} output -raw s3_bucket 2>/dev/null || echo "")

if [ -z "$BUCKET_NAME" ]; then
    echo "ERROR: Could not get bucket name from Terraform."
    echo "Make sure you've run './deploy-docker.sh' first."
    exit 1
fi

echo "Target bucket: s3://$BUCKET_NAME"
echo ""

# Check if source tracks directory exists
TRACKS_DIR="../tracks"
if [ ! -d "$TRACKS_DIR" ]; then
    echo "WARNING: Source directory '$TRACKS_DIR' not found."
    echo "Create it and place your audio files there, then re-run."
    echo ""
    echo "Expected files:"
    echo "  tracks/hero-bg-video.mp4"
    echo "  tracks/session Dobrichlapci - edit - Track 1 - Mac-9-5.wav"
    echo "  tracks/session Dobrichlapci - edit - Track 2 - Mac-9-5.wav"
    echo "  tracks/session Dobrichlapci - edit - Track 3 - Mac-9-5.wav"
    echo "  tracks/session Dobrichlapci - edit - Track 4 - Mac-9-5.wav"
    echo "  tracks/session Dobrichlapci - edit - Track 5 - MAC-9-5.wav"
    echo "  tracks/Speedstop 09.05.2023.mp3"
    echo "  tracks/0001 3-Audio-1.wav"
    exit 1
fi

echo "Uploading files from $TRACKS_DIR/ to s3://$BUCKET_NAME/tracks/ ..."
echo "  (renaming to clean lowercase filenames)"

# Create a temporary staging directory with renamed files
STAGING_DIR=$(mktemp -d)
trap "rm -rf $STAGING_DIR" EXIT

# Copy and rename files to staging directory
cp "$TRACKS_DIR"/*.wav "$TRACKS_DIR"/*.mp3 "$TRACKS_DIR"/*.mp4 "$STAGING_DIR/" 2>/dev/null || true

# Rename files to clean lowercase names based on actual filenames
# Hero video
for f in "$STAGING_DIR"/*hero*; do
    [ -f "$f" ] && mv "$f" "$STAGING_DIR/hero-bg-video.mp4"
done

# Speedstop
for f in "$STAGING_DIR"/*speedstop*; do
    [ -f "$f" ] && mv "$f" "$STAGING_DIR/speedstop.mp3"
done

# Okupe
for f in "$STAGING_DIR"/*okupe*; do
    [ -f "$f" ] && mv "$f" "$STAGING_DIR/okupe.mp3"
done

# Session tracks (all files matching *buoys-session* in order → track-1 through track-7)
idx=1
for f in $(ls "$STAGING_DIR"/*buoys-session* 2>/dev/null | sort); do
    [ -f "$f" ] && mv "$f" "$STAGING_DIR/session-dobrichlapci-track-$idx.wav" && idx=$((idx+1))
done

# Upload from staging directory (via Docker)
echo "  Uploading to S3..."
docker run --rm \
    --dns 8.8.8.8 \
    --add-host s3.eu-west-1.amazonaws.com:52.95.110.1 \
    -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
    -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
    -e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-eu-west-1} \
    -v "$STAGING_DIR:/data" \
    -v "${SCRIPT_DIR}:/workspace" \
    -w /workspace \
    amazon/aws-cli s3 cp \
        "/data/" \
        "s3://$BUCKET_NAME/tracks/" \
        --region ${AWS_DEFAULT_REGION:-eu-west-1} \
        --content-type "application/octet-stream" \
        --recursive \
        --no-verify-ssl

echo ""
echo "  Files uploaded with clean lowercase names."

echo ""
echo "========================================"
echo "  Upload complete!"
echo "========================================"
echo ""
echo "Files uploaded to: s3://$BUCKET_NAME/tracks/"
echo ""
echo "To verify:"
echo "  aws s3 ls s3://$BUCKET_NAME/tracks/"
echo ""
echo "Next: Update the API_BASE_URL in index.html and library.html"
echo "with the API Gateway endpoint from:"
echo "  terraform output api_endpoint"