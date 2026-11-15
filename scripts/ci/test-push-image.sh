#!/usr/bin/env bash
# Rehearses scripts/ci/push-image.sh in the pinned crane image against a throwaway local registry. No AWS.
# Needs a Kaniko-built tarball:  TEST_TAR=/path/to/image.tar scripts/ci/test-push-image.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
CRANE=gcr.io/go-containerregistry/crane@sha256:e78770b31258a3846f878036d9c1f63fbe4c871f9f56990bf77fd95c013e3c1b
REGISTRY=registry:2.8.3
TAR="${TEST_TAR:-/tmp/p5-out/nginx.tar}"
PORT=5056
NAME=p5-test-registry
[ -f "$TAR" ] || { echo "TEST_TAR $TAR not found"; exit 2; }

W="$(mktemp -d)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
cp "$TAR" "$W/image.tar"
( cd "$W" && sha256sum image.tar > SUMS )
cp "$W/image.tar" "$W/bad.tar"; printf 'x' >> "$W/bad.tar"
# SUMS claims bad.tar has the GOOD hash, so bad.tar must be refused
printf '%s  bad.tar\n' "$(cut -d' ' -f1 "$W/SUMS")" >> "$W/SUMS"

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --rm --name "$NAME" -p 127.0.0.1:$PORT:5000 "$REGISTRY" >/dev/null || exit 1
sleep 2

push() {  # push <tarball in $W> <repo:tag> [<sums file in $W>]
  local args=("/w/$1" "localhost:$PORT/$2")
  [ -n "${3:-}" ] && args+=("/w/$3")
  docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$PWD":/repo:ro -v "$W":/w:ro -w /repo --entrypoint /busybox/sh "$CRANE" \
    scripts/ci/push-image.sh "${args[@]}"
}
bad=0
check() { if [ "$2" = "$3" ]; then echo "   ok    $1"; else echo "   FAIL  $1 (got '$2', wanted '$3')"; bad=1; fi; }
show() { echo "$1" | grep -E 'OK|digest|PUSHED|refusing|mismatch|not found|FAILED' | sed 's/^/   | /'; }

echo "== 1 good tarball, matching checksum"
out="$(push image.tar test-good:t SUMS 2>&1)"; rc=$?; show "$out"; check "exit code" "$rc" 0
echo "== 2 tarball that no longer matches its checksum must NOT be pushed"
out="$(push bad.tar test-bad:t SUMS 2>&1)"; rc=$?; show "$out"; check "exit code" "$rc" 1
echo "== 3 missing tarball"
out="$(push nope.tar test-nope:t SUMS 2>&1)"; rc=$?; show "$out"; check "exit code" "$rc" 2
echo "== 4 what the registry holds"
repos="$(curl -s "http://127.0.0.1:$PORT/v2/_catalog")"
echo "   catalog: $repos"
check "only test-good was pushed" "$repos" '{"repositories":["test-good"]}'
[ $bad -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $bad
