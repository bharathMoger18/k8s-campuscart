# CampusCart image supply chain

Scope: how images are built, scanned, pushed and (later) signed for the EKS pipeline (`Jenkinsfile.aws`).
Sections 1, 2 and 7 describe what Phase 5 implemented. Sections 3 to 6 are proposals only: nothing in them is implemented.

## 1. Flow (implemented)

1. **Build Images (Kaniko, no push)** runs on every branch. It writes one tarball per image plus its sha256. No registry, no credentials.
2. **Trivy Gate** runs on every branch. It checks the sha256, downloads the vulnerability DB (retried), prints a non-blocking report of ALL HIGH/CRITICAL findings, then blocks on HIGH/CRITICAL that have a fix.
3. **Push Images (crane)** runs only when `RUN_AWS` is true and the branch is main. It pushes the SAME tarballs the gate scanned. Before the push it re-checks the sha256. After the push it compares the registry digest with the digest of the tarball.
4. **Check ECR** runs earlier on main with `RUN_AWS`. An image tag that already exists is skipped. Only `ImageNotFoundException` means "missing"; any other describe-images error fails the stage.

Guarantee: the bytes in ECR are the bytes that were scanned. Not verified against real ECR yet (see section 8).

## 2. Immutable ECR tags

`terraform/modules/ecr/main.tf` sets `image_tag_mutability = "IMMUTABLE"` and `scan_on_push = true` on every repository (read from the code, not checked in AWS).

- A tag can be pushed once. A second push to the same tag is rejected, so a tag can never silently change under a running Deployment.
- Tags are git short hashes: backend = last commit touching `campuscart-backend`, nginx = last commit touching `nginx`, `frontend` or `.dockerignore`.
- Consequence: rebuilding the same commit to pick up a newer Debian patch cannot be pushed under the same tag. A commit that touches the image folder is needed first.
- ECR's own scan-on-push is separate and happens AFTER the push. The Trivy Gate is what stops a bad image BEFORE the push.

## 3. ECR lifecycle policy (proposal, not applied)

Today: one rule per repository, `tagStatus any`, `imageCountMoreThan 10`, expire the rest.

Risks to rollback targets:
- Rollback (`kubectl rollout undo`) and any pod rescheduled from an old ReplicaSet need the old image to still exist. After an image is expired, the pull fails (ImagePullBackOff).
- Kubernetes keeps 10 revisions by default (`revisionHistoryLimit`). The cluster can offer a revision whose image ECR already deleted.
- If signatures or SBOM attestations (sections 4 and 5) are stored in the same repository, they will probably count toward the limit of 10 and shrink the real window. Verify in a real repository before relying on this.
- Nothing protects the image that is currently deployed.

Proposed rules (needs a Terraform change, which belongs to the Terraform phase):
1. Priority 1: `tagStatus untagged`, `sinceImagePushed` 7 days, expire. Untagged layers are clutter.
2. Priority 2: `tagStatus any`, `imageCountMoreThan` 30, expire. A `tagStatus any` rule must have the highest priority number (it runs last).
3. Optional: when a deploy succeeds, add a second tag such as `deployed-<sha>` and add a rule that keeps tags with that prefix for longer.
Cost: 30 images is a few GB per repository. Check current ECR pricing. Use ECR's lifecycle policy preview before applying, so you see what would be deleted.

## 4. SBOM with syft (proposal)

- What: a list of every package inside an image (Debian packages and pip packages), in CycloneDX or SPDX JSON.
- Why: when a new CVE appears, you can search the SBOMs to find which images contain the package, without rescanning every image. It is also what customers and auditors ask for.
- How: run syft on the same tarball the gate scanned (a `docker-archive:` input is expected to work for these Kaniko tarballs; try it first). Pin syft by exact tag or digest, looked up, not guessed.
- Where to store: (a) `archiveArtifacts` on the Jenkins build for a start; (b) later, attach it to the image in ECR as an attestation (see cosign), or keep it in a versioned S3 bucket keyed by image digest. The digest is the key, not the tag.
- Note: Trivy can also write CycloneDX, so one tool could do both jobs. Decide before adding a second tool to the pipeline.

## 5. Image signing with cosign (proposal)

- Sign the image DIGEST, never the tag.
- Keyless (Sigstore, short-lived certificate tied to an OIDC identity, entry in the public Rekor log): no key to protect. Weak fit here because Jenkins on a kubeadm cluster has no ready-made OIDC identity that Sigstore trusts, so a token issuer would be extra work. Good fit if the pipeline later moves to GitHub Actions.
- Key-based: a key pair in a Jenkins credential, or better an AWS KMS key (cosign supports `awskms://`) so the private key never leaves AWS. Cost: a KMS key and IAM permissions for the signing stage. Ties into the credentials design phase.
- Verification matters more than signing: a signature nobody checks protects nothing. Verify at admission on EKS with a policy engine (Kyverno `verifyImages` or sigstore policy-controller) so unsigned images are refused. ECR does not verify signatures itself.
- AWS also has its own signing service (AWS Signer with Notation). It was not evaluated here.

## 6. Base image pinning (finding, needs a backend change)

`campuscart-backend/Dockerfile` uses `FROM python:3.12-slim` (a floating tag) in both stages and runs `apt-get upgrade -y`. The same commit builds a different image on different days, so a scan or a rollback target is not reproducible. Three backend builds from the same commit had three different tarball sizes.
Proposal: pin to an exact tag plus digest (`python:3.12.16-slim@sha256:<digest>`, digest looked up when the change is made), and let a bot or a deliberate commit bump it. Changing the Dockerfile changes the backend image tag and forces a rebuild, so it needs a decision first.

## 7. Trivy gate rules

- Blocking gate: HIGH and CRITICAL, `--ignore-unfixed`. Findings with no available fix cannot be acted on, so they do not block.
- Non-blocking report: the same severities WITHOUT `--ignore-unfixed`, printed on every run, so nothing is hidden.
- Measured on Phase 5 images: backend 107 HIGH and 0 CRITICAL, all unfixed Debian 13.7 OS packages (nothing in the Python packages); nginx (Alpine 3.24.4) 0. 56 of the 107 are krb5 libraries pulled in by `libpq5`, which psycopg2 needs, so trimming the image would not remove them.
- `.trivyignore`: every entry needs `# reason`, `# owner` and `# expires` comment lines above it, and `exp:YYYY-MM-DD` on the ID line so Trivy itself stops honouring it after that date. Review the unfixed list on a schedule, because new fixes turn report-only findings into blocking ones.
- Negative control (done locally): an old `alpine:3.12.0` tarball fails the gate with 36 findings; ignoring those IDs with a future expiry passes, and the same IDs with a past expiry fail again.

## 8. Not proven locally

- Stash size and speed for a 111 MB tarball through Jenkins.
- Kaniko `--tar-path` and build time inside a cluster pod (local builds took 4.5 to 48 minutes).
- `crane auth login` against ECR with an `aws ecr get-login-password` token, and the push to a real immutable repository.
- `retry(2)` on the DB download under a real network failure.
