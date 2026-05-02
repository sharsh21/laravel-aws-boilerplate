output "alb_dns_name" {
  description = "Point your domain CNAME to this"
  value       = module.ecs.alb_dns_name
}

output "ecr_repository_url" {
  description = "Push Docker images here"
  value       = var.ecr_repository_url
}

output "rds_endpoint" {
  value     = module.rds.endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = module.cache.endpoint
  sensitive = true
}

output "s3_bucket_name" {
  value = module.storage.bucket_name
}

output "cloudfront_domain" {
  value = module.storage.cloudfront_domain
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_app" {
  value = module.ecs.service_app_name
}

output "ecs_service_worker" {
  value = module.ecs.service_worker_name
}

output "cloudwatch_dashboard_url" {
  value = module.ecs.cloudwatch_dashboard_url
}

output "alerts_sns_topic_arn" {
  value = module.ecs.alerts_sns_topic_arn
}
