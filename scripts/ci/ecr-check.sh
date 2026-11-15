#!/bin/sh
# Is image tag <tag> already in ECR repository <repo>?  Prints "true" or "false" on stdout.
# ONLY an ImageNotFoundException means "false". Any other failure (network, credentials,
# access denied, wrong repository) exits non-zero with the real aws message, so a broken
# check can never be mistaken for "image missing".
#   Jenkins:  sh scripts/ci/ecr-check.sh check <repo> <tag>      (needs AWS_REGION)
#   Tests:    sh scripts/ci/test-ecr-check.sh                    (fake stderr, never calls AWS)
set -eu

classify() {  # classify <aws-exit-code> <file-with-aws-stderr>
  rc="$1"; errfile="$2"
  if [ "$rc" -eq 0 ]; then echo true; return 0; fi
  if grep -q 'ImageNotFoundException' "$errfile"; then echo false; return 0; fi
  echo "ECR check FAILED (aws exit $rc). This is NOT 'image missing'; fix the cause and rerun:" >&2
  if [ -s "$errfile" ]; then sed 's/^/  aws: /' "$errfile" >&2; else echo "  aws: (no error text)" >&2; fi
  return 1
}

case "${1:-}" in
  classify)
    classify "${2:?exit code}" "${3:?stderr file}" ;;
  check)
    repo="${2:?repository}"; tag="${3:?tag}"
    err="$(mktemp)"; trap 'rm -f "$err"' EXIT
    rc=0
    aws ecr describe-images --region "${AWS_REGION:?AWS_REGION not set}" \
      --repository-name "$repo" --image-ids "imageTag=$tag" >/dev/null 2>"$err" || rc=$?
    classify "$rc" "$err" ;;
  *)
    echo "usage: ecr-check.sh check <repo> <tag> | classify <exit-code> <stderr-file>" >&2; exit 2 ;;
esac
