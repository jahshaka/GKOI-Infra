variable "name" {
  description = "Name prefix, e.g. gkoi-prod2-usw2."
  type        = string
}

variable "cidr" {
  description = "The VPC CIDR (a /16)."
  type        = string
}

variable "azs" {
  description = "Explicit AZ names; null = the first az_count available AZs sorted by name."
  type        = list(string)
  default     = null
}

variable "az_count" {
  type    = number
  default = 2
}

variable "nat_mode" {
  description = "none | single | per_az."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_mode)
    error_message = "nat_mode must be none, single or per_az."
  }
}

variable "map_public_ip_on_launch" {
  description = "Public subnets give instances a public IPv4 at launch (media/game boxes need one anyway)."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Interface endpoint service suffixes, e.g. [\"ecr.api\", \"logs\"]."
  type        = list(string)
  default     = []
}

variable "flow_log_group_name" {
  type = string
}

variable "flow_log_retention_days" {
  type    = number
  default = 7
}

variable "flow_log_traffic_type" {
  type    = string
  default = "ALL"
}

variable "flow_log_role_arn" {
  type = string
}
