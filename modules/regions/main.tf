# The prod2 region catalogue: the ONE place a region is enabled or paused.
#
# Every stack reads this module, so a region is enabled by ONE change here, then network → registry → observability,
# then data + edge-alb (they admit the new edge CIDR) (README "Enabling a paused region"). Tokyo (apne1) was enabled 2026-11-11 for a
# media box only (envs/prod2/media/README.md "Adding Tokyo (apne1)"); its game box stays off in envs/prod2/game.
#
# CIDRs are 10.x on purpose: Lightsail's own VPC in us-west-2 / eu-central-1 is 172.26.0.0/16 (peered to the
# default VPC) and the dev box's Docker uses 172.16–172.31.

locals {
  all = {
    usw2 = {
      region  = "us-west-2"
      cidr    = "10.10.0.0/16"
      role    = "home" # control plane + data
      enabled = true
      azs     = null # null = the first two available AZs, sorted by name
    }
    euc1 = {
      region  = "eu-central-1"
      cidr    = "10.20.0.0/16"
      role    = "edge" # media + game
      enabled = true
      azs     = null
    }
    use1 = {
      region  = "us-east-1"
      cidr    = "10.30.0.0/16"
      role    = "edge"
      enabled = true
      azs     = null
    }
    apne1 = {
      region  = "ap-northeast-1"
      cidr    = "10.40.0.0/16"
      role    = "edge"
      enabled = true # 2026-11-11: media only (game_regions.apne1 stays off)
      azs     = null
    }
  }

  home_key = "usw2"
}

output "all" {
  description = "Every region entry, enabled or not."
  value       = local.all
}

output "enabled" {
  description = "Only the enabled regions."
  value       = { for k, v in local.all : k => v if v.enabled }
}

output "home_key" {
  value = local.home_key
}

output "home" {
  value = local.all[local.home_key]
}

output "edge_enabled" {
  description = "The enabled non-home (media/game) regions."
  value       = { for k, v in local.all : k => v if v.enabled && k != local.home_key }
}
