#!/bin/sh
# Build ONE image with Kaniko into a tarball (no registry, no credentials). Runs INSIDE the kaniko debug container
# (busybox sh) with the repo as the current directory.
#   sh scripts/ci/kaniko-build.sh <backend|nginx> <tag> <output-dir>
# Writes <output-dir>/<image>.tar and <output-dir>/<image>.tar.sha256, which the scan and push stages verify.
# Keep <output-dir> outside the build context when you can.
set -eu
what="${1:-}"; tag="${2:?tag}"; out="${3:?output dir}"
root="$(pwd)"
case "$what" in
  backend) context="$root/campuscart-backend"; dockerfile="$root/campuscart-backend/Dockerfile"; image="campuscart-backend" ;;
  nginx)   context="$root";                    dockerfile="$root/nginx/Dockerfile";               image="campuscart-nginx" ;;
  *) echo "usage: kaniko-build.sh <backend|nginx> <tag> <output-dir>" >&2; exit 2 ;;
esac
mkdir -p "$out"
/kaniko/executor \
  --context="dir://$context" \
  --dockerfile="$dockerfile" \
  --no-push \
  --tar-path="$out/$image.tar" \
  --destination="$image:$tag"
( cd "$out" && sha256sum "$image.tar" > "$image.tar.sha256" )
echo "BUILT $out/$image.tar  $(cat "$out/$image.tar.sha256")"
