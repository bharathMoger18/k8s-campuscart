#!/bin/sh
# Annotates ONLY the Deployments this build changed, right after "rollout status" succeeded.
#   sh scripts/ci/annotate-release.sh NAMESPACE
#   env: WEB_REV_BEFORE, NGINX_REV_BEFORE (recorded before the deploy), BUILD_NUMBER, BUILD_URL, GIT_SHA, WEB_TAG, NGINX_TAG
# Order matters: a new revision copies the change-cause that is on the Deployment at that moment, so annotating AFTER the
# rollout labels the new revision (proven on kubeadm). Annotating the Deployment does not start a rollout.
# Never fails the build: any problem prints a WARNING and the script still exits 0.
set -u
ns="${1:?namespace}"
here="$(dirname "$0")"
tags="backend:${WEB_TAG:-?} nginx:${NGINX_TAG:-?}"
cause="build #${BUILD_NUMBER:-?} | git ${GIT_SHA:-unknown} | ${BUILD_URL:-no-url} | $tags"

annotate_one() {  # annotate_one <deployment> <revision before the deploy>
  dep="$1"; before="$2"
  now="$(sh "$here/rollback.sh" revision "$ns" "$dep")"
  if [ -z "$now" ]; then echo "annotate: $dep not found, skipping"; return 0; fi
  if [ "$now" = "$before" ]; then echo "annotate: $dep still on revision $before (this build did not change it), skipping"; return 0; fi
  if kubectl -n "$ns" annotate "deployment/$dep" --overwrite \
       "kubernetes.io/change-cause=$cause" "campuscart.io/git-sha=${GIT_SHA:-unknown}" \
       "campuscart.io/build-url=${BUILD_URL:-}" "campuscart.io/build-number=${BUILD_NUMBER:-?}" \
       "campuscart.io/image-tags=$tags" >/dev/null; then
    echo "annotate: $dep revision $now labelled: $cause"
  else
    echo "annotate: WARNING could not annotate $dep (the deploy itself is fine)"
  fi
}
annotate_one campuscart-backend "${WEB_REV_BEFORE:-}"
annotate_one campuscart-nginx "${NGINX_REV_BEFORE:-}"
exit 0
