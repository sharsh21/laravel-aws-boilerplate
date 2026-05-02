resource "aws_ecr_repository" "main" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# IAM — ECS task execution role (pull images, write logs, read SSM)
resource "aws_iam_role" "execution" {
  name = "${var.app_name}-${var.environment}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_ssm" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParametersByPath", "kms:Decrypt"]
        Resource = [var.ssm_parameter_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.db_password_arn]
      }
    ]
  })
}

# IAM — ECS task role (app runtime permissions)
resource "aws_iam_role" "task" {
  name = "${var.app_name}-${var.environment}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_permissions" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
      # CWAgent needs to read its own config from SSM
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.app_name}/${var.environment}/cwagent-config"
      }
    ]
  })
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}-${var.environment}/app"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.app_name}-${var.environment}/worker"
  retention_in_days = 30
}

# Dedicated log group for laravel.log (shipped by CWAgent sidecar)
resource "aws_cloudwatch_log_group" "laravel" {
  name              = "/ecs/${var.app_name}-${var.environment}/laravel"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "cwagent_app" {
  name              = "/ecs/${var.app_name}-${var.environment}/cwagent-app"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "cwagent_worker" {
  name              = "/ecs/${var.app_name}-${var.environment}/cwagent-worker"
  retention_in_days = 7
}

# CWAgent config stored in SSM — reads laravel.log from shared volume
resource "aws_ssm_parameter" "cwagent_config" {
  name  = "/${var.app_name}/${var.environment}/cwagent-config"
  type  = "String"
  value = jsonencode({
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path             = "/logs/laravel-*.log"
              log_group_name        = aws_cloudwatch_log_group.laravel.name
              log_stream_name       = "{hostname}"
              timestamp_format      = "[%Y-%m-%d %H:%M:%S]"
              # Groups multi-line stack traces into one log event
              multi_line_start_pattern = "^\\[\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\]"
              encoding              = "utf-8"
            }
          ]
        }
      }
      log_stream_name = "${var.app_name}-${var.environment}"
    }
  })
}

# SQS Queue for Laravel queues
resource "aws_sqs_queue" "main" {
  name                      = "${var.app_name}-${var.environment}"
  message_retention_seconds = 1209600  # 14 days
  visibility_timeout_seconds = 90

  tags = { Name = "${var.app_name}-${var.environment}" }
}

resource "aws_sqs_queue" "deadletter" {
  name                      = "${var.app_name}-${var.environment}-failed"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue_redrive_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deadletter.arn
    maxReceiveCount     = 3
  })
}

# ALB
resource "aws_lb" "main" {
  name               = "${var.app_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true
}

resource "aws_lb_target_group" "app" {
  name        = "${var.app_name}-${var.environment}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# App Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app_name}-${var.environment}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  # Add ~256 CPU + 256 MB headroom for the CWAgent sidecar
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Shared ephemeral volume: app writes laravel.log here, CWAgent reads it
  volume {
    name = "app-logs"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{ containerPort = 80 }]

      mountPoints = [{
        sourceVolume  = "app-logs"
        containerPath = "/var/www/html/storage/logs"
        readOnly      = false
      }]

      environment = [
        { name = "DB_HOST",              value = var.db_host },
        { name = "DB_DATABASE",          value = var.db_name },
        { name = "DB_USERNAME",          value = var.db_username },
        { name = "REDIS_HOST",           value = var.redis_host },
        { name = "SQS_QUEUE",            value = aws_sqs_queue.main.url },
        { name = "AWS_DEFAULT_REGION",   value = var.aws_region },
        { name = "FILESYSTEM_DISK",      value = "s3" },
        { name = "AWS_BUCKET",           value = var.s3_bucket_name },
        { name = "LOG_CHANNEL",          value = "daily" },
      ]

      secrets = [
        { name = "DB_PASSWORD", valueFrom = var.db_password_arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
    },
    {
      name      = "cloudwatch-agent"
      image     = "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest"
      essential = false

      mountPoints = [{
        sourceVolume  = "app-logs"
        containerPath = "/logs"
        readOnly      = true
      }]

      environment = [
        {
          name  = "CW_CONFIG_CONTENT"
          value = aws_ssm_parameter.cwagent_config.value
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cwagent_app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "cwagent"
        }
      }
    }
  ])
}

# Worker Task Definition
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.app_name}-${var.environment}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "worker-logs"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      command = ["php", "artisan", "queue:work", "sqs",
                 "--sleep=3", "--tries=3", "--max-time=3600"]

      mountPoints = [{
        sourceVolume  = "worker-logs"
        containerPath = "/var/www/html/storage/logs"
        readOnly      = false
      }]

      environment = [
        { name = "DB_HOST",              value = var.db_host },
        { name = "DB_DATABASE",          value = var.db_name },
        { name = "DB_USERNAME",          value = var.db_username },
        { name = "REDIS_HOST",           value = var.redis_host },
        { name = "SQS_QUEUE",            value = aws_sqs_queue.main.url },
        { name = "AWS_DEFAULT_REGION",   value = var.aws_region },
        { name = "FILESYSTEM_DISK",      value = "s3" },
        { name = "AWS_BUCKET",           value = var.s3_bucket_name },
        { name = "LOG_CHANNEL",          value = "daily" },
      ]

      secrets = [
        { name = "DB_PASSWORD", valueFrom = var.db_password_arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    },
    {
      name      = "cloudwatch-agent"
      image     = "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest"
      essential = false

      mountPoints = [{
        sourceVolume  = "worker-logs"
        containerPath = "/logs"
        readOnly      = true
      }]

      environment = [
        {
          name  = "CW_CONFIG_CONTENT"
          value = aws_ssm_parameter.cwagent_config.value
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cwagent_worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "cwagent"
        }
      }
    }
  ])
}

# App ECS Service
resource "aws_ecs_service" "app" {
  name            = "${var.app_name}-${var.environment}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 80
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller { type = "ECS" }

  lifecycle {
    ignore_changes = [task_definition]  # Managed by CI/CD
  }
}

# Worker ECS Service
resource "aws_ecs_service" "worker" {
  name            = "${var.app_name}-${var.environment}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}

# Auto-scaling for app service
resource "aws_appautoscaling_target" "app" {
  max_capacity       = 10
  min_capacity       = var.app_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "app_cpu" {
  name               = "${var.app_name}-${var.environment}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.app.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ─── CloudWatch: Laravel log metric filters + alarms ───────────────────────

resource "aws_cloudwatch_log_metric_filter" "laravel_errors" {
  name           = "${var.app_name}-${var.environment}-laravel-errors"
  log_group_name = aws_cloudwatch_log_group.laravel.name
  # Matches Laravel's default log format: production.ERROR and production.CRITICAL
  pattern        = "?ERROR ?CRITICAL"

  metric_transformation {
    name      = "LaravelErrors"
    namespace = "${var.app_name}/${var.environment}"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "laravel_worker_errors" {
  name           = "${var.app_name}-${var.environment}-worker-errors"
  log_group_name = aws_cloudwatch_log_group.laravel.name
  pattern        = "?ERROR ?CRITICAL"

  metric_transformation {
    name      = "LaravelWorkerErrors"
    namespace = "${var.app_name}/${var.environment}"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_sns_topic" "alerts" {
  name = "${var.app_name}-${var.environment}-alerts"
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "laravel_error_rate" {
  alarm_name          = "${var.app_name}-${var.environment}-high-error-rate"
  alarm_description   = "Laravel is logging errors at a high rate"
  namespace           = "${var.app_name}/${var.environment}"
  metric_name         = "LaravelErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_app_cpu" {
  alarm_name          = "${var.app_name}-${var.environment}-high-cpu"
  alarm_description   = "ECS app service CPU is high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.app_name}-${var.environment}-alb-5xx"
  alarm_description   = "ALB is returning 5xx errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# CloudWatch dashboard — single pane for the whole stack
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.app_name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "log"
        properties = {
          title   = "Laravel App Errors (last 1h)"
          region  = var.aws_region
          view    = "table"
          query   = "SOURCE '${aws_cloudwatch_log_group.laravel.name}' | fields @timestamp, level, message, context.exception | filter level = 'error' or level = 'critical' | sort @timestamp desc | limit 50"
          period  = 3600
        }
        width = 24; height = 6; x = 0; y = 0
      },
      {
        type = "log"
        properties = {
          title  = "Worker Errors (last 1h)"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.laravel.name}' | fields @timestamp, level, message | filter level = 'error' or level = 'critical' | sort @timestamp desc | limit 20"
          period = 3600
        }
        width = 24; height = 4; x = 0; y = 6
      },
      {
        type = "metric"
        properties = {
          title  = "Laravel Error Rate"
          region = var.aws_region
          metrics = [["${var.app_name}/${var.environment}", "LaravelErrors"]]
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
        }
        width = 8; height = 4; x = 0; y = 10
      },
      {
        type = "metric"
        properties = {
          title  = "ALB 5xx / 4xx"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.main.arn_suffix]
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
        width = 8; height = 4; x = 8; y = 10
      },
      {
        type = "metric"
        properties = {
          title  = "ECS CPU / Memory"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name]
          ]
          period = 60
          stat   = "Average"
          view   = "timeSeries"
        }
        width = 8; height = 4; x = 16; y = 10
      }
    ]
  })
}
