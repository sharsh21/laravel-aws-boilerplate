terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment after creating the S3 bucket + DynamoDB table for state
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "laravel-app/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source = "./modules/networking"

  app_name           = var.app_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "secrets" {
  source = "./modules/secrets"

  app_name    = var.app_name
  environment = var.environment
  app_env     = var.app_env
}

module "storage" {
  source = "./modules/storage"

  app_name    = var.app_name
  environment = var.environment
}

module "rds" {
  source = "./modules/rds"

  app_name            = var.app_name
  environment         = var.environment
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  app_security_group  = module.networking.app_security_group_id
  db_name             = var.db_name
  db_username         = var.db_username
  instance_class      = var.rds_instance_class
  multi_az            = var.rds_multi_az
}

module "cache" {
  source = "./modules/cache"

  app_name           = var.app_name
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  app_security_group = module.networking.app_security_group_id
  node_type          = var.redis_node_type
}

module "ecs" {
  source = "./modules/ecs"

  app_name            = var.app_name
  environment         = var.environment
  aws_region          = var.aws_region
  vpc_id              = module.networking.vpc_id
  public_subnet_ids   = module.networking.public_subnet_ids
  private_subnet_ids  = module.networking.private_subnet_ids
  ecr_repository_url  = var.ecr_repository_url
  image_tag           = var.image_tag
  app_cpu             = var.app_cpu
  app_memory          = var.app_memory
  worker_cpu          = var.worker_cpu
  worker_memory       = var.worker_memory
  app_count           = var.app_count
  worker_count        = var.worker_count
  ssm_parameter_arn   = module.secrets.ssm_parameter_arn
  s3_bucket_name      = module.storage.bucket_name
  db_host             = module.rds.endpoint
  db_name             = var.db_name
  db_username         = var.db_username
  db_password_arn     = module.rds.password_secret_arn
  redis_host          = module.cache.endpoint
  certificate_arn       = var.certificate_arn
  alb_security_group_id = module.networking.alb_security_group_id
  app_security_group_id = module.networking.app_security_group_id
  alert_email           = var.alert_email
}
