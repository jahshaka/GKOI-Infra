# Offline checks of the rehearsal stack (mock provider: no AWS call, no state). Run from envs/prod2/rehearsal:
#   docker run --rm --entrypoint sh -v "$PWD/../../..":/w -w /w/envs/prod2/rehearsal hashicorp/terraform:1.9 \
#     -c 'terraform init -backend=false -lockfile=readonly >/dev/null && terraform test'

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/x-AbCdEf" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:127214190346:log-group:/gkoi/prod2/ecs/rehearsal-driver" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::127214190346:role/gkoi/x" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { revision = 3 }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = { outputs = {} }
}
override_data {
  target = data.terraform_remote_state.edge
  values = { outputs = { alb_dns_name = "gkoi-prod2-alb-1.us-west-2.elb.amazonaws.com" } }
}
override_data {
  target = data.terraform_remote_state.data
  values = { outputs = { rehearsal_vods_bucket = { name = "gkoi-prod2-rehearsal-vods-127214190346", arn = "arn:aws:s3:::gkoi-prod2-rehearsal-vods-127214190346", region = "us-west-2", days = 3 } } }
}
override_data {
  target = data.terraform_remote_state.compute
  values = {
    outputs = {
      cluster_name     = "gkoi-prod2"
      run_task_network = { subnets = ["subnet-p1", "subnet-p2"], securityGroups = ["sg-tasks"], assignPublicIp = "DISABLED" }
      rehearsal        = { enabled = true, engine_bucket = "gkoi-prod2-rehearsal-vods-127214190346", running = ["engine-api", "engine-worker"] }
    }
  }
}
override_data {
  target = data.terraform_remote_state.media
  values = {
    outputs = {
      boxes = {
        usw2 = { stream_host = "stream-usw2-p2.gkoi.com", origin_host = "origin-live-usw2-p2.gkoi.com" }
        euc1 = { stream_host = "stream-euc1-p2.gkoi.com", origin_host = "origin-live-euc1-p2.gkoi.com" }
        use1 = { stream_host = "stream-use1-p2.gkoi.com", origin_host = "origin-live-use1-p2.gkoi.com" }
      }
      rehearsal = { enabled = true, recordings_bucket = "gkoi-prod2-rehearsal-vods-127214190346", origin_cidrs = ["32.189.104.202/32"] }
    }
  }
}

run "armed" {
  command = apply
  assert {
    condition     = jsonencode([for r in local.driver_regions : r.key]) == jsonencode(["euc1", "use1", "usw2"]) && local.driver_regions[0].region == "eu-central-1" && local.driver_regions[2].streamHost == "stream-usw2-p2.gkoi.com"
    error_message = "regions"
  }
  assert {
    condition     = local.armed.compute && local.armed.media && local.armed.scratch_matches
    error_message = "armed"
  }
  assert {
    condition     = jsonencode([for s in local.container.secrets : s.name]) == jsonencode(["GATEWAY_SHARED_SECRET", "ORIGIN_VERIFY_EUC1", "ORIGIN_VERIFY_USE1", "ORIGIN_VERIFY_USW2"])
    error_message = "secrets"
  }
  assert {
    condition     = local.driver_env.ENGINE_CONNECT_HOST == "gkoi-prod2-alb-1.us-west-2.elb.amazonaws.com" && local.driver_env.SCRATCH_BUCKET == "gkoi-prod2-rehearsal-vods-127214190346"
    error_message = "env"
  }
  assert {
    condition     = length(local.container_definitions) < 30000
    error_message = "container definition ${length(local.container_definitions)} bytes"
  }
  assert {
    condition     = jsondecode(output.run_task_request).taskDefinition == "gkoi-prod2-rehearsal-driver:3" && jsondecode(output.run_task_request).networkConfiguration.awsvpcConfiguration.assignPublicIp == "DISABLED"
    error_message = "run-task request"
  }
  assert {
    condition     = !strcontains(local.container_definitions, "origin-verify\":") && !strcontains(jsonencode(local.run_config), "secret:")
    error_message = "no secret values / ARNs in the run config"
  }
}

run "not_armed_still_plans" {
  command = plan
  override_data {
    target = data.terraform_remote_state.compute
    values = { outputs = { cluster_name = "gkoi-prod2", run_task_network = { subnets = ["subnet-p1"], securityGroups = ["sg-tasks"], assignPublicIp = "DISABLED" } } }
  }
  expect_failures = [check.rehearsal_armed]
  assert {
    condition     = !local.armed.compute && !local.armed.scratch_matches
    error_message = "armed must be false without compute's rehearsal output"
  }
}

run "no_scratch_bucket" {
  command = plan
  override_data {
    target = data.terraform_remote_state.data
    values = { outputs = {} }
  }
  expect_failures = [terraform_data.preflight, check.rehearsal_armed]
}

run "numeric_cms_user_refused" {
  command = plan
  variables {
    cms_user_id = "12345678"
  }
  expect_failures = [var.cms_user_id]
}
