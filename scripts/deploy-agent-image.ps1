# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS
  Builds the AgentCore Runtime agent image (linux/arm64) and pushes it to ECR.

.DESCRIPTION
  Target: <account>.dkr.ecr.<region>.amazonaws.com/lakehouse-claims-agent-mvp:<tag>
  Requires Docker (with buildx) and the AWS CLI configured for the target account.
  The repository is created if it does not exist. Afterwards deploy the stack with
  DeployAgentRuntime=true (CloudFormation) or deploy_agent_runtime=true (Terraform).

.EXAMPLE
  .\scripts\deploy-agent-image.ps1
  .\scripts\deploy-agent-image.ps1 -Tag v0.1.1 -Region us-east-1
#>
[CmdletBinding()]
param(
    [string]$Repository = "lakehouse-claims-agent-mvp",
    [string]$Tag = "v0.1.0",
    [string]$Region = "us-east-1",
    [string]$ExpectedAccountId = "991536801739"
)

$ErrorActionPreference = "Stop"

function Invoke-Native {
    param([scriptblock]$Command, [string]$Failure)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Failure (exit code $LASTEXITCODE)" }
}

foreach ($tool in "docker", "aws") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' was not found on PATH." }
}

$context = Join-Path (Split-Path $PSScriptRoot -Parent) "agent_runtime"
if (-not (Test-Path (Join-Path $context "Dockerfile"))) { throw "Dockerfile not found in $context" }

$account = (aws sts get-caller-identity --query Account --output text --region $Region)
if ($LASTEXITCODE -ne 0 -or -not $account) { throw "AWS credentials are not configured or have expired." }
if ($ExpectedAccountId -and $account -ne $ExpectedAccountId) {
    throw "Authenticated to account $account but expected $ExpectedAccountId. Switch profile or pass -ExpectedAccountId."
}

$registry = "$account.dkr.ecr.$Region.amazonaws.com"
$image = "${registry}/${Repository}:${Tag}"

Write-Host "Checking ECR repository '$Repository'..."
aws ecr describe-repositories --repository-names $Repository --region $Region *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Repository not found; creating it."
    Invoke-Native { aws ecr create-repository --repository-name $Repository --region $Region `
            --image-scanning-configuration scanOnPush=true --output text --query "repository.repositoryUri" } "Could not create the repository"
}

# Refuse to overwrite a tag when the repository has immutable tags; otherwise the push would fail late.
$mutability = aws ecr describe-repositories --repository-names $Repository --region $Region --query "repositories[0].imageTagMutability" --output text
$existing = aws ecr describe-images --repository-name $Repository --region $Region --image-ids imageTag=$Tag --query "imageDetails[0].imageDigest" --output text 2>$null
if ($LASTEXITCODE -eq 0 -and $existing -and $mutability -eq "IMMUTABLE") {
    throw "Tag '$Tag' already exists and the repository is IMMUTABLE. Use a new -Tag."
}

Write-Host "Logging in to $registry..."
$password = aws ecr get-login-password --region $Region
if ($LASTEXITCODE -ne 0) { throw "Could not get an ECR login password." }
$password | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "docker login failed." }

# AgentCore Runtime only runs ARM64 images. Docker Desktop emulates arm64 through QEMU on x86 hosts.
Write-Host "Building and pushing $image (linux/arm64)..."
Invoke-Native { docker buildx build --platform linux/arm64 --provenance=false --tag $image --push $context } "Image build/push failed"

$digest = aws ecr describe-images --repository-name $Repository --region $Region --image-ids imageTag=$Tag --query "imageDetails[0].imageDigest" --output text
Write-Host ""
Write-Host "Pushed: $image"
Write-Host "Digest: $digest"
Write-Host ""
Write-Host "Next: deploy with AgentRepositoryName=$Repository AgentImageTag=$Tag and DeployAgentRuntime=true."
