# Offline checks of the media stack (mock providers: no AWS call, no state). Run from envs/prod2/media:
#   docker run --rm --entrypoint sh -v "$PWD/../../..":/w -w /w/envs/prod2/media hashicorp/terraform:1.9 \
#     -c 'terraform init -backend=false -lockfile=readonly >/dev/null && terraform test'

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:loadbalancer/app/x/1", dns_name = "internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/x/1" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/x/1/2" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.7", allocation_id = "eipalloc-0123" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/x-AbCdEf" }
  }
}
mock_provider "aws" {
  alias = "euc1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:loadbalancer/app/x/1", dns_name = "internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/x/1" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/x/1/2" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.7", allocation_id = "eipalloc-0123" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/x-AbCdEf" }
  }
}
mock_provider "aws" {
  alias = "use1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:loadbalancer/app/x/1", dns_name = "internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/x/1" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/x/1/2" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.7", allocation_id = "eipalloc-0123" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/x-AbCdEf" }
  }
}
mock_provider "aws" {
  alias = "apne1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:loadbalancer/app/x/1", dns_name = "internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/x/1" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:listener/app/x/1/2" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.7", allocation_id = "eipalloc-0123" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/x-AbCdEf" }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      home_key                    = "usw2"
      home_cidr                   = "10.10.0.0/16"
      home_vpc_id                 = "vpc-home"
      home_private_subnet_ids     = ["subnet-p1", "subnet-p2"]
      ecs_tasks_security_group_id = "sg-tasks"
      regions = {
        usw2  = { cidr = "10.10.0.0/16", vpc_id = "vpc-home", public_subnet_ids = ["subnet-a", "subnet-b"] }
        euc1  = { cidr = "10.20.0.0/16", vpc_id = "vpc-euc1", public_subnet_ids = ["subnet-c", "subnet-d"] }
        use1  = { cidr = "10.30.0.0/16", vpc_id = "vpc-use1", public_subnet_ids = ["subnet-e", "subnet-f"] }
        apne1 = { cidr = "10.40.0.0/16", vpc_id = "vpc-apne1", public_subnet_ids = ["subnet-g", "subnet-h"] }
      }
    }
  }
}
override_data {
  target = data.terraform_remote_state.edge
  values = {
    outputs = {
      engine_internal = {
        target_group_arn  = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/gkoi-prod2-engine-api-int/1"
        dns_name          = "internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com"
        url               = "http://internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com:3000"
        security_group_id = "sg-internal"
      }
    }
  }
}
override_data {
  target = data.terraform_remote_state.data
  values = { outputs = { valkey_security_group_id = "sg-valkey" } }
}
override_data {
  target = data.terraform_remote_state.observability
  values = { outputs = { alerts_topic_arns = { usw2 = "arn:aws:sns:us-west-2:127214190346:gkoi-ops-alerts" } } }
}

# ORDER MATTERS: the runs share one state. The defaults manage the LIVE records of usw2 / euc1 / use1 (prevent_destroy),
# so every run that narrows media_regions or turns the live names off runs BEFORE the first apply of the defaults
# (default_four_regions); after it, a plan that drops a live record stops on prevent_destroy (as a real apply would).
# The defaults are only PLANNED: an applied live record (prevent_destroy) would stop the test's own final destroy.
run "all_three" {
  command = apply
  variables {
    media_regions = {
      usw2 = { enabled = true, label = "Oregon", rehearsal_stream_host = "stream-usw2-p2.gkoi.com", rehearsal_origin_host = "origin-live-usw2-p2.gkoi.com", live_stream_host = "stream.gkoi.com", live_origin_host = "origin-live-usw2.gkoi.com", origin_verify_secret = "gkoi/media/usw2/origin-verify" }
      euc1 = { enabled = true, label = "Frankfurt", rehearsal_stream_host = "stream-euc1-p2.gkoi.com", rehearsal_origin_host = "origin-live-euc1-p2.gkoi.com", live_stream_host = "stream-euc1.gkoi.com", live_origin_host = "origin-live-euc1.gkoi.com", origin_verify_secret = "gkoi/media/euc1/origin-verify", serve_live_names = true }
      use1 = { enabled = true, label = "Virginia", rehearsal_stream_host = "stream-use1-p2.gkoi.com", rehearsal_origin_host = "origin-live-use1-p2.gkoi.com", live_stream_host = "stream-use1.gkoi.com", live_origin_host = "origin-live-use1.gkoi.com", origin_verify_secret = "gkoi/media/use1/origin-verify", pool_count = 3 }
    }
  }
  assert {
    condition     = length(module.box_usw2) == 1 && length(module.box_euc1) == 1 && length(module.box_use1) == 1
    error_message = "three boxes"
  }
  assert {
    condition     = local.config.euc1.stream_host == "stream-euc1.gkoi.com" && local.config.usw2.stream_host == "stream-usw2-p2.gkoi.com"
    error_message = "serve_live_names"
  }
  assert {
    condition     = length(local.rehearsal_records.euc1) == 2 && length(local.live_records.euc1) == 0
    error_message = "records"
  }
  assert {
    condition     = startswith(local.config.usw2.images["media-agent"], "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/media-agent@sha256:0ca2d707") && startswith(local.config.euc1.images.mediamtx, "127214190346.dkr.ecr.eu-central-1.amazonaws.com/gkoi/mediamtx@sha256:")
    error_message = "images"
  }
  assert {
    condition     = local.config.usw2.engine_source.s3_uri == "s3://gkoi-build-sources-127214190346/mikaido/gkoi-2026.11.11-1/source.zip"
    error_message = "source"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.engine_internal_from_home_box) == 1 && local.config.usw2.portal_internal_url == "http://internal-gkoi-prod2-engine-internal-1.us-west-2.elb.amazonaws.com:3000"
    error_message = "internal ALB"
  }
  assert {
    condition     = local.config.euc1.images["media-origin"] == "127214190346.dkr.ecr.eu-central-1.amazonaws.com/gkoi/ci-nginx@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "origin image"
  }
  assert {
    condition     = length(jsonencode(local.config.use1)) < 3500
    error_message = "config size ${length(jsonencode(local.config.use1))}"
  }
  assert {
    condition     = length(local.user_data.usw2) < 4000 && strcontains(local.user_data.usw2, "PARAM='/gkoi/prod2/media/usw2/config'")
    error_message = "user data"
  }
  assert {
    condition     = length(module.box_use1[0].records) == 2
    error_message = "use1 records"
  }
}

run "no_internal_alb_yet" {
  command = plan
  override_data {
    target = data.terraform_remote_state.edge
    values = { outputs = {} }
  }
  expect_failures = [terraform_data.preflight]
}

run "bad_pool_count" {
  command = plan
  variables {
    media_regions = {
      usw2 = { enabled = true, label = "Oregon", rehearsal_stream_host = "stream-usw2-p2.gkoi.com", rehearsal_origin_host = "origin-live-usw2-p2.gkoi.com", live_stream_host = "stream.gkoi.com", live_origin_host = "origin-live-usw2.gkoi.com", origin_verify_secret = "x", pool_count = 6 }
    }
  }
  expect_failures = [var.media_regions]
}

# A key with no provider + module block is refused.
run "unknown_region_key" {
  command = plan
  variables {
    media_regions = {
      aps1 = { enabled = true, label = "Mumbai", rehearsal_stream_host = "stream-aps1-p2.gkoi.com", rehearsal_origin_host = "origin-live-aps1-p2.gkoi.com", live_stream_host = "stream-aps1.gkoi.com", live_origin_host = "origin-live-aps1.gkoi.com", origin_verify_secret = "gkoi/media/aps1/origin-verify" }
    }
  }
  expect_failures = [var.media_regions]
}

run "live_records_plan" {
  command = plan
  variables {
    media_regions = {
      usw2 = { enabled = true, label = "Oregon", rehearsal_stream_host = "stream-usw2-p2.gkoi.com", rehearsal_origin_host = "origin-live-usw2-p2.gkoi.com", live_stream_host = "stream.gkoi.com", live_origin_host = "origin-live-usw2.gkoi.com", origin_verify_secret = "gkoi/media/usw2/origin-verify", manage_live_records = true, serve_live_names = true }
    }
  }
  assert {
    condition     = jsonencode(local.live_records.usw2) == jsonencode(["stream.gkoi.com", "origin-live-usw2.gkoi.com"]) && local.config.usw2.origin_host == "origin-live-usw2.gkoi.com"
    error_message = "live"
  }
}

# Tokyo's switch to the live names (the later commit): serve + manage -> stream-apne1 / origin-live-apne1.
run "tokyo_live_names" {
  command = plan
  variables {
    media_regions = {
      apne1 = { enabled = true, label = "Tokyo", rehearsal_stream_host = "stream-apne1-p2.gkoi.com", rehearsal_origin_host = "origin-live-apne1-p2.gkoi.com", live_stream_host = "stream-apne1.gkoi.com", live_origin_host = "origin-live-apne1.gkoi.com", origin_verify_secret = "gkoi/media/apne1/origin-verify", serve_live_names = true, manage_live_records = true }
    }
  }
  assert {
    condition     = length(module.box_usw2) == 0 && length(module.box_apne1) == 1 && local.config.apne1.stream_host == "stream-apne1.gkoi.com"
    error_message = "apne1 alone, live host"
  }
  assert {
    condition     = jsonencode(local.live_records.apne1) == jsonencode(["stream-apne1.gkoi.com", "origin-live-apne1.gkoi.com"])
    error_message = "apne1 live records"
  }
}

# The rehearsal switch: the scratch bucket everywhere (agent env + role), the NAT on every origin's 443.
run "rehearsal_on" {
  command = apply
  variables {
    rehearsal = true
    # the defaults serve the live names since the window (the plan refuses the rehearsal there): the rehearsal names
    media_regions = {
      usw2  = { enabled = true, label = "Oregon", rehearsal_stream_host = "stream-usw2-p2.gkoi.com", rehearsal_origin_host = "origin-live-usw2-p2.gkoi.com", live_stream_host = "stream.gkoi.com", live_origin_host = "origin-live-usw2.gkoi.com", origin_verify_secret = "gkoi/media/usw2/origin-verify" }
      euc1  = { enabled = true, label = "Frankfurt", rehearsal_stream_host = "stream-euc1-p2.gkoi.com", rehearsal_origin_host = "origin-live-euc1-p2.gkoi.com", live_stream_host = "stream-euc1.gkoi.com", live_origin_host = "origin-live-euc1.gkoi.com", origin_verify_secret = "gkoi/media/euc1/origin-verify" }
      use1  = { enabled = true, label = "Virginia", rehearsal_stream_host = "stream-use1-p2.gkoi.com", rehearsal_origin_host = "origin-live-use1-p2.gkoi.com", live_stream_host = "stream-use1.gkoi.com", live_origin_host = "origin-live-use1.gkoi.com", origin_verify_secret = "gkoi/media/use1/origin-verify" }
      apne1 = { enabled = true, label = "Tokyo", rehearsal_stream_host = "stream-apne1-p2.gkoi.com", rehearsal_origin_host = "origin-live-apne1-p2.gkoi.com", live_stream_host = "stream-apne1.gkoi.com", live_origin_host = "origin-live-apne1.gkoi.com", origin_verify_secret = "gkoi/media/apne1/origin-verify" }
    }
  }
  override_data {
    target = data.terraform_remote_state.data
    values = { outputs = { valkey_security_group_id = "sg-valkey", rehearsal_vods_bucket = { name = "gkoi-prod2-rehearsal-vods-127214190346", arn = "arn:aws:s3:::gkoi-prod2-rehearsal-vods-127214190346", region = "us-west-2", days = 3 } } }
  }
  override_data {
    target = data.terraform_remote_state.network
    values = {
      outputs = {
        home_key                    = "usw2"
        home_cidr                   = "10.10.0.0/16"
        home_vpc_id                 = "vpc-home"
        home_private_subnet_ids     = ["subnet-p1", "subnet-p2"]
        home_nat_public_ips         = ["32.189.104.202"]
        ecs_tasks_security_group_id = "sg-tasks"
        regions = {
          usw2  = { cidr = "10.10.0.0/16", vpc_id = "vpc-home", public_subnet_ids = ["subnet-a", "subnet-b"] }
          euc1  = { cidr = "10.20.0.0/16", vpc_id = "vpc-euc1", public_subnet_ids = ["subnet-c", "subnet-d"] }
          use1  = { cidr = "10.30.0.0/16", vpc_id = "vpc-use1", public_subnet_ids = ["subnet-e", "subnet-f"] }
          apne1 = { cidr = "10.40.0.0/16", vpc_id = "vpc-apne1", public_subnet_ids = ["subnet-g", "subnet-h"] }
        }
      }
    }
  }
  assert {
    condition     = local.config.euc1.agent_env.S3_BUCKET == "gkoi-prod2-rehearsal-vods-127214190346" && local.config.usw2.agent_env.S3_BUCKET == "gkoi-prod2-rehearsal-vods-127214190346"
    error_message = "agent bucket"
  }
  assert {
    condition     = jsonencode(local.recordings_buckets) == jsonencode(["gkoi-prod2-rehearsal-vods-127214190346"])
    error_message = "role buckets: the live bucket must be gone"
  }
  assert {
    condition     = jsonencode(local.origin_ingress.use1) == jsonencode(["32.189.104.202/32"]) && !contains(keys(local.config.usw2.agent_env), "VOD_BUCKETS")
    error_message = "origin CIDRs / VOD_BUCKETS"
  }
}

run "rehearsal_off_is_live_bucket" {
  command = plan
  assert {
    condition     = local.config.usw2.agent_env.S3_BUCKET == "gkoi-beta-vods" && length(local.origin_ingress.usw2) == 0
    error_message = "rehearsal off = today's config"
  }
}

run "rehearsal_refused_on_live_names" {
  command = plan
  variables {
    rehearsal = true
    media_regions = {
      usw2 = { enabled = true, label = "Oregon", rehearsal_stream_host = "stream-usw2-p2.gkoi.com", rehearsal_origin_host = "origin-live-usw2-p2.gkoi.com", live_stream_host = "stream.gkoi.com", live_origin_host = "origin-live-usw2.gkoi.com", origin_verify_secret = "gkoi/media/usw2/origin-verify", serve_live_names = true }
    }
  }
  override_data {
    target = data.terraform_remote_state.data
    values = { outputs = { valkey_security_group_id = "sg-valkey", rehearsal_vods_bucket = { name = "gkoi-prod2-rehearsal-vods-127214190346" } } }
  }
  expect_failures = [terraform_data.preflight]
}

run "rehearsal_refused_without_bucket" {
  command = plan
  variables {
    rehearsal = true
  }
  expect_failures = [terraform_data.preflight]
}

run "default_four_regions" {
  command = plan
  assert {
    condition     = length(module.box_usw2) == 1 && length(module.box_euc1) == 1 && length(module.box_use1) == 1 && length(module.box_apne1) == 1
    error_message = "default = four regions"
  }
  assert {
    condition     = jsonencode(sort(output.valkey_peer_cidrs)) == jsonencode(["10.20.0.0/16", "10.30.0.0/16", "10.40.0.0/16"])
    error_message = "spokes"
  }
}

# Tokyo (2026-11-11): its own provider + ECR replica, the label, the REHEARSAL names (no live record yet), its secret.
run "tokyo_default" {
  command = plan
  assert {
    condition     = local.config.apne1.region == "ap-northeast-1" && local.config.apne1.label == "Tokyo" && local.config.apne1.ecr_registry == "127214190346.dkr.ecr.ap-northeast-1.amazonaws.com"
    error_message = "apne1 region / label / registry"
  }
  assert {
    condition     = local.config.apne1.stream_host == "stream-apne1-p2.gkoi.com" && local.config.apne1.origin_host == "origin-live-apne1-p2.gkoi.com"
    error_message = "apne1 starts on the rehearsal names"
  }
  assert {
    condition     = jsonencode(local.rehearsal_records.apne1) == jsonencode(["stream-apne1-p2.gkoi.com", "origin-live-apne1-p2.gkoi.com"]) && length(local.live_records.apne1) == 0
    error_message = "apne1 records: rehearsal only"
  }
  assert {
    condition     = jsonencode(local.config.apne1.cert_hosts) == jsonencode(["stream-apne1-p2.gkoi.com", "origin-live-apne1-p2.gkoi.com", "stream-apne1.gkoi.com", "origin-live-apne1.gkoi.com"])
    error_message = "apne1 certs: all four names at boot"
  }
  assert {
    condition     = startswith(local.config.apne1.images["media-agent"], "127214190346.dkr.ecr.ap-northeast-1.amazonaws.com/gkoi/media-agent@sha256:") && local.config.apne1.images["media-origin"] == "127214190346.dkr.ecr.ap-northeast-1.amazonaws.com/gkoi/ci-nginx@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "apne1 images from its own region's ECR"
  }
  assert {
    condition     = strcontains(local.user_data.apne1, "PARAM='/gkoi/prod2/media/apne1/config'") && local.config.apne1.cw.log_prefix == "/gkoi/prod2/media/apne1"
    error_message = "apne1 user data / log prefix"
  }
  assert {
    condition     = length(module.box_apne1[0].records) == 2 && local.config.apne1.live_origin_base == "https://live.gkoi.com"
    error_message = "apne1 box"
  }
}
