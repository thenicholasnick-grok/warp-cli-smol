#!/usr/bin/env bash
# Fetch the current Cloudflare WARP amd64 .deb from the public repo and
# rebuild it as cloudflare-warp-headless (CLI + warp-svc only).
set -euo pipefail

PACKAGES_URL="https://pkg.cloudflareclient.com/dists/trixie/main/binary-amd64/Packages"
UPSTREAM_BASE="https://pkg.cloudflareclient.com"
UPSTREAM_PACKAGE="cloudflare-warp"
OUTPUT_PACKAGE="cloudflare-warp-headless"

DROP_DEPS=(
  desktop-file-utils
  libayatana-appindicator3-1
  libwebkit2gtk-4.1-0
)

DELETE_PATHS=(
  bin/warp-taskbar
  usr/lib/warp
  usr/lib/systemd/user
  usr/share/applications
  usr/share/icons
  usr/share/dbus-1/services/com.cloudflare.WarpTaskbar.service
)

KEEP_PATHS=(
  bin/warp-cli
  bin/warp-svc
  lib/systemd/system/warp-svc.service
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_DIR="${ROOT}/downloads"
WORK_DIR="${ROOT}/work"
EXTRACT_DIR="${WORK_DIR}/extract"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

dep_name() {
  local item="$1"
  item="$(trim "$item")"
  item="${item%%[[:space:]]*}"
  item="${item%%:*}"
  printf '%s' "$item"
}

should_drop_dep() {
  local name="$1"
  local drop
  for drop in "${DROP_DEPS[@]}"; do
    if [[ "$name" == "$drop" ]]; then
      return 0
    fi
  done
  return 1
}

filter_depends() {
  local raw="$1"
  local item name
  local -a kept=()
  local IFS=','
  local -a items=($raw)
  unset IFS

  for item in "${items[@]}"; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue
    name="$(dep_name "$item")"
    if should_drop_dep "$name"; then
      log "Dropping dependency: ${item}"
      continue
    fi
    kept+=("$item")
  done

  if ((${#kept[@]} == 0)); then
    die "Depends line became empty after filtering"
  fi

  local result="${kept[0]}"
  local i
  for ((i = 1; i < ${#kept[@]}; i++)); do
    result+=", ${kept[i]}"
  done
  printf '%s' "$result"
}

# Print Version, Filename, and SHA256 (may be empty) for the upstream package.
# Handles blank-line-separated stanzas in a Debian Packages index.
parse_upstream_stanza() {
  local packages_file="$1"
  awk -v want="$UPSTREAM_PACKAGE" '
    function flush(    ok) {
      if (pkg == want && ver != "" && filename != "") {
        printf "%s\t%s\t%s\n", ver, filename, sha256
        found = 1
        exit 0
      }
      pkg = ""; ver = ""; filename = ""; sha256 = ""
    }
    /^Package:[[:space:]]*/  { if (pkg != "") flush(); pkg = $2; next }
    /^Version:[[:space:]]*/  { ver = $2; next }
    /^Filename:[[:space:]]*/ { filename = $2; next }
    /^SHA256:[[:space:]]*/   { sha256 = $2; next }
    /^$/                     { flush() }
    END {
      if (!found) flush()
      if (!found) exit 1
    }
  ' "$packages_file"
}

rewrite_control() {
  local src="$1"
  local dest="$2"
  local new_depends="$3"
  local line
  : >"$dest"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      Package:*)
        printf 'Package: %s\n' "$OUTPUT_PACKAGE" >>"$dest"
        ;;
      Depends:*)
        printf 'Depends: %s\n' "$new_depends" >>"$dest"
        ;;
      Installed-Size:*)
        printf 'Installed-Size: 0\n' >>"$dest"
        ;;
      *)
        printf '%s\n' "$line" >>"$dest"
        ;;
    esac
  done <"$src"
}

set_control_field() {
  local control="$1"
  local field="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v field="$field" -v value="$value" '
    BEGIN { prefix = field ": " }
    index($0, prefix) == 1 {
      print prefix value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print prefix value
      }
    }
  ' "$control" >"$tmp"
  mv "$tmp" "$control"
}

regenerate_md5sums() {
  local root="$1"
  (
    cd "$root"
    find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
      md5sum "$f"
    done >DEBIAN/md5sums
  )
}

regenerate_installed_size() {
  local root="$1"
  local kib
  kib="$(du -sk --exclude=DEBIAN "$root" | awk '{print $1}')"
  [[ -n "$kib" ]] || die "failed to compute Installed-Size"
  set_control_field "${root}/DEBIAN/control" "Installed-Size" "$kib"
  log "Regenerated Installed-Size: ${kib} KiB"
}

print_banner() {
  local title="$1"
  printf '\n========================================\n'
  printf '%s\n' "$title"
  printf '========================================\n'
}

needed_libs() {
  readelf -d "$1" | awk '/\(NEEDED\)/ {
    gsub(/.*\[/, "")
    gsub(/\].*/, "")
    print
  }'
}

prove_control() {
  local control="$1"
  print_banner "PROOF 1: new control has no webkit and no appindicator"
  cat "$control"
  printf '\n'
  if grep -Ei 'webkit|appindicator' "$control"; then
    die "PROOF 1 FAILED: control still mentions webkit or appindicator"
  fi
  grep -q "^Package: ${OUTPUT_PACKAGE}$" "$control" || die "PROOF 1 FAILED: Package is not ${OUTPUT_PACKAGE}"
  log "PROOF 1 PASSED: control has no webkit and no appindicator"
}

prove_warp_cli() {
  local bin="$1"
  print_banner "PROOF 2: readelf -d bin/warp-cli NEEDED is only libc, libm, libgcc_s"
  readelf -d "$bin"
  printf '\nNEEDED libraries:\n'
  local lib ok=1 count=0
  while IFS= read -r lib; do
    [[ -z "$lib" ]] && continue
    count=$((count + 1))
    printf '  NEEDED: %s\n' "$lib"
    case "$lib" in
      libc.so.*|libm.so.*|libgcc_s.so.*)
        ;;
      ld-linux*.so.*)
        # Dynamic linker is listed as NEEDED; not a library dependency.
        ;;
      *)
        log "FAIL: unexpected NEEDED library on warp-cli: ${lib}"
        ok=0
        ;;
    esac
  done < <(needed_libs "$bin")

  if ((count == 0)); then
    die "PROOF 2 FAILED: warp-cli has no NEEDED entries"
  fi
  if ((ok != 1)); then
    die "PROOF 2 FAILED: warp-cli NEEDED is not limited to libc, libm, libgcc_s"
  fi
  log "PROOF 2 PASSED: warp-cli NEEDED shows only libc, libm, libgcc_s"
}

prove_warp_svc() {
  local bin="$1"
  print_banner "PROOF 3: readelf -d bin/warp-svc does not show webkit or gtk"
  readelf -d "$bin"
  printf '\n'
  if readelf -d "$bin" | grep -Ei 'webkit|gtk'; then
    die "PROOF 3 FAILED: warp-svc dynamic section mentions webkit or gtk"
  fi
  log "PROOF 3 PASSED: warp-svc has no webkit or gtk in readelf -d"
}

need_cmd curl
need_cmd dpkg-deb
need_cmd readelf
need_cmd md5sum
need_cmd awk
need_cmd find
need_cmd du

rm -rf "$WORK_DIR"
mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR"

packages_file="${DOWNLOAD_DIR}/Packages"
log "Fetching ${PACKAGES_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$PACKAGES_URL" -o "$packages_file"

stanza="$(parse_upstream_stanza "$packages_file")" || die "could not parse ${UPSTREAM_PACKAGE} from Packages"
upstream_version="${stanza%%$'\t'*}"
rest="${stanza#*$'\t'}"
upstream_filename="${rest%%$'\t'*}"
upstream_sha256="${rest#*$'\t'}"
if [[ "$upstream_sha256" == "$upstream_filename" ]]; then
  upstream_sha256=""
fi

[[ -n "$upstream_version" ]] || die "empty Version in ${UPSTREAM_PACKAGE} stanza"
[[ -n "$upstream_filename" ]] || die "empty Filename in ${UPSTREAM_PACKAGE} stanza"

log "Upstream Version: ${upstream_version}"
log "Upstream Filename: ${upstream_filename}"

upstream_url="${UPSTREAM_BASE}/${upstream_filename}"
upstream_deb="${DOWNLOAD_DIR}/$(basename "$upstream_filename")"
log "Downloading ${upstream_url}"
curl -fL --retry 3 --retry-delay 2 "$upstream_url" -o "$upstream_deb"

if [[ -n "$upstream_sha256" ]]; then
  printf '%s  %s\n' "$upstream_sha256" "$upstream_deb" | sha256sum -c -
fi

log "Extracting with dpkg-deb -R"
dpkg-deb -R "$upstream_deb" "$EXTRACT_DIR"

control="${EXTRACT_DIR}/DEBIAN/control"
[[ -f "$control" ]] || die "missing DEBIAN/control after extract"

orig_depends="$(awk -F ': ' '/^Depends: / {sub(/^Depends: /, ""); print; exit}' "$control")"
[[ -n "$orig_depends" ]] || die "missing Depends in upstream control"
new_depends="$(filter_depends "$orig_depends")"
log "New Depends: ${new_depends}"

rewrite_control "$control" "${control}.new" "$new_depends"
mv "${control}.new" "$control"

for rel in "${DELETE_PATHS[@]}"; do
  target="${EXTRACT_DIR}/${rel}"
  if [[ -e "$target" || -L "$target" ]]; then
    log "Deleting ${rel}"
    rm -rf "$target"
  else
    log "Skip missing ${rel}"
  fi
done

for rel in "${KEEP_PATHS[@]}"; do
  [[ -e "${EXTRACT_DIR}/${rel}" ]] || die "expected path missing after strip: ${rel}"
done

log "Regenerating DEBIAN/md5sums"
regenerate_md5sums "$EXTRACT_DIR"
regenerate_installed_size "$EXTRACT_DIR"

prove_control "$control"
prove_warp_cli "${EXTRACT_DIR}/bin/warp-cli"
prove_warp_svc "${EXTRACT_DIR}/bin/warp-svc"

out_deb="${ROOT}/${OUTPUT_PACKAGE}_${upstream_version}_amd64.deb"
log "Building ${out_deb}"
rm -f "$out_deb"
dpkg-deb -b "$EXTRACT_DIR" "$out_deb"

log "Built $(basename "$out_deb") ($(wc -c <"$out_deb") bytes)"
log "Done."
