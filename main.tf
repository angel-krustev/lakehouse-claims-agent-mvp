# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
/**
 * Secure Insurance Claims Copilot - app configuration (Terraform equivalent of template.yaml).
 *
 *  - PEP on ECS Fargate behind an internal ALB (Plane A, 8080, HTTPS) - Plane B (8081) is never on the ALB.
 *  - Bedrock AgentCore Runtime agent (VPC mode), called by clients with their Entra ID JWT (inbound JWT
 *    authorizer, no AWS keys). It reaches Plane B only through a Lambda proxy whose verified role is the
 *    x-amzn-caller-arn the PEP sees.
 *  - IAM roles come from ./iam/vt-identity (mirror of iam/vt-identity-stack.yml).
 *  - The VPC subnets, NAT and security groups come from ./network (separate state), found by Name tag.
 *
 * Order: apply ./network first, then push the agent image (scripts/deploy-agent-image.ps1), then apply
 * this with deploy_agent_runtime=true. (Apply without it first if you want the PEP and ALB up before the
 * image exists.)
 */
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.12"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "lakehouse-claims-agent-mvp"
      Component = "claims-copilot"
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  type    = string
  default = "vpc-9f4ad5e6"
}

variable "internal_certificate_arn" {
  description = "ACM certificate for the ALB HTTPS listener."
  type        = string
  default     = "arn:aws:acm:us-east-1:991536801739:certificate/44ca45ca-daa3-43cd-9a59-9b39dc3a4e2f"
}

variable "pep_container_image" {
  type    = string
  default = "991536801739.dkr.ecr.us-east-1.amazonaws.com/agentcore-tip-mcp-test:7979d40"
}

variable "pep_cpu_architecture" {
  description = "CPU architecture of the PEP image."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.pep_cpu_architecture)
    error_message = "pep_cpu_architecture must be ARM64 or X86_64."
  }
}

variable "pep_desired_count" {
  description = "Keep at 1. The PEP keeps sessions in memory: /sessions/init (through the ALB) and the agent's tool calls (through Cloud Map DNS) are routed independently, so with 2 or more tasks a session created on one task is unknown to the others and tool calls fail intermittently with 'Invalid or expired session_ref'. Raise it only if the PEP is given a shared session store."
  type        = number
  default     = 1

  validation {
    condition     = var.pep_desired_count >= 1
    error_message = "pep_desired_count must be at least 1."
  }
}

variable "entra_tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "entra_client_id" {
  description = "Entra ID application (client) ID; the audience of the ID token."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Existing IAM OIDC provider for Entra ID (arn:aws:iam::<acct>:oidc-provider/login.microsoftonline.com/<tenant>/v2.0)."
  type        = string
}

variable "sso_application_arn" {
  description = "IAM Identity Center application ARN used for trusted identity propagation (the PEP's SSO_CLIENT_ID)."
  type        = string
}

variable "athena_workgroup" {
  type    = string
  default = "idc-wg"
}

variable "athena_database_name" {
  type    = string
  default = "insurance_analytics"
}

variable "service_discovery_domain" {
  description = "Private DNS domain in the VPC; Plane B resolves as plane-b.<domain>."
  type        = string
  default     = "claims-copilot.internal"
}

variable "deploy_agent_runtime" {
  description = "Set to true after the agent image has been pushed (scripts/deploy-agent-image.ps1)."
  type        = bool
  default     = false
}

variable "agent_repository_name" {
  description = "Existing ECR repository holding the agent image."
  type        = string
  default     = "lakehouse-claims-agent-mvp"
}

variable "agent_image_tag" {
  type    = string
  default = "v0.2.0"
}

variable "model_id" {
  description = "Bedrock model or inference profile ID the agent uses (Converse API with tool use)."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "model_temperature" {
  description = "Sampling temperature for the agent's model calls. 0 gives the most repeatable SQL."
  type        = number
  default     = 0

  validation {
    condition     = var.model_temperature >= 0 && var.model_temperature <= 1
    error_message = "model_temperature must be between 0 and 1."
  }
}

variable "model_top_p" {
  description = "Optional nucleus sampling (0-1). Leave empty to omit; recent Claude models reject temperature and topP together."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^$|^(0(\\.[0-9]+)?|1(\\.0+)?)$", var.model_top_p))
    error_message = "model_top_p must be empty or a number between 0 and 1."
  }
}

variable "model_max_tokens" {
  description = "Maximum output tokens per model call."
  type        = number
  default     = 4096

  validation {
    condition     = var.model_max_tokens >= 1
    error_message = "model_max_tokens must be at least 1."
  }
}

locals {
  plane_b_url = "http://plane-b.${var.service_discovery_domain}:8081"
}

# ---------------------------------------------------------------------------
# IAM: PEP base role, OIDC bootstrap role and carrier role (never created inline here)
# ---------------------------------------------------------------------------
module "identity" {
  source = "./iam/vt-identity"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_audiences    = [var.entra_client_id]
  athena_workgroup  = var.athena_workgroup
}

# ---------------------------------------------------------------------------
# Core network (separate state, see ./network): private subnets, NAT and security groups.
# Looked up by Name tag, so this configuration can fail or be destroyed without touching the
# subnets and security groups that AgentCore network interfaces keep for hours.
# Apply ./network first.
# ---------------------------------------------------------------------------
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["claims-copilot-private-a", "claims-copilot-private-b"]
  }
}

data "aws_security_group" "alb" {
  vpc_id = var.vpc_id
  tags   = { Name = "claims-copilot-alb" }
}

data "aws_security_group" "pep_task" {
  vpc_id = var.vpc_id
  tags   = { Name = "claims-copilot-pep-task" }
}

data "aws_security_group" "agent_runtime" {
  vpc_id = var.vpc_id
  tags   = { Name = "claims-copilot-agent-runtime" }
}

data "aws_security_group" "pep_proxy" {
  vpc_id = var.vpc_id
  tags   = { Name = "claims-copilot-pep-proxy" }
}

# ---------------------------------------------------------------------------
# ECS Fargate: PEP
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "pep" {
  name = "claims-copilot-pep"
}

resource "aws_cloudwatch_log_group" "pep" {
  name              = "/ecs/claims-copilot-pep"
  retention_in_days = 30
}

resource "aws_iam_role" "pep_execution" {
  name_prefix = "claims-copilot-pep-exec-"
  description = "ECS task execution role (image pull and logs only)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pep_execution" {
  role       = aws_iam_role.pep_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "pep" {
  family                   = "claims-copilot-pep"
  cpu                      = "1024"
  memory                   = "2048"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.pep_execution.arn
  # PEP base role from the identity module; it may only assume the carrier role.
  task_role_arn = module.identity.pep_service_role_arn

  runtime_platform {
    cpu_architecture        = var.pep_cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = "pep"
    image     = var.pep_container_image
    essential = true
    portMappings = [
      { containerPort = 8080, protocol = "tcp" },
      { containerPort = 8081, protocol = "tcp" },
    ]
    environment = [
      { name = "PEP_PLANE_A_PORT", value = "8080" },
      { name = "PEP_PLANE_B_PORT", value = "8081" },
      { name = "PEP_DEFAULT_DATABASE", value = var.athena_database_name },
      { name = "ATHENA_DATABASE", value = var.athena_database_name },
      { name = "ATHENA_WORKGROUP", value = var.athena_workgroup },
      { name = "IDP", value = "entra-id" },
      { name = "OIDC_CLIENT_ID", value = var.entra_client_id },
      { name = "OIDC_DISCOVERY_URL", value = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0/.well-known/openid-configuration" },
      { name = "SSO_CLIENT_ID", value = var.sso_application_arn },
      { name = "OIDC_ROLE_ARN", value = module.identity.oidc_role_arn },
      { name = "TIP_ROLE_ARN", value = module.identity.enhanced_role_arn },
      { name = "AWS_REGION", value = var.aws_region },
      # The PEP honours x-pep-agent-role-arn only from a trusted proxy, and only for an allow-listed agent.
      { name = "PEP_TRUSTED_PROXY_ROLES", value = aws_iam_role.pep_proxy.arn },
      { name = "PEP_ALLOWED_AGENT_ROLES", value = aws_iam_role.agent_runtime.arn },
    ]
    # The image ships without curl/wget; probe Plane A with its bundled Python.
    healthCheck = {
      command     = ["CMD-SHELL", "python3.12 -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8080/ping', timeout=4).status==200 else 1)\" || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 5
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.pep.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "pep"
      }
    }
  }])
}

# Private DNS for Plane B so the runtime reaches task IPs directly. The ALB never sees 8081.
resource "aws_service_discovery_private_dns_namespace" "pep" {
  name = var.service_discovery_domain
  vpc  = var.vpc_id
}

resource "aws_service_discovery_service" "plane_b" {
  name = "plane-b"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.pep.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_ecs_service" "pep" {
  name                              = "claims-copilot-pep"
  cluster                           = aws_ecs_cluster.pep.id
  task_definition                   = aws_ecs_task_definition.pep.arn
  launch_type                       = "FARGATE"
  desired_count                     = var.pep_desired_count
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [data.aws_security_group.pep_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.plane_a.arn
    container_name   = "pep"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.plane_b.arn
  }

  depends_on = [aws_lb_listener.plane_a]
}

# ---------------------------------------------------------------------------
# Internal ALB: Plane A (8080) only
# ---------------------------------------------------------------------------
resource "aws_lb" "plane_a" {
  name_prefix        = "pepa-"
  internal           = true
  load_balancer_type = "application"
  subnets            = data.aws_subnets.private.ids
  security_groups    = [data.aws_security_group.alb.id]
}

resource "aws_lb_target_group" "plane_a" {
  name_prefix = "pepa-"
  vpc_id      = var.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 8080

  health_check {
    path                = "/ping"
    port                = "8080"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_lb_listener" "plane_a" {
  load_balancer_arn = aws_lb.plane_a.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.internal_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.plane_a.arn
  }
}

# ---------------------------------------------------------------------------
# Plane B proxy Lambda, one per agent. AWS authenticates the agent's lambda:InvokeFunction call; this
# function then presents ITS OWN role ARN as x-amzn-caller-arn and the agent's role ARN (fixed in
# AGENT_ROLE_ARN, never taken from the request) as x-pep-agent-role-arn. To add an agent, deploy another
# copy of this function with that agent's role in AGENT_ROLE_ARN and grant only that role invoke rights.
# Only this function's security group may reach 8081.
# The code is lambda/pep_proxy.py (also inlined in template.yaml).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "pep_proxy" {
  name_prefix = "claims-copilot-proxy-"
  description = "Plane B proxy. Its ARN is the caller identity the PEP sees; add it to the PEP allow-list."

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "pep_proxy" {
  role       = aws_iam_role.pep_proxy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "pep_proxy" {
  name              = "/aws/lambda/claims-copilot-pep-proxy"
  retention_in_days = 30
}

data "archive_file" "pep_proxy" {
  type        = "zip"
  output_path = "${path.module}/.build/pep_proxy.zip"

  source {
    filename = "index.py"
    content  = file("${path.module}/lambda/pep_proxy.py")
  }
}

resource "aws_lambda_function" "pep_proxy" {
  function_name    = "claims-copilot-pep-proxy"
  description      = "Forwards agent tool calls to PEP Plane B with a verified x-amzn-caller-arn."
  runtime          = "python3.12"
  handler          = "index.handler"
  role             = aws_iam_role.pep_proxy.arn
  timeout          = 130
  memory_size      = 256
  filename         = data.archive_file.pep_proxy.output_path
  source_code_hash = data.archive_file.pep_proxy.output_base64sha256

  vpc_config {
    subnet_ids         = data.aws_subnets.private.ids
    security_group_ids = [data.aws_security_group.pep_proxy.id]
  }

  environment {
    variables = {
      PEP_PLANE_B_URL      = local.plane_b_url
      CALLER_ARN           = aws_iam_role.pep_proxy.arn
      AGENT_ROLE_ARN       = aws_iam_role.agent_runtime.arn
      PEP_DEFAULT_DATABASE = var.athena_database_name
    }
  }

  depends_on = [aws_iam_role_policy_attachment.pep_proxy, aws_cloudwatch_log_group.pep_proxy]
}

# ---------------------------------------------------------------------------
# Bedrock AgentCore Runtime (agent container, VPC mode)
# ---------------------------------------------------------------------------
data "aws_ecr_repository" "agent" {
  name = var.agent_repository_name
}

resource "aws_iam_role" "agent_runtime" {
  name_prefix = "claims-copilot-agent-"
  description = "AgentCore Runtime execution role. Model invocation, image pull and telemetry only."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "agent_runtime" {
  name = "agent-runtime"
  role = aws_iam_role.agent_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "EcrAuth", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      { Sid = "EcrPull", Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = data.aws_ecr_repository.agent.arn },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DescribeLogStreams", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"
      },
      {
        Sid      = "LogGroups"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
      },
      {
        Sid      = "Telemetry"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      },
      {
        Sid       = "Metrics"
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" } }
      },
      {
        Sid    = "WorkloadIdentity"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/*",
        ]
      },
      { Sid = "InvokePepProxy", Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.pep_proxy.arn },
      {
        Sid    = "InvokeModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
        ]
      },
    ]
  })
}

resource "aws_bedrockagentcore_agent_runtime" "claims_copilot" {
  count = var.deploy_agent_runtime ? 1 : 0

  agent_runtime_name = "claims_copilot_agent"
  description        = "Claims copilot agent. Discovers the schema and queries data through PEP Plane B MCP tools."
  role_arn           = aws_iam_role.agent_runtime.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${data.aws_ecr_repository.agent.repository_url}:${var.agent_image_tag}"
    }
  }

  network_configuration {
    network_mode = "VPC"

    network_mode_config {
      security_groups = [data.aws_security_group.agent_runtime.id]
      subnets         = data.aws_subnets.private.ids
    }
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  # Inbound auth is the caller's Entra ID JWT, validated at the edge. No request-header allow-list is set,
  # so the Authorization header never reaches the agent code. The audience is the app's client ID, the same
  # one the PEP validates (MVP trade-off, see README).
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0/.well-known/openid-configuration"
      allowed_audience = [var.entra_client_id]
    }
  }

  environment_variables = {
    # The agent has no route to Plane B; it can only invoke this function.
    PEP_PROXY_FUNCTION   = aws_lambda_function.pep_proxy.function_name
    PEP_DEFAULT_DATABASE = var.athena_database_name
    MODEL_ID             = var.model_id
    MODEL_TEMPERATURE    = tostring(var.model_temperature)
    MODEL_TOP_P          = var.model_top_p
    MODEL_MAX_TOKENS     = tostring(var.model_max_tokens)
  }

  depends_on = [aws_iam_role_policy.agent_runtime]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "plane_a_url" {
  description = "Set as PEP_PLANE_A_URL in .env (internal ALB, HTTPS, Plane A only)."
  value       = "https://${aws_lb.plane_a.dns_name}"
}

output "agent_image_uri" {
  description = "Agent image the runtime pulls (push it with scripts/deploy-agent-image.ps1)."
  value       = "${data.aws_ecr_repository.agent.repository_url}:${var.agent_image_tag}"
}

output "agent_runtime_arn" {
  description = "Set as BEDROCK_AGENT_ID in .env."
  value       = try(aws_bedrockagentcore_agent_runtime.claims_copilot[0].agent_runtime_arn, null)
}

output "agent_runtime_id" {
  value = try(aws_bedrockagentcore_agent_runtime.claims_copilot[0].agent_runtime_id, null)
}

output "agent_caller_arn" {
  description = "Proxy role the PEP sees on Plane B (x-amzn-caller-arn). Already set as PEP_TRUSTED_PROXY_ROLES on the PEP task."
  value       = aws_iam_role.pep_proxy.arn
}

output "agent_role_arn" {
  description = "Agent role the proxy forwards in x-pep-agent-role-arn. Already set as PEP_ALLOWED_AGENT_ROLES on the PEP task."
  value       = aws_iam_role.agent_runtime.arn
}

output "pep_proxy_function_name" {
  description = "Plane B proxy Lambda; the only invoker is the agent runtime role."
  value       = aws_lambda_function.pep_proxy.function_name
}

output "plane_b_internal_url" {
  description = "VPC-internal Plane B endpoint used by the proxy Lambda only. Never expose it."
  value       = local.plane_b_url
}
