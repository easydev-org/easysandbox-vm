# easysandbox-vm

A **native Linux desktop** in a QEMU/KVM guest, exposed to the AgentWorker
platform as a sandbox. Two flavors:

| flavor | desktop | display | golden disk |
|---|---|---|---|
| `gnome` | **GNOME 49** (`gnome-core`) | Wayland | `golden-linux-desktop/v17` |
| `kde`   | **KDE Plasma 6.3** (`kde-plasma-desktop`) | Wayland | `golden-linux-desktop/v23` |

Both are Debian trixie's **own** desktops, not vendor respins.

## Why a VM instead of a container

`gnome-session` / `mutter` need a **session manager with `systemd-logind`**:
they take control of their own logind session and become **DRM master** to drive
the display. A container has neither, so GNOME either refuses to start
(`Failed to find any matching session`, `not a graphical session`) or runs
headless (`No seat assigned, running headlessly`) and never draws to the GPU.

A VM provides the real thing, and the desktop is Debian's **own** GNOME — not a
vendor respin.

## How it is put together

```
  container (this image)                       guest (golden qcow2)
  ─────────────────────                        ────────────────────
  qemus/qemu base + KVM
    golden-disk.sh  ── downloads the disk ───▶  boots Debian trixie
    nginx :8090     ── /oem.sh, /worker,   ◀──  bootstrap.sh (the only launch
                       /easystream, /env          file on the disk) fetches
    nginx :8006     ── noVNC (one-time          /oem.sh and runs it
                       screen-share grant)       → GDM autologin → GNOME
                                                 Wayland → easystream + worker
```

* **The golden disk is pre-baked** and published to the artifact store. It
  carries the OS, GNOME, the seeded portal ScreenCast grant/token, and
  `bootstrap.sh` — **no launch logic**. Changing how the desktop starts is an
  *image* change (`oem.sh` lives here), never a rebake.
* **The guest binaries** (`easyworker`, `easystream`) are boot-fetched from
  nginx on every start, so upgrading them is also just an image change.
* **Zero hostPath.** Everything is `service-deploy` + ConfigMap + artifact.

## Running it

```bash
./build.sh                 # build + push the image
```

Deploy it with the golden disk and a KVM request:

```bash
service-deploy name=gnomevm image=<image> kvm=true \
  env.GOLDEN_DISK_URL=http://artifact.../golden-linux-desktop/v17/desktop.qcow2 \
  env.USER_PORTS=48080,22
```

Then:

* `http://<svc>/easystream/a11y/screenshot` — a PNG of the desktop
* `http://<svc>/easystream/a11y/apps` — the AT-SPI application list
* `http://<svc>-vnc/...` — noVNC, only needed to grant screen sharing once

## Environment

Kept deliberately close to the windows/macos sandboxes. The only additions are
`APP=Linux`, `HOST=host.lan` (so the guest can resolve the container) and
`DISPLAY=web` (QEMU VNC + websocket, for the one-time noVNC grant).

See `DEVELOP.md` for the traps that cost the most time.
