variable "app_name" { type = string }
variable "environment" { type = string }
variable "app_env" {
  type      = map(string)
  sensitive = true
}
