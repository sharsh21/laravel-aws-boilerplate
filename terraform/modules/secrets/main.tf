resource "aws_ssm_parameter" "app_env" {
  for_each = var.app_env

  name  = "/${var.app_name}/${var.environment}/${each.key}"
  type  = "SecureString"
  value = each.value

  lifecycle {
    ignore_changes = [value]  # Let the app update secrets without Terraform drift
  }
}
