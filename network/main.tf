# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
/**
 * Secure Insurance Claims Copilot - core network (Terraform equivalent of template-network.yaml).
 *
 * Long-lived and shared: private subnets, NAT gateway, route table, S3 gateway endpoint and the three
 * security groups. The app configuration in the repository root looks these up by their Name tags.
 * AgentCore Runtime keeps network interfaces in these subnets and security groups for hours after a
 * runtime is deleted, so they live in their own state, apart from the app that can fail or be destroyed.
 *
 * Usage:
 *   cd network
 *   terraform init
 *   terraform apply
 * Then apply the root (app) configuration. Destroy this one last, and only after the AgentCore network
 * interfaces are gone (up to 8 hours after the runtime is deleted).
 */
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.12"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "lakehouse-claims-agent-mvp"
      Component = "claims-copilot-network"
      ManagedBy = "Terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  type    = string
  default = "vpc-9f4ad5e6"
}

variable "nat_subnet_id" {
  description = "Existing PUBLIC subnet (route to the internet gateway) that hosts the NAT gateway."
  type        = string
  default     = "subnet-6295034e"
}

variable "private_subnet_cidrs" {
  description = "Two unused CIDR blocks inside the VPC for the private subnets (PEP, ALB and AgentCore Runtime)."
  type        = list(string)
  default     = ["172.31.96.0/20", "172.31.112.0/20"]
}

variable "private_subnet_az_ids" {
  description = "AZ IDs (not names) for the private subnets, in the same order as the CIDRs. In us-east-1 AgentCore Runtime supports only use1-az1, use1-az2 and use1-az4."
  type        = list(string)
  default     = ["use1-az2", "use1-az4"]
}

variable "vpn_or_streamlit_cidr" {
  description = "CIDR allowed to reach the internal ALB (Plane A). Only matches clients whose own address reaches the ALB (no address translation)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpn_security_group_id" {
  description = "Optional. Security group of a VPN gateway that translates client addresses (SNAT/masquerade), so the ALB sees the gateway's VPC address instead of the client's. The ALB then accepts HTTPS from this group."
  type        = string
  default     = ""

  validation {
    condition     = var.vpn_security_group_id == "" || can(regex("^sg-[0-9a-f]{8,17}$", var.vpn_security_group_id))
    error_message = "vpn_security_group_id must be empty or a security group ID such as sg-0123456789abcdef0."
  }
}

variable "create_s3_gateway_endpoint" {
  description = "Create the free S3 gateway endpoint on the private route table (keeps ECR layer downloads off the NAT)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Private subnets + NAT gateway. Fargate tasks and AgentCore Runtime ENIs have no public IP,
# so all their outbound traffic (ECR, STS, Athena, Bedrock, the IdP) goes through the NAT.
# ---------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = var.vpc_id
  availability_zone_id    = var.private_subnet_az_ids[count.index]
  cidr_block              = var.private_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "claims-copilot-private-${count.index == 0 ? "a" : "b"}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  subnet_id     = var.nat_subnet_id
  allocation_id = aws_eip.nat.id
}

resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  tags = { Name = "claims-copilot-private" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Free. Keeps ECR image-layer downloads from S3 off the NAT (no data processing charge).
resource "aws_vpc_endpoint" "s3" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids   = [aws_route_table.private.id]
}

# ---------------------------------------------------------------------------
# Security groups. Plane B (8081) is reachable ONLY from the Plane B proxy Lambda's SG.
# ---------------------------------------------------------------------------
resource "aws_security_group" "pep_proxy" {
  name_prefix = "claims-copilot-proxy-"
  description = "Plane B proxy Lambda network interfaces"
  vpc_id      = var.vpc_id

  tags = { Name = "claims-copilot-pep-proxy" }

  lifecycle { create_before_destroy = true }
}
resource "aws_security_group" "alb" {
  name_prefix = "claims-copilot-alb-"
  description = "Internal ALB for PEP Plane A"
  vpc_id      = var.vpc_id

  tags = { Name = "claims-copilot-alb" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "pep_task" {
  name_prefix = "claims-copilot-pep-"
  description = "PEP Fargate tasks"
  vpc_id      = var.vpc_id

  tags = { Name = "claims-copilot-pep-task" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "agent_runtime" {
  name_prefix = "claims-copilot-agent-"
  description = "AgentCore Runtime network interfaces"
  vpc_id      = var.vpc_id

  tags = { Name = "claims-copilot-agent-runtime" }

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "TLS from VPN / Streamlit"
  cidr_ipv4         = var.vpn_or_streamlit_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_from_vpn_sg" {
  count = var.vpn_security_group_id == "" ? 0 : 1

  security_group_id            = aws_security_group.alb.id
  description                  = "TLS from the VPN gateway (translated client addresses)"
  referenced_security_group_id = var.vpn_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_plane_a" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Plane A to PEP tasks"
  referenced_security_group_id = aws_security_group.pep_task.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "plane_a_from_alb" {
  security_group_id            = aws_security_group.pep_task.id
  description                  = "Plane A from the ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "plane_b_from_proxy" {
  security_group_id            = aws_security_group.pep_task.id
  description                  = "Plane B from the proxy Lambda only"
  referenced_security_group_id = aws_security_group.pep_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
}

resource "aws_vpc_security_group_egress_rule" "pep_https" {
  security_group_id = aws_security_group.pep_task.id
  description       = "AWS APIs and IdP over HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_plane_b" {
  security_group_id            = aws_security_group.pep_proxy.id
  description                  = "Plane B tool calls"
  referenced_security_group_id = aws_security_group.pep_task.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
}

resource "aws_vpc_security_group_egress_rule" "agent_https" {
  security_group_id = aws_security_group.agent_runtime.id
  description       = "Bedrock model invocation and Lambda API"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "pep_task_security_group_id" {
  value = aws_security_group.pep_task.id
}

output "agent_runtime_security_group_id" {
  value = aws_security_group.agent_runtime.id
}

output "pep_proxy_security_group_id" {
  value = aws_security_group.pep_proxy.id
}

output "nat_public_ip" {
  description = "Egress IP of the PEP and agent runtime (allow-list it at the IdP or elsewhere if needed)."
  value       = aws_eip.nat.public_ip
}
