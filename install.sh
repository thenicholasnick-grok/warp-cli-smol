#!/usr/bin/env bash
# Install cloudflare-warp-headless on a guest VM from install-dist
# (raw.githubusercontent.com — dual-stack). GitHub Release downloads stay
# IPv4-only via github.com, which has no AAAA.
# Debian 12 (bookworm), Debian 13 (trixie), and Arch/Omarchy, x86_64 only.
# Debian suite comes from /etc/os-release. Override with
# WARP_SMOL_SUITE=bookworm or WARP_SMOL_SUITE=trixie.
# Arch is ID=arch. Omarchy 4 is ID=omarchy and ID_LIKE=arch.
# Primary use: curl -fsSL .../install.sh | sudo bash
# Weekly auto-update is on by default (Tuesday 20:17 UTC).
# Opt out: --no-auto-update or WARP_SMOL_AUTO_UPDATE=0.
set -euo pipefail

REPO="thenicholasnick-grok/warp-cli-smol"
DIST_BRANCH="install-dist"
STABLE_SUMS_NAME="SHA256SUMS"
STABLE_SUMS_URL="https://raw.githubusercontent.com/${REPO}/${DIST_BRANCH}/${STABLE_SUMS_NAME}"
REFRESH_URL="https://raw.githubusercontent.com/${REPO}/main/install.sh"
AUTO_UPDATE_CRON="/etc/cron.d/warp-cli-smol"
AUTO_UPDATE_SERVICE="/etc/systemd/system/warp-cli-smol.service"
AUTO_UPDATE_TIMER="/etc/systemd/system/warp-cli-smol.timer"
# Same sentence as the README warning. Printed when the weekly root job is written.
AUTO_UPDATE_WARNING="By default this installer sets up a weekly root job that downloads and runs whatever install.sh is on main at that moment. That is remote code execution as root, and it trusts this repo, GitHub, and the maintainer every week. If you do not fully trust that, fork the repo and run your own CI build, point the installer at your fork, or opt out with --no-auto-update or WARP_SMOL_AUTO_UPDATE=0 and update manually."
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
    if has_cmd apt-get; then
      warn "setcap is missing. apt-get install -y libcap2-bin, then dpkg-reconfigure cloudflare-warp-headless"
    else
      warn "setcap is missing. Install libcap, then reinstall cloudflare-warp-headless."
    fi
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
  if [[ ! -e /dev/net/tun ]]; then
    warn "/dev/net/tun is missing. warp-svc cannot open a tunnel."
  fi

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

  # Length and a negated class, not {64}. Debian 12 mawk treats intervals as literals.
  line="$(awk -v name="$name" '
    length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ && $NF == name {
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

read_os_release_field() {
  local file="$1"
  local key="$2"
  local line val
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        val="${line#"${key}="}"
        val="${val%\"}"
        val="${val#\"}"
        val="${val%\'}"
        val="${val#\'}"
        printf '%s' "$val"
        return 0
        ;;
    esac
  done <"$file"
  return 0
}

suite_from_debian_release() {
  local codename="$1"
  local version_id="$2"
  local from_code="" from_id=""

  case "$codename" in
    bookworm) from_code="bookworm" ;;
    trixie) from_code="trixie" ;;
    "") ;;
    *)
      die "unsupported Debian release: VERSION_CODENAME=${codename} (Debian 12 bookworm and Debian 13 trixie only)"
      ;;
  esac

  case "$version_id" in
    12) from_id="bookworm" ;;
    13) from_id="trixie" ;;
    "") ;;
    *)
      die "unsupported Debian release: VERSION_ID=${version_id} (Debian 12 bookworm and Debian 13 trixie only)"
      ;;
  esac

  if [[ -n "$from_code" && -n "$from_id" && "$from_code" != "$from_id" ]]; then
    die "Debian release mismatch: VERSION_CODENAME=${codename} VERSION_ID=${version_id}"
  fi
  if [[ -z "$from_code" && -z "$from_id" ]]; then
    die "could not detect Debian release from VERSION_CODENAME or VERSION_ID (Debian 12 bookworm and Debian 13 trixie only)"
  fi
  printf '%s' "${from_code:-$from_id}"
}

suite_deb_name() {
  case "$1" in
    bookworm|trixie)
      printf 'cloudflare-warp-headless_%s_amd64.deb' "$1"
      ;;
    *)
      die "internal error: bad suite '${1}'"
      ;;
  esac
}

host_arch() {
  if has_cmd dpkg; then
    dpkg --print-architecture
    return
  fi
  uname -m
}

id_like_has_arch() {
  local rest="$1" tok
  while [[ -n "$rest" ]]; do
    tok="${rest%% *}"
    rest="${rest#"$tok"}"
    rest="${rest# }"
    [[ "$tok" == "arch" ]] && return 0
  done
  return 1
}

# select_os_family <arch> <os-release-path>
# Prints arch or debian. x86_64/amd64 only.
select_os_family() {
  local arch="$1"
  local os_release="$2"
  local id id_like

  case "$arch" in
    amd64|x86_64) ;;
    *)
      die "unsupported architecture: ${arch} (x86_64 only)"
      ;;
  esac

  [[ -f "$os_release" ]] || die "cannot read ${os_release} to detect the operating system"
  id="$(read_os_release_field "$os_release" ID)"
  id_like="$(read_os_release_field "$os_release" ID_LIKE)"

  if [[ "$id" == "arch" ]]; then
    printf 'arch'
    return 0
  fi
  # Omarchy 4: ID=omarchy and ID_LIKE=arch. Older Omarchy still uses ID=arch.
  if [[ "$id" == "omarchy" ]]; then
    if id_like_has_arch "$id_like"; then
      printf 'arch'
      return 0
    fi
    die "unsupported Omarchy identity: ID_LIKE=${id_like:-empty} (expected arch)"
  fi
  if [[ "$id" == "debian" ]]; then
    printf 'debian'
    return 0
  fi
  die "unsupported operating system: ${id:-unknown} (Debian 12, Debian 13, Arch, and Omarchy on x86_64 only)"
}

# Print the single Arch package filename listed in a SHA256SUMS file.
# The sums file is data. It is never evaluated as shell.
arch_pkg_name_from_sums() {
  local sums="$1"
  local name
  name="$(awk '
    function is_arch_pkg(name,    prefix, suffix, mid, n, i, c) {
      prefix = "cloudflare-warp-headless-"
      suffix = "-1-x86_64.pkg.tar.zst"
      n = length(name)
      if (index(name, prefix) != 1) return 0
      if (n <= length(prefix) + length(suffix)) return 0
      if (substr(name, n - length(suffix) + 1) != suffix) return 0
      mid = substr(name, length(prefix) + 1, n - length(prefix) - length(suffix))
      if (mid == "") return 0
      for (i = 1; i <= length(mid); i++) {
        c = substr(mid, i, 1)
        if (c !~ /[0-9A-Za-z._+]/) return 0
      }
      return 1
    }
    length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ && is_arch_pkg($NF) {
      print $NF
      count++
    }
    END { if (count != 1) exit 1 }
  ' "$sums")" || die "SHA256SUMS does not list exactly one Arch package"
  printf '%s' "$name"
}

# select_suite <arch> <os-release-path>
# WARP_SMOL_SUITE=bookworm|trixie overrides the suite from os-release.
# Architecture is never overridden.
select_suite() {
  local arch="$1"
  local os_release="$2"
  local id codename version_id

  case "$arch" in
    amd64|x86_64) ;;
    *)
      die "unsupported architecture: ${arch} (amd64 only)"
      ;;
  esac

  if [[ -n "${WARP_SMOL_SUITE:-}" ]]; then
    case "$WARP_SMOL_SUITE" in
      bookworm|trixie)
        printf '%s' "$WARP_SMOL_SUITE"
        return 0
        ;;
      *)
        die "WARP_SMOL_SUITE must be bookworm or trixie (got: ${WARP_SMOL_SUITE})"
        ;;
    esac
  fi

  [[ -f "$os_release" ]] || die "cannot read ${os_release} to detect the Debian release"

  id="$(read_os_release_field "$os_release" ID)"
  codename="$(read_os_release_field "$os_release" VERSION_CODENAME)"
  version_id="$(read_os_release_field "$os_release" VERSION_ID)"

  if [[ "$id" != "debian" ]]; then
    die "unsupported operating system: ${id:-unknown} (Debian 12 bookworm and Debian 13 trixie only)"
  fi

  suite_from_debian_release "$codename" "$version_id"
}

host_has_cron() {
  [[ -d /etc/cron.d ]] || return 1
  [[ -x /usr/sbin/cron || -x /usr/sbin/crond ]] && return 0
  has_cmd cron && return 0
  has_cmd crond && return 0
  return 1
}

# One scheduler per host. Cron wins when it is installed. systemd is the fallback.
parse_auto_update() {
  local arg
  AUTO_UPDATE=1
  if [[ "${WARP_SMOL_AUTO_UPDATE:-}" == "0" ]]; then
    AUTO_UPDATE=0
  fi
  for arg in "$@"; do
    case "$arg" in
      --no-auto-update)
        AUTO_UPDATE=0
        ;;
      *)
        die "unknown argument: ${arg}"
        ;;
    esac
  done
}

refresh_command() {
  local sink
  if has_cmd logger; then
    sink="logger -t warp-cli-smol"
  else
    sink="tee -a /var/log/warp-cli-smol.log >/dev/null"
  fi
  printf '%s' "{ curl -fsSL ${REFRESH_URL} | bash; } 2>&1 | ${sink}; { warp-cli --accept-tos status || true; } 2>&1 | ${sink}"
}

remove_auto_update_jobs() {
  rm -f "$AUTO_UPDATE_CRON"
  if has_cmd systemctl; then
    systemctl disable --now warp-cli-smol.timer >/dev/null 2>&1 || true
  fi
  if [[ -d /etc/systemd/system ]]; then
    rm -f "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"
  fi
  if systemd_looks_usable; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

write_auto_update_cron() {
  local cmd tmp
  cmd="$(refresh_command)"
  tmp="$(mktemp "${AUTO_UPDATE_CRON}.XXXXXX")"
  cat >"$tmp" <<EOF
CRON_TZ=UTC
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 20 * * 2 root ${cmd}
EOF
  chown root:root "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$AUTO_UPDATE_CRON"
}

write_auto_update_timer() {
  local cmd
  cmd="$(refresh_command)"
  cat >"$AUTO_UPDATE_SERVICE" <<EOF
[Unit]
Description=Weekly refresh of cloudflare-warp-headless

[Service]
Type=oneshot
ExecStart=/bin/sh -c '${cmd}'
EOF
  cat >"$AUTO_UPDATE_TIMER" <<EOF
[Unit]
Description=Weekly refresh of cloudflare-warp-headless

[Timer]
OnCalendar=Tue *-*-* 20:17:00 UTC

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"
  systemctl daemon-reload
  systemctl enable warp-cli-smol.timer
  systemctl restart warp-cli-smol.timer
}

# Rewrites the one job in place. The weekly run calls this again and does not add a second job.
install_auto_update_job() {
  if host_has_cron; then
    remove_auto_update_jobs
    write_auto_update_cron
    log "Auto-update is on. /etc/cron.d/warp-cli-smol runs the installer every Tuesday at 20:17 UTC."
    warn "$AUTO_UPDATE_WARNING"
    return 0
  fi
  if systemd_looks_usable; then
    remove_auto_update_jobs
    write_auto_update_timer
    log "Auto-update is on. systemd timer warp-cli-smol.timer runs the installer every Tuesday at 20:17 UTC."
    warn "$AUTO_UPDATE_WARNING"
    return 0
  fi
  warn "Auto-update was not scheduled. This host has no cron, and systemd is not running. Install cron and re-run install.sh, or update manually."
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

arch_conflict_installed() {
  local name
  for name in cloudflare-warp cloudflare-warp-bin cloudflare-warp-nox-bin cloudflare-warp-minimal-bin; do
    if pacman -Q "$name" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

install_verified_arch() {
  local sums="$1"
  local tmp="$2"
  local name url dest conflict

  has_cmd pacman || die "pacman is required"
  if conflict="$(arch_conflict_installed)"; then
    die "official ${conflict} is installed. Remove it first. Do not install cloudflare-warp; that package fights this headless build."
  fi

  name="$(arch_pkg_name_from_sums "$sums")"
  url="https://raw.githubusercontent.com/${REPO}/${DIST_BRANCH}/${name}"
  dest="${tmp}/${name}"
  log "Selected Arch package ${name}"
  fetch_release_asset "$url" "$dest" "downloaded package is empty"
  verify_release_deb "$dest" "$sums"

  pacman -Sy --noconfirm </dev/null
  pacman -U --noconfirm "$dest" </dev/null
  pacman -Q cloudflare-warp-headless >/dev/null 2>&1 \
    || die "cloudflare-warp-headless did not finish installing"
}

install_verified_debian() {
  local arch="$1"
  local sums="$2"
  local tmp="$3"
  local suite deb_name deb_url deb

  has_cmd dpkg || die "dpkg is required"
  suite="$(select_suite "$arch" /etc/os-release)"
  deb_name="$(suite_deb_name "$suite")"
  deb_url="https://raw.githubusercontent.com/${REPO}/${DIST_BRANCH}/${deb_name}"
  deb="${tmp}/${deb_name}"
  log "Selected ${suite} package ${deb_name}"

  if official_warp_installed; then
    die "official cloudflare-warp is installed. Remove it first. Do not apt-get install cloudflare-warp; that package fights this headless build."
  fi
  warn "Do not apt-get install cloudflare-warp after this. That pulls the official GUI client and replaces /bin/warp-cli and /bin/warp-svc."

  fetch_release_asset "$deb_url" "$deb" "downloaded package is empty"
  verify_release_deb "$deb" "$sums"

  export DEBIAN_FRONTEND=noninteractive
  if has_cmd apt-get; then
    apt-get update </dev/null
    # A leading ./ makes apt install this file. A bare name is a package lookup.
    (cd "$tmp" && apt-get install -y "./${deb_name}" </dev/null)
  elif ! dpkg -i "$deb" </dev/null; then
    log "dpkg reported missing dependencies; running apt-get install -f"
    apt-get update </dev/null
    apt-get install -f -y </dev/null
  fi

  pkg_ok_installed cloudflare-warp-headless \
    || die "cloudflare-warp-headless did not finish installing"
}

install_headless_warp() {
  require_root "$@"
  parse_auto_update "$@"
  if [[ "$AUTO_UPDATE" -eq 0 ]]; then
    remove_auto_update_jobs
    log "Auto-update is off. Removed any weekly refresh job."
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

  local arch family tmp sums
  arch="$(host_arch)"
  family="$(select_os_family "$arch" /etc/os-release)"
  log "Selected operating system family ${family}"

  tmp="$(mktemp -d)"
  # Expand $tmp now. EXIT can run after this function's locals unwind, and
  # under set -u a late "$tmp" becomes `tmp: unbound variable`.
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  sums="${tmp}/${STABLE_SUMS_NAME}"
  fetch_release_asset "$STABLE_SUMS_URL" "$sums" "downloaded checksum file is empty"

  if [[ "$family" == "arch" ]]; then
    install_verified_arch "$sums" "$tmp"
  else
    install_verified_debian "$arch" "$sums" "$tmp"
  fi

  command -v warp-cli >/dev/null 2>&1 || die "warp-cli is not on PATH after install"

  log "Installed cloudflare-warp-headless. warp-cli is on PATH."
  advise_warp_svc
  if [[ "$family" == "debian" ]]; then
    log "Do not apt-get install cloudflare-warp afterwards."
  fi
  note_mdm
  if [[ "$AUTO_UPDATE" -eq 1 ]]; then
    install_auto_update_job
  fi
}

if [[ "${INSTALL_SH_SOURCE:-0}" != 1 ]]; then
  install_headless_warp "$@"
fi
