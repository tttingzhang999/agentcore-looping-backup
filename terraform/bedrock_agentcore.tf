################################################################################
# ECR Repository
################################################################################
resource "aws_ecr_repository" "agentcore_terraform_runtime" {
  name                 = "bedrock-agentcore/${lower(var.app_name)}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

data "aws_ecr_authorization_token" "token" {}

locals {
  src_files = fileset("../${path.root}/src", "**")
  src_hashes = [
    for f in local.src_files :
    filesha256("../${path.root}/src/${f}")
  ]

  # Collapse all file hashes into one
  src_hash = sha256(join("", local.src_hashes))
}

resource "null_resource" "docker_image" {
  depends_on = [aws_ecr_repository.agentcore_terraform_runtime]

  triggers = {
    src_hash = local.src_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOF
      source ~/.bash_profile || source ~/.profile || true

      if ! command -v docker &> /dev/null; then
        echo "Docker is not installed or not in PATH. Please install Docker and try again."
        exit 1
      fi

      aws ecr get-login-password | docker login --username AWS --password-stdin ${data.aws_ecr_authorization_token.token.proxy_endpoint}

      docker build -t ${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:latest ../${path.root}

      docker push ${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:latest
    EOF
  }
}

################################################################################
# MCP Lambda Function
################################################################################
data "archive_file" "mcp_lambda_zip" {
  type        = "zip"
  source_dir  = "../${path.root}/mcp/lambda"
  output_path = "../${path.root}/mcp_lambda.zip"
}

resource "aws_lambda_function" "mcp_lambda" {
  function_name = "${var.app_name}-McpLambda"
  role          = aws_iam_role.mcp_lambda_role.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.mcp_lambda_zip.output_path
  source_code_hash = data.archive_file.mcp_lambda_zip.output_base64sha256
}

resource "aws_iam_role" "mcp_lambda_role" {
  name = "${var.app_name}-McpLambdaRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mcp_lambda_basic" {
  role       = aws_iam_role.mcp_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

################################################################################
# AgentCore Gateway Roles
################################################################################

resource "aws_iam_role" "agentcore_gateway_role" {
  name               = "${var.app_name}-AgentCoreGatewayRole"
  assume_role_policy = data.aws_iam_policy_document.bedrock_agentcore_assume_role.json
}

resource "aws_iam_role_policy_attachment" "agentcore_gateway_permissions" {
  role       = aws_iam_role.agentcore_gateway_role.name
  policy_arn = "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess"
}

resource "aws_iam_role_policy" "agentcore_gateway_lambda_invoke" {
  role = aws_iam_role.agentcore_gateway_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["lambda:InvokeFunction"]
      Effect   = "Allow"
      Resource = [aws_lambda_function.mcp_lambda.arn]
    }]
  })
}

################################################################################
# AgentCore Gateway Inbound Auth - Cognito
################################################################################

resource "aws_cognito_user_pool" "cognito_user_pool" {
  name = "${var.app_name}-CognitoUserPool"
}

resource "aws_cognito_resource_server" "cognito_resource_server" {
  identifier   = "${var.app_name}-CognitoResourceServer"
  name         = "${var.app_name}-CognitoResourceServer"
  user_pool_id = aws_cognito_user_pool.cognito_user_pool.id
  scope {
    scope_description = "Basic access to ${var.app_name}"
    scope_name        = "basic"
  }
}

resource "aws_cognito_user_pool_client" "cognito_app_client" {
  name                                 = "${var.app_name}-CognitoUserPoolClient"
  user_pool_id                         = aws_cognito_user_pool.cognito_user_pool.id
  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.cognito_resource_server.identifier}/basic"]
  supported_identity_providers         = ["COGNITO"]
}

resource "aws_cognito_user_pool_domain" "cognito_domain" {
  domain       = "${lower(var.app_name)}-${data.aws_region.current.region}"
  user_pool_id = aws_cognito_user_pool.cognito_user_pool.id
}

locals {
  cognito_discovery_url = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.cognito_user_pool.id}/.well-known/openid-configuration"
}

################################################################################
# AgentCore Gateway
################################################################################

resource "aws_bedrockagentcore_gateway" "agentcore_gateway" {
  name            = "${var.app_name}-Gateway"
  protocol_type   = "MCP"
  role_arn        = aws_iam_role.agentcore_gateway_role.arn
  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.cognito_app_client.id]
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "agentcore_gateway_lambda_target" {
  name               = "${var.app_name}-Target"
  gateway_identifier = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.mcp_lambda.arn

        tool_schema {
          inline_payload {
            name        = "placeholder_tool"
            description = "Placeholder tool (no-op)."
            input_schema {
              type        = "object"
              description = "Example input schema for placeholder tool"
              property {
                name        = "string_param"
                type        = "string"
                description = "Example string parameter."
              }
              property {
                name        = "int_param"
                type        = "integer"
                description = "Example integer parameter."
              }
              property {
                name        = "float_array_param"
                type        = "array"
                description = "Example float array parameter."
                items {
                  type = "number"
                }
              }
            }
          }
        }
      }
    }
  }
}

################################################################################
# AgentCore Runtime IAM Roles
################################################################################

data "aws_iam_policy_document" "bedrock_agentcore_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agentcore_runtime_execution_role" {
  name        = "${var.app_name}-AgentCoreRuntimeRole"
  description = "Execution role for Bedrock AgentCore Runtime"

  assume_role_policy = data.aws_iam_policy_document.bedrock_agentcore_assume_role.json
}

# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-execution
resource "aws_iam_role_policy" "agentcore_runtime_execution_role_policy" {
  role = aws_iam_role.agentcore_runtime_execution_role.id
  name = "${var.app_name}-AgentCoreRuntimeExecutionPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRImageAccess"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [
          "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:CreateLogGroup",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans",
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data:*",
        ]
      },
      {
        Sid    = "ECRTokenAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetTraceSegmentDestination",
        ]
        Resource = [
          "*",
        ]
      },
      {
        Effect   = "Allow"
        Resource = "*"
        Action   = "cloudwatch:PutMetricData"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      },
      {
        Sid    = "GetAgentAccessToken"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/agentName-*",
        ]
      },
      {
        Sid    = "BedrockModelInvocation"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*",
        ]
      },
    ]
  })
}


################################################################################
# AgentCore Memory
################################################################################
resource "aws_bedrockagentcore_memory" "agentcore_memory" {
  name                  = "solutionChatbotAgentCore_memory_ultraCyan"
  description           = "Memory resource with 30 days event expiry"
  event_expiry_duration = 30
}
# Add a built-in strategy from https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/built-in-strategies.html or define a custom one
# Example of adding semantic memory
# resource "aws_bedrockagentcore_memory_strategy" "semantic" {
#  name        = "semantic-strategy"
#  memory_id   = aws_bedrockagentcore_memory.agentcore_memory.id
#  type        = "SEMANTIC"
#  description = "Semantic understanding strategy"
#  namespaces  = ["default"]
# }

################################################################################
# AgentCore Runtime
################################################################################
resource "aws_bedrockagentcore_agent_runtime" "agentcore_runtime" {
  agent_runtime_name = "solutionChatbotAgentCore_ultraCyan"
  role_arn           = aws_iam_role.agentcore_runtime_execution_role.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:latest"
    }
  }

  depends_on = [null_resource.docker_image, aws_bedrockagentcore_memory.agentcore_memory]

  network_configuration {
    network_mode = "PUBLIC"
  }
  environment_variables = {
    AWS_REGION            = data.aws_region.current.region
    MEMORY_ID             = aws_bedrockagentcore_memory.agentcore_memory.id
    GATEWAY_URL           = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_url
    COGNITO_CLIENT_ID     = aws_cognito_user_pool_client.cognito_app_client.id
    COGNITO_CLIENT_SECRET = aws_cognito_user_pool_client.cognito_app_client.client_secret
    COGNITO_TOKEN_URL     = "https://${aws_cognito_user_pool_domain.cognito_domain.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/token"
    COGNITO_SCOPE         = "${aws_cognito_resource_server.cognito_resource_server.identifier}/basic"
  }

}


################################################################################
# AgentCore Runtime Endpoints
################################################################################
resource "aws_bedrockagentcore_agent_runtime_endpoint" "dev_endpoint" {
  name                  = "DEV"
  agent_runtime_id      = aws_bedrockagentcore_agent_runtime.agentcore_runtime.agent_runtime_id
  agent_runtime_version = var.agent_runtime_version
}


resource "aws_bedrockagentcore_agent_runtime_endpoint" "prod_endpoint" {
  name                  = "PROD"
  agent_runtime_id      = aws_bedrockagentcore_agent_runtime.agentcore_runtime.agent_runtime_id
  agent_runtime_version = var.agent_runtime_version
  depends_on            = [aws_bedrockagentcore_agent_runtime_endpoint.dev_endpoint] # Prevents ConflictException
}

################################################################################
# CloudWatch Transaction Search Configuration
# Required for AgentCore Observability
# See: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html
################################################################################

# Step 1: Create CloudWatch Logs resource policy to allow X-Ray to send traces
# Note: aws/spans is a reserved log group name that X-Ray automatically creates
# when the first span is sent. We cannot manually create it.
# See: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search-ingesting-span-log-groups.html
# See: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-and-resource-policy.html
resource "aws_cloudwatch_log_resource_policy" "transaction_search_xray_access" {
  policy_name = "${var.app_name}-TransactionSearchXRayAccess"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TransactionSearchXRayAccess"
        Effect = "Allow"
        Principal = {
          Service = "xray.amazonaws.com"
        }
        Action = "logs:PutLogEvents"
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data:*"
        ]
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:xray:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Step 2: Configure X-Ray trace segment destination to CloudWatch Logs
# Note: Terraform AWS provider doesn't have a direct resource for this,
# so we use null_resource with AWS CLI command
# This command is idempotent - it will skip if already set to CloudWatchLogs
resource "null_resource" "xray_trace_segment_destination" {
  depends_on = [aws_cloudwatch_log_resource_policy.transaction_search_xray_access]

  provisioner "local-exec" {
    command = <<-EOT
      CURRENT_DEST=$(aws xray get-trace-segment-destination --region ${data.aws_region.current.region} --query 'Destination' --output text 2>/dev/null || echo "")
      if [ "$CURRENT_DEST" != "CloudWatchLogs" ]; then
        aws xray update-trace-segment-destination --destination CloudWatchLogs --region ${data.aws_region.current.region}
      else
        echo "X-Ray trace segment destination is already set to CloudWatchLogs, skipping update."
      fi
    EOT
  }

  triggers = {
    policy_id = aws_cloudwatch_log_resource_policy.transaction_search_xray_access.id
  }
}

# Step 3: Configure X-Ray indexing rule (optional, defaults to 1% sampling)
# Note: UpdateIndexingRule is an X-Ray API that doesn't have a direct Terraform resource
# This sets the sampling percentage for spans to be indexed (1% is free)
# Using null_resource to execute AWS CLI command
resource "null_resource" "xray_indexing_rule" {
  depends_on = [null_resource.xray_trace_segment_destination]

  provisioner "local-exec" {
    command = "aws xray update-indexing-rule --name 'Default' --rule '{\"Probabilistic\": {\"DesiredSamplingPercentage\": 1}}' --region ${data.aws_region.current.region} || true"
  }

  triggers = {
    trace_destination = null_resource.xray_trace_segment_destination.id
  }
}

################################################################################
# CloudWatch Logs Delivery Configuration for AgentCore Runtime
# Required for traces to flow: Runtime → X-Ray → aws/spans
# See: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html (Section 7)
################################################################################

# NOTE: CloudWatch Logs Delivery resources (sources, destinations, and deliveries)
# are AUTOMATICALLY created and managed by AgentCore runtime.
#
# When you create an AgentCore runtime, AWS automatically provisions:
# 1. Delivery sources (APPLICATION_LOGS and TRACES)
# 2. Delivery destinations (CWL for logs, XRAY for traces)
# 3. Deliveries (connections between sources and destinations)
#
# These resources are named like "WdDeliverySource-XXXXXXXXX" and are visible via:
#   aws logs describe-delivery-sources --region ap-northeast-1
#   aws logs describe-deliveries --region ap-northeast-1
#
# DO NOT attempt to create these in Terraform as it will cause conflicts.
#
# For traces to flow to aws/spans, only the following configuration is needed:
# ✅ X-Ray trace segment destination = CloudWatchLogs (configured above at line 466-483)
# ✅ Runtime IAM role with xray:PutTraceSegments permission (configured above at line 302-314)
# ✅ ADOT instrumentation in container CMD (configured in Dockerfile line 34)
#
# To verify the auto-created delivery configuration:
#   aws logs describe-deliveries --region ap-northeast-1 | jq '.deliveries[] | select(.deliverySourceName | contains("WdDeliverySource"))'
