#!/bin/sh
# Renders k8s-aws using the NON-SECRET endpoints from a committed file, then calls render-manifests.sh unchanged
# (which still strips ":5432" from the RDS endpoint).
#   sh scripts/ci/render-from-config.sh
# Needs in the environment: ECR_REGISTRY (set by Prepare AWS Context), WEB_TAG, NGINX_TAG.
# CONFIG_FILE defaults to config/aws-production.env (keys RDS_ENDPOINT and REDIS_ENDPOINT). Never calls AWS.
set -eu
CONFIG_FILE="${CONFIG_FILE:-config/aws-production.env}"
[ -f "$CONFIG_FILE" ] || { echo "render-from-config: $CONFIG_FILE not found" >&2; exit 1; }
: "${ECR_REGISTRY:?render-from-config: ECR_REGISTRY is not set (Prepare AWS Context sets it)}"
printf '%s' "$ECR_REGISTRY" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$' || {
  echo "render-from-config: ECR_REGISTRY does not look like <account>.dkr.ecr.<region>.amazonaws.com" >&2; exit 1; }

get() { sed -n "s/^$1=//p" "$CONFIG_FILE" | head -n 1 | tr -d ' \r'; }
check() {  # check <name> <value>
  case "$2" in
    ""|null|REPLACE*) echo "render-from-config: $1 is missing or still a placeholder in $CONFIG_FILE" >&2; exit 1 ;;
  esac
  case "$2" in
    *[!A-Za-z0-9.:-]*) echo "render-from-config: $1 contains unexpected characters" >&2; exit 1 ;;
  esac
}
RDS_ENDPOINT="$(get RDS_ENDPOINT)";     check RDS_ENDPOINT "$RDS_ENDPOINT"
REDIS_ENDPOINT="$(get REDIS_ENDPOINT)"; check REDIS_ENDPOINT "$REDIS_ENDPOINT"
ECR_BACKEND_IMAGE="$ECR_REGISTRY/campuscart-backend"
ECR_NGINX_IMAGE="$ECR_REGISTRY/campuscart-nginx"
export RDS_ENDPOINT REDIS_ENDPOINT ECR_BACKEND_IMAGE ECR_NGINX_IMAGE
echo "render-from-config: endpoints read from $CONFIG_FILE, ECR URLs built from $ECR_REGISTRY"
exec sh scripts/ci/render-manifests.sh
