output "ssm_parameter_arn" {
  value = "arn:aws:ssm:*:*:parameter/${var.app_name}/${var.environment}/*"
}
