#!/usr/bin/env bash
# Plan (and optionally apply the saved plan) for one stack. Run by buildspec.yml in CodeBuild; also usable on a
# box with credentials: TF_STACK=network TF_ACTION=plan tools/tf-run.sh
set -euo pipefail

die() { echo "tf-run: $*" >&2; exit 2; }

case "${TF_ACTION:-}" in
  plan | apply) ;;
  *) die "TF_ACTION must be plan or apply (got '${TF_ACTION:-}')" ;;
esac
[[ "${TF_STACK:-}" =~ ^[a-z0-9-]+$ ]] || die "TF_STACK must be a stack directory name (got '${TF_STACK:-}')"

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/envs/prod2/$TF_STACK"
[ -f "$dir/versions.tf" ] || die "no stack at envs/prod2/$TF_STACK"

echo "== stack $TF_STACK, action $TF_ACTION, commit ${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"

terraform -chdir="$dir" init -input=false -lockfile=readonly

set +e
terraform -chdir="$dir" plan -input=false -lock-timeout=5m -detailed-exitcode -out=tfplan
plan_ec=$?
set -e
case "$plan_ec" in
  0) changes=no ;;
  2) changes=yes ;;
  *) echo "tf-run: plan FAILED (exit $plan_ec)" >&2; exit "$plan_ec" ;;
esac

terraform -chdir="$dir" show -json tfplan > "$dir/tfplan.json"
summary() {
  jq -r "[.resource_changes[]? | select(.change.actions | $1)] | length" "$dir/tfplan.json"
}
creates=$(summary 'index("create") and (index("delete") | not)')
updates=$(summary '. == ["update"]')
replaces=$(summary 'index("create") and index("delete")')
deletes=$(summary '. == ["delete"]')

echo "== plan summary: $creates to create, $updates to update, $replaces to replace, $deletes to delete"
jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
       | "   \(.change.actions | join("+"))  \(.address)"' "$dir/tfplan.json"
rm -f "$dir/tfplan.json"

if [ "$TF_ACTION" = plan ]; then
  echo "== plan only (changes: $changes)"
  exit 0
fi

if [ "$changes" = no ]; then
  echo "== no changes; nothing to apply"
  exit 0
fi

# README rule: anything that deletes needs the operator's approval — the orchestrator passes ALLOW_DESTROY=yes
# only after that approval.
if [ $((replaces + deletes)) -gt 0 ] && [ "${ALLOW_DESTROY:-}" != yes ]; then
  echo "tf-run: the plan deletes/replaces $((replaces + deletes)) resource(s); refusing to apply without ALLOW_DESTROY=yes" >&2
  exit 3
fi

terraform -chdir="$dir" apply -input=false -lock-timeout=5m tfplan
echo "== applied; outputs:"
terraform -chdir="$dir" output -no-color
