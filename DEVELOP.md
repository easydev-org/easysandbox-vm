# DEVELOP

## Build

```bash
./build.sh            # buildkit → skopeo push to the deploy registry
```

`build.sh` copies `Containerfile`, `oem-nixos.sh`, `00-token.conf`… into a temp context
and computes `ENTRY_HASH` over them. **That hash is not decoration**: buildkit
keys a `COPY` layer on the build args in scope, so without a changing arg it
reuses the OLD layer and the image keeps stale files. We shipped a stale
launch script and a stale nginx config that way, twice.

The runtime is **vendored** (`vendor/run/`, from the windows sandbox) with two
edits:

* `install.sh` ends by calling **`startLinux()`** (added) instead of
  `startWindows()`. It boots the pre-baked disk and never installs.
* **`samba.sh` is deleted** and its `. samba.sh` line removed from `entry.sh`.
  Upstream's samba setup calls `unix2dos`, which this base image lacks, and its
  failure aborts `entry.sh` **before `server.sh` runs** — so nginx never started
  and the guest could not fetch anything.

## Golden disk

Built by `bake/nixos` (see `bake/README.md`). The disk carries NixOS and the
desktop, and **`bootstrap.sh` only** - the loader that fetches `/oem.sh` from
the container. All launch logic lives in `oem-nixos.sh` here.

Two steps, not one install per desktop:

```sh
bash bake/nixos/bake-nixos-minimal.sh   # ISO -> plain NixOS base (~5 min)
bash bake/nixos/derive.sh               # boot base, nixos-rebuild, GC
```

`derive.sh` needs network (cache.nixos.org); the minimal install does not (it
uses the ISO's own store). `nixos/base/smoke.sh` boots a produced disk, waits
for the session, screenshots it and rejects a blank framebuffer - the harness
that turns "it booted" into "it painted a desktop".

## Traps (each cost real time)

The upper half of this table is from the Debian bake this repository used to
have; the bottom rows are what the NixOS path taught us. Kept together because
the runtime and display traps apply to any guest.

| Symptom | Cause | Fix |
|---|---|---|
| `Starting Windows for Docker` | `APP` defaults to Windows | `APP=Linux` |
| `nginx: bind() to 8090 failed` | two listeners on one port | guest routes on **8090**, runtime web on its own port |
| `DETECTED: unbound variable` | `startLinux` skips the install path | set `DETECTED` |
| `Failed to get "write lock"` | `BOOT` pointed at the same qcow2 as the data disk, so QEMU attached it twice | `BOOT=""` |
| `No guest disk`/`unix2dos` | samba.sh | delete it |
| GNOME `Failed to setup` | **no `/dev/dri`**: the cloud kernel has no DRM driver for an emulated GPU | install `linux-image-amd64`, remove the cloud kernel's boot files (apt refuses to purge the *running* kernel), point GRUB at the full one |
| `No seat assigned, running headlessly` | starting `gnome-session` by hand gives no logind seat | let **GDM** start it, with autologin + a `wayland-sessions/*.desktop` |
| `Permission denied … ~/.local/share/gnome-shell` | `~/.local` owned by root | `chown -R docker:docker ~/.local` |
| black noVNC | QEMU VNC without the websocket proxy | keep the base image's own `default.conf`; put our routes in `conf.d/` |
| `mmap() failed: No such device` | `~/.local/share/flatpak/db` created as a *directory* | let the portal create it (the seeder writes the file) |
| KDE: no wayland socket, nothing starts | `kde-plasma-desktop` does **not** depend on `sddm` (Debian leaves the DM to the user) | list `sddm` explicitly and write `/etc/sddm.conf.d/autologin.conf` + `wayland-sessions/plasma.desktop` |
| `apt: Unable to locate package a b c` | `PKGS` was quoted, so the whole list became one name | expand `$PKGS` **unquoted** |
| `xdg-desktop-portal` has no `ScreenCast` | session is not graphical+Wayland (e.g. under `dbus-run-session`) | let the DM start the session so `graphical-session.target` is active |
| desktop paints nothing, no error | a compositor with **no client** is a flat background, and flat looks like failure | start a terminal before judging the screenshot; a colour count near 1 is the only real "blank" |
| SMOKE: "Reached target Multi-User System" never matches | NixOS does not print it - systemd only announces targets it is asked about | check `Reached target Login Prompts` and `Started <dm>.service` instead |
| SDDM lands on its login screen, autologin ignored | `services.displayManager.sddm.autoLogin` is a **rename source** in sddm.nix, not a setting | use the generic `services.displayManager.autoLogin` |
| niri runs but never paints | its TTY backend is `GbmGlesBackend<GlesRenderer>` on `primary_render_node`, so it needs `/dev/dri/renderD128`; QEMU only gives that with 3D acceleration, which needs EGL on the host | not fixable on a runner without libEGL - niri was dropped |
| `nix-instantiate --eval --strict` segfaults on a big closure | `--strict` forces the whole nested attribute set | drop `--strict`; `drvPath` is a string and still catches bad options and failed assertions |

## Portal ScreenCast (why it exists)

`zwlr_screencopy_manager_v1` is **wlroots-only**. kwin and mutter do not
implement it, so `Capture::Wl` cannot capture them. The portal is the only path
they offer; `src/portalshim.c` (in easystream) drives it:

```
CreateSession → SelectSources(MONITOR, persist_mode=2, restore_token)
              → Start → OpenPipeWireRemote(fd) → pw_stream → BGRA
```

Two things make this work headless:

1. **The session must be graphical + Wayland**, or `xdg-desktop-portal` does not
   even export `ScreenCast`. That means `gnome-session` under systemd (so
   `graphical-session.target` is active) — **not** `dbus-run-session`, which
   hides systemd and leaves the target inactive.
2. **The grant must be pre-seeded.** `Start` otherwise pops a "Share your
   screen" dialog that nobody can click. The Debian bake had a
   `seed-screencast.sh` that installed the PermissionStore table **and**
   `~/.config/screencast-token`, and the token was replayed on every
   `SelectSources` so `Start` succeeded silently.

   The NixOS desktops do not use the portal for capture at all: labwc, sway and
   hyprland go through `wlr-screencopy`, and cosmic, gnome and kde through
   libei. There is no consent dialog to seed. This section stays because it
   describes the containment runtime, and because a future desktop that does go
   through xdg-desktop-portal will hit it again.

The token is **not tied to the easystream binary**, so easystream can be
upgraded freely.

**Each portal backend stores its own table and its own token** in the same db,
so the seed had to be per-flavor. KDE's dialog needed "Allow restoring on future
sessions" ticked to obtain its token; GNOME's grant was answered once too, but
GNOME reuses a token across a fresh session.

### PipeWire negotiation gotchas

* Offer **`BGRx`** as well as `BGRA` — GNOME advertises BGRx; a BGRA-only offer
  fails with `no more input formats`.
* Ask for **framerate `{0,1}`** ("any"). The node advertises `{0,1}`; a fixed
  `30/1` does not match and fails the same way.
* The portal **returns** the request object path — use it. Guessing it means the
  `Response` signal never matches and the call blocks forever.
* Add a `Response` **match rule**, or the bus filters the signal out.
* Every `{sv}` value must be wrapped in a variant; build them with
  `dict_add_str/u32/bool`, not by hand.
* `handle_token`s must be unique per request (a counter, not the pid).
