#!/usr/bin/env bash
# Proves, with real docker runs, that each CI image contains the tools its stage needs,
# and that Jenkinsfile.aws pins every image to an exact version. Never calls AWS.
# Usage: scripts/ci/check-tools.sh [tools|pins|all]
set -uo pipefail

MODE="${1:-all}"
JENKINSFILE="${JENKINSFILE:-Jenkinsfile.aws}"
fail=0

# name | image | shell | tools the stage needs (a leading / means "file must be executable") | version command
CHECKS=(
  "checkout-git|alpine/git:v2.54.0|sh|git|git --version"
  "checkout-aws|amazon/aws-cli:2.17.0|sh|aws|aws --version"
  "test-python|python:3.12.16-slim|sh|python pip apt-get|python --version"
  "test-postgres|postgres:15.20-alpine|sh|pg_isready postgres|postgres --version"
  "test-redis|redis:7.4.12-alpine|sh|redis-server|redis-server --version"
  "terraform|hashicorp/terraform:1.10.5|sh|terraform|terraform version"
  "render-templating|alpine/k8s:1.31.13|sh|envsubst jq|envsubst --version"
  "deploy|alpine/k8s:1.31.13|sh|aws kubectl envsubst jq curl git|kubectl version --client"
  "deploy-aws|alpine/k8s:1.31.13|sh|aws|aws --version"
  "build-kaniko|gcr.io/kaniko-project/executor:v1.24.0-debug|/busybox/sh|/kaniko/executor|/kaniko/executor version"
  "notify|alpine/k8s:1.31.13|sh|curl|curl --version"
)

check_tools() {
  local row name image shell tools vercmd tool probe
  for row in "${CHECKS[@]}"; do
    IFS='|' read -r name image shell tools vercmd <<<"$row"
    echo "== ${name}: ${image}"
    if ! docker pull -q "$image" >/dev/null 2>&1; then
      echo "   FAIL     cannot pull image (tag missing or no network)"; fail=1; continue
    fi
    for tool in $tools; do
      if [[ "$tool" == /* ]]; then probe="test -x $tool"; else probe="command -v $tool"; fi
      if docker run --rm --entrypoint "$shell" "$image" -c "$probe" >/dev/null 2>&1; then
        echo "   ok       $tool"
      else
        echo "   MISSING  $tool"; fail=1
      fi
    done
    if [[ -n "${vercmd:-}" ]]; then
      echo "   version: $(docker run --rm --entrypoint "$shell" "$image" -c "$vercmd" 2>&1 | head -1)"
    fi
  done
}

check_pins() {
  echo "== pin check: ${JENKINSFILE}"
  local n img tag
  while read -r n img; do
    case "$img" in
      *@sha256:*) echo "   ok    line $n  $img (digest-pinned)"; continue ;;
    esac
    tag="${img##*/}"
    if [[ "$tag" != *:* ]]; then
      echo "   BAD   line $n  $img  (no tag means :latest)"; fail=1; continue
    fi
    tag="${tag#*:}"
    if [[ "$tag" == latest || "$tag" == debug ]] || ! [[ "$tag" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
      echo "   BAD   line $n  $img  (not an exact x.y.z version)"; fail=1
    else
      echo "   ok    line $n  $img"
    fi
  done < <(awk '/^[[:space:]]*image:[[:space:]]/ {v=$2; gsub(/["\047]/,"",v); print NR, v}' "$JENKINSFILE")
}

case "$MODE" in
  tools) check_tools ;;
  pins)  check_pins ;;
  all)   check_tools; check_pins ;;
  *) echo "usage: $0 [tools|pins|all]"; exit 2 ;;
esac

[[ $fail -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $fail
