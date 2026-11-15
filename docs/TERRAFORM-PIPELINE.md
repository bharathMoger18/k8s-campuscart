# Terraform pipeline (Jenkinsfile.terraform)

Terraform plan, approval and apply live in `Jenkinsfile.terraform`. The app pipeline (`Jenkinsfile.aws`) never plans, applies or reads Terraform outputs and holds no Terraform wiring. Its Quality Gates still run `terraform fmt`/`validate` and `tflint` with `-backend=false` and no credentials (Phase 4 gates).

## Jenkins job setup
- Create a SEPARATE Jenkins job for `Jenkinsfile.terraform` (script path `Jenkinsfile.terraform`).
- Trigger it by hand only: no GitHub webhook, no SCM polling, no "build when a change is pushed". On a multibranch job, use the branch property that suppresses automatic SCM triggering (exact name depends on your Jenkins version: UNVERIFIED).
- Safety net: a build started by anything other than a person gets `RUN_AWS=false` (the default), so it only runs fmt, `init -backend=false` and validate.
- Edit `APPROVERS` (default placeholder `devops-approvers`) at the top of the file.

## What a run does
1. RUN_AWS=false (any branch): `terraform fmt -check`, `init -backend=false`, `validate` through `scripts/ci/gate.sh`. Nothing else.
2. RUN_AWS=true on main: plan with `-detailed-exitcode -lock-timeout=5m` (`scripts/ci/tf-plan.sh`).
   - exit 0: no changes, approval and apply are skipped.
   - exit 2: changes. `scripts/ci/plan-guard.sh` scans the plan. A delete or replace of aws_db_instance, aws_vpc, aws_eks_cluster, aws_s3_bucket or the state bucket prints a loud WARNING and needs a second confirmation (type DESTROY-OK).
   - exit 1: error, the build fails.
3. Approval by `APPROVERS`, then `apply` of the SAVED plan with `-lock-timeout=5m`. Apply is never retried; only `terraform init` has `retry(2)`.
4. `tfplan.json` can contain secret values, so it is deleted after the guard and never stashed or printed.

## How the app pipeline gets its endpoints (option b)
- `config/aws-production.env` holds `RDS_ENDPOINT` and `REDIS_ENDPOINT` (non-secret hostnames). After an apply, paste the new values and commit.
- It ships with `REPLACE_*` placeholders on purpose. Until you fill them in, the Render Manifests stage of `Jenkinsfile.aws` fails with a clear message (RUN_AWS=true only).
- ECR URLs are built from the AWS account id (Prepare AWS Context) + region + repo names, so they need no config.
- `scripts/ci/render-from-config.sh` refuses placeholders, missing keys and a malformed registry. `render-manifests.sh` still strips ":5432".
- Risk: the file can go stale after a Terraform change. Later upgrade (needs a Terraform change, not done here): write the endpoints to SSM Parameter Store and read them in the app pipeline.

## Known limits
- Both pipelines still use the credential `aws-campuscart-ci`. A Terraform-only credential belongs to the credentials-design phase.
- Nothing here has run against real AWS or Jenkins.
- `production-addons` is selectable, but its provider settings were not reviewed here and it may need cluster access.
