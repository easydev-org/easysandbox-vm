# DEVELOP

## Build

```bash
./build.sh            # buildkit → skopeo push to the deploy registry
```

`build.sh` copies `Containerfile`, `oem.sh`, `default.conf`… into a temp context
and computes `ENTRY_HASH` over them. **That hash is not decoration**: buildkit
keys a `COPY` layer on the build args in scope, so without a changing arg it
reuses the OLD layer and the image keeps stale files. We shipped a stale
`oem.sh` and a stale nginx config that way, twice.

The runtime is **vendored** (`vendor/run/`, from the windows sandbox) with two
edits:

* `install.sh` ends by calling **`startLinux()`** (added) instead of
  `startWindows()`. It boots the pre-baked disk and never installs.
* **`samba.sh` is deleted** and its `. samba.sh` line removed from `entry.sh`.
  Upstream's samba setup calls `unix2dos`, which this base image lacks, and its
  failure aborts `entry.sh` **before `server.sh` runs** — so nginx never started
  and the guest could not fetch anything.

## Golden disk

Built by `bake/` (see `bake/README.md`). The disk carries the OS, GNOME, and
**`bootstrap.sh` only** — the loader that fetches `/oem.sh` from the container.
All launch logic lives in `oem.sh` here.

## Traps (each cost real time)

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
   screen" dialog that nobody can click. `bake/seed-screencast.sh` installs the
   PermissionStore table **and** `~/.config/screencast-token`; the token is
   replayed on every `SelectSources` and makes `Start` succeed silently.

The token is **not tied to the easystream binary**, so easystream can be
upgraded freely.

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
