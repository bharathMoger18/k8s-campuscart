#!/bin/sh
# Waits for a Kubernetes Job and fails FAST if it fails (kubectl wait only knows "complete").
#   sh scripts/ci/wait-for-job.sh NAMESPACE JOB [TIMEOUT_SECONDS]
set -u
NS="${1:?namespace}"; JOB="${2:?job}"; TIMEOUT="${3:-300}"

dump() {
  kubectl get pods -n "$NS" -l "job-name=$JOB" -o wide || true
  kubectl describe "job/$JOB" -n "$NS" | tail -25 || true
  kubectl logs "job/$JOB" -n "$NS" --tail=100 || true
}

end=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$end" ]; do
  ok=$(kubectl get "job/$JOB" -n "$NS" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
  bad=$(kubectl get "job/$JOB" -n "$NS" -o jsonpath='{.status.failed}' 2>/dev/null || true)
  if [ "${ok:-0}" -ge 1 ]; then echo "job/$JOB completed"; exit 0; fi
  if [ "${bad:-0}" -ge 1 ]; then echo "job/$JOB FAILED"; dump; exit 1; fi
  sleep 5
done
echo "job/$JOB did not finish within ${TIMEOUT}s"
dump
exit 1
