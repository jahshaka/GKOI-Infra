# One Fargate task definition + its ECS service (+ target-tracking autoscaling on CPU).
#
# The caller builds the container definitions (JSON) and the roles; this module owns the deploy shape the operator
# ruled for every control-plane service (2026-11-10): min healthy 100 % / max 200 % (a deploy SURGES, it never drops
# below the running count), the circuit breaker with rollback, ECS Exec on, private subnets only, no public IP.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }
}

variable "name" {
  description = "The service name, also the task-definition family (gkoi-prod2-<name>)."
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cpu" {
  description = "Task CPU units (Fargate: 256 | 512 | 1024 | 2048 | 4096 …)."
  type        = number
}

variable "memory" {
  description = "Task memory, MiB (a valid Fargate pairing with cpu)."
  type        = number
}

variable "ephemeral_storage_gib" {
  description = "null = Fargate's default 20 GiB; else 21–200."
  type        = number
  default     = null
}

variable "container_definitions" {
  description = "The containers, as the JSON string ECS takes."
  type        = string
}

variable "efs_volumes" {
  description = "EFS volumes (TLS + IAM, through an access point): name → { file_system_id, access_point_id }."
  type = map(object({
    file_system_id  = string
    access_point_id = string
  }))
  default = {}
}

variable "scratch_volumes" {
  description = "Task-local bind volumes (on the task's ephemeral storage), shared between the task's containers."
  type        = list(string)
  default     = []
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "load_balancer" {
  description = "null = no load balancer (workers); else the target group and the container/port it forwards to."
  type = object({
    target_group_arn = string
    container_name   = string
    container_port   = number
  })
  default = null
}

variable "extra_load_balancers" {
  description = "More target groups the same service registers in (e.g. engine-api's api:3000 in the INTERNAL ALB for the media boxes). ECS allows 5 in all."
  type = list(object({
    target_group_arn = string
    container_name   = string
    container_port   = number
  }))
  default = []
}

variable "health_check_grace_period_seconds" {
  description = "With a load balancer only: how long ECS ignores a failing target-group health check after a start."
  type        = number
  default     = 60
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 1
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  type    = number
  default = 200
}

variable "enable_execute_command" {
  type    = bool
  default = true
}

variable "wait_for_steady_state" {
  description = "true = an apply waits until the new deployment is steady (and fails if it rolls back)."
  type        = bool
  default     = false
}

resource "aws_ecs_task_definition" "this" {
  family                   = "gkoi-prod2-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  container_definitions    = var.container_definitions

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # ruled: amd64 (ffmpeg and the UE server are amd64 only)
  }

  dynamic "ephemeral_storage" {
    for_each = var.ephemeral_storage_gib == null ? [] : [var.ephemeral_storage_gib]
    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  dynamic "volume" {
    for_each = var.efs_volumes
    content {
      name = volume.key
      efs_volume_configuration {
        file_system_id     = volume.value.file_system_id
        root_directory     = "/" # must be / with an access point (the access point sets the real root)
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = volume.value.access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }

  dynamic "volume" {
    for_each = toset(var.scratch_volumes)
    content {
      name = volume.value
    }
  }

  tags = { Name = "gkoi-prod2-${var.name}", service = var.name }
}

resource "aws_ecs_service" "this" {
  name                    = var.name
  cluster                 = var.cluster_arn
  task_definition         = aws_ecs_task_definition.this.arn
  desired_count           = var.min_capacity
  enable_execute_command  = var.enable_execute_command
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true
  wait_for_steady_state   = var.wait_for_steady_state

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
  platform_version = "1.4.0"

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = concat(var.load_balancer == null ? [] : [var.load_balancer], var.extra_load_balancers)
    content {
      target_group_arn = load_balancer.value.target_group_arn
      container_name   = load_balancer.value.container_name
      container_port   = load_balancer.value.container_port
    }
  }

  health_check_grace_period_seconds = var.load_balancer == null && length(var.extra_load_balancers) == 0 ? null : var.health_check_grace_period_seconds

  # The autoscaling target owns the running count between min and max.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Name = var.name, service = var.name }
}

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "gkoi-prod2-${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "service_id" {
  value = aws_ecs_service.this.id
}

output "task_definition_family" {
  value = aws_ecs_task_definition.this.family
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}
