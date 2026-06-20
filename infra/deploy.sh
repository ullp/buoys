#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Deployment script for Buoys media infrastructure
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "  Buoys Media Infrastructure Deployment"
echo "========================================"

# ---- Step 1: Generate CloudFront signing keys (if not exist) ----
if [ ! -f cloudfront-private-key.pem ]; then
    echo ""
    echo "[1/7] Generating CloudFront signing keys..."
    openssl genrsa -out cloudfront-private-key.pem 2048
    openssl rsa -pubout -in cloudfront-private-key.pem -out cloudfront-public-key.pem
    echo "  -> Generated cloudfront-private-key.pem and cloudfront-public-key.pem"
else
    echo ""
    echo "[1/7] CloudFront keys already exist, skipping."
fi

# ---- Step 2: Copy terraform.tfvars if not exist ----
if [ ! -f terraform.tfvars ]; then
    echo ""
    echo "[2/7] Creating terraform.tfvars from example..."
    cp terraform.tfvars.example terraform.tfvars
    echo "  -> Edit terraform.tfvars with your values before proceeding!"
    echo "  -> Then re-run this script."
    exit 1
else
    echo ""
    echo "[2/7] terraform.tfvars found."
fi

# ---- Step 3: Install Lambda dependencies ----
echo ""
echo "[3/7] Installing Lambda dependencies..."
cd lambda
npm install --production
cd "$SCRIPT_DIR"

# ---- Step 4: Terraform init ----
echo ""
echo "[4/7] Initializing Terraform..."
terraform init

# ---- Step 5: Terraform plan ----
echo ""
echo "[5/7] Planning infrastructure..."
terraform plan -out=tfplan

# ---- Step 6: Terraform apply ----
echo ""
echo "[6/7] Applying infrastructure..."
terraform apply tfplan

# ---- Step 7: Store private key in SSM ----
echo ""
echo "[7/7] Storing private key in SSM Parameter Store..."
# Extract the SSM path from terraform.tfvars
SSM_PATH=$(grep cloudfront_private_key_ssm_path terraform.tfvars | awk -F'=' '{print $2}' | tr -d ' "')
if [ -z "$SSM_PATH" ]; then
    SSM_PATH="/buoys/cloudfront-private-key"
    echo "  -> Using default SSM path: $SSM_PATH"
fi

aws ssm put-parameter \
    --name "$SSM_PATH" \
    --type "SecureString" \
    --value "$(cat cloudfront-private-key.pem)" \
    --overwrite

echo ""
echo "========================================"
echo "  Deployment complete!"
echo "========================================"
echo ""
echo "Outputs:"
terraform output

echo ""
echo "Next steps:"
echo "  1. Upload your audio files to S3:"
echo "     aws s3 sync ../tracks/ s3://$(terraform output -raw s3_bucket)/tracks/"
echo ""
echo "  2. Update index.html and library.html with the API endpoint:"
echo "     API Endpoint: $(terraform output -raw api_endpoint)"
echo ""
echo "  3. Wait ~5 minutes for CloudFront to deploy, then test."