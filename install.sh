#!/usr/bin/env bash
# Install cloudflare-warp-headless on a guest VM from the rolling GitHub Release.
# Primary use: curl -fsSL .../install.sh | sudo bash
set -euo pipefail

STABLE_DEB_NAME="cloudflare-warp-headless_amd64.deb"
STABLE_SUMS_NAME="SHA256SUMS"
STABLE_DEB_URL="https://github.com/thenicholasnick-grok/warp-cli-smol/releases/latest/download/${STABLE_DEB_NAME}"
STABLE_SUMS_URL="https://github.com/thenicholasnick-grok/warp-cli-smol/releases/latest/download/${STABLE_SUMS_NAME}"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

pkg_ok_installed() {
  local status
  status="$(dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null || true)"
  [[ "$status" == *'ok installed'* ]]
}

official_warp_installed() {
  pkg_ok_installed cloudflare-warp
}

# Verify $1 (the downloaded .deb) against the published SHA256SUMS in $2.
# Fails if the checksum file is missing the stable name, the hash line is
# empty/malformed, or the digest does not match.
verify_release_deb() {
  local deb="$1"
  local sums="$2"
  local name line

  name="$(basename "$deb")"
  [[ -f "$deb" ]] || die "package file is missing"
  [[ -s "$deb" ]] || die "downloaded package is empty"
  [[ -f "$sums" ]] || die "checksum file is missing"
  [[ -s "$sums" ]] || die "downloaded checksum file is empty"

  line="$(awk -v name="$name" '
    $1 ~ /^[0-9a-fA-F]{64}$/ && $NF == name {
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$sums")" || die "checksum file does not list ${name} (or hash line is empty/malformed)"

  log "Verifying ${name} against published ${STABLE_SUMS_NAME}"
  if ! (cd "$(dirname "$deb")" && printf '%s\n' "$line" | sha256sum -c --strict -); then
    die "checksum mismatch for ${name}; refusing to install"
  fi
}

require_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi

  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "$self" && -f "$self" && "$self" != bash && "$self" != - ]]; then
    if [[ "$self" != /* ]]; then
      self="$(pwd)/${self#./}"
    fi
    exec sudo -- "$self" "$@"
  fi

  die "this installer must run as root. Re-run with: curl -fsSL https://raw.githubusercontent.com/thenicholasnick-grok/warp-cli-smol/main/install.sh | sudo bash"
}

install_headless_warp() {
  require_root "$@"

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v dpkg >/dev/null 2>&1 || die "dpkg is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

  if official_warp_installed; then
    die "official cloudflare-warp is installed. Remove it first. Do not apt-get install cloudflare-warp; that package fights this headless build."
  fi

  warn "Do not apt-get install cloudflare-warp after this. That pulls the official GUI client and replaces /bin/warp-cli and /bin/warp-svc."

  local tmp deb sums
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  deb="${tmp}/${STABLE_DEB_NAME}"
  sums="${tmp}/${STABLE_SUMS_NAME}"

  log "Downloading ${STABLE_DEB_URL}"
  curl -fsSL --retry 3 --retry-delay 2 -o "$deb" "$STABLE_DEB_URL"
  [[ -s "$deb" ]] || die "downloaded package is empty"

  log "Downloading ${STABLE_SUMS_URL}"
  curl -fsSL --retry 3 --retry-delay 2 -o "$sums" "$STABLE_SUMS_URL"
  [[ -s "$sums" ]] || die "downloaded checksum file is empty"

  verify_release_deb "$deb" "$sums"

  export DEBIAN_FRONTEND=noninteractive
  if ! dpkg -i "$deb" </dev/null; then
    log "dpkg reported missing dependencies; running apt-get install -f"
    apt-get update </dev/null
    apt-get install -f -y </dev/null
  fi

  pkg_ok_installed cloudflare-warp-headless \
    || die "cloudflare-warp-headless did not finish installing"

  command -v warp-cli >/dev/null 2>&1 || die "warp-cli is not on PATH after install"

  log "Installed cloudflare-warp-headless. warp-cli is on PATH."
  log "Do not apt-get install cloudflare-warp afterwards."
}

install_headless_warp "$@"
