# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env bash
# Builds the AgentCore Runtime agent image (linux/arm64) and pushes it to ECR.
#
# Target: <account>.dkr.ecr.<region>.amazonaws.com/lakehouse-claims-agent-mvp:<tag>
# Requires Docker (with buildx) and the AWS CLI configured for the target account.
# The repository is created if it does not exist. Afterwards deploy the stack with
# DeployAgentRuntime=true (CloudFormation) or deploy_agent_runtime=true (Terraform).
#
# Usage: scripts/deploy-agent-image.sh [-r repository] [-t tag] [-R region] [-a expected-account-id]
set -euo pipefail

REPOSITORY="lakehouse-claims-agent-mvp"
TAG="v0.1.0"
REGION="us-east-1"
EXPECTED_ACCOUNT_ID="991536801739"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "r:t:R:a:h" opt; do
  case "$opt" in
    r) REPOSITORY="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    R) REGION="$OPTARG" ;;
    a) EXPECTED_ACCOUNT_ID="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

for tool in docker aws; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' was not found on PATH." >&2; exit 1; }
done

CONTEXT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent_runtime"
[ -f "$CONTEXT/Dockerfile" ] || { echo "error: Dockerfile not found in $CONTEXT" >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text --region "$REGION")" \
  || { echo "error: AWS credentials are not configured or have expired." >&2; exit 1; }
if [ -n "$EXPECTED_ACCOUNT_ID" ] && [ "$ACCOUNT" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo "error: authenticated to account $ACCOUNT but expected $EXPECTED_ACCOUNT_ID (use -a to override)." >&2
  exit 1
fi

REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"

echo "Checking ECR repository '${REPOSITORY}'..."
if ! aws ecr describe-repositories --repository-names "$REPOSITORY" --region "$REGION" >/dev/null 2>&1; then
  echo "Repository not found; creating it."
  aws ecr create-repository --repository-name "$REPOSITORY" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true --query 'repository.repositoryUri' --output text
fi

# Refuse to overwrite a tag when the repository has immutable tags; otherwise the push would fail late.
MUTABILITY="$(aws ecr describe-repositories --repository-names "$REPOSITORY" --region "$REGION" \
  --query 'repositories[0].imageTagMutability' --output text)"
if [ "$MUTABILITY" = "IMMUTABLE" ] && aws ecr describe-images --repository-name "$REPOSITORY" \
  --region "$REGION" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "error: tag '$TAG' already exists and the repository is IMMUTABLE. Use a new -t tag." >&2
  exit 1
fi

echo "Logging in to ${REGISTRY}..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# AgentCore Runtime only runs ARM64 images; buildx emulates arm64 through QEMU on x86 hosts.
echo "Building and pushing ${IMAGE} (linux/arm64)..."
docker buildx build --platform linux/arm64 --provenance=false --tag "$IMAGE" --push "$CONTEXT"

DIGEST="$(aws ecr describe-images --repository-name "$REPOSITORY" --region "$REGION" \
  --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text)"

echo
echo "Pushed: ${IMAGE}"
echo "Digest: ${DIGEST}"
echo
echo "Next: deploy with AgentRepositoryName=${REPOSITORY} AgentImageTag=${TAG} and DeployAgentRuntime=true."
