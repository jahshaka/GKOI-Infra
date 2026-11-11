# One region's GKOI media box (PLAN-AWS-MIGRATION-PROD2-V1 P5): an ASG of ONE EC2 instance (min/max from the stack),
# its Elastic IP (stable for DNS; the box associates it to itself at boot), two security groups (the public ingest +
# the private engine ports; the media origin's 443), an instance role under /gkoi/, the box's config in SSM, the
# rehearsal DNS records and a few alarms. What runs ON the box is envs/prod2/media/box/ (README there).
#
# Ports — the live Lightsail media box's (2026-11-11: `docker ps` + the Lightsail firewall), pool i = 0..pool_count-1:
#   public   tcp (i+1)1936  RTMPS ingest (MediaMTX terminates TLS)       11936, 21936
#            udp 8189+100·i WebRTC ICE (WHIP publish, WHEP preview)      8189, 8289
#            tcp 443        media origin (CloudFront → /r/<slug>/…)      SG `-origin`: CloudFront's prefix list
#   private  tcp (i+1)8888  LL-HLS, (i+1)8889 WHIP/WHEP signalling, (i+1)9997 control API — for the engine api/worker
#            (the api proxies watch/WHIP/WHEP and reads readiness at the pool's apiHost; DOCKER-USER on Lightsail
#            allowed only the control box — here the SG does it: the home ECS tasks only)
#   NOT open: plain RTMP (i+1)1935 (published by compose as on the live box, closed by its Lightsail firewall too),
#             22 (SSM only), 80.

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
  name  = "gkoi-prod2-media-${var.key}"
  pools = range(var.pool_count)

  public_tcp  = [for i in local.pools : (i + 1) * 10000 + 1936]
  public_udp  = [for i in local.pools : 8189 + 100 * i]
  private_tcp = flatten([for i in local.pools : [(i + 1) * 10000 + 8888, (i + 1) * 10000 + 8889, (i + 1) * 10000 + 9997]])

  tags = {
    Name         = local.name
    "gkoi-media" = var.key
    role         = "media"
  }
}

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# --- security groups ---------------------------------------------------------------------------------------------

resource "aws_security_group" "box" {
  name        = local.name
  description = "GKOI media box ${var.key}: public ingest (RTMPS, WebRTC ICE) + the engine's private pool ports"
  vpc_id      = var.vpc_id
  tags        = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "rtmps" {
  for_each          = toset([for p in local.public_tcp : tostring(p)])
  security_group_id = aws_security_group.box.id
  description       = "RTMPS ingest (pool ${floor(tonumber(each.value) / 10000) - 1})"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "ice" {
  for_each          = toset([for p in local.public_udp : tostring(p)])
  security_group_id = aws_security_group.box.id
  description       = "WebRTC ICE/UDP (pool ${floor((tonumber(each.value) - 8189) / 100)})"
  ip_protocol       = "udp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

# The engine api / worker → the pools' HLS, WHIP/WHEP signalling and control API (RELAY registration's apiHost).
resource "aws_vpc_security_group_ingress_rule" "engine_sg" {
  for_each                     = var.is_home ? toset([for p in local.private_tcp : tostring(p)]) : toset([])
  security_group_id            = aws_security_group.box.id
  description                  = "Engine ECS tasks → pool port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = var.ecs_tasks_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "engine_cidr" {
  for_each          = var.is_home ? toset([]) : toset([for p in local.private_tcp : tostring(p)])
  security_group_id = aws_security_group.box.id
  description       = "Engine (home VPC, peered) → pool port ${each.value}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = var.home_cidr
}

resource "aws_vpc_security_group_egress_rule" "box_all" {
  security_group_id = aws_security_group.box.id
  description       = "All egress (Valkey + the engine over peering, ECR, S3, Secrets Manager, SSM, Let's Encrypt, the platforms)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# The media origin's 443 in its own SG: CloudFront's origin-facing prefix list weighs ~55 rules on its own.
resource "aws_security_group" "origin" {
  name        = "${local.name}-origin"
  description = "GKOI media box ${var.key}: the regional live origin (443) for CloudFront live.gkoi.com"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.name}-origin" }
}

resource "aws_vpc_security_group_ingress_rule" "origin_cloudfront" {
  count             = var.origin_open_to_world ? 0 : 1
  security_group_id = aws_security_group.origin.id
  description       = "CloudFront origin-facing → media origin"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_ingress_rule" "origin_world" {
  count             = var.origin_open_to_world ? 1 : 0
  security_group_id = aws_security_group.origin.id
  description       = "Anyone → media origin (the X-Origin-Verify lock is the gate)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "origin_extra" {
  for_each          = var.origin_open_to_world ? toset([]) : toset(var.origin_ingress_cidrs)
  security_group_id = aws_security_group.origin.id
  description       = "Rehearsal tester → media origin"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# --- the Elastic IP (the box associates it to itself: phase eip of media-bootstrap.sh) ------------------------

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = local.name })
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
  statement {
    sid       = "RecordingsBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [for b in var.recordings_buckets : "arn:aws:s3:::${b}"]
  }
  statement {
    sid       = "RecordingsObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = [for b in var.recordings_buckets : "arn:aws:s3:::${b}/*"]
  }
  # Its own EIP onto itself — both resources carry the tag gkoi-media=<key> (the launch template tags the instance).
  statement {
    sid       = "OwnEip"
    actions   = ["ec2:AssociateAddress"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*", "arn:aws:ec2:${var.region}:${var.account_id}:elastic-ip/${aws_eip.this.allocation_id}"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/gkoi-media"
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
  # Let's Encrypt DNS-01 (certbot --dns-route53 with the instance role): TXT records _acme-challenge.<its names> only.
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
  name   = "media-box"
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
  name        = "/gkoi/prod2/media/${var.key}/config"
  description = "GKOI media box ${var.key}: the bootstrap's configuration (no secrets)"
  type        = "String"
  tier        = "Intelligent-Tiering"
  value = jsonencode(merge(var.config, {
    eip_allocation_id = aws_eip.this.allocation_id
    eip_public_ip     = aws_eip.this.public_ip
    asg_name          = local.name
    lifecycle_hook    = "drain"
  }))
}

# --- launch template + ASG ---------------------------------------------------------------------------------------

resource "aws_launch_template" "box" {
  name                   = local.name
  description            = "GKOI media box ${var.key} (Ubuntu 24.04, Docker, media-bootstrap.sh)"
  image_id               = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.instance_type
  update_default_version = true
  user_data              = base64encode(var.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.box.arn
  }

  # IMDSv2 only; hop limit 2 so the containers (the media agent's S3 client: the default credential chain) reach it.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true # until the bootstrap moves the EIP onto it (then the EIP is the public address)
    delete_on_termination       = true
    security_groups             = [aws_security_group.box.id, aws_security_group.origin.id]
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
  wait_for_capacity_timeout = "0" # an apply never waits on the bootstrap (it takes minutes; README "Bring one region up")
  enabled_metrics           = ["GroupInServiceInstances", "GroupDesiredCapacity", "GroupTerminatingInstances", "GroupPendingInstances"]

  launch_template {
    id      = aws_launch_template.box.id
    version = aws_launch_template.box.latest_version
  }

  # The drain on scale-in / replacement: box/lifecycle-watch.sh sees Terminating:Wait in IMDS, drains the box through the
  # agent, waits for idle (heartbeats) and completes with CONTINUE. Timeout default CONTINUE: a dead box never blocks.
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

  depends_on = [aws_ssm_parameter.config] # the box reads it at boot (and, through it, the uploaded bundle)

  # No instance_refresh block: ONE EIP per region means a new box would take the address from a live one. Replacing the
  # box is a window step (README "Replacing the box"); an image release never replaces it (box/roll.sh, in place).
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

# A LIVE name (stream.gkoi.com, origin-live-<slug>.gkoi.com …) taken over in the window: allow_overwrite adopts the
# existing record. prevent_destroy: turning manage_live_records off (or a destroy) must never DELETE a live name —
# the plan stops; roll the record back by hand, then `terraform state rm` it (README "Rollback").
resource "aws_route53_record" "live" {
  for_each        = toset(var.live_records)
  zone_id         = var.zone_id
  name            = each.value
  type            = "A"
  ttl             = 60
  records         = [aws_eip.this.public_ip]
  allow_overwrite = true
  lifecycle {
    prevent_destroy = true
  }
}

# --- alarms (the region's gkoi-ops-alerts) -------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "in_service" {
  alarm_name          = "${local.name}-not-in-service"
  alarm_description   = "Media ${var.key}: fewer in-service boxes than the ASG minimum for 10 minutes"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  ok_actions          = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${local.name}-cpu-high"
  alarm_description   = "Media ${var.key}: CPU above 75 % for 15 minutes (the per-box stream capacity is untested — plan §5.5)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 75
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  ok_actions          = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "status" {
  alarm_name          = "${local.name}-status-check"
  alarm_description   = "Media ${var.key}: EC2 status check failing for 5 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  ok_actions          = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "${local.name}-disk-high"
  alarm_description   = "Media ${var.key}: root disk above 80 % (recordings not uploaded yet, images, logs)"
  namespace           = "GKOI/Media"
  metric_name         = "disk_used_percent"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.box.name } # box/cloudwatch-agent.json.tmpl aggregates on it
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  ok_actions          = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
}
