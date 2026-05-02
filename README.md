# Laravel AWS Boilerplate

Production-ready Laravel deployment on AWS — ECS Fargate, RDS MySQL (Multi-AZ), ElastiCache Redis, S3 + CloudFront, SQS queues, GitHub Actions CI/CD, Terraform infrastructure.

**Skip the 2–5 day setup. Go from zero to production in under an hour.**

---

## What's included

| Layer | Technology |
|---|---|
| Container runtime | ECS Fargate (no EC2 to manage) |
| Web server | NGINX + PHP-FPM 8.3 in one container |
| Database | RDS MySQL 8.0, Multi-AZ, encrypted |
| Cache / Sessions | ElastiCache Redis 7 |
| Queue | SQS + dead-letter queue |
| Storage | S3 + CloudFront CDN |
| Secrets | AWS Secrets Manager + SSM Parameter Store |
| CI | GitHub Actions — test on PR |
| CD | GitHub Actions — build → ECR → ECS zero-downtime deploy |
| Infrastructure | Terraform modules (VPC, subnets, ALB, ECS, RDS, Redis, S3, CloudFront) |
| Auto-scaling | ECS App Auto Scaling on CPU (min 2, max 10) |
| Rollback | ECS deployment circuit breaker — auto-rolls back on failure |
| Observability | CloudWatch Logs, Container Insights |

---

## Prerequisites

- AWS account with admin access
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured (`aws configure`)
- [Docker](https://docs.docker.com/get-docker/)
- ACM certificate for your domain (must be in the same region as your ALB)

---

## Quick start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_ORG/laravel-aws-boilerplate.git my-app
cd my-app
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` — set `app_name`, `aws_region`, `certificate_arn`, and `app_env`.

### 2. Provision infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates (~8 minutes):
- VPC with public + private subnets across 2 AZs
- NAT Gateway
- ALB with HTTP→HTTPS redirect
- ECS Fargate cluster + app service + worker service
- RDS MySQL Multi-AZ
- ElastiCache Redis
- S3 bucket + CloudFront distribution
- ECR repository
- SQS queue + dead-letter queue
- All IAM roles and security groups

### 3. Point your domain

```bash
terraform output alb_dns_name
```

Create a CNAME record in your DNS pointing to the ALB DNS name.

### 4. Copy GitHub Actions workflows into your Laravel app

The workflow files live in `examples/workflows/`. Copy them into your Laravel project:

```bash
mkdir -p your-laravel-app/.github/workflows
cp examples/workflows/ci.yml your-laravel-app/.github/workflows/
cp examples/workflows/deploy.yml your-laravel-app/.github/workflows/
```

### 6. Set up GitHub Actions secrets

In your GitHub repo → Settings → Secrets and variables → Actions, add:

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |

In Variables (not secrets), add:

| Variable | Value (from `terraform output`) |
|---|---|
| `AWS_REGION` | e.g. `us-east-1` |
| `ECR_REPOSITORY` | ECR repo name (your `app_name`) |
| `ECS_CLUSTER` | From `terraform output ecs_cluster_name` |
| `ECS_SERVICE_APP` | From `terraform output ecs_service_app` |
| `ECS_SERVICE_WORKER` | From `terraform output ecs_service_worker` |
| `TASK_DEFINITION_APP` | `{app_name}-{environment}-app` |
| `TASK_DEFINITION_WORKER` | `{app_name}-{environment}-worker` |

### 7. First deploy

```bash
# One-time: build and push your Laravel app image manually
export APP_NAME=myapp
export ENVIRONMENT=production
export AWS_REGION=us-east-1
./scripts/deploy.sh
```

After this, every push to `main` triggers the GitHub Actions deploy pipeline automatically.

---

## Architecture

```
Internet
   │
   ▼
[ALB] ─── HTTPS 443 ──► [ECS Fargate: App] ──► [RDS MySQL Multi-AZ]
   │       (HTTP 301)                       └──► [ElastiCache Redis]
   │                                        └──► [S3 + CloudFront]
   │                                        └──► [SQS Queue]
   │                                              │
   │                                              ▼
   │                                    [ECS Fargate: Worker]
   │
[CloudFront] ◄── static assets ── [S3]
```

Private subnets: ECS tasks, RDS, Redis (never directly internet-accessible)
Public subnets: ALB, NAT Gateway only

---

## Deploying app config changes

Laravel `.env` values are stored in SSM Parameter Store. To update a value:

```bash
aws ssm put-parameter \
  --name "/myapp/production/APP_KEY" \
  --value "base64:xxxx" \
  --type SecureString \
  --overwrite
```

Then force a new ECS deployment to pick up the change:

```bash
aws ecs update-service \
  --cluster myapp-production \
  --service myapp-production-app \
  --force-new-deployment
```

---

## Laravel logging → CloudWatch

All Laravel logs are automatically shipped to CloudWatch Logs via the ECS `awslogs` driver — no extra package needed.

**Log groups created by Terraform:**
- `/ecs/{app_name}-{environment}/app` — web app logs
- `/ecs/{app_name}-{environment}/worker` — queue worker logs

**Configure JSON structured logging** (recommended — enables Log Insights queries):

Copy `examples/config/logging.php` into your Laravel app:

```bash
cp examples/config/logging.php your-laravel-app/config/logging.php
```

This formats every log entry as JSON so you can query them in CloudWatch Log Insights:

```
# Find all errors in the last hour
fields @timestamp, message, context.exception
| filter level = "error" or level = "critical"
| sort @timestamp desc
| limit 50
```

**CloudWatch alarms created automatically:**
| Alarm | Threshold |
|---|---|
| Laravel error rate | ≥ 10 errors in 5 min |
| ECS CPU | ≥ 85% for 10 min |
| ALB 5xx | ≥ 20 errors in 3 min |

Set `alert_email` in `terraform.tfvars` to receive email notifications. After `terraform apply` you'll get a confirmation email to activate the subscription.

**Access your dashboard:**
```bash
terraform output cloudwatch_dashboard_url
```

---

## Queue worker

The worker runs as a separate ECS Fargate service. It processes jobs from SQS. Failed jobs after 3 attempts go to the dead-letter queue `{app_name}-{environment}-failed`.

To monitor the dead-letter queue:

```bash
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name myapp-production-failed --query QueueUrl --output text) \
  --attribute-names ApproximateNumberOfMessages
```

---

## Scaling

App auto-scales between `app_count` (min) and 10 (max) based on CPU. Modify in `terraform/modules/ecs/main.tf`:

```hcl
resource "aws_appautoscaling_policy" "app_cpu" {
  target_tracking_scaling_policy_configuration {
    target_value = 70  # scale out when CPU > 70%
  }
}
```

---

## Costs (approximate, us-east-1)

| Resource | Monthly cost |
|---|---|
| ECS Fargate (2x 0.5vCPU/1GB) | ~$30 |
| RDS db.t3.micro Multi-AZ | ~$30 |
| ElastiCache cache.t3.micro | ~$15 |
| ALB | ~$18 |
| NAT Gateway | ~$35 |
| S3 + CloudFront | ~$5 |
| **Total** | **~$130/month** |

Scale down to single-AZ RDS + smaller instances for staging: ~$60/month.

---

## Folder structure

```
├── .github/workflows/
│   ├── ci.yml              # Run tests on every PR
│   └── deploy.yml          # Build → ECR → ECS on push to main
├── docker/
│   ├── Dockerfile          # Multi-stage: deps → release
│   ├── nginx.conf          # NGINX with /health endpoint for ALB
│   ├── supervisord.conf    # Runs NGINX + PHP-FPM + queue worker
│   └── php.ini             # OPcache + memory tuning
├── terraform/
│   ├── main.tf             # Root module wiring
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── networking/     # VPC, subnets, NAT, security groups
│       ├── ecs/            # Fargate cluster, services, ALB, ECR, SQS, IAM
│       ├── rds/            # MySQL, Multi-AZ, automated backups
│       ├── cache/          # ElastiCache Redis
│       ├── storage/        # S3 + CloudFront OAC
│       └── secrets/        # SSM Parameter Store
├── scripts/
│   └── deploy.sh           # Manual deploy for first deploy / hotfixes
└── .env.ci                 # .env for GitHub Actions CI runner
```

---

## License

MIT
