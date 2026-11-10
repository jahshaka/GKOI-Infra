# Stage 2 — the home-region ALB: public, 2 AZs, ACM cert (DNS-validated in the existing zone), HTTP→HTTPS, a 404
# default, host rules → placeholder target groups, and the origin-live lock.

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/network/terraform.tfstate"
    region = "us-west-2"
  }
}

locals {
  net = data.terraform_remote_state.network.outputs

  live_fqdn = "${var.live_origin_host}.${var.zone_name}"
  service_fqdns = {
    for k, s in var.services : k => [for h in s.hosts : "${h}.${var.zone_name}"]
  }
  cert_names   = distinct(concat(flatten(values(local.service_fqdns)), [local.live_fqdn]))
  cert_primary = "engine.${var.zone_name}"
  cert_sans    = [for n in local.cert_names : n if n != local.cert_primary]

  live_secret_raw = data.aws_secretsmanager_secret_version.live_origin.secret_string
  live_secret = (
    var.live_origin_secret_json_key == null
    ? local.live_secret_raw
    : jsondecode(local.live_secret_raw)[var.live_origin_secret_json_key]
  )

  # Stable rule priorities per service with hosts (cms 100, engine-api 110, ...).
  routed = { for k, s in var.services : k => s if length(s.hosts) > 0 }
  routed_priority = {
    for i, k in sort(keys(local.routed)) : k => 100 + i * 10
  }
}

data "aws_route53_zone" "this" {
  name         = var.zone_name
  private_zone = false
}

data "aws_secretsmanager_secret_version" "live_origin" {
  secret_id = var.live_origin_secret_id
}

# --- certificate -------------------------------------------------------------------------------------------------

resource "aws_acm_certificate" "alb" {
  domain_name               = local.cert_primary
  subject_alternative_names = local.cert_sans
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"
  tags                      = { Name = "gkoi-prod2-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

# ONLY the `_<token>.<name>` validation CNAMEs. ACM's validation record for a name is the same for every cert of
# that name in this account, so a CNAME an existing cert already uses has the identical value: allow_overwrite
# adopts it without changing it. (Destroying this stack would then delete it — see README "edge-alb".)
resource "aws_route53_record" "validation" {
  for_each = {
    for o in aws_acm_certificate.alb.domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  }
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# --- security groups -------------------------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "gkoi-prod2-alb"
  description = "The control-plane ALB: 80/443 from the internet"
  vpc_id      = local.net.home_vpc_id
  tags        = { Name = "gkoi-prod2-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirected to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# One rule per DISTINCT task port (two services on 8080 — cms nginx and the engine edge — share it; per-service
# rules would collide as duplicates).
locals {
  task_ports = toset([for s in var.services : tostring(s.port)])
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  for_each                     = local.task_ports
  security_group_id            = aws_security_group.alb.id
  description                  = "To tasks on ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  referenced_security_group_id = local.net.ecs_tasks_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  for_each                     = local.task_ports
  security_group_id            = local.net.ecs_tasks_security_group_id
  description                  = "Tasks on ${each.key} from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  referenced_security_group_id = aws_security_group.alb.id
}

# --- the load balancer -----------------------------------------------------------------------------------------

resource "aws_lb" "this" {
  name                       = "gkoi-prod2-alb"
  load_balancer_type         = "application"
  internal                   = false
  ip_address_type            = "ipv4"
  subnets                    = local.net.home_public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = var.idle_timeout
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  tags                       = { Name = "gkoi-prod2-alb" }
}

resource "aws_lb_target_group" "svc" {
  for_each = var.services
  # The port is in the name so a port change creates the new group BEFORE the old one is released by its rules.
  name                 = "gkoi-p2-${each.key}-${each.value.port}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.net.home_vpc_id
  deregistration_delay = 30

  health_check {
    path                = each.value.health_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "gkoi-p2-${each.key}", service = each.key }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = "{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}"
    }
  }
}

# --- origin-live: the lock (priorities 10–13, before every host rule) -----------------------------------------
# The engine edge's origin-live server (mikaido infra/nginx/edge-live-origin-on.conf.template) serves ONLY
# GET/HEAD/OPTIONS /api/v1/watch/** and only with the secret header; everything else 403 (no header) or 404.
# An ALB rule takes at most 5 condition values, so GET+HEAD and OPTIONS are two forward rules.

resource "aws_lb_listener_rule" "live_get_head" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["engine-api"].arn
  }

  condition {
    host_header { values = [local.live_fqdn] }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [local.live_secret]
    }
  }
  condition {
    path_pattern { values = [var.live_origin_path] }
  }
  condition {
    http_request_method { values = ["GET", "HEAD"] }
  }

  lifecycle {
    precondition {
      # ALB condition values are at most 128 chars; the engine edge allows 32–256 of [A-Za-z0-9_-].
      condition     = can(regex("^[A-Za-z0-9_-]{32,128}$", local.live_secret))
      error_message = "The live-origin secret must be 32–128 characters of [A-Za-z0-9_-] to fit an ALB header condition."
    }
  }
}

resource "aws_lb_listener_rule" "live_options" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 11

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["engine-api"].arn
  }

  condition {
    host_header { values = [local.live_fqdn] }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [local.live_secret]
    }
  }
  condition {
    path_pattern { values = [var.live_origin_path] }
  }
  condition {
    http_request_method { values = ["OPTIONS"] }
  }
}

# Secret present but another path/method: 404 no-store, as the nginx origin-live server answers.
resource "aws_lb_listener_rule" "live_other" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 12

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = "{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}"
    }
  }

  condition {
    host_header { values = [local.live_fqdn] }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [local.live_secret]
    }
  }
}

# No (or a wrong) secret: 403.
resource "aws_lb_listener_rule" "live_forbidden" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 13

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "403"
      message_body = "{\"error\":{\"code\":\"forbidden\",\"message\":\"Forbidden\"}}"
    }
  }

  condition {
    host_header { values = [local.live_fqdn] }
  }
}

# --- host rules ------------------------------------------------------------------------------------------------

resource "aws_lb_listener_rule" "host" {
  for_each     = local.routed
  listener_arn = aws_lb_listener.https.arn
  priority     = local.routed_priority[each.key]

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc[each.key].arn
  }

  condition {
    host_header { values = local.service_fqdns[each.key] }
  }

  lifecycle {
    precondition {
      condition     = length(local.service_fqdns[each.key]) <= 5
      error_message = "An ALB host-header condition takes at most 5 values."
    }
  }
}
