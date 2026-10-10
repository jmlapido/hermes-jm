variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1"
}

variable "name" {
  description = "Name prefix / Name tag for resources."
  type        = string
  default     = "hermes-agent"
}

variable "instance_type" {
  description = "EC2 instance type (must be arm64/Graviton to match the AMI)."
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 40
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the single public subnet."
  type        = string
  default     = "10.42.1.0/24"
}

variable "tailscale_hostname" {
  description = "Hostname the instance registers with on the tailnet."
  type        = string
  default     = "hermes-aws"
}

variable "snapshot_retain_count" {
  description = "Number of daily EBS snapshots to keep."
  type        = number
  default     = 7
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 50
}

variable "budget_alert_email" {
  description = "Email address that receives budget alerts (80% and 100% of actual spend)."
  type        = string
}
