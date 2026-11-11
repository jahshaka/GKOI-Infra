# One region's War Room GAME box (PLAN-AWS-MIGRATION-PROD2-V1 P6): an ASG of ONE EC2 instance (min/max from the stack),
# its Elastic IP (stable for DNS; the box associates it to itself at boot), one security group (exactly the live boxes'
# game ports), an instance role under /gkoi/, the box's config in SSM, the rehearsal DNS records (+ the live ones behind
# the stack's switch) and alarms. What runs ON the box is envs/prod2/game/box/ wrapping ops/warroom-game (README there).
#
# Ports — the live game boxes' SG (gkoi-game-usw2 sg-03a36024cd25b1701 / gkoi-game-euc1 sg-0d3efc112d4d89e81, read
# 2026-11-11), IPv4 only (the prod2 VPCs have no IPv6; the live SGs' ::/0 copies of the same three rules are dropped):
#   tcp 9443  matchd (TLS: /v1/version, matches, lobbies, rooms)
#   tcp 8443  wasm-gateway WSS
#   udp 8443  wasm-gateway WebTransport (QUIC)
#   NOT open: 22 (SSM only), 80 (certs by DNS-01), the monitors 9544/9545 (loopback), the UE servers' UDP 7777-7800
#   (loopback: the gateway proxies them), UE's TCP 1985 (loopback chain of warroom-game.sh).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }
}

locals {
  name   = "gkoi-prod2-game-${var.key}"
  t_type = can(regex("^t[0-9]", var.instance_type))

  tags = {
    Name        = local.name
    "gkoi-game" = var.key
    role        = "game"
  }
  alarm_actions = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
}

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# --- security group ----------------------------------------------------------------------------------------------

resource "aws_security_group" "box" {
  name        = local.name
  description = "GKOI War Room game box ${var.key}: matchd TLS, gateway WSS + WebTransport"
  vpc_id      = var.vpc_id
  tags        = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "matchd" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.box.id
  description       = "matchd (TLS)"
  ip_protocol       = "tcp"
  from_port         = var.matchd_port
  to_port           = var.matchd_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "gateway_tcp" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.box.id
  description       = "gateway wss"
  ip_protocol       = "tcp"
  from_port         = var.gateway_port
  to_port           = var.gateway_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "gateway_udp" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.box.id
  description       = "gateway webtransport"
  ip_protocol       = "udp"
  from_port         = var.gateway_port
  to_port           = var.gateway_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.box.id
  description       = "All egress (www.gkoi.com JWKS + invites + plays, ECR, S3, Secrets Manager, SSM, LetsEncrypt, apt)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- the Elastic IP (the box associates it to itself: phase eip of game-bootstrap.sh) ---------------------------

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = local.tags
}

# --- IAM ---------------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "box" {
  name                 = local.name
  path                 = "/gkoi/"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.box.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cwagent" {
  role       = aws_iam_role.box.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "box" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [for r in var.ecr_repositories : "arn:aws:ecr:${var.region}:${var.account_id}:repository/${r}"]
  }
  statement {
    sid       = "OwnSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.secret_arns
  }
  statement {
    sid       = "OwnConfig"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.config.arn]
  }
  statement {
    sid       = "Bundle"
    actions   = ["s3:GetObject"]
    resources = var.bundle_object_arns
  }
  # Its own EIP onto itself — both resources carry the tag gkoi-game=<key> (the launch template tags the instance).
  statement {
    sid       = "OwnEip"
    actions   = ["ec2:AssociateAddress"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*", "arn:aws:ec2:${var.region}:${var.account_id}:elastic-ip/${aws_eip.this.allocation_id}"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/gkoi-game"
      values   = [var.key]
    }
  }
  statement {
    sid       = "EipRead"
    actions   = ["ec2:DescribeAddresses"]
    resources = ["*"]
  }
  statement {
    sid       = "OwnLifecycle"
    actions   = ["autoscaling:CompleteLifecycleAction", "autoscaling:RecordLifecycleActionHeartbeat"]
    resources = ["arn:aws:autoscaling:${var.region}:${var.account_id}:autoScalingGroup:*:autoScalingGroupName/${local.name}"]
  }
  # Let's Encrypt DNS-01 (certbot --dns-route53 with the instance role): TXT records _acme-challenge.<its names> only
  # (= ops/warroom-game/bootstrap/iam-game-instance-policy.json.tmpl, for the rehearsal AND the live names).
  statement {
    sid       = "Dns01Lookup"
    actions   = ["route53:ListHostedZones", "route53:GetChange"]
    resources = ["*"]
  }
  statement {
    sid       = "Dns01ChallengeRecordsOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.zone_id}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [for n in var.acme_names : "_acme-challenge.${n}"]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }
}

resource "aws_iam_role_policy" "box" {
  name   = "game-box"
  role   = aws_iam_role.box.id
  policy = data.aws_iam_policy_document.box.json
}

resource "aws_iam_instance_profile" "box" {
  name = local.name
  path = "/gkoi/"
  role = aws_iam_role.box.name
}

# --- the box's configuration (non-secret; secrets are named by ARN and read on the box) ------------------------

resource "aws_ssm_parameter" "config" {
  name        = "/gkoi/prod2/game/${var.key}/config"
  description = "GKOI game box ${var.key}: the bootstrap configuration (no secrets)"
  type        = "String"
  tier        = "Intelligent-Tiering"
  value = jsonencode(merge(var.config, {
    eip_allocation_id = aws_eip.this.allocation_id
    eip_public_ip     = aws_eip.this.public_ip
    asg_name          = local.name
    lifecycle_hook    = "drain"
  }))
}

# The CloudWatch agent's Prometheus scrape of matchd /metrics writes EMF records here (the metrics are extracted from
# them); short retention — the metrics themselves live in CloudWatch Metrics.
resource "aws_cloudwatch_log_group" "metrics" {
  name              = var.metrics_log_group
  retention_in_days = 3
}

# --- launch template + ASG ---------------------------------------------------------------------------------------

resource "aws_launch_template" "box" {
  name                   = local.name
  description            = "GKOI game box ${var.key} (Ubuntu 24.04, Docker, ops/warroom-game via game-bootstrap.sh)"
  image_id               = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.instance_type
  update_default_version = true
  user_data              = base64encode(var.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.box.arn
  }

  # IMDSv2 only, hop limit 2 = the live boxes'. The game container runs with host networking, so the hop limit does not
  # keep it from IMDS: game-bootstrap.sh (phase imdsguard) REJECTs the runtime uid's traffic to 169.254.169.254.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  dynamic "credit_specification" {
    for_each = local.t_type ? [var.cpu_credits] : []
    content {
      cpu_credits = credit_specification.value
    }
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true # until the bootstrap moves the EIP onto it (then the EIP is the public address)
    delete_on_termination       = true
    security_groups             = [aws_security_group.box.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  tags = { Name = local.name }
}

resource "aws_autoscaling_group" "box" {
  name                      = local.name
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = var.public_subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 900
  default_cooldown          = 300
  wait_for_capacity_timeout = "0" # an apply never waits on the bootstrap (it takes minutes)
  enabled_metrics           = ["GroupInServiceInstances", "GroupDesiredCapacity", "GroupTerminatingInstances", "GroupPendingInstances"]

  launch_template {
    id      = aws_launch_template.box.id
    version = aws_launch_template.box.latest_version
  }

  # The drain on scale-in / replacement: box/lifecycle-watch.sh sees Terminating:Wait in IMDS, runs the War Room tool's
  # own drain-hook.sh (matchd drain-and-exit: live matches finish), heartbeats, completes with CONTINUE. Default
  # CONTINUE: a dead box (or watcher) never blocks a termination.
  initial_lifecycle_hook {
    name                 = "drain"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    default_result       = "CONTINUE"
    heartbeat_timeout    = var.lifecycle_heartbeat_seconds
  }

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false # the launch template tags the instance
    }
  }

  depends_on = [aws_ssm_parameter.config, aws_cloudwatch_log_group.metrics]

  # No instance_refresh: ONE EIP per region — a new box would take the address from the live one. Replacing the box is
  # a deliberate step (README "Replacing the box"); a release never replaces it (box/roll.sh, in place).
}

# --- DNS: the rehearsal names always; the live names only when the stack is told to take them over ------------

resource "aws_route53_record" "rehearsal" {
  for_each = toset(var.rehearsal_records)
  zone_id  = var.zone_id
  name     = each.value
  type     = "A"
  ttl      = 60
  records  = [aws_eip.this.public_ip]
}

# A LIVE name (game-<key>.gkoi.com, gw-<key>.gkoi.com) taken over at the switch: allow_overwrite adopts the existing
# record (today: the old instance's EIP, TTL 300). prevent_destroy: turning manage_live_records off (or a destroy) must
# never DELETE a live name — the plan stops; point the record back by hand, then `terraform state rm` it (README).
resource "aws_route53_record" "live" {
  for_each        = toset(var.live_records)
  zone_id         = var.zone_id
  name            = each.value
  type            = "A"
  ttl             = 300
  records         = [aws_eip.this.public_ip]
  allow_overwrite = true
  lifecycle {
    prevent_destroy = true
  }
}

# --- alarms (the region's gkoi-ops-alerts) -------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "in_service" {
  alarm_name          = "${local.name}-not-in-service"
  alarm_description   = "Game ${var.key}: fewer in-service boxes than the ASG minimum for 10 minutes"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "status" {
  alarm_name          = "${local.name}-status-check"
  alarm_description   = "Game ${var.key}: EC2 status check failing for 5 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${local.name}-cpu-high"
  alarm_description   = "Game ${var.key}: CPU above 70 % for 15 minutes (t3a baseline is 40 %)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# T-family only: in standard mode an empty balance throttles the box to its baseline (40 % of 4 vCPUs) — the War
# Room's "choppy matches" question of 2026-11-09. 100 credits = ~1 h of one extra full vCPU.
resource "aws_cloudwatch_metric_alarm" "credits" {
  count               = local.t_type ? 1 : 0
  alarm_name          = "${local.name}-cpu-credits-low"
  alarm_description   = "Game ${var.key}: CPU credit balance below 100 for 15 minutes (standard mode throttles to the baseline at 0)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "${local.name}-disk-high"
  alarm_description   = "Game ${var.key}: root disk above 80 % (images, match logs, container logs)"
  namespace           = var.cw_namespace
  metric_name         = "disk_used_percent"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name } # box/cloudwatch-agent.json.tmpl aggregates on it
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# matchd's own host sampler (matchd 0.5.4+, /metrics on the loopback monitor), scraped by the CloudWatch agent with the
# static label region_key (box/prometheus.yaml.tmpl). NO data for 15 min = matchd is not answering /metrics (down, or a
# drain/deploy that took that long): breaching.
resource "aws_cloudwatch_metric_alarm" "matchd_up" {
  alarm_name          = "${local.name}-matchd-silent"
  alarm_description   = "Game ${var.key}: no matchd /metrics sample for 15 minutes (matchd down, or a long drain)"
  namespace           = var.cw_namespace
  metric_name         = "matchd_box_cpu_busy_percent"
  dimensions          = { region_key = var.key, window = "5m" }
  statistic           = "SampleCount"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "steal" {
  alarm_name          = "${local.name}-steal-high"
  alarm_description   = "Game ${var.key}: CPU steal above 10 % (5-min window) for 15 minutes: the host is starving the box (credits / noisy neighbour)"
  namespace           = var.cw_namespace
  metric_name         = "matchd_box_steal_percent"
  dimensions          = { region_key = var.key, window = "5m" }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
