# The long-running services. Container definitions are built here; modules/ecs-service owns the task definition,
# the service (surge 100/200, circuit breaker + rollback, ECS Exec, private subnets) and the CPU target tracking.

locals {
  log_group = { for n in ["cms-server", "cms-nginx", "cms-migrate", "engine-api", "engine-worker", "engine-migrate", "fm-api", "fm-worker", "fm-web", "fm-migrate"] : n => "/gkoi/prod2/ecs/${n}" }

  # env / secrets as ECS lists, sorted (a stable task-definition diff)
  cms_server_env_list  = [for k in sort(keys(local.cms_server_env)) : { name = k, value = local.cms_server_env[k] }]
  cms_nginx_env_list   = [for k in sort(keys(local.cms_nginx_env)) : { name = k, value = local.cms_nginx_env[k] }]
  engine_env_list      = [for k in sort(keys(local.engine_env)) : { name = k, value = local.engine_env[k] }]
  engine_edge_env_list = [for k in sort(keys(local.engine_edge_env)) : { name = k, value = local.engine_edge_env[k] }]
  fm_env_list          = [for k in sort(keys(local.fm_env)) : { name = k, value = local.fm_env[k] }]
  cms_server_secrets   = [for k in sort(keys(var.cms_server_secret_env)) : { name = k, valueFrom = local.secret_arn[var.cms_server_secret_env[k]] }]
  cms_nginx_secrets    = [for k in sort(keys(var.cms_nginx_secret_env)) : { name = k, valueFrom = local.secret_arn[var.cms_nginx_secret_env[k]] }]
  engine_secrets       = [for k in sort(keys(var.engine_secret_env)) : { name = k, valueFrom = local.secret_arn[var.engine_secret_env[k]] }]
  fm_secrets           = [for k in sort(keys(var.fm_secret_env)) : { name = k, valueFrom = local.secret_arn[var.fm_secret_env[k]] }]
  engine_edge_secrets  = [{ name = "EDGE_LIVE_ORIGIN_SECRET", valueFrom = local.live_origin_value_from }]

  # The worker's Download-build scratch: a task volume on the (enlarged) ephemeral storage.
  vod_build_dir = "/scratch/vod-build"

  awslogs = { for n, g in merge(local.log_group, { engine-edge = aws_cloudwatch_log_group.engine_edge.name }) : n => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = g
      awslogs-region        = local.region
      awslogs-stream-prefix = n
    }
  } }

  node_health = { # node's fetch: the slim images have no curl / wget
    cms-server    = "fetch('http://127.0.0.1:8090/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
    engine-api    = "fetch('http://127.0.0.1:3000/api/v1/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
    engine-worker = "fetch('http://127.0.0.1:3001/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
    fm-api        = "fetch('http://127.0.0.1:3200/api/v1/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
  }

  nofile = [{ name = "nofile", softLimit = 65536, hardLimit = 65536 }]

  # ---------------------------------------------------------------------------------------------------------------
  # cms = cache-init (one shot) + server + nginx
  # ---------------------------------------------------------------------------------------------------------------
  # A Fargate task volume starts root:0755 and both CMS images run as uid 33, so the shared origin-cache directory is
  # handed to uid 33 first by a one-shot run of the nginx image as root (no third image).
  cms_cache_init = {
    name        = "cache-init"
    image       = local.image["cms-nginx"]
    essential   = false
    user        = "0"
    entryPoint  = ["/bin/sh", "-c"]
    command     = ["chown 33:0 /data/nginx-cache && chmod 0775 /data/nginx-cache"]
    mountPoints = [{ sourceVolume = "nginx-cache", containerPath = "/data/nginx-cache", readOnly = false }]
    logConfiguration = merge(local.awslogs["cms-nginx"], {
      options = merge(local.awslogs["cms-nginx"].options, { awslogs-stream-prefix = "cache-init" })
    })
  }

  cms_server = {
    name         = "server"
    image        = local.image["cms-server"]
    essential    = true
    portMappings = [{ containerPort = 8090, protocol = "tcp", name = "cms-server" }]
    environment  = local.cms_server_env_list
    secrets      = local.cms_server_secrets
    mountPoints = [
      { sourceVolume = "content", containerPath = "/data/content", readOnly = false },
      { sourceVolume = "nginx-cache", containerPath = "/data/nginx-cache", readOnly = false },
    ]
    dependsOn        = [{ containerName = "cache-init", condition = "SUCCESS" }]
    healthCheck      = { command = ["CMD", "node", "-e", local.node_health["cms-server"]], interval = 10, timeout = 5, retries = 6, startPeriod = 120 }
    stopTimeout      = 30
    linuxParameters  = { initProcessEnabled = true }
    logConfiguration = local.awslogs["cms-server"]
  }

  cms_nginx = {
    name         = "nginx"
    image        = local.image["cms-nginx"]
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp", name = "cms-nginx" }]
    environment  = local.cms_nginx_env_list
    secrets      = local.cms_nginx_secrets
    mountPoints = [
      { sourceVolume = "content", containerPath = "/data/content", readOnly = true },
      { sourceVolume = "nginx-cache", containerPath = "/data/nginx-cache", readOnly = false },
    ]
    dependsOn        = [{ containerName = "server", condition = "HEALTHY" }]
    stopTimeout      = 30
    ulimits          = local.nofile
    logConfiguration = local.awslogs["cms-nginx"]
  }

  # ---------------------------------------------------------------------------------------------------------------
  # engine-api = api (+ edge sidecar)
  # ---------------------------------------------------------------------------------------------------------------
  engine_api = {
    name             = "api"
    image            = local.image["engine-api"]
    essential        = true
    portMappings     = [{ containerPort = 3000, protocol = "tcp", name = "engine-api" }]
    environment      = local.engine_env_list
    secrets          = local.engine_secrets
    healthCheck      = { command = ["CMD", "node", "-e", local.node_health["engine-api"]], interval = 10, timeout = 5, retries = 6, startPeriod = 30 }
    stopTimeout      = 20
    ulimits          = local.nofile
    linuxParameters  = { initProcessEnabled = true }
    logConfiguration = local.awslogs["engine-api"]
  }

  engine_edge = var.engine_edge_sidecar ? {
    name             = "edge"
    image            = lookup(local.image, "engine-edge", "")
    essential        = true
    portMappings     = [{ containerPort = var.engine_edge_port, protocol = "tcp", name = "engine-edge" }]
    environment      = local.engine_edge_env_list
    secrets          = local.engine_edge_secrets
    dependsOn        = [{ containerName = "api", condition = "HEALTHY" }]
    stopTimeout      = 35 # the box's api-gw drain
    ulimits          = local.nofile
    logConfiguration = local.awslogs["engine-edge"]
  } : null

  engine_worker = {
    name             = "worker"
    image            = local.image["engine-worker"]
    essential        = true
    environment      = concat(local.engine_env_list, [{ name = "VOD_BUILD_DIR", value = local.vod_build_dir }])
    secrets          = local.engine_secrets
    mountPoints      = [{ sourceVolume = "vod-build", containerPath = local.vod_build_dir, readOnly = false }]
    healthCheck      = { command = ["CMD", "node", "-e", local.node_health["engine-worker"]], interval = 10, timeout = 5, retries = 6, startPeriod = 30 }
    stopTimeout      = 60
    linuxParameters  = { initProcessEnabled = true }
    logConfiguration = local.awslogs["engine-worker"]
  }

  # ---------------------------------------------------------------------------------------------------------------
  # file manager
  # ---------------------------------------------------------------------------------------------------------------
  fm_api = {
    name             = "api"
    image            = local.image["fm-api"]
    essential        = true
    portMappings     = [{ containerPort = 3200, protocol = "tcp", name = "fm-api" }]
    environment      = local.fm_env_list
    secrets          = local.fm_secrets
    healthCheck      = { command = ["CMD", "node", "-e", local.node_health["fm-api"]], interval = 10, timeout = 5, retries = 6, startPeriod = 20 }
    stopTimeout      = 20
    ulimits          = local.nofile
    linuxParameters  = { initProcessEnabled = true }
    logConfiguration = local.awslogs["fm-api"]
  }

  fm_worker = {
    name             = "worker"
    image            = local.image["fm-worker"]
    essential        = true
    environment      = local.fm_env_list
    secrets          = local.fm_secrets
    stopTimeout      = 60
    linuxParameters  = { initProcessEnabled = true }
    logConfiguration = local.awslogs["fm-worker"]
  }

  fm_web = var.fm_web_enabled ? {
    name             = "web"
    image            = lookup(local.image, "fm-web", "")
    essential        = true
    portMappings     = [{ containerPort = 80, protocol = "tcp", name = "fm-web" }]
    healthCheck      = { command = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/"], interval = 10, timeout = 5, retries = 6, startPeriod = 10 }
    logConfiguration = local.awslogs["fm-web"]
  } : null
}

# =================================================================================================================
# Services
# =================================================================================================================

module "cms" {
  source       = "../../../modules/ecs-service"
  name         = "cms"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  cpu    = var.sizes["cms"].cpu
  memory = var.sizes["cms"].memory

  container_definitions = jsonencode([local.cms_cache_init, local.cms_server, local.cms_nginx])
  efs_volumes = {
    content = {
      file_system_id  = local.data.efs_id
      access_point_id = local.data.efs_cms_content_access_point_id
    }
  }
  scratch_volumes = ["nginx-cache"]

  execution_role_arn = aws_iam_role.exec["cms"].arn
  task_role_arn      = aws_iam_role.task["cms"].arn
  subnet_ids         = local.subnets
  security_group_ids = local.tasks_sg

  load_balancer = {
    target_group_arn = local.tg["cms"].arn
    container_name   = "nginx"
    container_port   = 8080
  }
  health_check_grace_period_seconds = 300 # the boot runs both migrators before it listens

  min_capacity          = var.parked ? 0 : (local.tg["cms"].min_capacity)
  max_capacity          = var.parked ? 0 : (local.tg["cms"].max_capacity) # stays 1 until C16 is proven on 2 tasks
  cpu_target_percent    = var.cpu_target_percent
  wait_for_steady_state = var.wait_for_steady_state

  depends_on = [terraform_data.preflight, aws_ecs_cluster_capacity_providers.this]
}

module "engine_api" {
  source       = "../../../modules/ecs-service"
  name         = "engine-api"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  cpu    = var.sizes["engine-api"].cpu
  memory = var.sizes["engine-api"].memory

  container_definitions = var.engine_edge_sidecar ? jsonencode([local.engine_api, local.engine_edge]) : jsonencode([local.engine_api])

  execution_role_arn = aws_iam_role.exec["engine"].arn
  task_role_arn      = aws_iam_role.task["engine-api"].arn
  subnet_ids         = local.subnets
  security_group_ids = local.tasks_sg

  load_balancer = {
    target_group_arn = local.tg["engine-api"].arn
    container_name   = var.engine_edge_sidecar ? "edge" : "api"
    container_port   = var.engine_edge_sidecar ? var.engine_edge_port : 3000
  }
  health_check_grace_period_seconds = 60

  min_capacity          = var.parked ? 0 : (local.tg["engine-api"].min_capacity)
  max_capacity          = var.parked ? 0 : (local.tg["engine-api"].max_capacity)
  cpu_target_percent    = var.cpu_target_percent
  wait_for_steady_state = var.wait_for_steady_state

  depends_on = [terraform_data.preflight, aws_ecs_cluster_capacity_providers.this]
}

module "engine_worker" {
  source       = "../../../modules/ecs-service"
  name         = "engine-worker"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  cpu                   = var.sizes["engine-worker"].cpu
  memory                = var.sizes["engine-worker"].memory
  ephemeral_storage_gib = var.engine_worker_ephemeral_gib

  container_definitions = jsonencode([local.engine_worker])
  scratch_volumes       = ["vod-build"]

  execution_role_arn = aws_iam_role.exec["engine"].arn
  task_role_arn      = aws_iam_role.task["engine-worker"].arn
  subnet_ids         = local.subnets
  security_group_ids = local.tasks_sg

  min_capacity          = var.parked ? 0 : (var.worker_capacity["engine-worker"].min)
  max_capacity          = var.parked ? 0 : (var.worker_capacity["engine-worker"].max)
  cpu_target_percent    = var.cpu_target_percent
  wait_for_steady_state = var.wait_for_steady_state

  depends_on = [terraform_data.preflight, aws_ecs_cluster_capacity_providers.this]
}

module "fm_api" {
  source       = "../../../modules/ecs-service"
  name         = "fm-api"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  cpu    = var.sizes["fm-api"].cpu
  memory = var.sizes["fm-api"].memory

  container_definitions = jsonencode([local.fm_api])

  execution_role_arn = aws_iam_role.exec["fm"].arn
  task_role_arn      = aws_iam_role.task["fm-api"].arn
  subnet_ids         = local.subnets
  security_group_ids = local.tasks_sg

  load_balancer = {
    target_group_arn = local.tg["fm-api"].arn
    container_name   = "api"
    container_port   = 3200
  }
  health_check_grace_period_seconds = 60

  min_capacity          = var.parked ? 0 : (local.tg["fm-api"].min_capacity)
  max_capacity          = var.parked ? 0 : (local.tg["fm-api"].max_capacity)
  cpu_target_percent    = var.cpu_target_percent
  wait_for_steady_state = var.wait_for_steady_state

  depends_on = [terraform_data.preflight, aws_ecs_cluster_capacity_providers.this]
}

module "fm_worker" {
  source       = "../../../modules/ecs-service"
  name         = "fm-worker"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  cpu    = var.sizes["fm-worker"].cpu
  memory = var.sizes["fm-worker"].memory

  container_definitions = jsonencode([local.fm_worker])

  execution_role_arn = aws_iam_role.exec["fm"].arn
  task_role_arn      = aws_iam_role.task["fm-worker"].arn
  subnet_ids         = local.subnets
  security_group_ids = local.tasks_sg

  min_capacity          = var.parked ? 0 : (var.worker_capacity["fm-worker"].min)
  max_capacity          = var.parked ? 0 : (var.worker_capacity["fm-worker"].max)
  cpu_target_percent    = var.cpu_target_percent
  wait_for_steady_state = var.wait_for_steady_state

  depends_on = [terraform_data.preflight, aws_ecs_cluster_capacity_providers.this]
}

module "fm_web" {
  source       = "../../../modules/ecs-service"
  count        = var.fm_web_enabled ? 1 : 0
  name         = "fm-web"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  cpu    = var.sizes["fm-web"].cpu
  memory = var.sizes["fm-web"].memory

  container_definitions = jsonencode([local.fm_web])

  execution_role_arn = aws_iam_role.exec["fm"].arn
  task_role_arn      = aws_iam_role.task["fm-web"].arn
  subnet_ids         = local.subnets
  security_group_ids = local.tasks_sg

  # Its target group has no listener rule (edge-alb: no host), and ECS refuses a target group no load balancer uses.
  load_balancer = var.fm_web_attach_lb ? {
    target_group_arn = local.tg["fm-web"].arn
    container_name   = "web"
    container_port   = 80
  } : null

  min_capacity          = var.parked ? 0 : (var.fm_web_attach_lb ? local.tg["fm-web"].min_capacity : var.fm_web_capacity.min)
  max_capacity          = var.parked ? 0 : (var.fm_web_attach_lb ? local.tg["fm-web"].max_capacity : var.fm_web_capacity.max)
  cpu_target_percent    = var.cpu_target_percent
  wait_for_steady_state = var.wait_for_steady_state

  depends_on = [terraform_data.preflight, aws_ecs_cluster_capacity_providers.this]
}
