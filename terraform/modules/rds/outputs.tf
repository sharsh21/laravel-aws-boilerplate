output "endpoint" { value = aws_db_instance.main.address }
output "password_secret_arn" { value = aws_secretsmanager_secret.db_password.arn }
