#!/bin/sh
# Posts a build result to the webhook. Never fails the build: every problem exits 0 with a warning.
#   env: HOOK (from the notify-webhook credential), RESULT, JOB_NAME, BRANCH, AUTHOR, BUILD_NUMBER, BUILD_URL,
#        DURATION, RUN_AWS, WEB_TAG, NGINX_TAG, EXTRA (optional text, e.g. a manual rollback command)
# The JSON is built by jq, so quotes, backslashes and emoji in names are escaped correctly. HOOK is never printed.
set -u
if [ -z "${HOOK:-}" ]; then echo "notify: no webhook configured, skipping"; exit 0; fi
payload="$(mktemp)"; trap 'rm -f "$payload"' EXIT
if ! jq -n \
  --arg result "${RESULT:-UNKNOWN}" --arg job "${JOB_NAME:-unknown}" --arg branch "${BRANCH:-unknown}" \
  --arg author "${AUTHOR:-unknown}" --arg num "${BUILD_NUMBER:-?}" --arg url "${BUILD_URL:-}" \
  --arg duration "${DURATION:-unknown}" --arg runaws "${RUN_AWS:-unknown}" \
  --arg web "${WEB_TAG:-?}" --arg nginx "${NGINX_TAG:-?}" --arg extra "${EXTRA:-}" '
  {text: ("CampusCart " + $job + " #" + $num + " " + $result
          + "\nbranch: " + $branch + " | author: " + $author + " | duration: " + $duration
          + "\nRUN_AWS=" + $runaws + " | backend:" + $web + " nginx:" + $nginx
          + "\n" + $url + (if $extra != "" then "\n" + $extra else "" end)),
   details: {result: $result, job: $job, build: $num, branch: $branch, author: $author, url: $url,
             duration: $duration, run_aws: $runaws, backend_tag: $web, nginx_tag: $nginx}}' > "$payload"; then
  echo "notify: WARNING could not build the payload, skipping"; exit 0
fi
# curl's own error text is not printed: it could contain the webhook URL.
if curl -sS --max-time 15 -X POST -H 'Content-Type: application/json' --data @"$payload" "$HOOK" >/dev/null 2>&1; then
  echo "notify: sent (${RESULT:-UNKNOWN})"
else
  echo "notify: WARNING webhook post failed, build result is unaffected"
fi
exit 0
