pkgname=cloudflare-warp-headless
pkgver=2026.8.2115.0
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
source=('cloudflare-warp-headless_trixie_amd64.deb')
noextract=('cloudflare-warp-headless_trixie_amd64.deb')
sha256sums=('4f850e71540cc784c3d1fa6226d7e30976e393e39d3cc5255d91276686b401f1')

prepare() {
  mkdir -p extract
  bsdtar -xf 'cloudflare-warp-headless_trixie_amd64.deb'
  bsdtar -xf data.tar.zst -C extract
}

package() {
  local bin
  for bin in warp-cli warp-svc warp-diag warp-dex; do
    install -Dm755 "extract/bin/${bin}" "${pkgdir}/usr/bin/${bin}"
  done
  install -Dm644 extract/lib/systemd/system/warp-svc.service \
    "${pkgdir}/usr/lib/systemd/system/warp-svc.service"
  ln -s libpcap.so.1 "${pkgdir}/usr/lib/libpcap.so.0.8"
}
