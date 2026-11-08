#!/usr/bin/env bash
# Build an Arch package from the trixie headless .deb this job already produced.
# Does not fetch Cloudflare and does not run repack.sh.
#
# Usage: arch-wrap.sh <cloudflare-warp-headless_trixie_<version>_amd64.deb> [outdir]
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 || $# -eq 2 ]] || die "usage: arch-wrap.sh <trixie-deb> [outdir]"
command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required"
command -v makepkg >/dev/null 2>&1 || die "makepkg is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

deb="$(readlink -f "$1")"
outdir="$(readlink -f "${2:-$PWD}")"
[[ -s "$deb" ]] || die "deb is missing or empty: $1"
[[ -d "$outdir" ]] || die "outdir is not a directory: $outdir"

base="$(basename "$deb")"
[[ "$base" == cloudflare-warp-headless_trixie_*_amd64.deb ]] \
  || die "expected a versioned trixie deb, got ${base}"

control_text() {
  local member
  for member in control.tar.zst control.tar.xz control.tar.gz control.tar; do
    if bsdtar -tf "$deb" "$member" >/dev/null 2>&1; then
      bsdtar -xOf "$deb" "$member" | bsdtar -xOf - ./control
      return 0
    fi
  done
  return 1
}

control="$(control_text)" || die "could not read Debian control from ${base}"
pkgver="$(printf '%s\n' "$control" | awk -F': ' '/^Version: / { print $2; exit }')"
[[ -n "$pkgver" ]] || die "Debian control has no Version"
[[ "$pkgver" =~ ^[0-9A-Za-z._+]+$ ]] || die "Debian version is not an Arch pkgver: ${pkgver}"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
alias_name="cloudflare-warp-headless_trixie_amd64.deb"
cp -f "$deb" "${build}/${alias_name}"
if ! cmp -s "$deb" "${build}/${alias_name}"; then
  die "alias copy is not the input deb"
fi

sha="$(sha256sum "${build}/${alias_name}" | awk '{ print $1 }')"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash ${alias_name}"

listing="$(bsdtar -xOf "${build}/${alias_name}" data.tar.zst | bsdtar -tf -)"
for rel in bin/warp-cli bin/warp-svc bin/warp-diag bin/warp-dex lib/systemd/system/warp-svc.service; do
  printf '%s\n' "$listing" | grep -qxE "(\./)?${rel}" || die "trixie deb is missing ${rel}"
done

cat >"${build}/cloudflare-warp-headless.install" <<'EOF'
post_install() {
  setcap cap_setuid,cap_setgid,cap_net_raw,cap_dac_read_search,cap_net_admin,cap_net_bind_service,cap_sys_ptrace+ei /usr/bin/warp-svc
}

post_upgrade() {
  post_install
}

pre_remove() {
  systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
}
EOF

cat >"${build}/PKGBUILD" <<EOF
pkgname=cloudflare-warp-headless
pkgver=${pkgver}
pkgrel=1
pkgdesc='Headless Cloudflare WARP client binaries from the Debian trixie repack'
arch=('x86_64')
url='https://github.com/thenicholasnick-grok/warp-cli-smol'
license=('LicenseRef-unknown')
depends=(
  'ca-certificates'
  'dbus'
  'glibc>=2.39'
  'gnupg'
  'iproute2'
  'libcap'
  'libgcc'
  'libpcap'
  'nftables'
  'nss'
  'systemd'
  'tpm2-tss'
)
provides=('warp-cli' 'warp-svc' 'warp-diag' 'warp-dex')
conflicts=(
  'cloudflare-warp'
  'cloudflare-warp-bin'
  'cloudflare-warp-nox-bin'
  'cloudflare-warp-minimal-bin'
)
options=('!strip' '!debug')
install=cloudflare-warp-headless.install
source=('${alias_name}')
noextract=('${alias_name}')
sha256sums=('${sha}')

prepare() {
  mkdir -p extract
  bsdtar -xf '${alias_name}'
  bsdtar -xf data.tar.zst -C extract
}

package() {
  local bin
  for bin in warp-cli warp-svc warp-diag warp-dex; do
    install -Dm755 "extract/bin/\${bin}" "\${pkgdir}/usr/bin/\${bin}"
  done
  install -Dm644 extract/lib/systemd/system/warp-svc.service \\
    "\${pkgdir}/usr/lib/systemd/system/warp-svc.service"
  ln -s libpcap.so.1 "\${pkgdir}/usr/lib/libpcap.so.0.8"
}
EOF

if grep -q SKIP "${build}/PKGBUILD"; then
  die "PKGBUILD must not publish SKIP checksums"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  # makepkg -f --noconfirm refuses to build while these runtime depends are absent.
  pacman -Sy --noconfirm --needed \
    ca-certificates dbus glibc gnupg iproute2 libcap libgcc libpcap nftables nss systemd tpm2-tss
  id builder >/dev/null 2>&1 || useradd --create-home --user-group builder
  chown -R builder:builder "$build"
  runuser -u builder -- bash -c "cd $(printf '%q' "$build") && makepkg -f --noconfirm"
else
  (cd "$build" && makepkg -f --noconfirm)
fi

pkg="${build}/cloudflare-warp-headless-${pkgver}-1-x86_64.pkg.tar.zst"
[[ -s "$pkg" ]] || die "makepkg did not write $(basename "$pkg")"

cp -f "$pkg" "${outdir}/"
cp -f "${build}/PKGBUILD" "${build}/cloudflare-warp-headless.install" "${outdir}/"
printf 'Arch package: %s\npkgver: %s\nsha256: %s\n' \
  "$(basename "$pkg")" "$pkgver" "$sha"
