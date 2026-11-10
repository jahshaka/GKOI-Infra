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
