#!/bin/bash

# Script to force AgentCore Runtime to pull new container image
# This is needed when you've updated the ECR image but Runtime hasn't picked it up

set -e

# Get runtime ID from Terraform state or set manually
RUNTIME_ID="${RUNTIME_ID:-solutionChatbotAgentCore_ultraCyan-Mi81qTDRE7}"
REGION="${AWS_REGION:-ap-northeast-1}"

echo "=========================================="
echo "Forcing AgentCore Runtime to update"
echo "=========================================="
echo "Runtime ID: ${RUNTIME_ID}"
echo "Region: ${REGION}"
echo ""

# Get current runtime configuration
echo "Step 1: Getting current runtime configuration..."
CURRENT_CONFIG=$(aws bedrock-agentcore get-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --region "${REGION}")

# Extract container URI
CONTAINER_URI=$(echo "$CURRENT_CONFIG" | jq -r '.agentRuntime.agentRuntimeArtifact.containerConfiguration.containerUri')

echo "Current container URI: ${CONTAINER_URI}"
echo ""

# Update the runtime with the same URI to trigger a refresh
# This forces AgentCore to re-pull the :latest image
echo "Step 2: Updating runtime to trigger image refresh..."
aws bedrock-agentcore update-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${CONTAINER_URI}\"}}" \
  --region "${REGION}"

echo ""
echo "=========================================="
echo "✅ Runtime update initiated"
echo "=========================================="
echo "The runtime will now pull the latest container image."
echo "This may take a few minutes. Check the runtime status in AWS Console."
echo ""
echo "To check status, run:"
echo "aws bedrock-agentcore get-agent-runtime --agent-runtime-id ${RUNTIME_ID} --region ${REGION}"

