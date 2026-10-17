# Baking the golden disk

The guest disk is **pre-baked once** and published to the artifact store; the
image only downloads it (`golden-disk.sh`). Rebaking is needed only when the
**OS or the desktop packages** change — a change to how the desktop *starts*
belongs in `../oem.sh`.

## What goes on the disk

1. **Debian trixie cloud image** as the base.
2. `install-desktop.sh` installs **`gnome-core`** (Debian's own minimal GNOME,
   Wayland only), the **full kernel**, the DRM/firmware packages, and the
   runtime libraries `easystream` links (including `libxcb-xtest0`).
3. `seed-screencast.sh` installs the portal's **ScreenCast grant + restore
   token**, so screen capture works with no dialog.
4. **`bootstrap.sh`** — the only launch file. It fetches `/oem.sh` from the
   container and runs it, so launch logic never needs a rebake.

## How it is run

`service-deploy` a `qemus/qemu` container with `kvm=true`, a `vmbake-script`
ConfigMap holding `bake.sh`, and a `vmbake-ci` ConfigMap holding the cloud-init
`user-data`/`meta-data` (see `cloud-init.yaml`). The bake boots the cloud image
with that seed, installs everything, powers off, and PUTs the qcow2 to
`artifacts/generic/golden-linux-desktop/<version>/desktop.qcow2`.

## Hard-won details

* **Keep the cloud-init YAML trivial.** An embedded multi-line script once
  failed cloud-init's schema validation and the install was silently skipped.
  Anything substantial is fetched from the artifact store instead.
* **The guest needs a real GPU device**, but `/dev/dri` only appears if the
  **full** kernel is booted: `linux-image-cloud-amd64` has no DRM driver for an
  emulated GPU. `apt` refuses to purge the *running* kernel, so we delete the
  cloud kernel's `/boot` files and point GRUB at the full one.
* **The NIC is renamed** (`eth0` → `enp0s2`) and Debian's `systemd-networkd`
  only configures interfaces it has a file for — the guest came up with no
  address and no route. Ship `/etc/systemd/network/10-eth.network` matching
  `en*` with `DHCP=yes`.
* **`~/.local` must belong to `docker`**, or gnome-shell fails with
  `Permission denied` on `~/.local/share/gnome-shell`.
* **The portal's `PermissionStore` needs its db to be a *file*.** Creating
  `~/.local/share/flatpak/db` as a directory made it fail with
  `mmap() failed: No such device`.
* **The session must be started by GDM** (with autologin). Starting
  `gnome-session` by hand yields no logind seat, mutter goes headless, and
  nothing is drawn to the GPU (a black noVNC).

## Rebaking

```bash
service-deploy name=vmbake2 image=<qemus/qemu> kvm=true \
  command='["/bin/bash","/opt/bake/bake.sh"]' \
  config-mounts='[{"config-map":"vmbake-script","mount-path":"/opt/bake"},{"config-map":"vmbake-ci","mount-path":"/ci"}]' \
  env.GOLDEN_VER=v18 ...
```

The scripts in this directory are the source of truth for what gets installed;
publish them to
`artifacts/generic/golden-linux-desktop/scripts/` (the bake fetches them there)
before starting a bake.
