locals {
  boxes = merge(
    length(module.box_usw2) > 0 ? { usw2 = module.box_usw2[0] } : {},
    length(module.box_euc1) > 0 ? { euc1 = module.box_euc1[0] } : {},
    length(module.box_use1) > 0 ? { use1 = module.box_use1[0] } : {},
    length(module.box_apne1) > 0 ? { apne1 = module.box_apne1[0] } : {},
  )
}

output "boxes" {
  description = "Per enabled region: the ASG, the Elastic IP, the config parameter, the DNS names this stack manages."
  value = {
    for k, b in local.boxes : k => {
      region            = local.config[k].region
      asg               = b.asg_name
      eip               = b.eip_public_ip
      config_parameter  = b.config_parameter
      records           = b.records
      stream_host       = local.config[k].stream_host
      origin_host       = local.config[k].origin_host
      security_group_id = b.security_group_id
    }
  }
}

output "ingest" {
  description = <<-EOT
    SPEC-ONE-INGEST-ADDRESS-V1 (1.1.8): the automatic name and, per region, what its latency record needs — the EIP, the
    AWS region (latency region) and the CALCULATED health check id (null while ingest_auto_host is off).
    tools/gkoi-one-ingest-dns-swap reads it to print the one Route 53 change batch.
  EOT
  value = {
    auto_host       = var.ingest_auto_host
    latency_records = var.ingest_auto_latency_records
    srt             = var.ingest_srt
    zone_id         = var.zone_id
    regions = {
      for k, b in local.boxes : k => {
        region          = local.config[k].region
        eip             = b.eip_public_ip
        stream_host     = local.config[k].stream_host
        health_check_id = b.auto_health_check_id
      }
    }
  }
}

output "portal_internal_url" {
  description = "PORTAL_INTERNAL_URL the boxes use (the engine api's /internal/** through the internal ALB)."
  value       = local.portal_internal_url
}


output "valkey_peer_cidrs" {
  description = "The spoke VPCs that must reach Valkey — the data stack admits network's edge_cidrs by default (valkey_peer_cidrs = null)."
  value       = [for k, v in local.enabled : local.net.regions[k].cidr if k != local.home_key]
}

output "bundle" {
  description = "Where the box bundle went (s3://<bucket>/<prefix>) — the boxes read it from their config parameter."
  value       = "s3://${var.bundle_bucket}/${local.bundle_prefix}"
}

output "media_origin_images" {
  value = local.origin_image
}

output "engine_release" {
  value = { tag = local.engine_source.tag, commit = local.engine_source.commit, images = local.image_ref }
}

output "rehearsal" {
  description = "The rehearsal switch as applied: on/off, the bucket every agent records into, the extra origin CIDRs."
  value = {
    enabled           = var.rehearsal
    recordings_bucket = local.recordings_bucket
    origin_cidrs      = local.rehearsal_origin
  }
}
