# After the deploy: smoke test, release annotations, notifications

All of this lives in `Jenkinsfile.aws` (end of "Deploy to EKS", the "Smoke Test" stage, the `post` block) and three scripts in `scripts/ci/`.

## Smoke test (`smoke-test.sh`)
- Runs only with RUN_AWS on main. It waits up to 10 minutes for the ALB hostname (`kubectl get ingress campuscart-ingress`), then calls the ALB over plain HTTP.
- Checks: `/healthz` (answered by nginx) = 200; `/api/v1/readyz` = 200 and the body has "status" and "ok" (it reaches Django and the DB); `/api/v1/products/` = 200 and the body has "results" (anonymous GET is allowed by `IsAuthenticatedOrReadOnly`; an empty list is a pass).
- Each check retries until it passes or the shared total limit (300 s) is reached. Redirects are not followed: a 301/302 is a failure with a hint (the ALB is HTTP only).
- A failure fails the build. `post { failure }` then runs `rollback.sh undo` because `env.ROLLBACK_ARMED` and the recorded revisions are `env.*` values set in the Deploy stage (UNVERIFIED until a real run).
- Nothing secret is printed.

## Release annotations (`annotate-release.sh`)
- Runs right after `rollout status`. Only Deployments whose revision moved during this build are annotated: `kubernetes.io/change-cause` = `build #N | git <sha> | <url> | backend:<tag> nginx:<tag>`, plus `campuscart.io/git-sha`, `build-url`, `build-number`, `image-tags`.
- Proven on kubeadm: `kubectl rollout history` shows the change-cause after annotating, and annotating does NOT start a rollout.
- Order matters: a new revision copies the change-cause that is on the Deployment at that moment, so annotate AFTER the rollout (annotating before stamps the old revision).
- `rollout undo` creates a new revision whose change-cause comes from the current annotation (the failed build's text). Not tested: UNVERIFIED.
- It never fails the build.

## Notifications (`notify.sh`)
- Sent on SUCCESS, FAILURE, ABORTED and UNSTABLE: job, branch, commit author, build URL, result, duration, RUN_AWS, image tags.
- The JSON is built with `jq -n --arg`, so quotes, backslashes and emoji in names are safe. The webhook comes from the `notify-webhook` credential and is never printed. A notification failure never fails the build.
- Author and sha are captured in Checkout (`git log -1 --format=%an`, falls back to "unknown").

## Aborted builds
- A timeout or manual abort skips `post { failure }`. An `aborted` block now notifies and prints the manual rollback commands with the recorded revisions.
- Decision A: it does NOT roll back by itself. An abort is a human choice, and database migrations are never rolled back, so an automatic code rollback could leave code and schema mismatched.

## Not proven
Real ALB and `/healthz` through it, real Django plain-HTTP behaviour, `ROLLBACK_ARMED` surviving into `post`, the aborted block after a timeout kill, `currentBuild.durationString`, rollback change-cause behaviour.
