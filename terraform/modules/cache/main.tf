resource "aws_security_group" "redis" {
  name   = "${var.app_name}-${var.environment}-redis-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.app_security_group]
  }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.app_name}-${var.environment}-redis-subnet"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.app_name}-${var.environment}-redis"
  description          = "Redis for ${var.app_name} ${var.environment}"

  node_type            = var.node_type
  num_cache_clusters   = 1
  port                 = 6379
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = false  # Set true if your Laravel app uses TLS for Redis

  tags = { Name = "${var.app_name}-${var.environment}-redis" }
}
