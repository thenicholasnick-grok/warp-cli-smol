# warp-cli-smol

Official Debian `cloudflare-warp` now hard-depends on AppIndicator + WebKit, which drags a desktop onto a server. See [Debian WARP package requires full desktop environment on a server](https://community.cloudflare.com/t/debian-warp-package-requires-full-desktop-environment-on-a-server/928991).

![Cloudflare: working on a headless package](docs/cloudflare-headless-quote.png)

Cloudflare Team, on that thread:

> We are working on a headless package, you will also soon be able to run it in containers as well.

So in the meantime this works.

But this is the internet — get your agent to build the same for you…

```bash
curl -fsSL https://raw.githubusercontent.com/thenicholasnick-grok/warp-cli-smol/main/install.sh | sudo bash
```

Unofficial **headless** rebuild of the Cloudflare WARP Linux client. Each CI run re-fetches the current **Debian trixie** `cloudflare-warp` amd64 package from [Cloudflare's public APT repo](https://pkg.cloudflareclient.com) (`dists/trixie/main/binary-amd64/Packages`), strips the GUI/taskbar bits, and publishes a rolling GitHub Release guests can `curl` without logging in.

The rebuilt package keeps `warp-cli`, `warp-svc`, and `warp-svc.service`. It drops desktop-file, AppIndicator, and WebKit dependencies, plus the taskbar/Flutter tree.

This is the Debian trixie package only (`pool/trixie/...`). Cloudflare also publishes bookworm, jammy, noble, and other suites; those are different `.deb`s (different Depends, including t64 vs non-t64 names) and are not used.

This is not an official Cloudflare package.

## Install on a guest VM

That one-liner is the install. No GitHub login. It downloads the stable release asset and `dpkg -i`s it:

```text
https://github.com/thenicholasnick-grok/warp-cli-smol/releases/latest/download/cloudflare-warp-headless_amd64.deb
```

Direct one-liner without the script:

```bash
curl -fsSL -o /tmp/cloudflare-warp-headless_amd64.deb \
  https://github.com/thenicholasnick-grok/warp-cli-smol/releases/latest/download/cloudflare-warp-headless_amd64.deb \
  && sudo dpkg -i /tmp/cloudflare-warp-headless_amd64.deb
```

**Do not** install the official package afterwards:

```bash
# Do NOT run this. It pulls the full GUI client and fights this package.
sudo apt-get install cloudflare-warp
```

Do not add Cloudflare's APT repo and `apt-get install cloudflare-warp` on the same machine. That replaces or conflicts with the headless binaries (`/bin/warp-cli`, `/bin/warp-svc`).

`.deb` files are never committed to this repo. The rolling `latest` release is rebuilt by CI after proofs pass. Actions artifacts (14-day retention) remain a secondary copy.

## What CI does

- `ubuntu-latest`, on `workflow_dispatch` and weekly Monday 06:00 UTC.
- Installs `dpkg-dev` and `binutils`.
- Runs `./repack.sh` against the Debian trixie index, which fails the job if Filename is not under `pool/trixie/` or if any proof fails:
  1. New control has no `webkit` and no `appindicator`.
  2. `readelf -d` on `bin/warp-cli` `NEEDED` is only `libc`, `libm`, `libgcc_s`.
  3. `readelf -d` on `bin/warp-svc` does not show webkit or gtk.
- Uploads the versioned `.deb` with `actions/upload-artifact` (`retention-days: 14`).
- Recreates the rolling GitHub Release tagged `latest` and uploads:
  - `cloudflare-warp-headless_amd64.deb` (stable name; this is the guest-VM URL)
  - `cloudflare-warp-headless_<upstream-version>_amd64.deb` (same bits, versioned name)

Proofs must pass before either publish step runs.

## Local rebuild

```bash
sudo apt-get install -y dpkg-dev binutils
./repack.sh
```

Work files land in `downloads/` and `work/` (gitignored). The output `.deb` is written to the repo root and is also gitignored.
