#!/bin/sh
# Push ONE image tarball with crane and prove the registry holds exactly that tarball.
#   sh scripts/ci/push-image.sh <tarball> <destination-ref> [<checksum-file>]
# 1. With a checksum file ("<sha256>  <name>" lines, in the same folder as the tarball), the tarball must still match
#    the checksum recorded when it was built. A changed or corrupted file is never pushed.
# 2. crane pushes the tarball.
# 3. The digest the registry reports must equal the digest crane computes from the tarball itself.
# Runs INSIDE the crane debug container (busybox sh). Never calls AWS: the caller runs "crane auth login" first.
set -eu
tar_path="${1:?usage: push-image.sh <tarball> <destination-ref> [<checksum-file>]}"
dest="${2:?destination ref}"
sums="${3:-}"

[ -f "$tar_path" ] || { echo "push-image: $tar_path not found" >&2; exit 2; }

if [ -n "$sums" ]; then
  [ -f "$sums" ] || { echo "push-image: checksum file $sums not found" >&2; exit 2; }
  name="$(basename "$tar_path")"
  line="$(grep "  ${name}\$" "$sums" || true)"
  [ -n "$line" ] || { echo "push-image: no checksum recorded for $name; refusing to push" >&2; exit 1; }
  if ! ( cd "$(dirname "$sums")" && printf '%s\n' "$line" | sha256sum -c - ); then
    echo "push-image: $name does not match its recorded checksum; refusing to push" >&2
    exit 1
  fi
fi

want="$(crane digest --tarball "$tar_path")"
echo "tarball digest:  $want"
crane push "$tar_path" "$dest"
got="$(crane digest "$dest")"
echo "registry digest: $got"
if [ "$want" != "$got" ]; then
  echo "push-image: digest mismatch, the registry does not hold the scanned tarball" >&2
  exit 1
fi
echo "PUSHED $dest (digest matches the tarball)"
