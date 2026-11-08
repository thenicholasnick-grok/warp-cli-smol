#!/usr/bin/env bash
# Build (and optionally force-push) an orphan install-dist commit that
# contains the stable suite .debs and SHA256SUMS. History is replaced each
# successful run so large blobs do not accumulate.
#
# Usage: publish-install-dist.sh <sums> <asset> [asset...] [remote-url]
# Omit remote-url to stop after creating the orphan commit (local check).
#
# Required debs (any order):
#   cloudflare-warp-headless_amd64.deb            trixie bits; legacy name
#   cloudflare-warp-headless_bookworm_amd64.deb
#   cloudflare-warp-headless_trixie_amd64.deb
# Also required: PKGBUILD, cloudflare-warp-headless.install, and exactly
# one cloudflare-warp-headless-<pkgver>-1-x86_64.pkg.tar.zst.
# The legacy amd64 file must be byte-identical to the trixie build.
# SHA256SUMS must list each staged file. Extra lines (versioned release
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
  printf 'Usage: %s <sums> <asset> [asset...] [remote-url]\n' "${0##*/}" >&2
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

assets=()
remote=""
for arg in "$@"; do
  if [[ "$arg" == *"://"* || "$arg" == git@* ]]; then
    [[ -z "$remote" ]] || die "multiple remote URLs given"
    remote="$arg"
  else
    assets+=("$arg")
  fi
done

if ((${#assets[@]} < ${#REQUIRED_DEBS[@]})); then
  die "expected the Debian debs plus Arch assets, got ${#assets[@]} files"
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

is_allowed_asset() {
  local name="$1"
  is_required_deb "$name" && return 0
  case "$name" in
    PKGBUILD|cloudflare-warp-headless.install) return 0 ;;
    cloudflare-warp-headless-*-x86_64.pkg.tar.zst) return 0 ;;
  esac
  return 1
}

path_for() {
  local name="$1"
  local asset base
  for asset in "${assets[@]}"; do
    base="$(basename "$asset")"
    if [[ "$base" == "$name" ]]; then
      printf '%s' "$asset"
      return 0
    fi
  done
  return 1
}

seen=""
pkg_count=0
have_pkgbuild=0
have_install=0
for asset in "${assets[@]}"; do
  [[ -s "$asset" ]] || die "asset is missing or empty: ${asset}"
  base="$(basename "$asset")"
  is_allowed_asset "$base" || die "unexpected asset name: ${base}"
  case " ${seen} " in
    *" ${base} "*) die "duplicate asset name: ${base}" ;;
  esac
  seen="${seen} ${base}"
  case "$base" in
    PKGBUILD) have_pkgbuild=1 ;;
    cloudflare-warp-headless.install) have_install=1 ;;
    cloudflare-warp-headless-*-x86_64.pkg.tar.zst) pkg_count=$((pkg_count + 1)) ;;
  esac
done

((have_pkgbuild == 1)) || die "missing PKGBUILD"
((have_install == 1)) || die "missing cloudflare-warp-headless.install"
((pkg_count == 1)) || die "expected exactly one Arch package, found ${pkg_count}"

for req in "${REQUIRED_DEBS[@]}"; do
  path_for "$req" >/dev/null || die "missing required deb: ${req}"
done

sum_line_for() {
  local name="$1"
  awk -v name="$name" '
    length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ && $NF == name {
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

asset_names=()
for asset in "${assets[@]}"; do
  asset_names+=("$(basename "$asset")")
done

for req in "${asset_names[@]}"; do
  line="$(sum_line_for "$req")" || die "SHA256SUMS does not list ${req} (or hash line is empty/malformed)"
  src="$(path_for "$req")" || die "missing asset: ${req}"
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
for req in "${asset_names[@]}"; do
  cp -f "${verify_dir}/${req}" "$work/"
done

git -C "$work" init --quiet --initial-branch="$DIST_BRANCH"
git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Force-add: a global excludesFile may ignore *.deb and generated PKGBUILDs.
git -C "$work" add -f "${asset_names[@]}" "$STABLE_SUMS_NAME"

mapfile -t tracked < <(git -C "$work" ls-files)
expected_count=$((${#asset_names[@]} + 1))
if ((${#tracked[@]} != expected_count)); then
  die "expected exactly ${expected_count} tracked files, found: ${tracked[*]:-none}"
fi
for req in "${asset_names[@]}" "$STABLE_SUMS_NAME"; do
  printf '%s\n' "${tracked[@]}" | grep -qx "$req" || die "${req} was not staged"
done

git -C "$work" commit --quiet -m "Publish IPv6-reachable install assets"

mapfile -t tree < <(git -C "$work" ls-tree --name-only HEAD)
expected="$(printf '%s\n' "${asset_names[@]}" "$STABLE_SUMS_NAME" | sort)"
actual="$(printf '%s\n' "${tree[@]}" | sort)"
if [[ "$actual" != "$expected" ]]; then
  die "install-dist tree mismatch, found: ${tree[*]:-none}"
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
