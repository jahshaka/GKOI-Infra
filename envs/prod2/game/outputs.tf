locals {
  boxes = merge(
    length(module.box_usw2) > 0 ? { usw2 = module.box_usw2[0] } : {},
    length(module.box_euc1) > 0 ? { euc1 = module.box_euc1[0] } : {},
    length(module.box_use1) > 0 ? { use1 = module.box_use1[0] } : {},
    length(module.box_apne1) > 0 ? { apne1 = module.box_apne1[0] } : {},
  )
}

output "boxes" {
  description = "Per enabled region: the ASG, the Elastic IP, the config parameter, the names it serves and the DNS records this stack manages."
  value = {
    for k, b in local.boxes : k => {
      region            = local.config[k].region
      asg               = b.asg_name
      eip               = b.eip_public_ip
      config_parameter  = b.config_parameter
      records           = b.records
      serving           = local.serving[k]
      security_group_id = b.security_group_id
      # the CMS labs.game_regions hosts entry for this box (README "Registering a region on the site")
      cms_hosts = { matchd = "https://${local.serving[k][0]}:${var.matchd_port}", gateway = "https://${local.serving[k][1]}:${var.gateway_port}" }
    }
  }
}

output "warroom_release" {
  value = { tag = local.release_tag, digest = local.release_digest, tool = local.tool }
}

output "match_server_key_secret_arn" {
  description = "Put the value with the CLI (README 'Secrets'); the boxes start the stack once it has one."
  value       = local.match_server_key_arn
}

output "bundle" {
  value = "s3://${var.bundle_bucket}/${local.bundle_prefix}"
}
