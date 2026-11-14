#!/bin/sh
# Helpers for the Deploy stage and for post { failure }.
#   sh scripts/ci/rollback.sh revision NAMESPACE DEPLOYMENT
#       prints the Deployment's current revision (empty if it does not exist yet)
#   sh scripts/ci/rollback.sh undo NAMESPACE DEPLOYMENT:REVISION_BEFORE [DEPLOYMENT:REVISION_BEFORE ...]
#       restores REVISION_BEFORE, but only for Deployments this build actually changed
set -u

revision_of() {
  kubectl get "deployment/$2" -n "$1" \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
  revision)
    revision_of "${1:?namespace}" "${2:?deployment}"
    ;;
  undo)
    ns="${1:?namespace}"; shift
    rc=0
    for pair in "$@"; do
      dep="${pair%%:*}"
      before="${pair#*:}"
      [ "$pair" = "$dep" ] && before=""
      now=$(revision_of "$ns" "$dep")
      if [ -z "$before" ]; then
        echo "== $dep: no earlier revision was recorded (first deploy?), nothing to restore"; continue
      fi
      if [ -z "$now" ]; then
        echo "== $dep: deployment not found, nothing to restore"; continue
      fi
      if [ "$now" = "$before" ]; then
        echo "== $dep: still on revision $before, this build did not change it, leaving it alone"; continue
      fi
      echo "== $dep: revision $now is the failed one; restoring revision $before"
      if ! kubectl rollout undo "deployment/$dep" -n "$ns" --to-revision="$before"; then
        echo "== $dep: rollout undo FAILED"; rc=1; continue
      fi
      if ! kubectl rollout status "deployment/$dep" -n "$ns" --timeout=300s; then
        echo "== $dep: restored revision did not become ready"; rc=1; continue
      fi
      echo "== $dep: restored. Now on revision $(revision_of "$ns" "$dep") (same pod template as old revision $before)"
      kubectl rollout history "deployment/$dep" -n "$ns" | tail -4
    done
    exit "$rc"
    ;;
  *)
    echo "usage: rollback.sh revision NS DEP | undo NS DEP:REV [DEP:REV ...]" >&2
    exit 2
    ;;
esac
