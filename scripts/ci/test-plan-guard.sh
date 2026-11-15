#!/usr/bin/env bash
# Runs plan-guard.sh (with jq, in the pinned alpine/k8s image) on every fixture. No AWS, no Terraform.
cd "$(dirname "$0")/../.."
IMG=alpine/k8s:1.31.13
bad=0
t() {  # t <fixture name> <expected exit> <warning expected: yes|no>
  out="$(docker run --rm -v "$PWD":/ws:ro -w /ws --entrypoint sh "$IMG" scripts/ci/plan-guard.sh "scripts/ci/fixtures/$1.json" 2>&1)"; rc=$?
  if echo "$out" | grep -q WARNING; then w=yes; else w=no; fi
  if [ "$rc" = "$2" ] && [ "$w" = "$3" ]; then echo "   ok    $1  exit=$rc warning=$w"
  else echo "   FAIL  $1  exit=$rc warning=$w (wanted $2 / $3)"; bad=1; fi
}
t plan-create-only 0 no
t plan-update-rds 0 no
t plan-delete-unprotected 0 no
t plan-no-changes 0 no
t plan-replace-rds 3 yes
t plan-replace-rds-cbd 3 yes
t plan-delete-vpc 3 yes
t plan-replace-eks 3 yes
t plan-delete-state-bucket 3 yes
t plan-delete-other-bucket 3 yes
t plan-invalid 1 no
[ $bad -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $bad
