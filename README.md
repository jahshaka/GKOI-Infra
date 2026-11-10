# GKOI-Infra — the AWS infrastructure for GKOI prod 2, as code

Terraform for account 127214190346 (PLAN-AWS-MIGRATION-PROD2-V1 in GKOIBuilder_AI `docs/specs/`).

- **Regions:** us-west-2 (home: control plane), eu-central-1, us-east-1; ap-northeast-1 paused until its quota is approved.
- **Rule (operator 2026-11-10):** the full infrastructure is built properly (ALB, NAT, endpoints, RDS, Valkey, EFS, CloudFront,
  Secrets Manager/KMS, CloudWatch, CI); only SERVER COUNTS stay minimal — every ECS service and ASG min 1 / max 1 until raised.
- **No secrets in this repo.** Values live in Secrets Manager; Terraform state lives in an encrypted, versioned S3 bucket with a
  lock, never in git.
- **CI:** GitHub Actions via the account's GitHub OIDC provider (no stored AWS keys): a pull request shows the plan; a merge to
  `main` applies it (anything that deletes needs the operator's approval).
- **IAM:** every role and policy this repo creates lives under the path `/gkoi/`.

Layout (filled in P1): `bootstrap/` (state bucket + lock), `modules/` (network, edge, data, compute, observability),
`envs/prod2/` (the regions).
