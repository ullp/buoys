terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================
# Variables
# ============================================================
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1" # Ireland — good latency for Europe
}

variable "bucket_name" {
  description = "Name of the S3 bucket for audio files"
  type        = string
}

variable "domain_name" {
  description = "Your GitHub Pages domain (e.g., buoys.example.com or ullp.github.io/buoys)"
  type        = string
}

variable "api_gateway_stage" {
  description = "API Gateway stage name"
  type        = string
  default     = "v1"
}

variable "cloudfront_public_key_path" {
  description = "Path to the CloudFront public key PEM file"
  type        = string
}

variable "cloudfront_private_key_ssm_path" {
  description = "SSM Parameter Store path for the CloudFront private key PEM"
  type        = string
  default     = "/buoys/cloudfront-private-key"
}

# ============================================================
# S3 Bucket (private)
# ============================================================
resource "aws_s3_bucket" "media" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ============================================================
# CloudFront Origin Access Control (OAC)
# ============================================================
resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.bucket_name}-oac"
  description                       = "OAC for ${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ============================================================
# S3 Bucket Policy (allow only CloudFront via OAC)
# ============================================================
data "aws_iam_policy_document" "s3_cloudfront" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.media.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = data.aws_iam_policy_document.s3_cloudfront.json
}

# ============================================================
# CloudFront Key Group for signed URLs
# ============================================================
resource "aws_cloudfront_public_key" "signer" {
  comment     = "Key for signing CloudFront URLs for ${var.bucket_name}"
  encoded_key = file(var.cloudfront_public_key_path)
  name        = "${var.bucket_name}-signing-key"
}

resource "aws_cloudfront_key_group" "signer" {
  comment = "Key group for signing CloudFront URLs for ${var.bucket_name}"
  items   = [aws_cloudfront_public_key.signer.id]
  name    = "${var.bucket_name}-key-group"
}

# ============================================================
# CloudFront Distribution
# ============================================================
resource "aws_cloudfront_distribution" "media" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN for Buoys media files"
  default_root_object = ""
  price_class         = "PriceClass_100" # US, Canada, Europe only

  origin {
    domain_name              = aws_s3_bucket.media.bucket_regional_domain_name
    origin_id                = "s3-media"
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-media"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"

    # Require signed URLs for all content
    trusted_key_groups = [aws_cloudfront_key_group.signer.id]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # No custom error responses needed

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name    = "buoys-media"
    Project = "buoys"
  }
}

# ============================================================
# Lambda Function (signed URL generator)
# ============================================================
resource "aws_iam_role" "lambda" {
  name = "${var.bucket_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow Lambda to read the private key from SSM Parameter Store
resource "aws_iam_role_policy" "lambda_ssm" {
  name = "${var.bucket_name}-lambda-ssm"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.cloudfront_private_key_ssm_path}"
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "signed_url" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "${var.bucket_name}-signed-url"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      CLOUDFRONT_DOMAIN          = aws_cloudfront_distribution.media.domain_name
      CLOUDFRONT_KEY_PAIR_ID     = aws_cloudfront_public_key.signer.id
      PRIVATE_KEY_SSM_PATH       = var.cloudfront_private_key_ssm_path
      PREVIEW_DURATION_SECONDS   = "20"
      RENT_DURATION_HOURS        = "24"
      BUY_DURATION_DAYS          = "365"
    }
  }
}

# ============================================================
# API Gateway (REST API)
# ============================================================
resource "aws_api_gateway_rest_api" "media" {
  name        = "${var.bucket_name}-api"
  description = "API for generating signed CloudFront URLs for Buoys media"
}

resource "aws_api_gateway_resource" "audio" {
  rest_api_id = aws_api_gateway_rest_api.media.id
  parent_id   = aws_api_gateway_rest_api.media.root_resource_id
  path_part   = "audio"
}

resource "aws_api_gateway_resource" "audio_track" {
  rest_api_id = aws_api_gateway_rest_api.media.id
  parent_id   = aws_api_gateway_resource.audio.id
  path_part   = "{trackId}"
}

resource "aws_api_gateway_method" "audio_track_get" {
  rest_api_id   = aws_api_gateway_rest_api.media.id
  resource_id   = aws_api_gateway_resource.audio_track.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "audio_track_get" {
  rest_api_id             = aws_api_gateway_rest_api.media.id
  resource_id             = aws_api_gateway_resource.audio_track.id
  http_method             = aws_api_gateway_method.audio_track_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.signed_url.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signed_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.media.execution_arn}/*/*/*"
}

resource "aws_api_gateway_deployment" "media" {
  depends_on = [aws_api_gateway_integration.audio_track_get]

  rest_api_id = aws_api_gateway_rest_api.media.id
  stage_name  = var.api_gateway_stage
}

# ============================================================
# Outputs
# ============================================================
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.media.domain_name
}

output "api_endpoint" {
  value = "${aws_api_gateway_deployment.media.invoke_url}/audio"
}

output "s3_bucket" {
  value = aws_s3_bucket.media.id
}

output "cloudfront_key_pair_id" {
  value = aws_cloudfront_public_key.signer.id
}