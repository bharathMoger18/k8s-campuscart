#!/bin/sh
# Plan ONE Terraform directory with -detailed-exitcode and write tfplan, tfplan.txt and tfplan.json inside it.
#   sh scripts/ci/tf-plan.sh <terraform-dir>
# Exit: 0 = no changes, 2 = changes, 1 = error. Jenkins must call it with returnStatus and branch on the code
# (a plain sh step would fail on 2). tfplan.json can hold secret values: use it for plan-guard, never print or stash it.
set -eu
dir="${1:?usage: tf-plan.sh <terraform-dir>}"
rc=0
terraform -chdir="$dir" plan -detailed-exitcode -lock-timeout=5m -input=false -no-color -out=tfplan || rc=$?
case "$rc" in
  0|2) ;;
  *) echo "tf-plan: terraform plan failed (exit $rc)" >&2; exit 1 ;;
esac
terraform -chdir="$dir" show -no-color tfplan > "$dir/tfplan.txt"
terraform -chdir="$dir" show -json tfplan > "$dir/tfplan.json"
if [ "$rc" -eq 0 ]; then echo "tf-plan: exit 0, no changes"; else echo "tf-plan: exit 2, changes to apply"; fi
exit "$rc"
