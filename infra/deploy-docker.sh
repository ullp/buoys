#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Docker-based deployment for Buoys media infrastructure
# No local tools needed — uses Docker containers only.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Buoys Media Infrastructure Deployment${NC}"
echo -e "${BLUE}  (via Docker)${NC}"
echo -e "${BLUE}========================================${NC}"

# ============================================================
# Configuration — set these before running!
# ============================================================
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-buoys-media-files-$(date +%s)}"
GITHUB_PAGES_DOMAIN="${GITHUB_PAGES_DOMAIN:-ullp.github.io}"

# Check AWS credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo -e "${RED}ERROR: AWS credentials not set.${NC}"
    echo ""
    echo "Set them as environment variables or edit this script:"
    echo "  export AWS_ACCESS_KEY_ID=YOUR_KEY"
    echo "  export AWS_SECRET_ACCESS_KEY=YOUR_SECRET"
    echo ""
    echo "Or pass them inline:"
    echo "  AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... ./deploy-docker.sh"
    exit 1
fi

# Check Docker
if ! command -v docker &>/dev/null; then
    echo -e "${RED}ERROR: Docker not found. Please install Docker first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ AWS credentials provided${NC}"
echo -e "${GREEN}✓ Docker available${NC}"
echo -e "  Region:     ${YELLOW}${AWS_DEFAULT_REGION}${NC}"
echo -e "  Bucket:     ${YELLOW}${S3_BUCKET_NAME}${NC}"
echo -e "  Domain:     ${YELLOW}${GITHUB_PAGES_DOMAIN}${NC}"
echo ""

# Docker run helper — uses the same AWS credentials and working directory
DOCKER_BASE="docker run --rm \
    -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
    -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
    -e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} \
    -v ${SCRIPT_DIR}:/workspace \
    -w /workspace"

DOCKER_TERRAFORM="${DOCKER_BASE} hashicorp/terraform:1.9"
DOCKER_AWS_CLI="${DOCKER_BASE} amazon/aws-cli"

# ============================================================
# Step 1: Generate CloudFront signing keys
# ============================================================
echo -e "${BLUE}[1/7]${NC} Generating CloudFront signing keys..."
if [ ! -f cloudfront-private-key.pem ]; then
    docker run --rm -v "${SCRIPT_DIR}:/workspace" -w /workspace \
        alpine:latest \
        sh -c "apk add --no-cache openssl && \
               openssl genrsa -out cloudfront-private-key.pem 2048 && \
               openssl rsa -pubout -in cloudfront-private-key.pem -out cloudfront-public-key.pem"
    echo -e "${GREEN}  → Generated cloudfront-private-key.pem and cloudfront-public-key.pem${NC}"
else
    echo -e "${YELLOW}  → Keys already exist, skipping.${NC}"
fi

# ============================================================
# Step 2: Create terraform.tfvars
# ============================================================
echo ""
echo -e "${BLUE}[2/7]${NC} Creating terraform.tfvars..."
cat > terraform.tfvars <<EOF
bucket_name                = "${S3_BUCKET_NAME}"
domain_name                = "${GITHUB_PAGES_DOMAIN}"
cloudfront_public_key_path = "cloudfront-public-key.pem"
cloudfront_private_key_ssm_path = "/buoys/cloudfront-private-key"
aws_region                 = "${AWS_DEFAULT_REGION}"
EOF
echo -e "${GREEN}  → Created terraform.tfvars${NC}"

# ============================================================
# Step 3: Install Lambda dependencies
# ============================================================
echo ""
echo -e "${BLUE}[3/7]${NC} Installing Lambda dependencies..."
docker run --rm -v "${SCRIPT_DIR}/lambda:/lambda" -w /lambda \
    node:20-alpine \
    sh -c "npm install --production 2>&1 | tail -1"
echo -e "${GREEN}  → Lambda dependencies installed${NC}"

# ============================================================
# Step 4: Terraform init
# ============================================================
echo ""
echo -e "${BLUE}[4/7]${NC} Initializing Terraform..."
${DOCKER_TERRAFORM} init
echo -e "${GREEN}  → Terraform initialized${NC}"

# ============================================================
# Step 5: Terraform apply
# ============================================================
echo ""
echo -e "${BLUE}[5/7]${NC} Applying infrastructure (this may take 5-10 minutes)..."
${DOCKER_TERRAFORM} apply -auto-approve
echo -e "${GREEN}  → Infrastructure deployed${NC}"

# ============================================================
# Step 6: Store private key in SSM
# ============================================================
echo ""
echo -e "${BLUE}[6/7]${NC} Storing private key in SSM Parameter Store..."
PRIVATE_KEY=$(cat cloudfront-private-key.pem)
${DOCKER_AWS_CLI} ssm put-parameter \
    --name "/buoys/cloudfront-private-key" \
    --type "SecureString" \
    --value "${PRIVATE_KEY}" \
    --overwrite
echo -e "${GREEN}  → Private key stored in SSM${NC}"

# ============================================================
# Step 7: Upload audio files to S3
# ============================================================
echo ""
echo -e "${BLUE}[7/7]${NC} Uploading audio files to S3..."
if [ -d "../tracks" ]; then
    ${DOCKER_AWS} --env AWS_PAGER="" amazon/aws-cli s3 sync \
        "/workspace/../tracks/" \
        "s3://${S3_BUCKET_NAME}/tracks/" \
        --no-progress
    echo -e "${GREEN}  → Audio files uploaded${NC}"
else
    echo -e "${YELLOW}  → No ../tracks/ directory found. You can upload files later with:${NC}"
    echo "    docker run --rm -v $(pwd)/../tracks:/data amazon/aws-cli s3 sync /data/ s3://${S3_BUCKET_NAME}/tracks/"
fi

# ============================================================
# Get outputs
# ============================================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Deployment complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Extract outputs from Terraform
OUTPUTS=$(${DOCKER_TERRAFORM} output -json)
API_ENDPOINT=$(echo "$OUTPUTS" | jq -r '.api_endpoint.value')
CLOUDFRONT_DOMAIN=$(echo "$OUTPUTS" | jq -r '.cloudfront_domain.value')
S3_BUCKET_OUT=$(echo "$OUTPUTS" | jq -r '.s3_bucket.value')

echo -e "  ${YELLOW}API Endpoint:${NC}      ${GREEN}${API_ENDPOINT}${NC}"
echo -e "  ${YELLOW}CloudFront URL:${NC}    https://${CLOUDFRONT_DOMAIN}/"
echo -e "  ${YELLOW}S3 Bucket:${NC}         ${S3_BUCKET_OUT}"
echo ""
echo -e "${BLUE}── Next steps ──${NC}"
echo ""
echo -e "1. Update the API_BASE_URL in these files:"
echo -e "   ${YELLOW}../index.html${NC}"
echo -e "   ${YELLOW}../library.html${NC}"
echo ""
echo -e "   Replace:"
echo -e "   ${YELLOW}const API_BASE_URL = 'https://YOUR_API_ID.execute-api.YOUR_REGION.amazonaws.com/v1/audio'${NC}"
echo -e "   With:"
echo -e "   ${GREEN}const API_BASE_URL = '${API_ENDPOINT}'${NC}"
echo ""
echo -e "2. Wait ~5 minutes for CloudFront to deploy globally."
echo -e "3. Push the updated HTML files to GitHub."
echo ""
echo -e "${BLUE}========================================${NC}"