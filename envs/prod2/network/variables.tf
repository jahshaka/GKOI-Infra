variable "account_id" {
  description = "The AWS account every provider is locked to."
  type        = string
  default     = "127214190346"
}

variable "home_nat_mode" {
  description = "NAT in the home region: single (one NAT, ruled 2026-11-10) or per_az (one per AZ, +1 NAT's cost)."
  type        = string
  default     = "single"
}

variable "edge_nat_mode" {
  description = "NAT in the media/game regions. none: their boxes sit in public subnets with public IPs."
  type        = string
  default     = "none"
}

variable "home_interface_endpoints" {
  description = "Interface endpoints in the home VPC's private subnets (one ENI per AZ each)."
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "secretsmanager",
    "logs",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "kms",
    "sts",
  ]
}

variable "flow_log_retention_days" {
  type    = number
  default = 7
}

variable "flow_log_traffic_type" {
  description = "ALL | ACCEPT | REJECT."
  type        = string
  default     = "ALL"
}
