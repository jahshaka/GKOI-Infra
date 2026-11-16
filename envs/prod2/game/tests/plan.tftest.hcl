# Offline checks of the game stack (mock providers: no AWS call, no state). Every run is a PLAN: an apply run would
# leave the live records (prevent_destroy) in the test state, and every later run that drops them would fail. The one
# apply run (last) manages no live record. Run from envs/prod2/game:
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
        usw2  = { cidr = "10.10.0.0/16", vpc_id = "vpc-home", public_subnet_ids = ["subnet-a", "subnet-b"] }
        euc1  = { cidr = "10.20.0.0/16", vpc_id = "vpc-euc1", public_subnet_ids = ["subnet-c", "subnet-d"] }
        use1  = { cidr = "10.30.0.0/16", vpc_id = "vpc-use1", public_subnet_ids = ["subnet-e", "subnet-f"] }
        apne1 = { cidr = "10.40.0.0/16", vpc_id = "vpc-apne1", public_subnet_ids = ["subnet-g", "subnet-h"] }
      }
    }
  }
}
override_data {
  target = data.terraform_remote_state.observability
  values = { outputs = { alerts_topic_arns = { usw2 = "arn:aws:sns:us-west-2:127214190346:gkoi-ops-alerts", use1 = "arn:aws:sns:us-east-1:127214190346:gkoi-ops-alerts", apne1 = "arn:aws:sns:ap-northeast-1:127214190346:gkoi-ops-alerts" } } }
}

variables {
  warroom_release_file  = "tests/warroom-game.fixture.json"
  warroom_tool_override = { s3_key = "warroom-game/tool/0123456789abcdef0123456789abcdef01234567.zip", sha256 = "4444444444444444444444444444444444444444444444444444444444444444", commit = "0123456789abcdef0123456789abcdef01234567" }
}

# The defaults (2026-11-11): usw2 + euc1 + use1 + apne1, every box on its LIVE names and owning the live records; the
# snap-free tool zip for Tokyo ONLY — the three live boxes keep the release's own tool (their configs unchanged).
run "default_four_regions" {
  command = plan
  variables {
    warroom_tool_override_regions = ["apne1"]
  }
  assert {
    condition     = length(module.box_usw2) == 1 && length(module.box_euc1) == 1 && length(module.box_use1) == 1 && length(module.box_apne1) == 1
    error_message = "four boxes"
  }
  assert {
    condition     = local.config.apne1.region == "ap-northeast-1" && local.config.apne1.warroom_env == "beta-apne1" && local.config.apne1.matchd_host == "game-apne1.gkoi.com" && local.config.apne1.gateway_host == "gw-apne1.gkoi.com"
    error_message = "Tokyo on its live names"
  }
  assert {
    condition     = alltrue([for k in ["usw2", "euc1", "use1", "apne1"] : jsonencode(local.live_records[k]) == jsonencode(["game-${k}.gkoi.com", "gw-${k}.gkoi.com"])])
    error_message = "every region owns its two live records"
  }
  assert {
    condition     = length(module.box_apne1[0].records) == 4
    error_message = "apne1: the two rehearsal + the two live records"
  }
  assert {
    condition     = jsonencode(local.acme_names.apne1) == jsonencode(["game-apne1-p2.gkoi.com", "gw-apne1-p2.gkoi.com", "game-apne1.gkoi.com", "gw-apne1.gkoi.com"])
    error_message = "DNS-01 names: both sets"
  }
  assert {
    condition     = local.config.apne1.image.ref == "127214190346.dkr.ecr.ap-northeast-1.amazonaws.com/gkoi/warroom-game@sha256:2222222222222222222222222222222222222222222222222222222222222222" && local.config.apne1.image.tag == "1.0.15.3.3-h6"
    error_message = "image from the region's replica, by digest"
  }
  assert {
    condition     = local.config.apne1.tool.s3_key == "warroom-game/tool/0123456789abcdef0123456789abcdef01234567.zip" && local.config.apne1.tool.commit == "0123456789abcdef0123456789abcdef01234567"
    error_message = "Tokyo runs the snap-free tool zip"
  }
  assert {
    condition     = alltrue([for k in ["usw2", "euc1", "use1"] : local.config[k].tool.s3_key == "warroom-game/1.0.15.3.3-h6/source.zip" && local.config[k].tool.sha256 == "3333333333333333333333333333333333333333333333333333333333333333"])
    error_message = "the live three keep the release's own tool (unchanged configs)"
  }
  assert {
    condition     = length(local.user_data.apne1) < 4000 && strcontains(local.user_data.apne1, "/gkoi/prod2/game/apne1/config")
    error_message = "user data"
  }
  assert {
    condition     = contains(keys(local.bundle_sha), "game-bootstrap.sh") && !contains(keys(local.bundle_sha), "user-data.sh.tftpl")
    error_message = "bundle"
  }
  assert {
    condition     = output.boxes.apne1.cms_hosts.matchd == "https://game-apne1.gkoi.com:9443" && output.boxes.apne1.cms_hosts.gateway == "https://gw-apne1.gkoi.com:8443"
    error_message = "CMS hosts entry"
  }
}

run "tokyo_without_snap_free_tool" {
  command = plan
  variables {
    warroom_tool_override = null
  }
  expect_failures = [terraform_data.preflight]
}

run "tokyo_override_scoped_elsewhere" {
  command = plan
  variables {
    warroom_tool_override_regions = ["use1"]
  }
  expect_failures = [terraform_data.preflight]
}

run "tokyo_release_tool_snap_free" {
  command = plan
  variables {
    warroom_tool_override  = null
    release_tool_snap_free = true
  }
  assert {
    condition     = local.config.apne1.tool.s3_key == "warroom-game/1.0.15.3.3-h6/source.zip"
    error_message = "a snap-free release tool needs no override"
  }
}

run "override_regions_must_be_enabled" {
  command = plan
  variables {
    game_regions                  = { use1 = { enabled = true } }
    warroom_tool_override_regions = ["apne1"]
  }
  expect_failures = [terraform_data.preflight]
}

run "no_release_record" {
  command = plan
  variables {
    warroom_release_file = "tests/does-not-exist.json"
  }
  expect_failures = [terraform_data.preflight]
}

run "rehearsal_names" {
  command = plan
  variables {
    game_regions = { use1 = { enabled = true } }
  }
  assert {
    condition     = local.config.use1.matchd_host == "game-use1-p2.gkoi.com" && local.config.use1.gateway_host == "gw-use1-p2.gkoi.com" && length(local.live_records.use1) == 0
    error_message = "rehearsal names, no live records"
  }
  assert {
    condition     = output.boxes.use1.cms_hosts.matchd == "https://game-use1-p2.gkoi.com:9443"
    error_message = "CMS hosts entry (rehearsal)"
  }
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

run "live_records_need_live_names" {
  command = plan
  variables {
    game_regions = { usw2 = { enabled = true, manage_live_records = true } }
  }
  expect_failures = [var.game_regions]
}

run "max_one_box" {
  command = plan
  variables {
    game_regions = { use1 = { enabled = true, max_size = 2 } }
  }
  expect_failures = [var.game_regions]
}

run "ticket_secret_and_tool_override_everywhere" {
  command = plan
  variables {
    game_regions = { use1 = { enabled = true, ticket_key_secret = "gkoi/prod2/game/use1/ticket-key", cpu_credits = "unlimited" } }
  }
  assert {
    condition     = local.config.use1.secrets.ticket_key == "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/game/use1/ticket-key-AbCdEf"
    error_message = "ticket secret"
  }
  assert {
    condition     = local.config.use1.tool.s3_key == "warroom-game/tool/0123456789abcdef0123456789abcdef01234567.zip"
    error_message = "override regions null = every enabled region"
  }
}

run "tool_override_outside_prefix" {
  command = plan
  variables {
    warroom_tool_override = { s3_key = "other/x.zip", sha256 = "4444444444444444444444444444444444444444444444444444444444444444", commit = "0123456789abcdef0123456789abcdef01234567" }
  }
  expect_failures = [var.warroom_tool_override]
}

# The one APPLY (computed values: the secret ARN, the config size): last, and without live records (prevent_destroy
# would stop the test's own teardown).
run "apply_tokyo_values" {
  command = apply
  variables {
    game_regions                  = { apne1 = { enabled = true, serve_live_names = true } }
    warroom_tool_override_regions = ["apne1"]
  }
  assert {
    condition     = length(jsonencode(local.config.apne1)) < 3000
    error_message = "config size ${length(jsonencode(local.config.apne1))}"
  }
  assert {
    condition     = length(local.secret_arns.apne1) == 1 && local.config.apne1.secrets.ticket_key == null
    error_message = "match-server key only; the ticket key generated on the box"
  }
}
