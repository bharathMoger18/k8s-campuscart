#!/bin/sh
# One entry point per quality gate. Runs INSIDE the tool container, with the repo as the current directory.
#   Jenkins:  sh scripts/ci/gate.sh <gate>
#   Local:    scripts/ci/rehearse-gates.sh   (same commands, same pinned images, on a clean copy of the repo)
# Never calls AWS: terraform runs with -backend=false and needs no credentials.
set -eu
export PATH="$HOME/.local/bin:$PATH"
RUFF_VERSION="${RUFF_VERSION:-0.17.5}"
K8S_VERSION="${K8S_VERSION:-1.31.0}"
TF_DIRS="terraform/bootstrap terraform/environments/production terraform/environments/production-addons"

case "${1:-}" in
  render)
    sh scripts/ci/render-manifests.sh --dummy ;;

  gitleaks)
    # Jenkins stash has no .git, so scan the files. History is scanned by scripts/ci/quality-gates.sh.
    gitleaks dir . --no-banner --redact --verbose ;;

  ruff-install)
    pip install -q --no-cache-dir --disable-pip-version-check --user "ruff==${RUFF_VERSION}" ;;
  ruff)
    echo "-- BLOCKING: syntax errors and undefined names (E9, F63, F7, F82)"
    ruff check --select E9,F63,F7,F82 --output-format concise --no-cache campuscart-backend
    echo "-- NON-BLOCKING: rule set pinned in ruff.toml, by rule"
    ruff check --statistics --no-cache campuscart-backend | head -15 || true ;;

  hadolint)
    hadolint --config .hadolint.yaml campuscart-backend/Dockerfile nginx/Dockerfile ;;

  kubeconform)
    [ -d rendered ] || { echo "rendered/ is missing: run 'gate.sh render' first"; exit 1; }
    /kubeconform -kubernetes-version "$K8S_VERSION" -strict -ignore-missing-schemas -summary rendered
    echo "-- skipped kinds (no schema available, usually CRDs):"
    /kubeconform -kubernetes-version "$K8S_VERSION" -strict -ignore-missing-schemas -output text -verbose rendered | grep -i skipped || true ;;

  terraform-fmt)
    terraform fmt -check -recursive -diff terraform ;;
  terraform-init)
    for d in $TF_DIRS; do
      echo "--- init $d"
      terraform -chdir="$d" init -backend=false -input=false -no-color
    done ;;
  terraform-validate)
    for d in $TF_DIRS; do
      echo "--- validate $d"
      terraform -chdir="$d" validate -no-color
    done ;;

  tflint)
    ( cd terraform && tflint --recursive --minimum-failure-severity=error --format compact ) ;;

  checkov)
    # Soft-fail: findings are printed, nothing blocks yet.
    checkov -d terraform -d rendered --framework terraform kubernetes --compact --quiet --soft-fail
    echo "-- Dockerfiles (separate run, so a silent skip is visible)"
    checkov -f campuscart-backend/Dockerfile -f nginx/Dockerfile --framework dockerfile --compact --quiet --soft-fail > /tmp/checkov-docker.txt 2>&1 || true
    cat /tmp/checkov-docker.txt
    grep -q 'dockerfile scan results' /tmp/checkov-docker.txt || echo "WARNING: checkov reported no Dockerfile results; the Dockerfiles may not have been scanned" ;;

  *)
    echo "usage: gate.sh render|gitleaks|ruff-install|ruff|hadolint|kubeconform|terraform-fmt|terraform-init|terraform-validate|tflint|checkov" >&2
    exit 2 ;;
esac
