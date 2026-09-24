#!/usr/bin/env bash
# Install cloudflare-warp-headless on a guest VM from install-dist
# (raw.githubusercontent.com — dual-stack). GitHub Release downloads stay
# IPv4-only via github.com, which has no AAAA.
# Primary use: curl -fsSL .../install.sh | sudo bash
set -euo pipefail

REPO="thenicholasnick-grok/warp-cli-smol"
DIST_BRANCH="install-dist"
STABLE_DEB_NAME="cloudflare-warp-headless_amd64.deb"
STABLE_SUMS_NAME="SHA256SUMS"
STABLE_DEB_URL="https://raw.githubusercontent.com/${REPO}/${DIST_BRANCH}/${STABLE_DEB_NAME}"
STABLE_SUMS_URL="https://raw.githubusercontent.com/${REPO}/${DIST_BRANCH}/${STABLE_SUMS_NAME}"
WARP_SVC_BIN="/bin/warp-svc"
WARP_SVC_UNIT="warp-svc"
MDM_XML_PATH="/var/lib/cloudflare-warp/mdm.xml"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Download $1 to $2. On curl failure print a clear ERROR (URL + exit) and
# exit non-zero. Empty-file message is $3 so callers keep their wording.
fetch_release_asset() {
  local url="$1"
  local dest="$2"
  local empty_msg="$3"
  local rc=0

  log "Downloading ${url}"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    die "failed to download ${url} (curl exit ${rc}). Need outbound HTTPS to raw.githubusercontent.com."
  fi
  [[ -s "$dest" ]] || die "$empty_msg"
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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

note_mdm() {
  log "Zero Trust MDM (optional): ${MDM_XML_PATH} must be an Apple-style XML plist <dict> (not key=value). README has the snippet."
}

systemd_looks_usable() {
  has_cmd systemctl || return 1
  local state
  state="$(systemctl is-system-running 2>/dev/null || true)"
  case "$state" in
    running|degraded|starting|initializing|maintenance) return 0 ;;
    *) return 1 ;;
  esac
}

warp_svc_unit_present() {
  [[ -f /lib/systemd/system/warp-svc.service || -f /usr/lib/systemd/system/warp-svc.service ]] && return 0
  systemctl cat "${WARP_SVC_UNIT}.service" >/dev/null 2>&1
}

# Silent when /bin/warp-svc is absent, or when only setcap exists (cannot inspect).
advise_caps() {
  [[ -e "$WARP_SVC_BIN" ]] || return 0
  if ! has_cmd getcap && ! has_cmd setcap; then
    warn "setcap is missing. apt-get install -y libcap2-bin, then dpkg-reconfigure cloudflare-warp-headless"
    return 0
  fi
  has_cmd getcap || return 0
  local caps
  caps="$(getcap "$WARP_SVC_BIN" 2>/dev/null || true)"
  if [[ "$caps" != *cap_net_admin* ]]; then
    warn "capabilities on ${WARP_SVC_BIN} look incomplete. apt-get install -y libcap2-bin, then dpkg-reconfigure cloudflare-warp-headless"
  fi
}

# Never fails the installer: enable/start is already || true in postinst; MDM is optional.
advise_warp_svc() {
  if ! has_cmd systemctl; then
    warn "systemctl is not available; this package expects systemd to run warp-svc."
    warn "Start the daemon manually if needed: ${WARP_SVC_BIN}"
    advise_caps
    return 0
  fi

  if ! systemd_looks_usable; then
    warn "systemd does not appear to be running (container or non-systemd host)."
    warn "This package expects systemd. Start the daemon manually if needed: ${WARP_SVC_BIN}"
    advise_caps
    return 0
  fi

  if ! warp_svc_unit_present; then
    warn "warp-svc.service unit file is missing (unexpected for this package). Reinstall cloudflare-warp-headless."
    advise_caps
    return 0
  fi

  local active enabled
  active="$(systemctl is-active "${WARP_SVC_UNIT}" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "${WARP_SVC_UNIT}" 2>/dev/null || true)"

  if [[ "$active" == "active" || "$active" == "activating" ]]; then
    log "warp-svc is running."
    if [[ "$enabled" == "disabled" || "$enabled" == "masked" ]]; then
      log "To enable on boot: systemctl enable ${WARP_SVC_UNIT}"
    fi
    advise_caps
    return 0
  fi

  warn "warp-svc is not running (${active:-unknown})."
  warn "Check: systemctl status ${WARP_SVC_UNIT}"
  warn "Start and enable: systemctl enable --now ${WARP_SVC_UNIT}"
  advise_caps
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
  # Expand $tmp now. EXIT can run after this function's locals unwind, and
  # under set -u a late "$tmp" becomes `tmp: unbound variable`.
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  deb="${tmp}/${STABLE_DEB_NAME}"
  sums="${tmp}/${STABLE_SUMS_NAME}"

  fetch_release_asset "$STABLE_DEB_URL" "$deb" "downloaded package is empty"
  fetch_release_asset "$STABLE_SUMS_URL" "$sums" "downloaded checksum file is empty"

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
  advise_warp_svc
  log "Do not apt-get install cloudflare-warp afterwards."
  note_mdm
}

if [[ "${INSTALL_SH_SOURCE:-0}" != 1 ]]; then
  install_headless_warp "$@"
fi
