#!/bin/bash

# Script to force AgentCore Runtime to update with new environment variables
# This triggers the runtime to restart and pick up new OTEL configuration

set -e

RUNTIME_ID="${RUNTIME_ID:-solutionChatbotAgentCore_ultraCyan-Mi81qTDRE7}"
REGION="${AWS_REGION:-ap-northeast-1}"

echo "=========================================="
echo "Forcing AgentCore Runtime Environment Update"
echo "=========================================="
echo "Runtime ID: ${RUNTIME_ID}"
echo "Region: ${REGION}"
echo ""

# Get current runtime configuration
echo "Step 1: Getting current runtime configuration..."
CURRENT_CONFIG=$(aws bedrock-agentcore get-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --region "${REGION}")

# Extract necessary fields
RUNTIME_NAME=$(echo "$CURRENT_CONFIG" | jq -r '.agentRuntime.agentRuntimeName')
ROLE_ARN=$(echo "$CURRENT_CONFIG" | jq -r '.agentRuntime.roleArn')
CONTAINER_URI=$(echo "$CURRENT_CONFIG" | jq -r '.agentRuntime.agentRuntimeArtifact.containerConfiguration.containerUri')
NETWORK_MODE=$(echo "$CURRENT_CONFIG" | jq -r '.agentRuntime.networkConfiguration.networkMode')

echo "Runtime Name: ${RUNTIME_NAME}"
echo "Container URI: ${CONTAINER_URI}"
echo "Network Mode: ${NETWORK_MODE}"
echo ""

# Build the update command with REQUIRED environment variables
# This will trigger the runtime to restart with new env vars
echo "Step 2: Updating runtime with new OTEL environment variables..."
aws bedrock-agentcore update-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --agent-runtime-name "${RUNTIME_NAME}" \
  --region "${REGION}" \
  --no-paginate

echo ""
echo "=========================================="
echo "✅ Runtime update initiated"
echo "=========================================="
echo "The runtime will restart with new environment variables."
echo "This may take 5-10 minutes. Monitor the logs for the new configuration."
echo ""
echo "To check status:"
echo "aws bedrock-agentcore get-agent-runtime --agent-runtime-id ${RUNTIME_ID} --region ${REGION} --query 'agentRuntime.agentRuntimeStatus'"
echo ""
echo "To monitor logs:"
echo "aws logs tail /aws/bedrock-agentcore/runtimes/${RUNTIME_NAME}-DEFAULT --region ${REGION} --follow"
