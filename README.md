# Lakehouse Claims Agent (MVP Reference Implementation)

A functional, local-VPC Bedrock Agent demonstrating how to securely query enterprise data lakes using the [AgentCore TIP MCP Broker](https://github.com/your-username/agentcore-tip-mcp).

> ⚠️ **Architecture Notice: MVP vs. Production**
> This repository provides an MVP implementation using AWS Cloud Map and raw Fargate for local VPC testing. It does **not** include the private API Gateway and IAM Auth required for production-grade Machine-to-Machine (M2M) Zero-Trust. 
>
> For deploying this agent into strict enterprise compliance environments (SOC2, HIPAA), you must implement the API Gateway / mTLS architecture detailed in the main broker repository. 
> 
> *If your team requires assistance upgrading this MVP to a production enterprise architecture, please contact me for consulting.*

## Overview

This MVP implements a **Secure Insurance Claims Copilot** — a Streamlit-powered conversational AI that lets users query insurance claims data in an AWS data lake through natural language, with row- and column-level security enforced natively by **AWS Lake Formation**.

### Architecture Flow

```
┌─────────────┐     PKCE Login      ┌──────────────────┐
│   User      │ ──────────────────► │   Entra ID (MSAL) │
│  (Browser)  │  ◄───────────────── │   (JWT Issued)    │
└──────┬──────┘                     └──────────────────┘
       │ JWT
       │ HTTP POST /sessions/init
       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Streamlit App (app.py)                              │
│                                                                         │
│  1. Authenticates user via Entra ID (MSAL PublicClient, PKCE)          │
│  2. Sends JWT to PEP Plane A → receives opaque session_ref             │
│  3. Sends user prompt + session_ref to Bedrock Agent via invoke_agent   │
│  4. Renders agent responses (tables, summaries)                         │
│                                                                         │
│  🔒 Never touches Plane B — never sees Lake Formation data directly      │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ prompt + session_ref
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                AWS Bedrock Agent (AgentCore Runtime)                     │
│                                                                         │
│  1. Receives prompt, generates Athena SQL using table schemas in prompt  │
│  2. Invokes tool: query_lake_formation(session_ref, sql)                 │
│  3. Tool call → Lambda proxy (pep_proxy.py) → PEP Plane B (port 8081)   │
│                                                                         │
│  🔒 Agent is "token blind" — sees only opaque session_ref, not the JWT   │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ MCP tool calls (session_ref + SQL)
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              Zero-Trust Broker PEP (Fargate, plane-a:8080, plane-b:8081)│
│                                                                         │
│  Plane A (8080): /sessions/init — binds user identity to session_ref    │
│  Plane B (8081): MCP tool endpoint — executes Athena queries via        │
│                  Lake Formation with row/column-level security           │
│                                                                         │
│  🔒 Identity propagation to Lake Formation handled entirely by the PEP   │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ Athena queries (with LF security)
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│            AWS Lake Formation + Athena (insurance_analytics DB)          │
│                                                                         │
│  Tables: insurance_claims_enriched, claim_payments                       │
│  Security: row-level + column-level enforcement per user identity        │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Security Properties

| Property | How It's Achieved |
|----------|-------------------|
| **Zero-Trust Authentication** | Entra ID via MSAL PKCE — no client secrets stored |
| **Token Blindness** | Bedrock Agent never sees the user's JWT; only an opaque `session_ref` |
| **Air-Gapped Plane B** | Plane B (port 8081) is never exposed to the ALB or internet; only the Lambda proxy reaches it |
| **Row/Column Security** | Enforced natively by AWS Lake Formation — no Python-side filtering |
| **Identity Propagation** | AWS Trusted Identity Propagation (TIP) handled by the PEP — no STS `AssumeRole` in app code |

## Setup Instructions

### Prerequisites

- **AWS CLI** configured for your target account and region (`us-east-1`)
- **Docker** with `buildx` (for building `linux/arm64` images)
- **Python 3.10+** with `pip`
- **AWS CloudFormation** CLI or Console
- **Terraform** 1.6+ (if using the Terraform IaC path)
- **Entra ID** tenant with a registered public client application (redirect URI: `http://localhost:8501/`)

### Step 1 — Configure Environment Variables

```bash
cp .env.example .env
```

Edit `.env` with your Entra ID credentials, PEP Plane A URL, and Bedrock Agent ARN:

| Variable | Description |
|----------|-------------|
| `ENTRA_CLIENT_ID` | Your Entra ID application (client) ID |
| `ENTRA_TENANT_ID` | Your Entra ID tenant ID |
| `ENTRA_AUTHORITY` | (Optional) Custom authority URL; defaults to `https://login.microsoftonline.com/<tenant>` |
| `PEP_PLANE_A_URL` | HTTPS URL of the ALB-facing PEP Plane A (e.g., `https://pep-plane-a.internal.example.com`) |
| `BEDROCK_AGENT_ID` | Full AgentCore Runtime ARN (e.g., `arn:aws:bedrock-agentcore:us-east-1:<account>:runtime/<name>-<id>`) |

If using a self-signed ALB certificate, set the shell environment variable:
```bash
export PEP_CA_BUNDLE=cert/cert.pem
```

### Step 2 — Deploy the Identity Stack

The identity stack creates the three IAM roles required by the PEP (OIDC, carrier, and service roles).

**CloudFormation:**
```bash
aws cloudformation create-stack --stack-name vt-identity --region us-east-1 \
  --template-body file://iam/vt-identity-stack.yml --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=OidcProviderArn,ParameterValue=arn:aws:iam::<acct>:oidc-provider/login.microsoftonline.com/<tenant>/v2.0 \
    ParameterKey=OidcAudiences,ParameterValue="<client-id-1>,<client-id-2>"
```

**Terraform** (integrated in root `main.tf` — no separate step needed).

### Step 3 — Deploy the Network Stack (CloudFormation only)

```bash
aws cloudformation create-stack --stack-name claims-copilot-network --region us-east-1 \
  --template-body file://template-network.yaml
```

### Step 4 — Build and Push the Agent Image

```bash
# Windows (PowerShell)
.\scripts\deploy-agent-image.ps1 -Tag v0.1.0

# Linux/macOS
bash scripts/deploy-agent-image.sh -t v0.1.0
```

This builds the `linux/arm64` image for the AgentCore Runtime agent and pushes it to ECR.

### Step 5 — Deploy the App Stack

**CloudFormation:**
```bash
aws cloudformation create-stack --stack-name lakehouse-claims-agent-mvp --region us-east-1 \
  --template-body file://template.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=EntraTenantId,ParameterValue="<your-tenant-id>" \
    ParameterKey=EntraClientId,ParameterValue="<your-client-id>" \
    ParameterKey=AgentImageTag,ParameterValue=v0.1.0 \
    ParameterKey=DeployAgentRuntime,ParameterValue=true
```

**Terraform:**
```bash
terraform init
terraform apply \
  -var 'entra_tenant_id=<your-tenant-id>' \
  -var 'entra_client_id=<your-client-id>' \
  -var 'deploy_agent_runtime=true' \
  -var 'agent_image_tag=v0.1.0'
```

### Step 6 — Run the Streamlit App

```bash
pip install -r requirements.txt
streamlit run app.py
```

Navigate to `http://localhost:8501` in your browser. You will be redirected to your Entra ID login page. After authentication, the copilot chat interface will appear.

### Example Queries

Once logged in, try asking:

- *"Show me the top 5 claims with the highest fraud risk score"*
- *"Which tables can I query?"*
- *"Total claim payments by payment type"*

## Project Structure

| Path | Description |
|------|-------------|
| `app.py` | Streamlit frontend — Entra ID login, chat UI, Bedrock Agent invocation |
| `agent_runtime/` | AgentCore Runtime agent Docker image (SQL generation + tool use) |
| `lambda/pep_proxy.py` | Lambda proxy between the Bedrock Agent and PEP Plane B |
| `iam/` | Identity stack (CloudFormation + Terraform) — OIDC, carrier, and PEP service roles |
| `network/` | VPC, subnets, NAT gateway, and security groups (Terraform module) |
| `template.yaml` | CloudFormation app stack (PEP, ALB, Bedrock Agent, Lambda proxy) |
| `template-network.yaml` | CloudFormation network stack |
| `main.tf` | Terraform app stack (equivalent of `template.yaml`) |
| `scripts/` | Agent image build and push scripts (bash and PowerShell) |
| `data/` | Athena DDL for the `insurance_analytics` database tables |

## Data Schema

The agent queries the `insurance_analytics` Athena database, which contains:

| Table | Description |
|-------|-------------|
| `insurance_claims_enriched` | Claims with fraud risk scores, policy details, and claimant information |
| `claim_payments` | Payment records linked to claims |

DDL files are in `data/insurance_athena_ddl/`.

## License

Copyright 2026 Angel Krustev / VerticalTurn Inc.

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).
