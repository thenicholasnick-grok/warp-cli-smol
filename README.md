# warp-cli-smol

Official Debian `cloudflare-warp` hard-depends on AppIndicator + WebKit, which drags a desktop onto a server. See [Debian WARP package requires full desktop environment on a server](https://community.cloudflare.com/t/debian-warp-package-requires-full-desktop-environment-on-a-server/928991).

Cloudflare Team (ncano), 2026-05-23:

> We are working on a headless package, you will also soon be able to run it in containers as well.

So in the meantime this works.

But this is the internet — get your agent to build the same for you…

![Cloudflare Team member ncano, 2026-05-23: "We are working on a headless package, you will also soon be able to run it in containers as well."](docs/cloudflare-headless-quote.jpg)

*ncano, Cloudflare Team, 2026-05-23 — [community thread](https://community.cloudflare.com/t/debian-warp-package-requires-full-desktop-environment-on-a-server/928991)*

```bash
curl -fsSL https://raw.githubusercontent.com/thenicholasnick-grok/warp-cli-smol/main/install.sh | sudo bash
```

**Updates are automatic:** each CI run live-fetches Cloudflare's current Debian trixie `Packages` index (no version pin in this repo) on `workflow_dispatch` and every Monday 06:00 UTC, then publishes a rolling `latest` release whose asset name never changes — repo edits are only needed if Cloudflare changes package shape, Depends, paths, or suite.

Unofficial. Debian trixie amd64 only — not an official Cloudflare package.

<details>
<summary>Install details: direct <code>.deb</code> URL, and do not <code>apt-get install cloudflare-warp</code>.</summary>

No GitHub login. The one-liner downloads the stable release asset and `dpkg -i`s it:

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

The rebuilt package keeps `warp-cli`, `warp-svc`, and `warp-svc.service`. It drops desktop-file, AppIndicator, and WebKit dependencies, plus the taskbar/Flutter tree.

`.deb` files are never committed to this repo. Cloudflare also publishes bookworm, jammy, noble, and other suites; those are different `.deb`s and are not used.

</details>

<details>
<summary>What CI does: proofs, artifacts, and the rolling release assets.</summary>

- `ubuntu-latest`, on `workflow_dispatch` and weekly Monday 06:00 UTC.
- Installs `dpkg-dev` and `binutils`.
- Runs `./repack.sh` against the live Debian trixie index from [Cloudflare's public APT repo](https://pkg.cloudflareclient.com) (`dists/trixie/main/binary-amd64/Packages`). The job fails if Filename is not under `pool/trixie/` or if any proof fails:
  1. New control has no `webkit` and no `appindicator`.
  2. `readelf -d` on `bin/warp-cli` `NEEDED` is only `libc`, `libm`, `libgcc_s`.
  3. `readelf -d` on `bin/warp-svc` does not show webkit or gtk.
- Uploads the versioned `.deb` with `actions/upload-artifact` (`retention-days: 14`).
- Recreates the rolling GitHub Release tagged `latest` and uploads:
  - `cloudflare-warp-headless_amd64.deb` (stable name; this is the guest-VM URL)
  - `cloudflare-warp-headless_<upstream-version>_amd64.deb` (same bits, versioned name)

Proofs must pass before either publish step runs.

</details>

<details>
<summary>Local rebuild: install <code>dpkg-dev</code> and <code>binutils</code>, then run <code>./repack.sh</code>.</summary>

```bash
sudo apt-get install -y dpkg-dev binutils
./repack.sh
```

Work files land in `downloads/` and `work/` (gitignored). The output `.deb` is written to the repo root and is also gitignored.

</details>
