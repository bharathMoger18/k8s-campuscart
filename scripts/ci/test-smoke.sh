#!/usr/bin/env bash
# Rehearses smoke-test.sh: docker nginx (the real EKS config) in front of a tiny python fake backend. No AWS, no cluster.
cd "$(dirname "$0")/../.."
IMG=alpine/k8s:1.31.13
NGX=nginx:1.27.5-alpine
W="$(mktemp -d)"; trap 'docker rm -f p7-nginx >/dev/null 2>&1; kill $BE 2>/dev/null; rm -rf "$W"' EXIT
bad=0
check() { if [ "$2" = "$3" ]; then echo "   ok    $1"; else echo "   FAIL  $1 (got '$2', wanted '$3')"; bad=1; fi; }

# the nginx config comes from the real ConfigMap, upstream pointed at the fake backend on the host
python3 - "$W" <<'PY'
import sys, re
t = open("k8s-aws/nginx-configmap.yaml").read()
conf = t.split("campuscart.conf: |\n", 1)[1]
conf = "\n".join(l[4:] if l.startswith("    ") else l for l in conf.splitlines())
conf = conf.replace("server campuscart-backend:8000", "server 127.0.0.1:18000")
conf = conf.replace("listen 8080;", "listen 18080;")
open(sys.argv[1] + "/campuscart.conf", "w").write(conf)
PY
cat > "$W/backend.py" <<'PY'
import http.server, sys, time, os
mode = os.environ.get("MODE", "ok")        # ok | flaky | dead
state = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        state["n"] += 1
        if mode == "dead" or (mode == "flaky" and state["n"] <= 3):
            self.send_response(503); self.end_headers(); self.wfile.write(b'{"status":"error"}'); return
        if self.path.startswith("/api/v1/readyz"): b = b'{"status":"ok"}'
        elif self.path.startswith("/api/v1/products"): b = b'{"count":0,"results":[]}'
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 18000), H).serve_forever()
PY
run() { docker run --rm --network host -v "$PWD":/ws:ro -w /ws --entrypoint sh "$IMG" -c "$1"; }
startbe() { [ -n "${BE:-}" ] && kill $BE 2>/dev/null; sleep 0.5; MODE=$1 python3 "$W/backend.py" & BE=$!; sleep 1; }
docker rm -f p7-nginx >/dev/null 2>&1
docker run -d --rm --name p7-nginx --network host -v "$W/campuscart.conf":/etc/nginx/conf.d/default.conf:ro $NGX >/dev/null || exit 1
sleep 2

echo "== 1 healthy: passes"
startbe ok; out="$(run 'sh scripts/ci/smoke-test.sh http://127.0.0.1:18080 30 1')"; rc=$?; echo "$out" | sed 's/^/   | /'; check "exit code" "$rc" 0
echo "== 2 first 3 backend calls return 503, then healthy: retry makes it pass"
startbe flaky; out="$(run 'sh scripts/ci/smoke-test.sh http://127.0.0.1:18080 60 1')"; rc=$?; echo "$out" | sed 's/^/   | /'; check "exit code" "$rc" 0
echo "$out" | grep -Eq 'PASS readyz .* after [2-9]' && echo "   ok    readyz needed more than one attempt" || { echo "   FAIL  retry not visible"; bad=1; }
echo "== 3 permanently unhealthy: fails with exit 1 within the time bound"
startbe dead; s=$(date +%s); out="$(run 'sh scripts/ci/smoke-test.sh http://127.0.0.1:18080 12 2')"; rc=$?; e=$(( $(date +%s) - s ))
echo "$out" | sed 's/^/   | /'; check "exit code" "$rc" 1; echo "   elapsed ${e}s (limit 12s per check, three checks share it)"
[ "$e" -le 45 ] && echo "   ok    finished in bounded time" || { echo "   FAIL  took too long"; bad=1; }
echo "== 4 nothing listening: fails cleanly"
out="$(run 'sh scripts/ci/smoke-test.sh http://127.0.0.1:9 4 1')"; rc=$?; echo "$out" | tail -2 | sed 's/^/   | /'; check "exit code" "$rc" 1
[ $bad -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $bad
