# easysandbox-vm

A **native Linux desktop** in a QEMU/KVM guest, exposed to the AgentWorker
platform as a sandbox.

Six flavors, all NixOS, all Wayland:

| desktop | display manager | disk |
|---|---|---|
| `labwc` | greetd | `nixos-labwc.qcow2` |
| `gnome` | gdm | `nixos-gnome.qcow2` |
| `kde` | sddm | `nixos-kde.qcow2` |
| `cosmic` | cosmic-greeter | `nixos-cosmic.qcow2` |
| `hyprland` | sddm | `nixos-hyprland.qcow2` |
| `miracle` | sddm | `nixos-miracle.qcow2` |

Every one was verified by booting the disk and looking at the screen: the
harness screenshots the guest and rejects a blank framebuffer, so the claim is
not "it booted" but "it painted a desktop".

## How the disks are built

`bake/nixos` builds them in two steps rather than one `nixos-install` per
desktop:

```
step 1  bake-nixos-minimal.sh + configuration-minimal.nix
        ISO -> plain NixOS: no desktop, no sandbox pieces. ~5 min, 1.84 GiB.
        -> nixos-base.qcow2, published as an artifact

step 2  derive.sh + configuration-desktop.nix, once per desktop
        boot the base disk, replace configuration.nix, nixos-rebuild boot,
        nix-collect-garbage -d
        -> nixos-<desktop>.qcow2
```

The base is built once and reused, so adding a desktop is a rebuild, not a full
install. `configuration-desktop.nix` imports the minimal one, which is why each
derived disk still carries the filesystems, bootloader and user the base was
installed with.

`nixos-rebuild` needs the network - the desktop closure comes from
cache.nixos.org - while `nixos-install` does not, because it uses the ISO's own
store. That difference is why the two steps are separate scripts.

## What is on a disk, and what is not

A derived disk is a stock desktop and nothing else:

```nix
environment.systemPackages = [ wl-clipboard kitty ];
```

Two tools, no autostart, no launcher unit, no sandbox daemon. Anything that has
to run at boot is layered on later by whoever builds their image; that is the
separate startup step, and it is deliberately not baked in here.

**The desktop is chosen by the golden disk, not by the image.** There is no
per-flavor image: one image plus one `GOLDEN_DISK_URL` is a complete sandbox.
The artifact store keeps one qcow2 per desktop - there are no per-desktop
subdirectories - so the URL is the only thing that decides which desktop you get.

```sh
env.GOLDEN_DISK_URL=http://artifact.../nixos-disks/gnome.qcow2
env.GOLDEN_DISK_URL=http://artifact.../nixos-disks/kde.qcow2
```

`build.sh` takes `GOLDEN_DISK` (default `labwc`) and builds the default URL from
it.

## What was removed

The Debian path is gone: `install-desktop.sh` (apt `gnome-core` /
`kde-plasma-desktop`), `cloud-init.yaml`, `bootstrap.sh`, `oem.sh`, the two
`seed-*.sh` portal-permission scripts, and `fetch-golden.sh`, which pulled the
Debian disks from an OCI mirror.

The NixOS path replaced all of it. One minimal base plus `nixos-rebuild` is
cheaper to maintain than two independent bake pipelines, and it gives every
desktop a shared base instead of a fresh install each time.

`oem-nixos.sh` survives and is the launch logic for all six desktops.

## Why a VM instead of a container

Every desktop here needs a **session manager with `systemd-logind`**: it takes
control of its own logind session and becomes **DRM master** to drive the
display. A container has neither, so the desktop either refuses to start
(`Failed to find any matching session`, `not a graphical session`) or runs
headless (`No seat assigned, running headlessly`) and never draws.

A VM provides the real thing: its own kernel, its own PID 1, and a real seat.
That is also why a VM can run hyprland, cosmic and miracle-wm, which a container
could not seat at all.

## How it is put together

```
  container (this image)                       guest (golden qcow2)
  ─────────────────────                        ────────────────────
  qemus/qemu base + KVM
    golden-disk.sh  ── downloads the disk ───▶  boots NixOS
    nginx :8090     ── /oem.sh, /worker,   ◀──  bootstrap.sh (the only launch
                       /easystream, /env          file on the disk) fetches
                                                 /oem.sh and runs it
                                                 → display manager autologin
                                                 → compositor → easystream
                                                 + easyworker
```

* **The golden disk is pre-baked** and published to the artifact store. It
  carries the OS, the desktop, and `bootstrap.sh` - **no launch logic**.
  Changing how the desktop starts is an *image* change (`oem-nixos.sh` lives
  here), never a rebake.
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
  env.GOLDEN_DISK_URL=http://artifact.../nixos-disks/gnome.qcow2 \
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

### Services: one per surface, three per sandbox

Every desktop sandbox needs **three** Services, exactly like windows/macos
(`deploy-gnomevm.yaml` + `svc-gnomevm.yaml` are a working pair; the kdevm files
are the KDE copies):

| Service | port | targetPort | what |
|---|---|---|---|
| `<name>` | 80 | **48080** | the Go worker: RPC + control panel |
| `<name>-web` | 80 | **48078** | easystream: video/input stream, `/a11y/*`, its webui |
| `<name>-vnc` | 80 | **8006** | QEMU's VNC websocket (only for the one-time screen-share grant) |

Verified live (KDE + GNOME both):

```
gnomevm        :80/health     -> 200
gnomevm-web    :80/a11y/apps  -> 200  ':1.0  gnome-shell …'
gnomevm-vnc    :80/           -> 200  (noVNC page, 19.8 KB)
kdevm          :80/health     -> 200
kdevm-web      :80/a11y/apps  -> 200  ':1.0  ksmserver …'
kdevm-vnc      :80/           -> 200  (noVNC page, 19.8 KB)
```

Skipping `<name>-web` is the common mistake: the desktop works over VNC but
every `/a11y` call and the est stream fail, because nothing routes 48078.

## Environment

Kept deliberately close to the windows/macos sandboxes. The only additions are
`APP=Linux`, `HOST=host.lan` (so the guest can resolve the container) and
`DISPLAY=web` (QEMU VNC + websocket, for the one-time noVNC grant).

## Three traps this image had

These were found on the Debian bake that this repository used to have. The
NixOS path replaced it, but the traps are written down because each one cost
hours and two of them are about the container runtime rather than the desktop -
so they would come back for any guest, NixOS included.

**0. GNOME booted to a black 640x480 screen.** The bake wrote its own
`/usr/share/wayland-sessions/gnome.desktop` with
`Exec=gnome-session --session gnome`, and GDM's autologin picked it. That form
**deadlocks**: `--session gnome` makes gnome-session wait for every
`RequiredComponents` entry — `org.gnome.Shell` first — to appear on D-Bus, but
starting the shell is gnome-session's own job, and the shell cannot start until
a compositor has created a `WAYLAND_DISPLAY`. Nothing progresses, so no
compositor sets a mode and QEMU sits at its 640x480 default, black.

Shipping the distro's own session entry fixes it - verified in a live guest:
640x480/black to **1024x768 with a rendered desktop**. The lesson outlived the
Debian path: do not hand-write a session file when one already exists.

**1. The boot monitor only recognised Windows.** `vendor/run/` is the vendored
runtime shared with the windows/macos images, and its `bootStatus` matched only
`UEFI_WINDOWS_BOOT_PATTERN` — `BdsDxe: starting … "Windows Boot Manager" …`.
A Linux guest boots GRUB (or systemd-boot), so the pattern never matched, the
monitor decided the guest had not booted, killed a perfectly healthy QEMU at
its deadline, and the container exited 0 → systemd restarts → **the pod was
restarting every ~2 minutes** while the desktop inside it was fine. Fixed by
also accepting any UEFI hard-disk boot (`UEFI_HD_BOOT_PATTERN`).

**2. easystream ran unauthenticated.** The launch script started the daemon
without a control token, so anyone who could reach `:48079`/`:48078` could drive
the guest. The token now travels `/env → oem-nixos.sh → the daemon command line`:
`EAZYSTREAM_CONTROL_TOKEN` (= the worker's own token) and an empty
`EAZYSTREAM_VIEW_TOKEN` — control needs the token, view stays open.

See `DEVELOP.md` for the traps that cost the most time.
