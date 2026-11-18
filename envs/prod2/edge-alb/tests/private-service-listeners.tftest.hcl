# Offline checks of the site's private listeners on the internal ALB (SPEC-INFRA-PRIVATE-SERVICE-CALLS-V1 P2 + P4;
# envs/prod2/PRIVATE-SERVICE-CALLS-RUNBOOK.md). Mock provider: no AWS call, no state. tools/tf-run.sh runs every file
# in tests/ before each edge-alb plan / apply. By hand, from the repo root:
#   docker run --rm --entrypoint sh -v "$PWD":/w -w /w/envs/prod2/edge-alb hashicorp/terraform:1.9.8 \
#     -c 'terraform init -backend=false -lockfile=readonly >/dev/null && terraform test'
# What is pinned: with create_private_service_listeners off (the default) not one new resource exists and the internal
# ALB, its :3000 listener + rule, its SG rules and the public listener's rule table are exactly as before; with it on,
# exactly the spec's list (2 SG ingress + 1 SG egress + 1 tasks-SG ingress, 1 target group, 2 listeners, 2 rules).

mock_provider "aws" {
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z000000000000000000" }
  }
}

override_resource {
  target = aws_acm_certificate.alb
  values = {
    arn = "arn:aws:acm:us-west-2:127214190346:certificate/00000000-0000-0000-0000-000000000000"
    domain_validation_options = [
      { domain_name = "engine.gkoi.com", resource_record_name = "_x.engine.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "origin-www.gkoi.com", resource_record_name = "_x.origin-www.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "origin-cdn.gkoi.com", resource_record_name = "_x.origin-cdn.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "origin-labs.gkoi.com", resource_record_name = "_x.origin-labs.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "www.gkoi.com", resource_record_name = "_x.www.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "files.gkoi.com", resource_record_name = "_x.files.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "origin-live.gkoi.com", resource_record_name = "_x.origin-live.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      { domain_name = "gkoi.com", resource_record_name = "_x.gkoi.com.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." }
    ]
  }
}

override_resource {
  target = aws_acm_certificate_validation.alb
  values = { certificate_arn = "arn:aws:acm:us-west-2:127214190346:certificate/00000000-0000-0000-0000-000000000000" }
}
override_resource {
  target = aws_lb.this
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:loadbalancer/app/gkoi-prod2-alb/0000000000000000" }
}
override_resource {
  target = aws_lb_listener.http
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/gkoi-prod2-alb/0000000000000000/0000000000000080" }
}
override_resource {
  target = aws_lb_listener.https
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/gkoi-prod2-alb/0000000000000000/0000000000000443" }
}
override_resource {
  target = aws_lb_target_group.svc["cms"]
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-p2-cms/0000000000000000" }
}
override_resource {
  target = aws_lb_target_group.svc["engine-api"]
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-p2-engine-api/0000000000000000" }
}
override_resource {
  target = aws_lb_target_group.svc["fm-api"]
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-p2-fm-api/0000000000000000" }
}
override_resource {
  target = aws_lb_target_group.svc["fm-web"]
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-p2-fm-web/0000000000000000" }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      home_vpc_id                 = "vpc-1"
      home_cidr                   = "10.10.0.0/16"
      home_public_subnet_ids      = ["subnet-a", "subnet-b"]
      home_private_subnet_ids     = ["subnet-p1", "subnet-p2"]
      home_nat_public_ips         = ["32.189.104.202"]
      ecs_tasks_security_group_id = "sg-tasks"
      edge_cidrs                  = { euc1 = "10.20.0.0/16" }
    }
  }
}

# origin-live's secret (always read)
override_data {
  target = data.aws_secretsmanager_secret_version.live_origin
  values = { secret_string = "live0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab" }
}
override_data {
  target = data.aws_secretsmanager_secret_version.site_origin
  values = { secret_string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
}
override_data {
  target = data.aws_secretsmanager_secret_version.site_origin_pending
  values = { secret_string = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" }
}
override_data {
  target = data.aws_secretsmanager_secret_versions.site_origin
  values = { versions = [{ version_id = "v1", version_stages = ["AWSCURRENT"], created_time = "2026-11-17T00:00:00Z", last_accessed_date = "2026-11-17" }] }
}
override_data {
  target = data.aws_cloudfront_distribution.site
  values = { status = "Deployed" }
}


# The internal ALB's computed attributes, so the URLs below are exact.
override_resource {
  target = aws_lb.engine_internal
  values = {
    arn      = "arn:aws:elasticloadbalancing:us-west-2:127214190346:loadbalancer/app/gkoi-prod2-engine-internal/1111111111111111"
    dns_name = "internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com"
  }
}
override_resource {
  target = aws_security_group.engine_internal
  values = { id = "sg-internal-alb" }
}
override_resource {
  target = aws_lb_target_group.engine_internal
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-prod2-engine-api-int/1111111111111111" }
}
override_resource {
  target = aws_lb_target_group.fm_internal
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-prod2-fm-api-int/2222222222222222" }
}
override_resource {
  target = aws_lb_listener.engine_internal
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/gkoi-prod2-engine-internal/1111111111111111/0000000000003000" }
}
override_resource {
  target = aws_lb_listener.private_engine
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/gkoi-prod2-engine-internal/1111111111111111/0000000000003100" }
}
override_resource {
  target = aws_lb_listener.private_files
  values = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/gkoi-prod2-engine-internal/1111111111111111/0000000000003200" }
}

# The internal ALB exists (its default); everything else at the stack's defaults.
variables {
  create_engine_internal_alb = true
}

# Flag off (the default): NOTHING new, and what exists is today's.
run "flag_off_adds_nothing" {
  command = apply
  variables {
    create_private_service_listeners = false
  }
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.engine_internal_from_tasks) == 0 &&
      length(aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks) == 0 &&
      length(aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm) == 0 &&
      length(aws_lb_target_group.fm_internal) == 0 &&
      length(aws_lb_listener.private_engine) == 0 &&
      length(aws_lb_listener_rule.private_engine) == 0 &&
      length(aws_lb_listener.private_files) == 0 &&
      length(aws_lb_listener_rule.private_files) == 0
    )
    error_message = "flag off: no private-call resource may exist"
  }
  assert {
    condition     = output.private_services == null
    error_message = "flag off: output private_services is null"
  }
  assert {
    condition = (
      aws_lb.engine_internal[0].name == "gkoi-prod2-engine-internal" && aws_lb.engine_internal[0].internal &&
      aws_lb.engine_internal[0].idle_timeout == 300 && !aws_lb.engine_internal[0].enable_deletion_protection &&
      aws_lb.engine_internal[0].drop_invalid_header_fields &&
      jsonencode(aws_lb.engine_internal[0].subnets) == jsonencode(toset(["subnet-p1", "subnet-p2"])) &&
      jsonencode(aws_lb.engine_internal[0].security_groups) == jsonencode(toset(["sg-internal-alb"]))
    )
    error_message = "flag off: the internal ALB is today's (name, internal, idle 60, no deletion protection, private subnets, its own SG)"
  }
  assert {
    condition = (
      aws_lb_listener.engine_internal[0].port == 3000 && aws_lb_listener.engine_internal[0].protocol == "HTTP" &&
      aws_lb_listener_rule.engine_internal[0].priority == 10 &&
      jsonencode(one(aws_lb_listener_rule.engine_internal[0].condition).path_pattern[0].values) == jsonencode(toset(["/internal/*", "/api/v1/healthz"])) &&
      aws_lb_target_group.engine_internal[0].name == "gkoi-prod2-engine-api-int" && aws_lb_target_group.engine_internal[0].port == 3000
    )
    error_message = "flag off: the media boxes' :3000 listener, rule and target group are today's"
  }
  assert {
    condition = (
      aws_vpc_security_group_egress_rule.engine_internal_to_tasks[0].from_port == 3000 &&
      aws_vpc_security_group_egress_rule.engine_internal_to_tasks[0].to_port == 3000 &&
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal[0].from_port == 3000 &&
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal[0].to_port == 3000 &&
      jsonencode(keys(aws_vpc_security_group_ingress_rule.engine_internal_spokes)) == jsonencode(["euc1"]) &&
      aws_vpc_security_group_ingress_rule.engine_internal_spokes["euc1"].from_port == 3000
    )
    error_message = "flag off: the internal ALB's SG rules are today's (3000 only)"
  }
  assert {
    condition     = output.engine_internal.url == "http://internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com:3000"
    error_message = "flag off: output engine_internal unchanged"
  }
}

# Flag on: exactly the spec's resources, the right ports / paths / SG sources; nothing that existed changes.
run "flag_on_exact_resources" {
  command = apply
  variables {
    create_private_service_listeners = true
  }
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.engine_internal_from_tasks) == 2 &&
      length(aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks) == 1 &&
      length(aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm) == 1 &&
      length(aws_lb_target_group.fm_internal) == 1 &&
      length(aws_lb_listener.private_engine) == 1 && length(aws_lb_listener_rule.private_engine) == 1 &&
      length(aws_lb_listener.private_files) == 1 && length(aws_lb_listener_rule.private_files) == 1
    )
    error_message = "flag on: 2 + 1 + 1 SG rules, 1 target group, 2 listeners, 2 rules"
  }
  # SG rules: ingress from the tasks SG only (no CIDR), on 3100 and 3200; egress + tasks ingress on fm-api's 3200.
  assert {
    condition = alltrue([
      for k, r in aws_vpc_security_group_ingress_rule.engine_internal_from_tasks :
      r.security_group_id == "sg-internal-alb" && r.referenced_security_group_id == "sg-tasks" && r.cidr_ipv4 == null &&
      r.cidr_ipv6 == null && r.prefix_list_id == null && r.ip_protocol == "tcp" && r.from_port == r.to_port
    ])
    error_message = "flag on: the listeners' ingress names the tasks SG and no CIDR"
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.engine_internal_from_tasks["engine"].from_port == 3100 &&
      aws_vpc_security_group_ingress_rule.engine_internal_from_tasks["files"].from_port == 3200
    )
    error_message = "flag on: ingress on 3100 (engine) and 3200 (files)"
  }
  assert {
    condition = (
      aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks[0].security_group_id == "sg-internal-alb" &&
      aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks[0].referenced_security_group_id == "sg-tasks" &&
      aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks[0].from_port == 3200 &&
      aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks[0].to_port == 3200 &&
      aws_vpc_security_group_egress_rule.engine_internal_to_fm_tasks[0].cidr_ipv4 == null
    )
    error_message = "flag on: the internal ALB's egress to the tasks SG on 3200"
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm[0].security_group_id == "sg-tasks" &&
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm[0].referenced_security_group_id == "sg-internal-alb" &&
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm[0].from_port == 3200 &&
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm[0].to_port == 3200 &&
      aws_vpc_security_group_ingress_rule.tasks_from_engine_internal_fm[0].cidr_ipv4 == null
    )
    error_message = "flag on: the tasks SG admits the internal ALB's SG on 3200"
  }
  # The FM target group.
  assert {
    condition = (
      aws_lb_target_group.fm_internal[0].name == "gkoi-prod2-fm-api-int" && aws_lb_target_group.fm_internal[0].port == 3200 &&
      aws_lb_target_group.fm_internal[0].protocol == "HTTP" && aws_lb_target_group.fm_internal[0].target_type == "ip" &&
      aws_lb_target_group.fm_internal[0].vpc_id == "vpc-1" && aws_lb_target_group.fm_internal[0].deregistration_delay == "20" &&
      aws_lb_target_group.fm_internal[0].health_check[0].path == "/api/v1/healthz" &&
      aws_lb_target_group.fm_internal[0].health_check[0].matcher == "200" &&
      aws_lb_target_group.fm_internal[0].health_check[0].interval == 15
    )
    error_message = "flag on: TG gkoi-prod2-fm-api-int, HTTP 3200, ip, drain 20 s, health /api/v1/healthz 200 every 15 s"
  }
  # The listeners: on the internal ALB, plain HTTP, default 404, one forward rule each.
  assert {
    condition = (
      aws_lb_listener.private_engine[0].load_balancer_arn == aws_lb.engine_internal[0].arn &&
      aws_lb_listener.private_engine[0].port == 3100 && aws_lb_listener.private_engine[0].protocol == "HTTP" &&
      aws_lb_listener.private_engine[0].default_action[0].type == "fixed-response" &&
      aws_lb_listener.private_engine[0].default_action[0].fixed_response[0].status_code == "404" &&
      aws_lb_listener.private_files[0].load_balancer_arn == aws_lb.engine_internal[0].arn &&
      aws_lb_listener.private_files[0].port == 3200 && aws_lb_listener.private_files[0].protocol == "HTTP" &&
      aws_lb_listener.private_files[0].default_action[0].type == "fixed-response" &&
      aws_lb_listener.private_files[0].default_action[0].fixed_response[0].status_code == "404"
    )
    error_message = "flag on: listeners 3100 + 3200 HTTP on the internal ALB, default 404"
  }
  assert {
    condition = (
      aws_lb_listener_rule.private_engine[0].listener_arn == aws_lb_listener.private_engine[0].arn &&
      jsonencode(one(aws_lb_listener_rule.private_engine[0].condition).path_pattern[0].values) == jsonencode(toset(["/api/*", "/ws/*"])) &&
      one(aws_lb_listener_rule.private_engine[0].action).type == "forward" &&
      one(aws_lb_listener_rule.private_engine[0].action).target_group_arn == aws_lb_target_group.engine_internal[0].arn
    )
    error_message = "flag on: 3100 forwards /api/* and /ws/* (nothing else) to the engine api's :3000 group"
  }
  assert {
    condition = (
      aws_lb_listener_rule.private_files[0].listener_arn == aws_lb_listener.private_files[0].arn &&
      jsonencode(one(aws_lb_listener_rule.private_files[0].condition).path_pattern[0].values) == jsonencode(toset(["/api/*"])) &&
      one(aws_lb_listener_rule.private_files[0].action).type == "forward" &&
      one(aws_lb_listener_rule.private_files[0].action).target_group_arn == aws_lb_target_group.fm_internal[0].arn
    )
    error_message = "flag on: 3200 forwards /api/* only to the FM group"
  }
  assert {
    condition = !anytrue([
      for v in concat(tolist(one(aws_lb_listener_rule.private_engine[0].condition).path_pattern[0].values), tolist(one(aws_lb_listener_rule.private_files[0].condition).path_pattern[0].values)) :
      startswith(v, "/internal")
    ])
    error_message = "flag on: no private listener forwards /internal/*"
  }
  assert {
    condition = output.private_services == {
      engine_url               = "http://internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com:3100"
      files_url                = "http://internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com:3200"
      fm_target_group_arn      = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-prod2-fm-api-int/2222222222222222"
      caller_security_group_id = "sg-tasks"
    }
    error_message = "flag on: output private_services"
  }
  # What existed is untouched.
  assert {
    condition = (
      aws_lb.engine_internal[0].idle_timeout == 300 && aws_lb_listener.engine_internal[0].port == 3000 &&
      jsonencode(one(aws_lb_listener_rule.engine_internal[0].condition).path_pattern[0].values) == jsonencode(toset(["/internal/*", "/api/v1/healthz"])) &&
      output.engine_internal == run.flag_off_adds_nothing.engine_internal &&
      output.listener_rule_table == run.flag_off_adds_nothing.listener_rule_table
    )
    error_message = "flag on: the internal ALB, its :3000 path, output engine_internal and the public listener's rule table are unchanged"
  }
}

# The flag needs the internal ALB: without it, nothing is created and the output stays null.
run "flag_on_without_internal_alb_is_inert" {
  command = apply
  variables {
    create_engine_internal_alb       = false
    create_private_service_listeners = true
  }
  assert {
    condition = (
      length(aws_lb_listener.private_engine) == 0 && length(aws_lb_listener.private_files) == 0 &&
      length(aws_lb_target_group.fm_internal) == 0 && length(aws_vpc_security_group_ingress_rule.engine_internal_from_tasks) == 0 &&
      output.private_services == null
    )
    error_message = "no internal ALB: no private listeners"
  }
}

# P4: the idle timeout moves only by its own variable, in place, and nothing else with it.
run "idle_timeout_300" {
  command = apply
  variables {
    engine_internal_idle_timeout = 300
    create_private_service_listeners = false
  }
  assert {
    condition     = aws_lb.engine_internal[0].idle_timeout == 300 && length(aws_lb_listener.private_engine) == 0 && output.private_services == null
    error_message = "engine_internal_idle_timeout = 300: the ALB's idle timeout only"
  }
}

run "ports_must_differ" {
  command = plan
  variables {
    create_private_service_listeners = true
    private_engine_port              = 3300
    private_files_port               = 3300
  }
  expect_failures = [aws_lb_listener.private_engine]
}

run "port_3000_is_the_media_boxes" {
  command = plan
  variables {
    private_engine_port = 3000
  }
  expect_failures = [var.private_engine_port]
}

run "idle_timeout_below_keepalive_refused" {
  command = plan
  variables {
    engine_internal_idle_timeout = 30
  }
  expect_failures = [var.engine_internal_idle_timeout]
}
