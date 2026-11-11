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
  apex_fqdn    = var.zone_name
  cert_names   = distinct(concat(flatten(values(local.service_fqdns)), [local.live_fqdn], var.apex_redirect ? [local.apex_fqdn] : []))
  cert_primary = "engine.${var.zone_name}"
  cert_sans    = [for n in local.cert_names : n if n != local.cert_primary]

  live_secret_raw = data.aws_secretsmanager_secret_version.live_origin.secret_string
  live_secret = (
    var.live_origin_secret_json_key == null
    ? local.live_secret_raw
    : jsondecode(local.live_secret_raw)[var.live_origin_secret_json_key]
  )

  # Stable rule priorities per service with hosts (cms 100, engine-api 110, fm-api 120 — computed over EVERY service with
  # hosts, so taking cms and fm-api out of the generic rule below leaves engine-api at 110, unchanged).
  with_hosts = { for k, s in var.services : k => s if length(s.hosts) > 0 }
  routed_priority = {
    for i, k in sort(keys(local.with_hosts)) : k => 100 + i * 10
  }
  # cms and fm-api have their own rules (the "cms" and "files" sections below); every other service with hosts gets
  # the generic host → forward rule.
  custom_routed = ["cms", "fm-api"]
  routed        = { for k, s in local.with_hosts : k => s if !contains(local.custom_routed, k) }

  # --- cms (audit 2026-11-11 B4-2/B4-3/B4-4): prod's HOST nginx on the site box, rule by rule ---------------------
  cms_cdn_fqdn  = "${var.cms_cdn_origin_host}.${var.zone_name}"
  cms_labs_fqdn = "${var.cms_labs_origin_host}.${var.zone_name}"
  site_fqdn     = "${var.cms_site_host}.${var.zone_name}"
  # every other cms host (origin-www, www) is forwarded whole, as prod's www server block does
  cms_open_fqdns = [for h in local.service_fqdns["cms"] : h if h != local.cms_cdn_fqdn && h != local.cms_labs_fqdn]

  # --- files (audit B3-6): prod's public file-manager listener is an allow-list --------------------------------
  fm_fqdns = local.service_fqdns["fm-api"]
  # ≤ 3 values per condition: the public paths in groups of three, one rule each (priorities 300, 301, …)
  fm_public_path_groups = { for i, g in chunklist(var.fm_public_paths, 3) : tostring(i) => g }
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

  # HSTS on every response of this listener (www / apex / labs / cdn origins, engine, files): the Lightsail host nginx
  # used to add it; nothing did after the move (2026-11-11). No includeSubDomains / preload: stream-*, game-* and dev
  # hosts stay unpinned. Set by hand the same day; this keeps an apply from clearing it.
  routing_http_response_strict_transport_security_header_value = "max-age=31536000"

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
      condition     = length(local.service_fqdns[each.key]) <= 3
      error_message = "An ALB condition takes at most 3 values (and a rule at most 5 in all)."
    }
  }
}

# --- cms (priorities 200–230) — audit 2026-11-11 B4-2 / B4-3 / B4-4 ---------------------------------------------
# Prod's HOST nginx on the Lightsail site box (sites-enabled/{www,cdn,labs}.gkoi.com) put a server block per name in
# front of the container nginx. What an ALB rule can reproduce is here; what it can not — rewriting Host (the AWS
# provider in use, < 6.0, has no listener-rule `transform`), stripping Cookie / Set-Cookie / X-Labs-Isolation — is
# listed in README "edge-alb, the cms hosts".
# The new numbers do not reuse 100 / 120 (the old generic cms / files rules): an apply creates these while it deletes
# those, and two rules may not share a priority.

# origin-cdn (CloudFront cdn.gkoi.com, Host = origin-cdn.gkoi.com): ONLY /content/** and /assets/**, GET/HEAD — the
# same answers as prod's `limit_except GET HEAD { deny all; }` (403) and `location / { return 404; }`.
resource "aws_lb_listener_rule" "cms_cdn" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["cms"].arn
  }

  condition {
    host_header { values = [local.cms_cdn_fqdn] }
  }
  condition {
    path_pattern { values = var.cms_cdn_paths }
  }
  condition {
    http_request_method { values = ["GET", "HEAD"] }
  }

  lifecycle {
    precondition {
      condition     = contains(local.service_fqdns["cms"], local.cms_cdn_fqdn) && length(var.cms_cdn_paths) <= 2
      error_message = "cms_cdn_origin_host must be one of services.cms.hosts, and cms_cdn_paths at most 2 (1 host + 2 paths + 2 methods = the 5-value rule limit)."
    }
  }
}

resource "aws_lb_listener_rule" "cms_cdn_method" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 201

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Forbidden"
    }
  }

  condition {
    host_header { values = [local.cms_cdn_fqdn] }
  }
  condition {
    path_pattern { values = var.cms_cdn_paths }
  }
}

resource "aws_lb_listener_rule" "cms_cdn_other" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 202

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "Not found"
    }
  }

  condition {
    host_header { values = [local.cms_cdn_fqdn] }
  }
}

# origin-labs (CloudFront labs.gkoi.com, Host = origin-labs.gkoi.com). Prod rewrote Host to labs.gkoi.com so the
# container nginx's LABS server block (server_name labs.invalid ${LABS_HOST}) answered: /content/labs/** off disk with
# the per-version isolation headers, everything else a 302 to the site's /labs. The ALB can not rewrite Host, so until
# the container nginx also names origin-labs.gkoi.com (README "edge-alb, the cms hosts") the request lands on the MAIN
# server. These rules keep the labs name from serving the whole site meanwhile: /content/labs/** GET/HEAD is
# forwarded, any other GET/HEAD gets the labs block's own 302 to the site's Labs page, any other method 403 (prod's
# `limit_except GET HEAD`). Once the nginx side lands they stay correct (the labs block then answers /content/labs/**).
resource "aws_lb_listener_rule" "cms_labs" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 210

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["cms"].arn
  }

  condition {
    host_header { values = [local.cms_labs_fqdn] }
  }
  condition {
    path_pattern { values = ["/content/labs/*"] }
  }
  condition {
    http_request_method { values = ["GET", "HEAD"] }
  }

  lifecycle {
    precondition {
      condition     = contains(local.service_fqdns["cms"], local.cms_labs_fqdn)
      error_message = "cms_labs_origin_host must be one of services.cms.hosts."
    }
  }
}

resource "aws_lb_listener_rule" "cms_labs_to_site" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 211

  action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      host        = local.site_fqdn
      path        = "/labs"
      status_code = "HTTP_302"
    }
  }

  condition {
    host_header { values = [local.cms_labs_fqdn] }
  }
  condition {
    http_request_method { values = ["GET", "HEAD"] }
  }
}

resource "aws_lb_listener_rule" "cms_labs_method" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 212

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Forbidden"
    }
  }

  condition {
    host_header { values = [local.cms_labs_fqdn] }
  }
}

# The apex (gkoi.com): prod's 443 server `server_name gkoi.com; return 301 https://www.gkoi.com$request_uri;`. Only
# reached once the apex record points at this ALB (today it is the Lightsail site box's address).
resource "aws_lb_listener_rule" "apex_redirect" {
  count        = var.apex_redirect ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = 220

  action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      host        = local.site_fqdn
      path        = "/#{path}"
      query       = "#{query}"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header { values = [local.apex_fqdn] }
  }
}

# origin-www (CloudFront www.gkoi.com's /assets, /content, /favicon*, /apple-touch-icon* behaviours, Host =
# origin-www.gkoi.com) and www.gkoi.com (its default behaviour forwards the viewer's Host, B4-2): the whole site.
resource "aws_lb_listener_rule" "cms" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 230

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["cms"].arn
  }

  condition {
    host_header { values = local.cms_open_fqdns }
  }

  lifecycle {
    precondition {
      condition     = length(local.cms_open_fqdns) >= 1 && length(local.cms_open_fqdns) <= 3
      error_message = "The cms hosts other than the cdn / labs origins must be 1–3 (an ALB condition takes at most 3 values)."
    }
  }
}

# --- files (priorities 300–3xx) — audit 2026-11-11 B3-6 -----------------------------------------------------------
# Prod's public file-manager listener (gkoi-beta-core sites-enabled/files.gkoi.com, from filemanager
# infra/nginx/fm-proxy.conf.example) is an ALLOW-LIST: /api/v1/app/**, /thumbs/**, /api/v1/healthz, /api/v1/readyz;
# everything else (admin, auth incl. the one-shot register, devices, /me) 404. The CMS (and the engine pilot) used a
# PRIVATE listener (172.26.7.222:3210) open to the site box only. Here: the public paths for everyone, every other path
# only from var.cms_source_cidrs (the Lightsail site box, then the NAT every ECS task leaves by), else 404.
# (cdn.gkoi.com's /thumbs/* behaviour uses files.gkoi.com as its origin — /thumbs/* is public on purpose.)
resource "aws_lb_listener_rule" "files_public" {
  for_each     = local.fm_public_path_groups
  listener_arn = aws_lb_listener.https.arn
  priority     = 300 + tonumber(each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["fm-api"].arn
  }

  condition {
    host_header { values = local.fm_fqdns }
  }
  condition {
    path_pattern { values = each.value }
  }

  lifecycle {
    precondition {
      condition     = length(local.fm_fqdns) <= 2
      error_message = "fm-api takes at most 2 hosts here (host values + 3 paths ≤ the 5-value rule limit)."
    }
  }
}

resource "aws_lb_listener_rule" "files_private" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 320

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["fm-api"].arn
  }

  condition {
    host_header { values = local.fm_fqdns }
  }
  condition {
    source_ip { values = var.cms_source_cidrs }
  }

  lifecycle {
    precondition {
      condition     = length(local.fm_fqdns) <= 3
      error_message = "An ALB condition takes at most 3 values."
    }
  }
}

resource "aws_lb_listener_rule" "files_other" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 321

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = "{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}"
    }
  }

  condition {
    host_header { values = local.fm_fqdns }
  }
}

# The NAT's address is the CMS's (and every ECS task's) source once the CMS runs on ECS (P4): warn when the network
# stack's NAT addresses are not all in cms_source_cidrs.
check "cms_source_cidrs_cover_nat" {
  assert {
    condition     = alltrue([for ip in local.net.home_nat_public_ips : contains(var.cms_source_cidrs, "${ip}/32")])
    error_message = "cms_source_cidrs does not hold every home NAT address (network output home_nat_public_ips) as /32."
  }
}
