#!/usr/bin/env bash
# Build (and optionally force-push) an orphan install-dist commit that
# contains the stable suite .debs and SHA256SUMS. History is replaced each
# successful run so large blobs do not accumulate.
#
# Usage: publish-install-dist.sh <sums> <deb> [deb...] [remote-url]
# Omit remote-url to stop after creating the orphan commit (local check).
#
# Required debs (any order):
#   cloudflare-warp-headless_amd64.deb            trixie bits; legacy name
#   cloudflare-warp-headless_bookworm_amd64.deb
#   cloudflare-warp-headless_trixie_amd64.deb
# The legacy amd64 file must be byte-identical to the trixie build.
# SHA256SUMS must list each staged deb. Extra lines (versioned release
# names) are allowed and are published with the same file.
set -euo pipefail

STABLE_SUMS_NAME="SHA256SUMS"
DIST_BRANCH="install-dist"
LEGACY_DEB_NAME="cloudflare-warp-headless_amd64.deb"
TRIXIE_DEB_NAME="cloudflare-warp-headless_trixie_amd64.deb"
REQUIRED_DEBS=(
  cloudflare-warp-headless_amd64.deb
  cloudflare-warp-headless_bookworm_amd64.deb
  cloudflare-warp-headless_trixie_amd64.deb
)

usage() {
  printf 'Usage: %s <sums> <deb> [deb...] [remote-url]\n' "${0##*/}" >&2
  exit 2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage
[[ "$DIST_BRANCH" != "main" ]] || die "refusing to publish to main"

sums="$1"
shift

debs=()
remote=""
for arg in "$@"; do
  if [[ "$arg" == *"://"* || "$arg" == git@* ]]; then
    [[ -z "$remote" ]] || die "multiple remote URLs given"
    remote="$arg"
  else
    debs+=("$arg")
  fi
done

if ((${#debs[@]} != ${#REQUIRED_DEBS[@]})); then
  die "expected ${#REQUIRED_DEBS[@]} debs (${REQUIRED_DEBS[*]}), got ${#debs[@]}"
fi

[[ -s "$sums" ]] || die "checksum file is missing or empty: ${sums}"
[[ "$(basename "$sums")" == "$STABLE_SUMS_NAME" ]] || die "expected checksum filename ${STABLE_SUMS_NAME}, got $(basename "$sums")"

is_required_deb() {
  local name="$1"
  local req
  for req in "${REQUIRED_DEBS[@]}"; do
    [[ "$name" == "$req" ]] && return 0
  done
  return 1
}

path_for() {
  local name="$1"
  local deb base
  for deb in "${debs[@]}"; do
    base="$(basename "$deb")"
    if [[ "$base" == "$name" ]]; then
      printf '%s' "$deb"
      return 0
    fi
  done
  return 1
}

seen=""
for deb in "${debs[@]}"; do
  [[ -s "$deb" ]] || die "deb is missing or empty: ${deb}"
  base="$(basename "$deb")"
  is_required_deb "$base" || die "unexpected deb name: ${base}"
  case " ${seen} " in
    *" ${base} "*) die "duplicate deb name: ${base}" ;;
  esac
  seen="${seen} ${base}"
done

for req in "${REQUIRED_DEBS[@]}"; do
  path_for "$req" >/dev/null || die "missing required deb: ${req}"
done

sum_line_for() {
  local name="$1"
  awk -v name="$name" '
    $1 ~ /^[0-9a-fA-F]{64}$/ && $NF == name {
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$sums"
}

parent="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf -- $(printf '%q' "$parent")" EXIT

verify_dir="${parent}/verify"
work="${parent}/work"
mkdir -p "$verify_dir" "$work"
cp -f "$sums" "${verify_dir}/${STABLE_SUMS_NAME}"

for req in "${REQUIRED_DEBS[@]}"; do
  line="$(sum_line_for "$req")" || die "SHA256SUMS does not list ${req} (or hash line is empty/malformed)"
  src="$(path_for "$req")" || die "missing required deb: ${req}"
  cp -f "$src" "${verify_dir}/${req}"
  if ! (cd "$verify_dir" && printf '%s\n' "$line" | sha256sum -c --strict -); then
    die "checksum mismatch for ${req}"
  fi
  printf '%s\n' "$line" >>"${parent}/checked-lines"
done

if ! cmp -s "${verify_dir}/${LEGACY_DEB_NAME}" "${verify_dir}/${TRIXIE_DEB_NAME}"; then
  die "${LEGACY_DEB_NAME} must be identical to the trixie build ${TRIXIE_DEB_NAME}"
fi

cp -f "${verify_dir}/${STABLE_SUMS_NAME}" "$work/"
for req in "${REQUIRED_DEBS[@]}"; do
  cp -f "${verify_dir}/${req}" "$work/"
done

git -C "$work" init --quiet --initial-branch="$DIST_BRANCH"
git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Force-add: a global excludesFile may ignore *.deb.
git -C "$work" add -f "${REQUIRED_DEBS[@]}" "$STABLE_SUMS_NAME"

mapfile -t tracked < <(git -C "$work" ls-files)
expected_count=$((${#REQUIRED_DEBS[@]} + 1))
if ((${#tracked[@]} != expected_count)); then
  die "expected exactly ${expected_count} tracked files, found: ${tracked[*]:-none}"
fi
for req in "${REQUIRED_DEBS[@]}" "$STABLE_SUMS_NAME"; do
  printf '%s\n' "${tracked[@]}" | grep -qx "$req" || die "${req} was not staged"
done

git -C "$work" commit --quiet -m "Publish IPv6-reachable install assets"

mapfile -t tree < <(git -C "$work" ls-tree --name-only HEAD)
expected="$(printf '%s\n' "${REQUIRED_DEBS[@]}" "$STABLE_SUMS_NAME" | sort)"
actual="$(printf '%s\n' "${tree[@]}" | sort)"
if [[ "$actual" != "$expected" ]]; then
  die "install-dist tree must be ${REQUIRED_DEBS[*]} and ${STABLE_SUMS_NAME}, found: ${tree[*]:-none}"
fi

printf 'install-dist tree:\n'
git -C "$work" ls-tree --long HEAD
printf 'Stable asset SHA256 lines:\n'
cat "${parent}/checked-lines"

if [[ -z "$remote" ]]; then
  printf 'No remote given; orphan commit created locally only.\n'
  exit 0
fi

git -C "$work" remote add origin "$remote"
git -C "$work" push --force origin "HEAD:${DIST_BRANCH}"
printf 'Force-pushed orphan %s.\n' "$DIST_BRANCH"
