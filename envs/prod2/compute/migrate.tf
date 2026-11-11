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

  # One-off: copy the CMS content from the Lightsail site box onto EFS (C11). rsync over SSH with a key the box
  # restricts to `rrsync -ro /opt/aisolver-www/content` (read-only, that one directory). Run with `ecs run-task`;
  # the final sync in the P4 window adds the override RSYNC_DELETE=1. Files land as the access point's uid/gid (33).
  cms_content_sync = {
    name         = "sync"
    image        = var.content_sync_image
    essential    = true
    portMappings = []
    entryPoint   = ["sh", "-c"]
    command = [<<-EOS
      set -eu
      apk add --no-cache rsync openssh-client >/dev/null
      umask 077; mkdir -p /root/.ssh
      printf '%s\n' "$SYNC_SSH_KEY" > /root/.ssh/id; chmod 600 /root/.ssh/id
      printf '%s\n' "$SYNC_HOST_KEY" > /root/.ssh/known_hosts
      extra=""; if [ "$${RSYNC_DELETE:-0}" = 1 ]; then extra="--delete"; fi
      echo "content-sync: start (delete=$${RSYNC_DELETE:-0})"
      rsync -rlt --omit-dir-times --no-perms --no-owner --no-group --partial --stats $extra \
        -e "ssh -i /root/.ssh/id -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes -o ServerAliveInterval=30" \
        "root@$SYNC_HOST:/" /data/content/ > /tmp/rsync.log 2>&1 || { rc=$?; tail -n 30 /tmp/rsync.log; echo "CONTENT_SYNC_FAILED rsync exit $rc"; exit "$rc"; }
      tail -n 20 /tmp/rsync.log
      echo "content-sync: files on EFS: $(find /data/content -type f | wc -l)"
      echo "CONTENT_SYNC_OK"
    EOS
    ]
    environment = [
      { name = "SYNC_HOST", value = var.content_sync_host },
      { name = "SYNC_HOST_KEY", value = var.content_sync_host_key },
    ]
    secrets          = [{ name = "SYNC_SSH_KEY", valueFrom = local.secret_arn["cms/CONTENT_SYNC_SSH_KEY"] }]
    mountPoints      = [{ sourceVolume = "content", containerPath = "/data/content", readOnly = false }]
    logConfiguration = merge(local.awslogs["cms-migrate"], { options = merge(local.awslogs["cms-migrate"].options, { awslogs-stream-prefix = "cms-content-sync" }) })
  }

  migrate_tasks = {
    cms-migrate = {
      container = local.cms_migrate
      exec_role = aws_iam_role.exec["cms"].arn
      task_role = aws_iam_role.task["cms"].arn # the content mount (a migration may seed files)
      efs       = true
    }
    cms-content-sync = {
      container = local.cms_content_sync
      exec_role = aws_iam_role.exec["cms"].arn
      task_role = aws_iam_role.task["cms"].arn
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
