# One-off migrator task definitions (no service). The orchestrator runs ONE of each with `ecs run-task` BEFORE it
# updates the service to the same release — never as a container in every task (the engine and FM migrators take no
# lock: two concurrent runs both apply the same pending files; scheduler audit 2026-11-10). Same images and env as the
# service, so a migrator always runs the release it prepares.
#
#   cms-migrate     node dist/index.js --migrate      (+ --enter-maintenance for an `update: stop` release — C17;
#                   then --maintenance=off as a second run-task once every task runs the new build; override `command`)
#   engine-migrate  node server/apps/api/dist/migrate.js   (the engine-api image)
#   fm-migrate      node apps/api/dist/migrate.js          (the fm-api image)

locals {
  cms_migrate = merge(local.cms_server, {
    name             = "migrate"
    portMappings     = []
    command          = ["node", "dist/index.js", "--migrate"]
    dependsOn        = null
    healthCheck      = null
    mountPoints      = [{ sourceVolume = "content", containerPath = "/data/content", readOnly = false }]
    logConfiguration = local.awslogs["cms-migrate"]
  })

  engine_migrate = merge(local.engine_api, {
    name             = "migrate"
    portMappings     = []
    command          = ["node", "server/apps/api/dist/migrate.js"]
    healthCheck      = null
    logConfiguration = local.awslogs["engine-migrate"]
  })

  fm_migrate = merge(local.fm_api, {
    name             = "migrate"
    portMappings     = []
    command          = ["node", "apps/api/dist/migrate.js"]
    healthCheck      = null
    logConfiguration = local.awslogs["fm-migrate"]
  })

  migrate_tasks = {
    cms-migrate = {
      container = local.cms_migrate
      exec_role = aws_iam_role.exec["cms"].arn
      task_role = aws_iam_role.task["cms"].arn # the content mount (a migration may seed files)
      efs       = true
    }
    engine-migrate = {
      container = local.engine_migrate
      exec_role = aws_iam_role.exec["engine"].arn
      task_role = aws_iam_role.task["migrate"].arn
      efs       = false
    }
    fm-migrate = {
      container = local.fm_migrate
      exec_role = aws_iam_role.exec["fm"].arn
      task_role = aws_iam_role.task["migrate"].arn
      efs       = false
    }
  }
}

resource "aws_ecs_task_definition" "migrate" {
  for_each                 = local.migrate_tasks
  family                   = "gkoi-prod2-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.sizes[each.key].cpu)
  memory                   = tostring(var.sizes[each.key].memory)
  execution_role_arn       = each.value.exec_role
  task_role_arn            = each.value.task_role
  container_definitions    = jsonencode([each.value.container])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  dynamic "volume" {
    for_each = each.value.efs ? [1] : []
    content {
      name = "content"
      efs_volume_configuration {
        file_system_id     = local.data.efs_id
        root_directory     = "/"
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = local.data.efs_cms_content_access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }

  tags = { Name = "gkoi-prod2-${each.key}", service = each.key }

  depends_on = [terraform_data.preflight]
}
