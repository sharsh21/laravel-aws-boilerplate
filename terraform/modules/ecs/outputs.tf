output "alb_dns_name" { value = aws_lb.main.dns_name }
output "cluster_name" { value = aws_ecs_cluster.main.name }
output "service_app_name" { value = aws_ecs_service.app.name }
output "service_worker_name" { value = aws_ecs_service.worker.name }
output "ecr_repository_url" { value = aws_ecr_repository.main.repository_url }
output "sqs_queue_url" { value = aws_sqs_queue.main.url }
