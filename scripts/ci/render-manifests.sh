#!/bin/sh
# Renders k8s-aws/*.yaml into ./rendered with envsubst.
#   sh scripts/ci/render-manifests.sh           real values must already be in the environment
#   sh scripts/ci/render-manifests.sh --dummy   safe fake values, no Terraform or AWS needed
set -eu

SRC_DIR="${SRC_DIR:-k8s-aws}"
OUT_DIR="${OUT_DIR:-rendered}"

if [ "${1:-}" = "--dummy" ]; then
  : "${RDS_ENDPOINT:=dummy-db.abc123xyz.ap-south-1.rds.amazonaws.com:5432}"
  : "${REDIS_ENDPOINT:=dummy-redis.abc123.0001.aps1.cache.amazonaws.com}"
  : "${ECR_BACKEND_IMAGE:=000000000000.dkr.ecr.ap-south-1.amazonaws.com/campuscart-backend}"
  : "${ECR_NGINX_IMAGE:=000000000000.dkr.ecr.ap-south-1.amazonaws.com/campuscart-nginx}"
  : "${WEB_TAG:=a1b2c3d}"
  : "${NGINX_TAG:=e4f5a6b}"
fi

for v in RDS_ENDPOINT REDIS_ENDPOINT ECR_BACKEND_IMAGE ECR_NGINX_IMAGE WEB_TAG NGINX_TAG; do
  eval "val=\${$v:-}"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo "render-manifests: $v is empty or null" >&2
    exit 1
  fi
done

# RDS returns host:port, but the app has a separate DB_PORT and entrypoint.sh runs: nc -z "$DB_HOST" "$DB_PORT"
RDS_ENDPOINT="${RDS_ENDPOINT%%:*}"
export RDS_ENDPOINT REDIS_ENDPOINT ECR_BACKEND_IMAGE ECR_NGINX_IMAGE WEB_TAG NGINX_TAG

VARS='${RDS_ENDPOINT} ${REDIS_ENDPOINT} ${ECR_BACKEND_IMAGE} ${ECR_NGINX_IMAGE} ${IMAGE_TAG} ${WEB_TAG} ${NGINX_TAG}'

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

for f in "$SRC_DIR"/*.yaml; do
  name=$(basename "$f")
  case "$name" in
    nginx-deployment.yaml) tag="$NGINX_TAG" ;;
    *)                      tag="$WEB_TAG" ;;
  esac
  IMAGE_TAG="$tag" envsubst "$VARS" < "$f" > "$OUT_DIR/$name"
done

# Any ${PLACEHOLDER} left on a non-comment line means a variable was never filled in.
left=$(grep -nE '^[^#]*\$\{[A-Za-z_]+\}' "$OUT_DIR"/*.yaml || true)
if [ -n "$left" ]; then
  echo "render-manifests: unreplaced placeholders:" >&2
  echo "$left" >&2
  exit 1
fi
echo "rendered $(ls "$OUT_DIR" | wc -l) files into $OUT_DIR"
