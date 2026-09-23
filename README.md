# warp-cli-smol

Unofficial **headless** rebuild of the Cloudflare WARP Linux client.

Each CI run re-fetches the current **Debian trixie** `cloudflare-warp` amd64 package from [Cloudflare's public APT repo](https://pkg.cloudflareclient.com) (`dists/trixie/main/binary-amd64/Packages`), strips the GUI/taskbar bits, and emits:

```text
cloudflare-warp-headless_<upstream-version>_amd64.deb
```

The rebuilt package keeps `warp-cli`, `warp-svc`, and `warp-svc.service`. It drops desktop-file, AppIndicator, and WebKit dependencies, plus the taskbar/Flutter tree.

This is the Debian trixie package only (`pool/trixie/...`). Cloudflare also publishes bookworm, jammy, noble, and other suites; those are different `.deb`s (different Depends, including t64 vs non-t64 names) and are not used.

This is not an official Cloudflare package.

## Download the Actions artifact and install it

`.deb` files are **CI artifacts only**. They are never committed to this repo and are never attached to GitHub Releases.

1. Open the [Actions](../../actions) tab.
2. Select the **Repack headless WARP** workflow.
3. Open the latest successful run (manual `workflow_dispatch`, or the Monday 06:00 UTC schedule).
4. Download the `cloudflare-warp-headless` artifact and unzip it.
5. Install that file only:

```bash
sudo dpkg -i cloudflare-warp-headless_*_amd64.deb
sudo apt-get install -f   # only if dpkg reports missing Depends
```

**Do not** install the official package afterwards:

```bash
# Do NOT run this. It pulls the full GUI client and fights this package.
sudo apt-get install cloudflare-warp
```

Do not add Cloudflare's APT repo and `apt-get install cloudflare-warp` on the same machine. That replaces or conflicts with the headless binaries (`/bin/warp-cli`, `/bin/warp-svc`).

## What CI does

- `ubuntu-latest`, on `workflow_dispatch` and weekly Monday 06:00 UTC.
- Installs `dpkg-dev` and `binutils`.
- Runs `./repack.sh` against the Debian trixie index, which fails the job if Filename is not under `pool/trixie/` or if any proof fails:
  1. New control has no `webkit` and no `appindicator`.
  2. `readelf -d` on `bin/warp-cli` `NEEDED` is only `libc`, `libm`, `libgcc_s`.
  3. `readelf -d` on `bin/warp-svc` does not show webkit or gtk.
- Uploads the `.deb` with `actions/upload-artifact` (`retention-days: 14`).

There is no release-create step.

## Local rebuild

```bash
sudo apt-get install -y dpkg-dev binutils
./repack.sh
```

Work files land in `downloads/` and `work/` (gitignored). The output `.deb` is written to the repo root and is also gitignored.
