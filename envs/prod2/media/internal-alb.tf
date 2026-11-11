# How a media box reaches the engine api PRIVATELY (PORTAL_INTERNAL_URL) — README "How a box reaches the engine".
#
# The agent calls the api's /internal/** (publish-auth on EVERY publish, ingest heartbeats, session health/state,
# vod events) with the relay secret. The public path cannot carry it: the engine edge (the ECS sidecar renders the
# same infra/nginx/edge.conf.template) answers `location ^~ /internal/ { return 404; }`. ECS Service Connect is for
# ECS clients only; Cloud Map DNS would need its private zone associated with every peered VPC and gives no health
# gate. So: an INTERNAL ALB in the home VPC's private subnets, :3000 → the api container's own port 3000 (not the
# edge), forwarding ONLY /internal/* and the health path. Its DNS name is public DNS resolving to private addresses,
# so a box in any peered VPC uses it with no DNS plumbing; inter-region peering traffic is encrypted by AWS.
#
# NEEDS A COMPUTE CHANGE (not made here — README "Cross-stack"): the engine-api service must register its `api`
# container (port 3000) in this target group as a SECOND load balancer (modules/ecs-service takes one today).
# Until then the target group is empty and every agent call answers 503.

resource "aws_security_group" "engine_internal" {
  count       = var.create_engine_internal_alb ? 1 : 0
  name        = "gkoi-prod2-engine-internal-alb"
  description = "Internal ALB: media boxes to the engine api /internal/* on 3000"
  vpc_id      = local.net.home_vpc_id
  tags        = { Name = "gkoi-prod2-engine-internal-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "engine_internal_home_box" {
  count                        = var.create_engine_internal_alb ? length(module.box_usw2) : 0
  security_group_id            = aws_security_group.engine_internal[0].id
  description                  = "usw2 media box"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = module.box_usw2[0].security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "engine_internal_spokes" {
  for_each          = var.create_engine_internal_alb ? { for k, v in local.enabled : k => local.net.regions[k].cidr if k != local.home_key } : {}
  security_group_id = aws_security_group.engine_internal[0].id
  description       = "${each.key} media VPC (peered)"
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "engine_internal_to_tasks" {
  count                        = var.create_engine_internal_alb ? 1 : 0
  security_group_id            = aws_security_group.engine_internal[0].id
  description                  = "To the engine api tasks (3000)"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = local.net.ecs_tasks_security_group_id
}

# The ECS tasks SG admits the internal ALB on the api's own port (edge-alb / data add their rules the same way).
resource "aws_vpc_security_group_ingress_rule" "tasks_from_engine_internal" {
  count                        = var.create_engine_internal_alb ? 1 : 0
  security_group_id            = local.net.ecs_tasks_security_group_id
  description                  = "Engine internal ALB → api 3000 (media boxes' /internal/*)"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.engine_internal[0].id
}

resource "aws_lb" "engine_internal" {
  count                      = var.create_engine_internal_alb ? 1 : 0
  name                       = "gkoi-prod2-engine-internal"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = local.net.home_private_subnet_ids
  security_groups            = [aws_security_group.engine_internal[0].id]
  idle_timeout               = 60 # the agents' HTTP_KEEPALIVE_MS (55 s) stays below it
  drop_invalid_header_fields = true
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "engine_internal" {
  count                = var.create_engine_internal_alb ? 1 : 0
  name                 = "gkoi-prod2-engine-api-int"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.net.home_vpc_id
  deregistration_delay = 20

  health_check {
    path                = "/api/v1/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "engine_internal" {
  count             = var.create_engine_internal_alb ? 1 : 0
  load_balancer_arn = aws_lb.engine_internal[0].arn
  port              = 3000
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"not_found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "engine_internal" {
  count        = var.create_engine_internal_alb ? 1 : 0
  listener_arn = aws_lb_listener.engine_internal[0].arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/internal/*", "/api/v1/healthz"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.engine_internal[0].arn
  }
}
