#!/usr/bin/env bash
# Rehearses notify.sh (local listener, jq validation) and annotate-release.sh (fake kubectl). No AWS, no cluster.
cd "$(dirname "$0")/../.."
IMG=alpine/k8s:1.31.13
PORT=5057
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bad=0
check() { if [ "$2" = "$3" ]; then echo "   ok    $1"; else echo "   FAIL  $1 (got '$2', wanted '$3')"; bad=1; fi; }
indocker() { docker run --rm --network host -v "$PWD":/ws:ro -v "$W":/w -w /ws -e HOOK -e AUTHOR -e RESULT --entrypoint sh "$IMG" -c "$1"; }

cat > "$W/listener.py" <<'PY'
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open(out, "wb").write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H); s.timeout = 30; s.handle_request()
PY
export AUTHOR='Zoe "Quote" back\slash 🚀' RESULT=SUCCESS
echo "== 1 notify: author with quotes, backslash and emoji reaches a listener as valid JSON"
python3 "$W/listener.py" "$W/got.json" $PORT & lp=$!; sleep 1
export HOOK="http://127.0.0.1:$PORT/secret-token-abc"
out="$(indocker 'JOB_NAME=campuscart BRANCH=main BUILD_NUMBER=7 BUILD_URL=http://j/7 DURATION="1 min" RUN_AWS=true WEB_TAG=abc1234 NGINX_TAG=def5678 sh scripts/ci/notify.sh')"; rc=$?
wait $lp
echo "   | $out"
check "exit code" "$rc" 0
check "jq validates the payload" "$(docker run --rm -v "$W":/w:ro --entrypoint jq "$IMG" -e . /w/got.json >/dev/null 2>&1 && echo valid)" valid
check "author survives exactly" "$(docker run --rm -v "$W":/w:ro --entrypoint jq "$IMG" -r .details.author /w/got.json)" "$AUTHOR"
check "webhook token not printed" "$(echo "$out" | grep -c secret-token-abc)" 0
docker run --rm -v "$W":/w:ro --entrypoint jq "$IMG" -r .text /w/got.json | sed 's/^/   | /'
echo "== 2 notify: unreachable webhook must still exit 0"
HOOK=http://127.0.0.1:1/x; out="$(indocker 'sh scripts/ci/notify.sh')"; check "exit code" "$?" 0; echo "   | $out"
echo "== 3 notify: empty webhook must exit 0"
HOOK=""; out="$(indocker 'sh scripts/ci/notify.sh')"; check "exit code" "$?" 0; echo "   | $out"

echo "== 4 annotate: only the Deployment whose revision moved is annotated"
mkdir -p "$W/bin"
cat > "$W/bin/kubectl" <<'K'
#!/bin/sh
case "$1" in
  get) case "$2" in deployment/campuscart-backend) printf '%s' "$REV_BACKEND";; deployment/campuscart-nginx) printf '%s' "$REV_NGINX";; esac ;;
  -n) echo "$*" >> "$LOG"; exit "${ANN_RC:-0}" ;;
esac
K
chmod +x "$W/bin/kubectl"
run() { PATH="$W/bin:$PATH" LOG="$W/ann.log" BUILD_NUMBER=7 BUILD_URL=http://j/7 GIT_SHA=abc1234 WEB_TAG=abc1234 NGINX_TAG=def5678 "$@"; }
: > "$W/ann.log"
out="$(run env REV_BACKEND=4 REV_NGINX=2 WEB_REV_BEFORE=3 NGINX_REV_BEFORE=2 sh scripts/ci/annotate-release.sh campuscart)"; rc=$?
echo "$out" | sed 's/^/   | /'
check "exit code" "$rc" 0
check "backend annotated once" "$(grep -c 'deployment/campuscart-backend' "$W/ann.log")" 1
check "nginx not annotated" "$(grep -c 'deployment/campuscart-nginx' "$W/ann.log")" 0
echo "== 5 annotate: first deploy (no revision before) is annotated"
: > "$W/ann.log"; run env REV_BACKEND=1 REV_NGINX=1 WEB_REV_BEFORE= NGINX_REV_BEFORE= sh scripts/ci/annotate-release.sh campuscart >/dev/null
check "both annotated" "$(wc -l < "$W/ann.log" | tr -d ' ')" 2
echo "== 6 annotate: a failing annotate must still exit 0"
run env REV_BACKEND=4 REV_NGINX=2 WEB_REV_BEFORE=3 NGINX_REV_BEFORE=2 ANN_RC=1 sh scripts/ci/annotate-release.sh campuscart | sed 's/^/   | /'
run env REV_BACKEND=4 REV_NGINX=2 WEB_REV_BEFORE=3 NGINX_REV_BEFORE=2 ANN_RC=1 sh scripts/ci/annotate-release.sh campuscart >/dev/null; check "exit code" "$?" 0
[ $bad -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $bad
