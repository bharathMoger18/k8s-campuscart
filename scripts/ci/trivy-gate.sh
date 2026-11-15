#!/bin/sh
# Trivy on image tarballs. Runs INSIDE the aquasec/trivy container (it has sh and cat), repo as the current directory.
#   sh scripts/ci/trivy-gate.sh db                    download the vulnerability DB (Jenkins wraps this in retry(2))
#   sh scripts/ci/trivy-gate.sh gate <tar> [<tar>..]  BLOCKING: HIGH and CRITICAL that have a fix; honours .trivyignore
#   sh scripts/ci/trivy-gate.sh report <tar> [..]     NEVER fails: HIGH and CRITICAL including unfixed, nothing ignored
# Never calls AWS and needs no registry credentials.
set -eu
CACHE="${TRIVY_CACHE_DIR:-/tmp/trivy-cache}"
IGNORE="${TRIVY_IGNOREFILE:-.trivyignore}"
mode="${1:-}"; [ $# -gt 0 ] && shift

case "$mode" in
  db)
    trivy image --cache-dir "$CACHE" --download-db-only --no-progress ;;
  gate)
    [ $# -gt 0 ] || { echo "gate: no tarball given" >&2; exit 2; }
    rc=0
    for t in "$@"; do
      [ -f "$t" ] || { echo "gate: $t not found" >&2; exit 2; }
      echo "== TRIVY GATE: $t"
      trivy image --cache-dir "$CACHE" --skip-db-update --no-progress --input "$t" --scanners vuln \
        --severity HIGH,CRITICAL --ignore-unfixed --ignorefile "$IGNORE" --exit-code 1 --format table || rc=1
    done
    [ $rc -eq 0 ] && echo "TRIVY GATE: PASS" || echo "TRIVY GATE: FAIL (fixable HIGH/CRITICAL found)"
    exit $rc ;;
  report)
    [ $# -gt 0 ] || { echo "report: no tarball given" >&2; exit 2; }
    for t in "$@"; do
      echo "== TRIVY REPORT (non-blocking, includes unfixed): $t"
      trivy image --cache-dir "$CACHE" --skip-db-update --no-progress --input "$t" --scanners vuln \
        --severity HIGH,CRITICAL --exit-code 0 --format table || true
    done ;;
  *)
    echo "usage: trivy-gate.sh db | gate <tar>... | report <tar>..." >&2; exit 2 ;;
esac
