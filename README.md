# easysandbox-vm

A **native Linux desktop** in a QEMU/KVM guest, exposed to the AgentWorker
platform as a sandbox. Two flavors:

| flavor | desktop | display | golden disk |
|---|---|---|---|
| `gnome` | **GNOME 49** (`gnome-core`) | Wayland | `golden-linux-desktop/v17` |
| `kde`   | **KDE Plasma 6.3** (`kde-plasma-desktop`) | Wayland | `golden-linux-desktop/v23` |

Both are Debian trixie's **own** desktops, not vendor respins.

**The desktop is chosen by the golden disk, not by the image.** There is no
per-flavor image: one image plus one `GOLDEN_DISK_URL` is a complete sandbox.
The artifact store keeps ONE `desktop.qcow2` per version — there are no
`gnome/` or `kde/` subdirectories — so the version number is the only thing
that decides which desktop you get. Verified by booting each version and
inspecting the live session:

| version | desktop | evidence |
|---|---|---|
| `v17` | **GNOME 49** | `/usr/bin/gnome-shell`, `gnome-wayland.desktop`, `gnome-shell` running |
| `v23` | **KDE Plasma** | `/usr/bin/plasmashell`, `plasma.desktop`, `kwin_wayland` + `plasmashell` running |
| `v27` | **KDE Plasma** | same as v23 |
| `v1` (old default) | **neither** | 2.05 GB; no desktop installed, boots to a text console |

So a deployment named `gnomevm` that points at `v27` is **running KDE**. Pick
the URL for the desktop you actually want:

```sh
# GNOME
env.GOLDEN_DISK_URL=http://artifact.../golden-linux-desktop/v17/desktop.qcow2
# KDE
env.GOLDEN_DISK_URL=http://artifact.../golden-linux-desktop/v27/desktop.qcow2
```

`build.sh` defaults to the newest known-good disk (`GOLDEN_DISK_VERSION`,
currently 27) rather than `v1`, which had no desktop at all.

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
  env.USER_PORTS=48080,48078,22
```

**`USER_PORTS` must include 48078.** It is QEMU's port-forward list into the
guest: 48080 is the Go worker, but **48078 is easystream's HTTP/a11y surface** —
the thing a viewer and the `/a11y/*` calls actually talk to. Omit it and the
guest happily listens on 48078 while nothing in the pod can reach it
(connection refused). A ready-to-apply example is `deploy-gnomevm.yaml`.

Then:

* `http://<svc>/easystream/a11y/screenshot` — a PNG of the desktop
* `http://<svc>/easystream/a11y/apps` — the AT-SPI application list
* `http://<svc>-vnc/...` — noVNC, only needed to grant screen sharing once

## Environment

Kept deliberately close to the windows/macos sandboxes. The only additions are
`APP=Linux`, `HOST=host.lan` (so the guest can resolve the container) and
`DISPLAY=web` (QEMU VNC + websocket, for the one-time noVNC grant).

## Two traps this image had

**1. The boot monitor only recognised Windows.** `vendor/run/` is the vendored
runtime shared with the windows/macos images, and its `bootStatus` matched only
`UEFI_WINDOWS_BOOT_PATTERN` — `BdsDxe: starting … "Windows Boot Manager" …`.
A Linux guest boots GRUB (or systemd-boot), so the pattern never matched, the
monitor decided the guest had not booted, killed a perfectly healthy QEMU at
its deadline, and the container exited 0 → systemd restarts → **the pod was
restarting every ~2 minutes** while the desktop inside it was fine. Fixed by
also accepting any UEFI hard-disk boot (`UEFI_HD_BOOT_PATTERN`).

**2. easystream ran unauthenticated.** `oem.sh` started the daemon via
`su -l "$USER" -c "… exec easystream serve"` and never passed a control token,
so anyone who could reach `:48079`/`:48078` could drive the guest. The token
now travels `/env → oem.sh → the su command line`:
`EAZYSTREAM_CONTROL_TOKEN` (= the worker's own token) and an empty
`EAZYSTREAM_VIEW_TOKEN` — control needs the token, view stays open.

See `DEVELOP.md` for the traps that cost the most time.
