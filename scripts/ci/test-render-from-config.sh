#!/usr/bin/env bash
# Rehearses render-from-config.sh in the pinned alpine/k8s image with dummy config files. No AWS.
cd "$(dirname "$0")/../.."
IMG=alpine/k8s:1.31.13
REG=000000000000.dkr.ecr.ap-south-1.amazonaws.com
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bad=0
printf 'RDS_ENDPOINT=mydb.abc123.ap-south-1.rds.amazonaws.com:5432\nREDIS_ENDPOINT=myredis.abc123.cache.amazonaws.com\n' > "$W/good.env"
printf 'RDS_ENDPOINT=REPLACE_ME\nREDIS_ENDPOINT=myredis.abc123.cache.amazonaws.com\n' > "$W/placeholder.env"
printf 'RDS_ENDPOINT=mydb.abc123.ap-south-1.rds.amazonaws.com:5432\n' > "$W/missing.env"
run() {  # run <config path inside container> <registry>
  docker run --rm -v "$PWD":/ws:ro -v "$W":/cfg:ro -w /ws -e CONFIG_FILE="$1" -e ECR_REGISTRY="$2" \
    -e WEB_TAG=a1b2c3d -e NGINX_TAG=e4f5a6b -e OUT_DIR=/tmp/rendered --entrypoint sh "$IMG" \
    -c 'sh scripts/ci/render-from-config.sh && grep -n "DB_HOST" -A1 /tmp/rendered/configmap.yaml && grep -h "image:" /tmp/rendered/backend-deployment.yaml' 2>&1
}
check() { if [ "$2" = "$3" ]; then echo "   ok    $1"; else echo "   FAIL  $1 (got '$2', wanted '$3')"; bad=1; fi; }

echo "== 1 good config: renders, ':5432' stripped, ECR image built from the account id"
out="$(run /cfg/good.env "$REG")"; rc=$?; echo "$out" | sed 's/^/   | /'
check "exit code" "$rc" 0
echo "$out" | grep -q 'rds.amazonaws.com:5432' && { echo "   FAIL  ':5432' still present"; bad=1; } || echo "   ok    no ':5432' in the rendered output"
echo "$out" | grep -Eq "image: \"?$REG/campuscart-backend:a1b2c3d" && echo "   ok    backend image URL" || { echo "   FAIL  backend image URL"; bad=1; }
echo "== 2 placeholder value must fail";   run /cfg/placeholder.env "$REG" >/dev/null 2>&1; check "exit non-zero" "$([ $? -ne 0 ] && echo y)" y
echo "== 3 missing REDIS_ENDPOINT must fail"; run /cfg/missing.env "$REG" >/dev/null 2>&1; check "exit non-zero" "$([ $? -ne 0 ] && echo y)" y
echo "== 4 bad registry must fail";        run /cfg/good.env "not-a-registry" >/dev/null 2>&1; check "exit non-zero" "$([ $? -ne 0 ] && echo y)" y
echo "== 5 empty registry must fail";      run /cfg/good.env "" >/dev/null 2>&1; check "exit non-zero" "$([ $? -ne 0 ] && echo y)" y
echo "== 6 the committed config/aws-production.env still holds placeholders, so it must fail"
run /ws/config/aws-production.env "$REG" >/dev/null 2>&1; check "exit non-zero" "$([ $? -ne 0 ] && echo y)" y
[ $bad -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $bad
