# Offline checks of the HTTPS listener's rule table and the site-origin lock (mock provider: no AWS call, no state).
# tools/tf-run.sh runs them before every edge-alb plan / apply (in CodeBuild). By hand, from the repo root:
#   docker run --rm --entrypoint sh -v "$PWD":/w -w /w/envs/prod2/edge-alb hashicorp/terraform:1.9.8 \
#     -c 'terraform init -backend=false -lockfile=readonly >/dev/null && terraform test'
# The tables below are the listener, one line per priority (output listener_rule_table): a rule change that is meant
# changes its line here in the same commit.

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

variables {
  create_engine_internal_alb = false
}

# Lock off (the default): EXACTLY the listener as it is live on 2026-11-17 — 18 rules + the default.
run "lock_off_is_todays_table" {
  command = apply
  assert {
    condition = output.listener_rule_table == {
      "10"  = "host=origin-live.gkoi.com path=/api/v1/watch/* method=GET,HEAD x-origin-verify×1 => forward:engine-api"
      "11"  = "host=origin-live.gkoi.com path=/api/v1/watch/* method=OPTIONS x-origin-verify×1 => forward:engine-api"
      "12"  = "host=origin-live.gkoi.com x-origin-verify×1 => fixed:404"
      "13"  = "host=origin-live.gkoi.com => fixed:403"
      "110" = "host=engine.gkoi.com => forward:engine-api"
      "200" = "host=origin-cdn.gkoi.com path=/assets/*,/content/* method=GET,HEAD => forward:cms"
      "201" = "host=origin-cdn.gkoi.com path=/assets/*,/content/* => fixed:403"
      "202" = "host=origin-cdn.gkoi.com => fixed:404"
      "210" = "host=origin-labs.gkoi.com path=/content/labs/* method=GET,HEAD => forward:cms"
      "211" = "host=origin-labs.gkoi.com method=GET,HEAD => redirect:HTTP_302:www.gkoi.com/labs"
      "212" = "host=origin-labs.gkoi.com => fixed:403"
      "220" = "host=gkoi.com => redirect:HTTP_301:www.gkoi.com/#{path}"
      "230" = "host=origin-www.gkoi.com,www.gkoi.com => forward:cms"
      "300" = "host=files.gkoi.com path=/api/v1/app/*,/api/v1/healthz,/thumbs/* => forward:fm-api"
      "301" = "host=files.gkoi.com path=/api/v1/readyz => forward:fm-api"
      "319" = "host=files.gkoi.com path=/api/v1/admin/* source=88.20.102.164/32 => forward:fm-api"
      "320" = "host=files.gkoi.com source=32.189.104.202/32 => forward:fm-api"
      "321" = "host=files.gkoi.com => fixed:404"
    }
    error_message = "lock off must be today's 18 rules, unchanged"
  }
  assert {
    condition     = length(data.aws_secretsmanager_secret_version.site_origin) == 0 && length(data.aws_cloudfront_distribution.site) == 0 && output.site_origin_lock.accepted_values == 0
    error_message = "lock off reads neither the secret nor CloudFront"
  }
  assert {
    condition     = output.listener_rule_max_values <= 5
    error_message = "an ALB rule takes at most 5 condition values"
  }
}

# Lock on: 27 rules; every cms forward demands the secret; a 403 closes each host; one door on origin-www.
run "lock_on" {
  command = apply
  variables {
    site_origin_lock = true
  }
  assert {
    condition = output.listener_rule_table == {
      "10"  = "host=origin-live.gkoi.com path=/api/v1/watch/* method=GET,HEAD x-origin-verify×1 => forward:engine-api"
      "11"  = "host=origin-live.gkoi.com path=/api/v1/watch/* method=OPTIONS x-origin-verify×1 => forward:engine-api"
      "12"  = "host=origin-live.gkoi.com x-origin-verify×1 => fixed:404"
      "13"  = "host=origin-live.gkoi.com => fixed:403"
      "110" = "host=engine.gkoi.com => forward:engine-api"
      "196" = "host=origin-cdn.gkoi.com path=/content/* method=GET x-origin-verify×1 => forward:cms"
      "197" = "host=origin-cdn.gkoi.com path=/content/* method=HEAD x-origin-verify×1 => forward:cms"
      "198" = "host=origin-cdn.gkoi.com path=/assets/* method=GET x-origin-verify×1 => forward:cms"
      "199" = "host=origin-cdn.gkoi.com path=/assets/* method=HEAD x-origin-verify×1 => forward:cms"
      "200" = "host=origin-cdn.gkoi.com path=/assets/*,/content/* x-origin-verify×1 => fixed:403"
      "201" = "host=origin-cdn.gkoi.com path=/assets/*,/content/* => fixed:403"
      "202" = "host=origin-cdn.gkoi.com x-origin-verify×1 => fixed:404"
      "203" = "host=origin-cdn.gkoi.com => fixed:403"
      "208" = "host=origin-labs.gkoi.com path=/content/labs/* method=GET x-origin-verify×1 => forward:cms"
      "209" = "host=origin-labs.gkoi.com path=/content/labs/* method=HEAD x-origin-verify×1 => forward:cms"
      "210" = "host=origin-labs.gkoi.com path=/content/labs/* x-origin-verify×1 => fixed:403"
      "211" = "host=origin-labs.gkoi.com method=GET,HEAD x-origin-verify×1 => redirect:HTTP_302:www.gkoi.com/labs"
      "212" = "host=origin-labs.gkoi.com => fixed:403"
      "220" = "host=gkoi.com => redirect:HTTP_301:www.gkoi.com/#{path}"
      "228" = "host=origin-www.gkoi.com path=/api/v1/app-updates/submissions*,/api/v1/app-updates/tool/info,/api/v1/downloads/* => forward:cms"
      "230" = "host=origin-www.gkoi.com,www.gkoi.com x-origin-verify×1 => forward:cms"
      "231" = "host=origin-www.gkoi.com,www.gkoi.com => fixed:403"
      "300" = "host=files.gkoi.com path=/api/v1/app/*,/api/v1/healthz,/thumbs/* => forward:fm-api"
      "301" = "host=files.gkoi.com path=/api/v1/readyz => forward:fm-api"
      "319" = "host=files.gkoi.com path=/api/v1/admin/* source=88.20.102.164/32 => forward:fm-api"
      "320" = "host=files.gkoi.com source=32.189.104.202/32 => forward:fm-api"
      "321" = "host=files.gkoi.com => fixed:404"
    }
    error_message = "lock on: the 27-rule table"
  }
  assert {
    condition     = output.site_origin_lock.accepted_values == 1 && output.listener_rule_max_values <= 5
    error_message = "one accepted value; no rule above the ALB's 5 (the two-value case is the next run)"
  }
  assert {
    condition     = nonsensitive(alltrue([for r in [aws_lb_listener_rule.cms, aws_lb_listener_rule.cms_cdn, aws_lb_listener_rule.cms_cdn_other, aws_lb_listener_rule.cms_labs, aws_lb_listener_rule.cms_labs_to_site] : alltrue(flatten([for c in r.condition : [for h in c.http_header : h.values == toset(["0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"])]]))]))
    error_message = "the accepted value is the secret's AWSCURRENT"
  }
}

# A rotation in flight (the secret has an AWSPENDING version): CURRENT + PENDING accepted, no rule above 5 values.
run "lock_on_with_a_pending_value" {
  command = apply
  variables {
    site_origin_lock = true
  }
  override_data {
    target = data.aws_secretsmanager_secret_versions.site_origin
    values = { versions = [
      { version_id = "v1", version_stages = ["AWSCURRENT"], created_time = "2026-11-17T00:00:00Z", last_accessed_date = "2026-11-17" },
      { version_id = "v2", version_stages = ["AWSPENDING"], created_time = "2026-11-18T00:00:00Z", last_accessed_date = "2026-11-18" },
    ] }
  }
  assert {
    condition = output.listener_rule_table == {
      "10"  = "host=origin-live.gkoi.com path=/api/v1/watch/* method=GET,HEAD x-origin-verify×1 => forward:engine-api"
      "11"  = "host=origin-live.gkoi.com path=/api/v1/watch/* method=OPTIONS x-origin-verify×1 => forward:engine-api"
      "12"  = "host=origin-live.gkoi.com x-origin-verify×1 => fixed:404"
      "13"  = "host=origin-live.gkoi.com => fixed:403"
      "110" = "host=engine.gkoi.com => forward:engine-api"
      "196" = "host=origin-cdn.gkoi.com path=/content/* method=GET x-origin-verify×2 => forward:cms"
      "197" = "host=origin-cdn.gkoi.com path=/content/* method=HEAD x-origin-verify×2 => forward:cms"
      "198" = "host=origin-cdn.gkoi.com path=/assets/* method=GET x-origin-verify×2 => forward:cms"
      "199" = "host=origin-cdn.gkoi.com path=/assets/* method=HEAD x-origin-verify×2 => forward:cms"
      "200" = "host=origin-cdn.gkoi.com path=/assets/*,/content/* x-origin-verify×2 => fixed:403"
      "201" = "host=origin-cdn.gkoi.com path=/assets/*,/content/* => fixed:403"
      "202" = "host=origin-cdn.gkoi.com x-origin-verify×2 => fixed:404"
      "203" = "host=origin-cdn.gkoi.com => fixed:403"
      "208" = "host=origin-labs.gkoi.com path=/content/labs/* method=GET x-origin-verify×2 => forward:cms"
      "209" = "host=origin-labs.gkoi.com path=/content/labs/* method=HEAD x-origin-verify×2 => forward:cms"
      "210" = "host=origin-labs.gkoi.com path=/content/labs/* x-origin-verify×2 => fixed:403"
      "211" = "host=origin-labs.gkoi.com method=GET,HEAD x-origin-verify×2 => redirect:HTTP_302:www.gkoi.com/labs"
      "212" = "host=origin-labs.gkoi.com => fixed:403"
      "220" = "host=gkoi.com => redirect:HTTP_301:www.gkoi.com/#{path}"
      "228" = "host=origin-www.gkoi.com path=/api/v1/app-updates/submissions*,/api/v1/app-updates/tool/info,/api/v1/downloads/* => forward:cms"
      "230" = "host=origin-www.gkoi.com,www.gkoi.com x-origin-verify×2 => forward:cms"
      "231" = "host=origin-www.gkoi.com,www.gkoi.com => fixed:403"
      "300" = "host=files.gkoi.com path=/api/v1/app/*,/api/v1/healthz,/thumbs/* => forward:fm-api"
      "301" = "host=files.gkoi.com path=/api/v1/readyz => forward:fm-api"
      "319" = "host=files.gkoi.com path=/api/v1/admin/* source=88.20.102.164/32 => forward:fm-api"
      "320" = "host=files.gkoi.com source=32.189.104.202/32 => forward:fm-api"
      "321" = "host=files.gkoi.com => fixed:404"
    }
    error_message = "rotation: the same 27 rules, two accepted values each"
  }
  assert {
    condition     = output.site_origin_lock.accepted_values == 2 && output.listener_rule_max_values == 5
    error_message = "two accepted values and no rule above the ALB's 5"
  }
  assert {
    condition     = nonsensitive(alltrue(flatten([for c in aws_lb_listener_rule.cms.condition : [for h in c.http_header : h.values == toset(["0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"])]])))
    error_message = "the accepted values are AWSCURRENT + AWSPENDING"
  }
}

# The same value under both stages (the moment between the two halves of `promote`): ONE accepted value.
run "pending_equal_to_current" {
  command = plan
  variables {
    site_origin_lock = true
  }
  override_data {
    target = data.aws_secretsmanager_secret_versions.site_origin
    values = { versions = [{ version_id = "v2", version_stages = ["AWSCURRENT", "AWSPENDING"], created_time = "2026-11-18T00:00:00Z", last_accessed_date = "2026-11-18" }] }
  }
  override_data {
    target = data.aws_secretsmanager_secret_version.site_origin_pending
    values = { secret_string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  }
  assert {
    condition     = nonsensitive(length(local.site_secrets)) == 1
    error_message = "equal values collapse to one"
  }
}

# A value stored with a trailing newline (or any character outside [A-Za-z0-9_-]) stops the plan.
run "a_malformed_secret_stops_the_plan" {
  command = plan
  variables {
    site_origin_lock = true
  }
  override_data {
    target = data.aws_secretsmanager_secret_version.site_origin
    values = { secret_string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n" }
  }
  expect_failures = [aws_lb_listener_rule.cms_cdn]
}

# A distribution still deploying stops the plan.
run "cloudfront_in_progress_stops_the_plan" {
  command = plan
  variables {
    site_origin_lock = true
  }
  override_data {
    target = data.aws_cloudfront_distribution.site
    values = { status = "InProgress" }
  }
  expect_failures = [aws_lb_listener_rule.cms]
}

run "no_open_door" {
  command = plan
  variables {
    site_origin_lock      = true
    cms_origin_open_paths = []
  }
  assert {
    condition     = length(aws_lb_listener_rule.cms_origin_open) == 0
    error_message = "[] = no door"
  }
}

run "open_paths_must_be_api" {
  command = plan
  variables {
    site_origin_lock      = true
    cms_origin_open_paths = ["/*"]
  }
  expect_failures = [var.cms_origin_open_paths]
}
