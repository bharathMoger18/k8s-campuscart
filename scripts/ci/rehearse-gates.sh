#!/usr/bin/env bash
# Runs each gate from scripts/ci/gate.sh in the same pinned image Jenkins will use, against a clean copy of the
# tracked files (what a Jenkins checkout contains). No AWS. Nothing is written to your repo or your .terraform.
# Usage: scripts/ci/rehearse-gates.sh [group ...]
#   groups: gitleaks ruff hadolint kubeconform terraform tflint checkov negative   (default: all)
set -uo pipefail
cd "$(dirname "$0")/../.."
BASE=/tmp/rehearsal
UIDGID="$(id -u):$(id -g)"

TOOLS_IMG=alpine/k8s:1.31.13
GITLEAKS_IMG=zricethezav/gitleaks:v8.30.1
PYTHON_IMG=python:3.12.16-slim
HADOLINT_IMG=hadolint/hadolint:v2.15.1-alpine
KUBECONFORM_IMG=ghcr.io/yannh/kubeconform:v0.8.0-alpine
TERRAFORM_IMG=hashicorp/terraform:1.10.5
TFLINT_IMG=ghcr.io/terraform-linters/tflint:v0.66.0
CHECKOV_IMG=bridgecrew/checkov:3.4.5

declare -A RESULT
fresh() {  # fresh copy of the tracked files, like a Jenkins checkout
  W="$BASE/$1"; rm -rf "$W"; mkdir -p "$W"
  git ls-files -z | tar --null -T - -cf - | tar -C "$W" -xf -
}
step() {   # step <workdir> <image> "<gate> [gate ...]"   (runs as you, so nothing root-owned is left behind)
  docker run --rm --user "$UIDGID" -e HOME=/tmp/home -e TF_IN_AUTOMATION=1 \
    -v "$1":/ws -w /ws --entrypoint sh "$2" \
    -c "mkdir -p /tmp/home; for g in $3; do echo \"== gate: \$g\"; sh scripts/ci/gate.sh \$g || exit 1; done"
}

group_gitleaks()    { fresh gitleaks;    step "$W" "$GITLEAKS_IMG" gitleaks; }
group_ruff()        { fresh ruff;        step "$W" "$PYTHON_IMG" "ruff-install ruff"; }
group_hadolint()    { fresh hadolint;    step "$W" "$HADOLINT_IMG" hadolint; }
group_kubeconform() { fresh kubeconform; step "$W" "$TOOLS_IMG" render && step "$W" "$KUBECONFORM_IMG" kubeconform; }
group_terraform()   { fresh terraform;   step "$W" "$TERRAFORM_IMG" "terraform-fmt terraform-init terraform-validate"; }
group_tflint()      { fresh tflint;      step "$W" "$TFLINT_IMG" tflint; }
group_checkov()     { fresh checkov;     step "$W" "$TOOLS_IMG" render && step "$W" "$CHECKOV_IMG" checkov; }

group_negative() {  # every control must make its gate FAIL, otherwise the gate proves nothing
  local rc bad=0
  fresh neg-ruff; printf 'print(undefined_name)\n' > "$W/campuscart-backend/zz_negative.py"
  step "$W" "$PYTHON_IMG" "ruff-install ruff" >/dev/null 2>&1; rc=$?
  echo "   ruff, file with an undefined name:   exit $rc (expect non-zero)"; [ $rc -ne 0 ] || bad=1

  fresh neg-gitleaks; printf 'STRIPE_SECRET_KEY=sk_live_%s\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)" > "$W/zz_negative.env"
  step "$W" "$GITLEAKS_IMG" gitleaks >/dev/null 2>&1; rc=$?
  echo "   gitleaks, a new fake live key:       exit $rc (expect non-zero)"; [ $rc -ne 0 ] || bad=1

  fresh neg-kubeconform; git show main:k8s-aws/ingress.yaml > "$W/k8s-aws/ingress.yaml"
  step "$W" "$TOOLS_IMG" render >/dev/null 2>&1
  step "$W" "$KUBECONFORM_IMG" kubeconform >/dev/null 2>&1; rc=$?
  echo "   kubeconform, the old broken ingress: exit $rc (expect non-zero)"; [ $rc -ne 0 ] || bad=1

  fresh neg-terraform; printf 'this is not valid terraform {\n' > "$W/terraform/modules/ecr/zz_negative.tf"
  step "$W" "$TERRAFORM_IMG" "terraform-fmt terraform-init terraform-validate" >/dev/null 2>&1; rc=$?
  echo "   terraform, a syntax error:           exit $rc (expect non-zero)"; [ $rc -ne 0 ] || bad=1
  return $bad
}

GROUPS_TO_RUN=("$@")
[ ${#GROUPS_TO_RUN[@]} -gt 0 ] || GROUPS_TO_RUN=(gitleaks ruff hadolint kubeconform terraform tflint checkov negative)
for g in "${GROUPS_TO_RUN[@]}"; do
  echo; echo "################ $g"
  declare -F "group_$g" >/dev/null || { echo "unknown group: $g"; exit 2; }
  "group_$g"; rc=$?
  if [ $rc -eq 0 ]; then RESULT[$g]="PASS"; else RESULT[$g]="FAIL (exit $rc)"; fi
  [ "$g" = checkov ] && [ $rc -eq 0 ] && RESULT[$g]="SOFT (findings printed, not blocking)"
  [ "$g" = negative ] && [ $rc -eq 0 ] && RESULT[$g]="PASS (every control was blocked)"
done

echo; echo "================ REHEARSAL SUMMARY ================"
for g in "${GROUPS_TO_RUN[@]}"; do printf '%-12s %s\n' "$g" "${RESULT[$g]}"; done
