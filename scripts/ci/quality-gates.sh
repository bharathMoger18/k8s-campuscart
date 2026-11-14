#!/usr/bin/env bash
# Runs every quality gate locally in pinned docker images. Never calls AWS:
# terraform runs with -backend=false on a throwaway copy (no state, no tfvars, no .terraform).
# Usage: scripts/ci/quality-gates.sh [gate ...]
#   gates: preflight gitleaks ruff hadolint kubeconform terraform tflint checkov   (default: all)
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
OUT="${OUT:-/tmp/qg}"
mkdir -p "$OUT"
UIDGID="$(id -u):$(id -g)"

GITLEAKS_IMG=zricethezav/gitleaks:v8.30.1
HADOLINT_IMG=hadolint/hadolint:v2.15.1
KUBECONFORM_IMG=ghcr.io/yannh/kubeconform:v0.8.0
TERRAFORM_IMG=hashicorp/terraform:1.10.5
TFLINT_IMG=ghcr.io/terraform-linters/tflint:v0.66.0
CHECKOV_IMG=bridgecrew/checkov:3.4.5
PYTHON_IMG=python:3.12.16-slim
RUFF_VERSION=0.17.5
K8S_VERSION=1.31.0

declare -A RESULT
record() { RESULT["$1"]="$2"; echo "   => $1: $2"; }

# clean copy of terraform/: no .terraform, no state, no tfvars, no plans
copy_tf() {
  rm -rf "$1"; mkdir -p "$1"
  tar -C "$ROOT" --exclude='.terraform' --exclude='*.tfstate' --exclude='*.tfstate.*' \
      --exclude='*.tfvars' --exclude='*.tfplan' -cf - terraform | tar -C "$1" -xf -
}

gate_preflight() {
  echo "== preflight: can each image be pulled, and does it have a shell with cat? (Jenkins needs both)"
  local img
  for img in "$GITLEAKS_IMG" "$HADOLINT_IMG" "$KUBECONFORM_IMG" "$TERRAFORM_IMG" "$TFLINT_IMG" "$CHECKOV_IMG" "$PYTHON_IMG"; do
    if ! docker pull -q "$img" >/dev/null 2>&1; then echo "   MISSING     $img (cannot pull)"; continue; fi
    if docker run --rm --entrypoint sh "$img" -c 'command -v cat' >/dev/null 2>&1; then
      echo "   ok+shell    $img"
    else
      echo "   ok,no shell $img"
    fi
  done
  echo "-- variants with a shell, for Jenkins"
  for img in hadolint/hadolint:v2.15.1-alpine hadolint/hadolint:v2.15.1-debian ghcr.io/yannh/kubeconform:v0.8.0-alpine; do
    if docker manifest inspect "$img" >/dev/null 2>&1; then echo "   exists      $img"; else echo "   MISSING     $img"; fi
  done
}

gate_gitleaks() {
  echo "== gitleaks: secrets in git history (values redacted)"
  docker run --rm --user "$UIDGID" -v "$ROOT":/repo:ro \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
    "$GITLEAKS_IMG" git --no-banner --redact --verbose /repo >"$OUT/gitleaks.txt" 2>&1
  local rc=$?
  tail -20 "$OUT/gitleaks.txt"
  if [ $rc -eq 0 ]; then record gitleaks PASS; else record gitleaks "FAIL (exit $rc)"; fi
}

gate_ruff() {
  echo "== ruff $RUFF_VERSION: default rules (syntax errors, pyflakes)"
  docker run --rm -v "$ROOT":/w:ro -w /w "$PYTHON_IMG" sh -c "
    pip install -q --no-cache-dir --disable-pip-version-check --root-user-action=ignore ruff==$RUFF_VERSION
    ruff check --output-format concise --no-cache campuscart-backend; rc=\$?
    echo '-- findings by rule:'; ruff check --statistics --no-cache campuscart-backend | head -15
    exit \$rc" >"$OUT/ruff.txt" 2>&1
  local rc=$?
  tail -25 "$OUT/ruff.txt"
  if [ $rc -eq 0 ]; then record ruff PASS; else record ruff "FAIL (exit $rc)"; fi
}

gate_hadolint() {
  echo "== hadolint: both Dockerfiles"
  local rc=0 f
  : >"$OUT/hadolint.txt"
  for f in campuscart-backend/Dockerfile nginx/Dockerfile; do
    echo "--- $f" | tee -a "$OUT/hadolint.txt"
    docker run --rm -i --entrypoint /bin/hadolint "$HADOLINT_IMG" --no-color - <"$f" 2>&1 | tee -a "$OUT/hadolint.txt"
    [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
  done
  if [ $rc -eq 0 ]; then record hadolint PASS; else record hadolint "FAIL"; fi
}

gate_kubeconform() {
  echo "== kubeconform: rendered manifests against Kubernetes $K8S_VERSION schemas"
  if ! sh scripts/ci/render-manifests.sh --dummy >/dev/null; then record kubeconform "FAIL (render)"; return; fi
  docker run --rm -v "$ROOT/rendered":/m:ro "$KUBECONFORM_IMG" \
    -kubernetes-version "$K8S_VERSION" -strict -ignore-missing-schemas -summary -output json /m \
    >"$OUT/kubeconform.json" 2>"$OUT/kubeconform.err"
  local rc=$?
  jq -c '.summary' "$OUT/kubeconform.json" 2>/dev/null || cat "$OUT/kubeconform.err"
  echo "-- skipped (no schema for these kinds, usually CRDs):"
  jq -r '.resources[]? | select(.status=="statusSkipped") | "   SKIPPED \(.kind) \(.name)"' "$OUT/kubeconform.json" 2>/dev/null
  echo "-- invalid:"
  jq -r '.resources[]? | select(.status=="statusInvalid" or .status=="statusError") | "   INVALID \(.filename): \(.kind) \(.name): \(.msg)"' "$OUT/kubeconform.json" 2>/dev/null
  echo "-- negative control: the OLD ingress from main must be rejected"
  git show main:k8s-aws/ingress.yaml | docker run --rm -i "$KUBECONFORM_IMG" \
    -kubernetes-version "$K8S_VERSION" -strict -ignore-missing-schemas -summary - 2>&1 | tail -4
  if [ $rc -eq 0 ]; then record kubeconform PASS; else record kubeconform "FAIL (exit $rc)"; fi
}

gate_terraform() {
  echo "== terraform: fmt -check, init -backend=false, validate (throwaway copy, no state, no AWS)"
  local W="$OUT/tfwork" rc=0 d n
  copy_tf "$W"
  if docker run --rm --user "$UIDGID" -e HOME=/tmp -v "$W":/w -w /w/terraform "$TERRAFORM_IMG" \
       fmt -check -recursive -diff >"$OUT/tf-fmt.txt" 2>&1; then
    echo "   fmt: ok"
  else
    echo "   fmt: FAIL (files below are not formatted)"; head -40 "$OUT/tf-fmt.txt"; rc=1
  fi
  for d in bootstrap environments/production environments/production-addons; do
    n="$(basename "$d")"
    echo "--- $d"
    if docker run --rm --user "$UIDGID" -e HOME=/tmp -e TF_IN_AUTOMATION=1 -v "$W":/w -w "/w/terraform/$d" \
         "$TERRAFORM_IMG" init -backend=false -input=false -no-color >"$OUT/tf-init-$n.txt" 2>&1; then
      if docker run --rm --user "$UIDGID" -e HOME=/tmp -v "$W":/w -w "/w/terraform/$d" \
           "$TERRAFORM_IMG" validate -no-color >"$OUT/tf-validate-$n.txt" 2>&1; then
        echo "   validate: ok"
      else
        echo "   validate: FAIL"; head -30 "$OUT/tf-validate-$n.txt"; rc=1
      fi
    else
      echo "   init: FAIL"; tail -15 "$OUT/tf-init-$n.txt"; rc=1
    fi
  done
  if [ $rc -eq 0 ]; then record terraform PASS; else record terraform "FAIL"; fi
}

gate_tflint() {
  echo "== tflint: core Terraform rules only (no cloud plugin yet)"
  local W="$OUT/tflintwork"
  copy_tf "$W"
  docker run --rm --user "$UIDGID" -e HOME=/tmp -v "$W":/w -w /w/terraform "$TFLINT_IMG" \
    --recursive --format compact >"$OUT/tflint.txt" 2>&1
  local rc=$?
  tail -30 "$OUT/tflint.txt"
  if [ $rc -eq 0 ]; then record tflint PASS; else record tflint "FAIL (exit $rc)"; fi
}

gate_checkov() {
  echo "== checkov: soft-fail, findings are shown but nothing blocks yet"
  local S="$OUT/scan"
  rm -rf "$S"; mkdir -p "$S/docker/backend" "$S/docker/nginx"
  copy_tf "$S/tf"
  sh scripts/ci/render-manifests.sh --dummy >/dev/null && cp -r rendered "$S/rendered"
  cp campuscart-backend/Dockerfile "$S/docker/backend/Dockerfile"
  cp nginx/Dockerfile "$S/docker/nginx/Dockerfile"
  docker run --rm -e HOME=/tmp -v "$S":/scan:ro "$CHECKOV_IMG" \
    -d /scan --framework terraform dockerfile kubernetes --compact --quiet --soft-fail >"$OUT/checkov.txt" 2>&1
  grep -E 'scan results:|Passed checks:' "$OUT/checkov.txt"
  echo "-- failed checks, grouped (count  check):"
  awk '/^Check: /{c=$0} /FAILED for resource/{print c}' "$OUT/checkov.txt" | sort | uniq -c | sort -rn | head -60
  if ! grep -q 'FAILED for resource' "$OUT/checkov.txt"; then echo "-- (no FAILED lines parsed; raw tail:)"; tail -25 "$OUT/checkov.txt"; fi
  record checkov "SOFT (full report: $OUT/checkov.txt)"
}

GATES=("$@")
[ ${#GATES[@]} -gt 0 ] || GATES=(preflight gitleaks ruff hadolint kubeconform terraform tflint checkov)
for g in "${GATES[@]}"; do
  if declare -F "gate_$g" >/dev/null; then "gate_$g"; else echo "unknown gate: $g"; exit 2; fi
done

echo; echo "================ SUMMARY ================"
bad=0
for g in "${GATES[@]}"; do
  [ "$g" = preflight ] && continue
  r="${RESULT[$g]:-not run}"
  printf '%-12s %s\n' "$g" "$r"
  case "$r" in FAIL*) bad=1 ;; esac
done
exit $bad
