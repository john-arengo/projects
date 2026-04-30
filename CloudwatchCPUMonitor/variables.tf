variable "region" {
  default = "us-east-1"
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
}