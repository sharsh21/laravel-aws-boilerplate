variable "app_name" {
  description = "Application name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (production, staging)"
  type        = string
  default     = "production"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

# --- App env vars stored in SSM ---
variable "app_env" {
  description = "Map of Laravel .env values to store in SSM Parameter Store"
  type        = map(string)
  sensitive   = true
}

# --- RDS ---
variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "rds_multi_az" {
  type    = bool
  default = true
}

# --- ElastiCache ---
variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

# --- ECS ---
variable "ecr_repository_url" {
  description = "Full ECR repository URL (without tag)"
  type        = string
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "app_cpu" {
  type    = number
  default = 512
}

variable "app_memory" {
  type    = number
  default = 1024
}

variable "worker_cpu" {
  type    = number
  default = 256
}

variable "worker_memory" {
  type    = number
  default = 512
}

variable "app_count" {
  description = "Number of app container instances"
  type        = number
  default     = 2
}

variable "worker_count" {
  type    = number
  default = 1
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS on the ALB"
  type        = string
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications (errors, high CPU, 5xx)"
  type        = string
  default     = ""
}
