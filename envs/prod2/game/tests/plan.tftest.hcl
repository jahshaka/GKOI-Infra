# Offline checks of the game stack (mock providers: no AWS call, no state). Run from envs/prod2/game:
#   docker run --rm --entrypoint sh -v "$PWD/../../..":/w -w /w/envs/prod2/game hashicorp/terraform:1.9 \
#     -c 'terraform init -backend=false -lockfile=readonly >/dev/null && terraform test'

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/use1/ticket-key-AbCdEf" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/match-server-key-AbCdEf" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-west-2:127214190346:parameter/gkoi/prod2/game/x/config" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.9", allocation_id = "eipalloc-0123" }
  }
}
mock_provider "aws" {
  alias = "euc1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/use1/ticket-key-AbCdEf" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/match-server-key-AbCdEf" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-west-2:127214190346:parameter/gkoi/prod2/game/x/config" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.9", allocation_id = "eipalloc-0123" }
  }
}
mock_provider "aws" {
  alias = "use1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/use1/ticket-key-AbCdEf" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/match-server-key-AbCdEf" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-west-2:127214190346:parameter/gkoi/prod2/game/x/config" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.9", allocation_id = "eipalloc-0123" }
  }
}
mock_provider "aws" {
  alias = "apne1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/use1/ticket-key-AbCdEf" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/match-server-key-AbCdEf" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::127214190346:instance-profile/gkoi/x" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-west-2:127214190346:parameter/gkoi/prod2/game/x/config" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.9", allocation_id = "eipalloc-0123" }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      regions = {
        usw2 = { cidr = "10.10.0.0/16", vpc_id = "vpc-home", public_subnet_ids = ["subnet-a", "subnet-b"] }
        euc1 = { cidr = "10.20.0.0/16", vpc_id = "vpc-euc1", public_subnet_ids = ["subnet-c", "subnet-d"] }
        use1 = { cidr = "10.30.0.0/16", vpc_id = "vpc-use1", public_subnet_ids = ["subnet-e", "subnet-f"] }
      }
    }
  }
}
override_data {
  target = data.terraform_remote_state.observability
  values = { outputs = { alerts_topic_arns = { usw2 = "arn:aws:sns:us-west-2:127214190346:gkoi-ops-alerts", use1 = "arn:aws:sns:us-east-1:127214190346:gkoi-ops-alerts" } } }
}

variables {
  warroom_release_file = "tests/warroom-game.fixture.json"
}

# The defaults: usw2 + euc1 + use1 on the rehearsal names, apne1 defined + off; the release read from the record file.
run "default_three_regions" {
  command = apply
  assert {
    condition     = length(module.box_usw2) == 1 && length(module.box_euc1) == 1 && length(module.box_use1) == 1 && length(module.box_apne1) == 0
    error_message = "three boxes, no Tokyo"
  }
  assert {
    condition     = local.config.use1.matchd_host == "game-use1-p2.gkoi.com" && local.config.use1.gateway_host == "gw-use1-p2.gkoi.com" && local.config.use1.warroom_env == "beta-use1"
    error_message = "rehearsal names"
  }
  assert {
    condition     = length(local.live_records.usw2) == 0 && length(module.box_usw2[0].records) == 2
    error_message = "only the two rehearsal records"
  }
  assert {
    condition     = jsonencode(local.acme_names.euc1) == jsonencode(["game-euc1-p2.gkoi.com", "gw-euc1-p2.gkoi.com", "game-euc1.gkoi.com", "gw-euc1.gkoi.com"])
    error_message = "DNS-01 names: both sets"
  }
  assert {
    condition     = local.config.euc1.image.ref == "127214190346.dkr.ecr.eu-central-1.amazonaws.com/gkoi/warroom-game@sha256:2222222222222222222222222222222222222222222222222222222222222222" && local.config.euc1.image.tag == "1.0.15.3.3-h6"
    error_message = "image from the region's replica, by digest"
  }
  assert {
    condition     = local.config.usw2.tool.s3_key == "warroom-game/1.0.15.3.3-h6/source.zip" && local.config.usw2.tool.sha256 == "3333333333333333333333333333333333333333333333333333333333333333"
    error_message = "the tool = the release's own source.zip"
  }
  assert {
    condition     = length(jsonencode(local.config.use1)) < 3000
    error_message = "config size ${length(jsonencode(local.config.use1))}"
  }
  assert {
    condition     = length(local.user_data.usw2) < 4000 && strcontains(local.user_data.usw2, "PARAM='/gkoi/prod2/game/usw2/config'") && strcontains(local.user_data.usw2, "HOME=\"$${HOME:-/root}\"")
    error_message = "user data"
  }
  assert {
    condition     = contains(keys(local.bundle_sha), "game-bootstrap.sh") && !contains(keys(local.bundle_sha), "user-data.sh.tftpl")
    error_message = "bundle"
  }
  assert {
    condition     = length(local.secret_arns.use1) == 1 && local.config.use1.secrets.ticket_key == null
    error_message = "match-server key only; the ticket key generated on the box"
  }
  assert {
    condition     = output.boxes.use1.cms_hosts.matchd == "https://game-use1-p2.gkoi.com:9443" && output.boxes.use1.cms_hosts.gateway == "https://gw-use1-p2.gkoi.com:8443"
    error_message = "CMS hosts entry"
  }
}

run "no_release_record" {
  command = plan
  variables {
    warroom_release_file = "tests/does-not-exist.json"
  }
  expect_failures = [terraform_data.preflight]
}

run "serve_live_names_only" {
  command = plan
  variables {
    game_regions = { use1 = { enabled = true, serve_live_names = true } }
  }
  assert {
    condition     = local.config.use1.matchd_host == "game-use1.gkoi.com" && length(local.live_records.use1) == 0
    error_message = "serving the live names, records untouched"
  }
}

run "switch_live_records" {
  command = plan
  variables {
    game_regions = { usw2 = { enabled = true, serve_live_names = true, manage_live_records = true } }
  }
  assert {
    condition     = jsonencode(local.live_records.usw2) == jsonencode(["game-usw2.gkoi.com", "gw-usw2.gkoi.com"])
    error_message = "live records"
  }
}

run "live_records_need_live_names" {
  command = plan
  variables {
    game_regions = { usw2 = { enabled = true, manage_live_records = true } }
  }
  expect_failures = [var.game_regions]
}

# modules/regions enabled apne1 on 2026-11-11 (a Tokyo MEDIA box): the game box stays OFF by default (the default run
# above asserts box_apne1 == 0); turning it on is only game_regions.apne1.enabled once its VPC exists.
run "tokyo_game_box_when_asked" {
  command = plan
  variables {
    game_regions = { apne1 = { enabled = true } }
  }
  override_data {
    target = data.terraform_remote_state.network
    values = {
      outputs = {
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
    condition     = length(module.box_apne1) == 1 && length(module.box_usw2) == 0
    error_message = "apne1 game box only when asked"
  }
}

run "max_one_box" {
  command = plan
  variables {
    game_regions = { use1 = { enabled = true, max_size = 2 } }
  }
  expect_failures = [var.game_regions]
}

run "ticket_secret_and_tool_override" {
  command = plan
  variables {
    game_regions          = { use1 = { enabled = true, ticket_key_secret = "gkoi/prod2/game/use1/ticket-key", cpu_credits = "unlimited" } }
    warroom_tool_override = { s3_key = "warroom-game/tool/0123456789abcdef0123456789abcdef01234567.zip", sha256 = "4444444444444444444444444444444444444444444444444444444444444444", commit = "0123456789abcdef0123456789abcdef01234567" }
  }
  assert {
    condition     = length(local.secret_arns.use1) == 2 && local.config.use1.secrets.ticket_key != null
    error_message = "ticket secret"
  }
  assert {
    condition     = local.config.use1.tool.s3_key == "warroom-game/tool/0123456789abcdef0123456789abcdef01234567.zip"
    error_message = "tool override"
  }
}

run "tool_override_outside_prefix" {
  command = plan
  variables {
    warroom_tool_override = { s3_key = "other/x.zip", sha256 = "4444444444444444444444444444444444444444444444444444444444444444", commit = "0123456789abcdef0123456789abcdef01234567" }
  }
  expect_failures = [var.warroom_tool_override]
}
