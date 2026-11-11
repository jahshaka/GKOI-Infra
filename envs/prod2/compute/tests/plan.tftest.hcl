# Offline checks of compute's parking + rehearsal switch (mock provider: no AWS call, no state). From envs/prod2/compute:
#   docker run --rm --entrypoint sh -v "$PWD/../../..":/w -w /w/envs/prod2/compute hashicorp/terraform:1.9 \
#     -c 'terraform init -backend=false -lockfile=readonly >/dev/null && terraform test'

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/edge/live-origin-AbCdEf" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:127214190346:secret:gkoi/prod2/x-AbCdEf" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::127214190346:role/gkoi/x" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-west-2:127214190346:cluster/gkoi-prod2" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-west-2:127214190346:task-definition/x:1", revision = 1 }
  }
  mock_resource "aws_ecs_service" {
    defaults = { id = "arn:aws:ecs:us-west-2:127214190346:service/gkoi-prod2/x" }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      home_cidr                   = "10.10.0.0/16"
      home_private_subnet_ids     = ["subnet-p1", "subnet-p2"]
      home_nat_public_ips         = ["32.189.104.202"]
      ecs_tasks_security_group_id = "sg-tasks"
    }
  }
}
override_data {
  target = data.terraform_remote_state.edge
  values = {
    outputs = {
      target_groups = {
        cms        = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/cms/1", min_capacity = 1, max_capacity = 1 }
        engine-api = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/engine/1", min_capacity = 1, max_capacity = 1 }
        fm-api     = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/fm/1", min_capacity = 1, max_capacity = 1 }
        fm-web     = { arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/fmweb/1", min_capacity = 1, max_capacity = 1 }
      }
      engine_internal = { target_group_arn = "arn:aws:elasticloadbalancing:us-west-2:127214190346:targetgroup/int/1" }
    }
  }
}
override_data {
  target = data.terraform_remote_state.data
  values = {
    outputs = {
      db_endpoint                      = "gkoi-prod2-pg.x.us-west-2.rds.amazonaws.com"
      db_port                          = 5432
      efs_id                           = "fs-1"
      efs_arn                          = "arn:aws:elasticfilesystem:us-west-2:127214190346:file-system/fs-1"
      efs_cms_content_access_point_id  = "fsap-1"
      efs_cms_content_access_point_arn = "arn:aws:elasticfilesystem:us-west-2:127214190346:access-point/fsap-1"
      rehearsal_vods_bucket            = { name = "gkoi-prod2-rehearsal-vods-127214190346", arn = "arn:aws:s3:::gkoi-prod2-rehearsal-vods-127214190346", region = "us-west-2", days = 3 }
    }
  }
}
override_data {
  target = data.terraform_remote_state.registry
  values = {
    outputs = {
      repositories = {
        cms-server    = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/cms-server"
        cms-nginx     = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/cms-nginx"
        engine-api    = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/engine-api"
        engine-worker = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/engine-worker"
        engine-edge   = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/engine-edge"
        fm-api        = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/fm-api"
        fm-worker     = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/fm-worker"
        fm-web        = "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/fm-web"
      }
    }
  }
}

run "default_all_parked_live_bucket" {
  command = plan
  assert {
    condition     = alltrue([for n, p in local.is_parked : p])
    error_message = "default: every service parked"
  }
}

run "default_values" {
  command = apply
  assert {
    condition     = local.engine_env.S3_BUCKET == "gkoi-beta-vods" && local.engine_env.CDN_DISTRIBUTION_ID == "E2LXDFW5VZ1UHD" && local.engine_env.CDN_DOWNLOAD_BASE == "https://vod.gkoi.com"
    error_message = "rehearsal off = today's engine env"
  }
  assert {
    condition     = jsonencode(local.vod_buckets) == jsonencode(["gkoi-beta-vods"]) && jsonencode(local.vod_distribution_ids) == jsonencode(["E2LXDFW5VZ1UHD"])
    error_message = "rehearsal off = today's IAM"
  }
  assert {
    condition     = length(output.rehearsal.running) == 0 && !output.rehearsal.enabled
    error_message = "nothing runs by default"
  }
}

run "rehearsal_engine_only" {
  command = apply
  variables {
    rehearsal       = true
    parked_services = ["cms", "fm-api", "fm-worker", "fm-web"]
  }
  assert {
    condition     = local.engine_env.S3_BUCKET == "gkoi-prod2-rehearsal-vods-127214190346" && local.engine_env.CDN_DISTRIBUTION_ID == "" && local.engine_env.CDN_DOWNLOAD_BASE == ""
    error_message = "rehearsal engine env"
  }
  assert {
    condition     = jsonencode(local.vod_buckets) == jsonencode(["gkoi-prod2-rehearsal-vods-127214190346"]) && length(local.vod_distribution_ids) == 0
    error_message = "rehearsal IAM: the scratch bucket only, no invalidation"
  }
  assert {
    condition     = jsonencode(output.rehearsal.running) == jsonencode(["engine-api", "engine-worker"]) && output.rehearsal.engine_bucket == "gkoi-prod2-rehearsal-vods-127214190346"
    error_message = "running"
  }
  assert {
    condition     = !local.is_parked["engine-api"] && !local.is_parked["engine-worker"] && local.is_parked["cms"] && local.is_parked["fm-api"]
    error_message = "parking"
  }
}

run "rehearsal_refused_with_fm_running" {
  command = plan
  variables {
    rehearsal       = true
    parked_services = ["cms"]
  }
  expect_failures = [terraform_data.preflight]
}

run "rehearsal_refused_with_engine_env_bucket" {
  command = plan
  variables {
    rehearsal       = true
    parked_services = ["cms", "fm-api", "fm-worker", "fm-web"]
    engine_env      = { CDN_DOWNLOAD_BASE = "https://vod.gkoi.com" }
  }
  expect_failures = [terraform_data.preflight]
}

run "rehearsal_refused_without_bucket" {
  command = plan
  variables {
    rehearsal       = true
    parked_services = ["cms", "fm-api", "fm-worker", "fm-web"]
  }
  override_data {
    target = data.terraform_remote_state.data
    values = { outputs = { db_endpoint = "x", db_port = 5432, efs_id = "fs-1", efs_arn = "arn:aws:elasticfilesystem:us-west-2:127214190346:file-system/fs-1", efs_cms_content_access_point_id = "fsap-1", efs_cms_content_access_point_arn = "arn:aws:elasticfilesystem:us-west-2:127214190346:access-point/fsap-1" } }
  }
  expect_failures = [terraform_data.preflight]
}

run "bad_service_name" {
  command = plan
  variables {
    parked_services = ["engine"]
  }
  expect_failures = [var.parked_services]
}
