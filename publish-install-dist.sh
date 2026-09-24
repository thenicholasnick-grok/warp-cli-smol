#!/usr/bin/env bash
# Build (and optionally force-push) an orphan install-dist commit that
# contains only the stable .deb and SHA256SUMS. History is replaced each
# successful run so 38MB blobs do not accumulate.
#
# Usage: publish-install-dist.sh <deb> <sums> [remote-url]
# Omit remote-url to stop after creating the orphan commit (local check).
set -euo pipefail

STABLE_DEB_NAME="cloudflare-warp-headless_amd64.deb"
STABLE_SUMS_NAME="SHA256SUMS"
DIST_BRANCH="install-dist"

usage() {
  printf 'Usage: %s <deb> <sums> [remote-url]\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 2 || $# -eq 3 ]] || usage
[[ "$DIST_BRANCH" != "main" ]] || {
  printf 'ERROR: refusing to publish to main\n' >&2
  exit 1
}

deb="$1"
sums="$2"
remote="${3:-}"

[[ -s "$deb" ]] || {
  printf 'ERROR: deb is missing or empty: %s\n' "$deb" >&2
  exit 1
}
[[ -s "$sums" ]] || {
  printf 'ERROR: checksum file is missing or empty: %s\n' "$sums" >&2
  exit 1
}
[[ "$(basename "$deb")" == "$STABLE_DEB_NAME" ]] || {
  printf 'ERROR: expected filename %s, got %s\n' "$STABLE_DEB_NAME" "$(basename "$deb")" >&2
  exit 1
}

line="$(awk -v name="$STABLE_DEB_NAME" '
  $1 ~ /^[0-9a-fA-F]{64}$/ && $NF == name {
    print
    found = 1
    exit
  }
  END { if (!found) exit 1 }
' "$sums")" || {
  printf 'ERROR: SHA256SUMS does not list %s (or hash line is empty/malformed)\n' "$STABLE_DEB_NAME" >&2
  exit 1
}

parent="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf -- $(printf '%q' "$parent")" EXIT

verify_dir="${parent}/verify"
work="${parent}/work"
mkdir -p "$verify_dir" "$work"
cp -f "$deb" "${verify_dir}/${STABLE_DEB_NAME}"
cp -f "$sums" "${verify_dir}/${STABLE_SUMS_NAME}"
if ! (cd "$verify_dir" && printf '%s\n' "$line" | sha256sum -c --strict -); then
  printf 'ERROR: checksum mismatch for %s\n' "$STABLE_DEB_NAME" >&2
  exit 1
fi

cp -f "${verify_dir}/${STABLE_DEB_NAME}" "${verify_dir}/${STABLE_SUMS_NAME}" "$work/"
git -C "$work" init --quiet --initial-branch="$DIST_BRANCH"
git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Force-add: a global excludesFile may ignore *.deb.
git -C "$work" add -f "$STABLE_DEB_NAME" "$STABLE_SUMS_NAME"

mapfile -t tracked < <(git -C "$work" ls-files)
if ((${#tracked[@]} != 2)); then
  printf 'ERROR: expected exactly two tracked files, found: %s\n' "${tracked[*]:-none}" >&2
  exit 1
fi
printf '%s\n' "${tracked[@]}" | grep -qx "$STABLE_DEB_NAME" \
  || { printf 'ERROR: %s was not staged\n' "$STABLE_DEB_NAME" >&2; exit 1; }
printf '%s\n' "${tracked[@]}" | grep -qx "$STABLE_SUMS_NAME" \
  || { printf 'ERROR: %s was not staged\n' "$STABLE_SUMS_NAME" >&2; exit 1; }

git -C "$work" commit --quiet -m "Publish IPv6-reachable install assets"

mapfile -t tree < <(git -C "$work" ls-tree --name-only HEAD)
expected="$(printf '%s\n' "$STABLE_DEB_NAME" "$STABLE_SUMS_NAME" | sort)"
actual="$(printf '%s\n' "${tree[@]}" | sort)"
if ((${#tree[@]} != 2)) || [[ "$actual" != "$expected" ]]; then
  printf 'ERROR: install-dist tree must be only %s and %s, found: %s\n' \
    "$STABLE_DEB_NAME" "$STABLE_SUMS_NAME" "${tree[*]:-none}" >&2
  exit 1
fi

printf 'install-dist tree:\n'
git -C "$work" ls-tree --long HEAD
printf 'Stable asset SHA256:\n'
printf '%s\n' "$line"

if [[ -z "$remote" ]]; then
  printf 'No remote given; orphan commit created locally only.\n'
  exit 0
fi

git -C "$work" remote add origin "$remote"
git -C "$work" push --force origin "HEAD:${DIST_BRANCH}"
printf 'Force-pushed orphan %s.\n' "$DIST_BRANCH"
