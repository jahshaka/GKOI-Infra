output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "For CloudWatch metric dimensions (LoadBalancer)."
  value       = aws_lb.this.arn_suffix
}

output "alb_dns_name" {
  description = "The CNAME/alias target for the hostnames at cut-over (P3/P4). No DNS record is changed here."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.alb.certificate_arn
}

output "target_groups" {
  description = "Per service: target group ARN, ARN suffix (metrics), port, and the ECS min/max bounds."
  value = {
    for k, s in var.services : k => {
      arn          = aws_lb_target_group.svc[k].arn
      arn_suffix   = aws_lb_target_group.svc[k].arn_suffix
      port         = s.port
      hosts        = local.service_fqdns[k]
      min_capacity = s.min_capacity
      max_capacity = s.max_capacity
    }
  }
}

output "site_origin_lock" {
  description = "The site-origin lock as applied: on/off, how many secret values the rules accept (2 = a rotation in flight), the secret (name + ARN — never the value), the paths of origin-www left open."
  value = {
    enabled         = var.site_origin_lock
    accepted_values = local.site_secret_count
    secret_name     = aws_secretsmanager_secret.site_origin.name
    secret_arn      = aws_secretsmanager_secret.site_origin.arn
    open_paths      = var.site_origin_lock ? var.cms_origin_open_paths : []
  }
}

# Every rule of the HTTPS listener as one line per priority — what `terraform test` pins (tests/) and what a reader
# compares with `elbv2 describe-rules`. No secret: a header condition shows only as `secret×<number of accepted values>`.
locals {
  all_rules = concat(
    [aws_lb_listener_rule.live_get_head, aws_lb_listener_rule.live_options, aws_lb_listener_rule.live_other, aws_lb_listener_rule.live_forbidden],
    values(aws_lb_listener_rule.host),
    values(aws_lb_listener_rule.cms_cdn_locked),
    [aws_lb_listener_rule.cms_cdn, aws_lb_listener_rule.cms_cdn_method, aws_lb_listener_rule.cms_cdn_other],
    aws_lb_listener_rule.cms_cdn_forbidden,
    values(aws_lb_listener_rule.cms_labs_locked),
    [aws_lb_listener_rule.cms_labs, aws_lb_listener_rule.cms_labs_to_site, aws_lb_listener_rule.cms_labs_method],
    aws_lb_listener_rule.apex_redirect,
    aws_lb_listener_rule.cms_origin_open,
    [aws_lb_listener_rule.cms],
    aws_lb_listener_rule.cms_forbidden,
    values(aws_lb_listener_rule.files_public),
    aws_lb_listener_rule.files_publishers,
    [aws_lb_listener_rule.files_private, aws_lb_listener_rule.files_other],
  )
  tg_name = { for k, t in aws_lb_target_group.svc : t.arn => k }
}

output "listener_rule_table" {
  description = "priority → \"<hosts> [paths] [methods] [source] [secret×N] => <action>\" for every HTTPS listener rule (no secret value)."
  value = {
    for r in local.all_rules : tostring(r.priority) => nonsensitive(join(" ", compact(concat(
      flatten([for c in r.condition : [for h in c.host_header : "host=${join(",", sort(h.values))}"]]),
      flatten([for c in r.condition : [for h in c.path_pattern : "path=${join(",", sort(h.values))}"]]),
      flatten([for c in r.condition : [for h in c.http_request_method : "method=${join(",", sort(h.values))}"]]),
      flatten([for c in r.condition : [for h in c.source_ip : "source=${join(",", sort(h.values))}"]]),
      flatten([for c in r.condition : [for h in c.http_header : "${lower(h.http_header_name)}×${length(h.values)}"]]),
      ["=>"],
      [for a in r.action : a.type == "forward" ? "forward:${lookup(local.tg_name, a.target_group_arn, "?")}" : a.type == "redirect" ? "redirect:${a.redirect[0].status_code}:${a.redirect[0].host}${a.redirect[0].path}" : "fixed:${a.fixed_response[0].status_code}"],
    ))))
  }
}

output "listener_rule_max_values" {
  description = "The largest number of condition values any rule uses (the ALB allows 5 per rule)."
  value = max([
    for r in local.all_rules : nonsensitive(sum(concat([0], flatten([
      for c in r.condition : [
        [for h in c.host_header : length(h.values)], [for h in c.path_pattern : length(h.values)],
        [for h in c.http_request_method : length(h.values)], [for h in c.source_ip : length(h.values)],
        [for h in c.http_header : length(h.values)],
      ]
    ]))))
  ]...)
}
