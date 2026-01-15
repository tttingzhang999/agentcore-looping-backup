#!/bin/bash

# Script to manually build and push Docker image to ECR
# This is useful when you've updated the model ID or other source code

set -e

# Get AWS account ID and region from Terraform state or environment
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-593713876380}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
APP_NAME="${APP_NAME:-ultracyan}"

ECR_REPOSITORY="bedrock-agentcore/${APP_NAME}"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"

echo "=========================================="
echo "Building and pushing Docker image to ECR"
echo "=========================================="
echo "ECR Repository: ${ECR_REPOSITORY}"
echo "ECR URI: ${ECR_URI}"
echo "Region: ${AWS_REGION}"
echo ""

# Step 1: Login to ECR
echo "Step 1: Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URI}

# Step 2: Build Docker image
echo ""
echo "Step 2: Building Docker image..."
docker build -t ${ECR_REPOSITORY}:latest -t ${ECR_URI}:latest .

# Step 3: Push Docker image
echo ""
echo "Step 3: Pushing Docker image to ECR..."
docker push ${ECR_URI}:latest

echo ""
echo "=========================================="
echo "✅ Successfully pushed Docker image to ECR"
echo "=========================================="
echo "Image URI: ${ECR_URI}:latest"
echo ""
echo "Note: After pushing, you may need to update the AgentCore Runtime"
echo "      to use the new image, or wait for it to automatically pull the latest tag."

