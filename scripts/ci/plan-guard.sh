#!/bin/sh
# Reads a "terraform show -json" plan and warns loudly when a PROTECTED resource would be deleted or replaced.
#   sh scripts/ci/plan-guard.sh <plan.json>        (needs jq)
# Exit: 0 = nothing protected is deleted or replaced, 3 = DANGER (Jenkins asks for a second confirmation),
#       1 = the plan could not be read. Protected: aws_db_instance, aws_vpc, aws_eks_cluster, aws_s3_bucket,
#       and anything whose address contains terraform_state (the state bucket).
# A replace shows up as actions ["delete","create"] or ["create","delete"], so "contains delete" covers both.
set -eu
f="${1:?usage: plan-guard.sh <plan.json>}"
[ -f "$f" ] || { echo "plan-guard: $f not found" >&2; exit 1; }
hits="$(jq -r '
  def protected: (.type | IN("aws_db_instance","aws_vpc","aws_eks_cluster","aws_s3_bucket")) or (.address | test("terraform_state"));
  (.resource_changes // [])[]
  | select(.mode == "managed" and protected and (.change.actions | contains(["delete"])))
  | "  \(if (.change.actions | length) > 1 then "REPLACE" else "DELETE " end)  \(.address)"
' "$f")" || { echo "plan-guard: jq could not read $f" >&2; exit 1; }
if [ -n "$hits" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "WARNING: this plan DELETES or REPLACES protected infrastructure:"
  echo "$hits"
  echo "Data loss is possible (database, network, cluster or state bucket)."
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "PLAN_GUARD=danger"
  exit 3
fi
echo "plan-guard: no delete or replace of protected resources"
echo "PLAN_GUARD=safe"
