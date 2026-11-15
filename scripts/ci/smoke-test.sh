#!/bin/sh
# HTTP smoke test with a bounded total time. Plain HTTP (the ALB has no HTTPS yet). Never prints secrets.
#   sh scripts/ci/smoke-test.sh <base-url> [total-seconds] [pause-seconds]
# Checks: /healthz = 200 | /api/v1/readyz = 200 and body has "status" and "ok" | /api/v1/products/ = 200 and body has "results".
# Retries each check until it passes or the TOTAL deadline is reached. Redirects are NOT followed: a 301/302 is a failure.
# Exit: 0 all passed, 1 a check failed (the build must fail and roll back), 2 usage.
set -u
base="${1:?usage: smoke-test.sh <base-url> [total-seconds] [pause-seconds]}"
total="${2:-300}"; pause="${3:-5}"
base="${base%/}"
end=$(( $(date +%s) + total ))
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
fail=0

check() {  # check <name> <path> <body must contain, space separated, may be empty>
  name="$1"; path="$2"; needs="$3"; code=000; tries=0
  while :; do
    tries=$((tries + 1))
    code="$(curl -s --max-time 10 -o "$body" -w '%{http_code}' "$base$path" 2>/dev/null)" || code=000
    ok=0
    if [ "$code" = 200 ]; then
      ok=1
      for w in $needs; do grep -q "$w" "$body" || ok=0; done
    fi
    if [ "$ok" = 1 ]; then echo "smoke: PASS $name  HTTP $code after $tries attempt(s)"; return 0; fi
    if [ "$(date +%s)" -ge "$end" ]; then break; fi
    sleep "$pause"
  done
  echo "smoke: FAIL $name  last HTTP $code after $tries attempt(s), total time limit ${total}s reached"
  [ "$code" = 301 ] || [ "$code" = 302 ] && echo "smoke: hint: this is a redirect; the ALB is HTTP only, so Django must not force HTTPS"
  return 1
}

check healthz /healthz "" || fail=1
check readyz /api/v1/readyz '"status" "ok"' || fail=1
check products /api/v1/products/ '"results"' || fail=1
[ "$fail" -eq 0 ] && echo "smoke: ALL PASSED" || echo "smoke: FAILED"
exit "$fail"
