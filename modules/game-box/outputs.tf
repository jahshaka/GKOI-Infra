output "asg_name" {
  value = aws_autoscaling_group.box.name
}

output "eip_public_ip" {
  value = aws_eip.this.public_ip
}

output "eip_allocation_id" {
  value = aws_eip.this.allocation_id
}

output "security_group_id" {
  value = aws_security_group.box.id
}

output "role_arn" {
  value = aws_iam_role.box.arn
}

output "config_parameter" {
  value = aws_ssm_parameter.config.name
}

output "launch_template_version" {
  value = aws_launch_template.box.latest_version
}

output "records" {
  value = concat([for r in aws_route53_record.rehearsal : r.fqdn], [for r in aws_route53_record.live : r.fqdn])
}
