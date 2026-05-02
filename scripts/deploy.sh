#!/usr/bin/env bash
# Manual deploy script — useful for first deploy or hotfixes outside CI
set -euo pipefail

: "${APP_NAME:?Set APP_NAME}"
: "${ENVIRONMENT:?Set ENVIRONMENT}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${IMAGE_TAG:=${ENVIRONMENT}-$(git rev-parse --short HEAD)}"

ECR_REGISTRY=$(aws ecr describe-repositories \
  --repository-names "$APP_NAME" \
  --region "$AWS_REGION" \
  --query 'repositories[0].repositoryUri' \
  --output text | cut -d/ -f1)

ECR_REPO_URL="$ECR_REGISTRY/$APP_NAME"
CLUSTER="${APP_NAME}-${ENVIRONMENT}"
SERVICE_APP="${APP_NAME}-${ENVIRONMENT}-app"
SERVICE_WORKER="${APP_NAME}-${ENVIRONMENT}-worker"

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "==> Building image: $ECR_REPO_URL:$IMAGE_TAG"
docker build -t "$ECR_REPO_URL:$IMAGE_TAG" \
             -t "$ECR_REPO_URL:latest" \
             --target release \
             -f docker/Dockerfile .

echo "==> Pushing image..."
docker push "$ECR_REPO_URL:$IMAGE_TAG"
docker push "$ECR_REPO_URL:latest"

echo "==> Updating ECS services..."
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE_APP" \
  --force-new-deployment \
  --region "$AWS_REGION" > /dev/null

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE_WORKER" \
  --force-new-deployment \
  --region "$AWS_REGION" > /dev/null

echo "==> Waiting for app service to stabilize..."
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "$SERVICE_APP" \
  --region "$AWS_REGION"

echo "==> Deploy complete."
