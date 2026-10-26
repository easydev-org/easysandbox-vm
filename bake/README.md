# Baking the golden disks

The guest disk is **pre-baked once per desktop** and published to the artifact
store; the image only downloads it (`../golden-disk.sh`). Rebaking is needed
only when the OS or the desktop changes - a change to how the desktop *starts*
belongs in `../oem-nixos.sh`.

## Two steps, not one install per desktop

```
step 1   bake-nixos-minimal.sh
         official NixOS ISO -> plain NixOS. No desktop, no sandbox pieces.
         ~5 minutes, 1.84 GiB. -> nixos-base.qcow2 (an artifact)

step 2   derive.sh, once per desktop
         boot the base disk, drop in configuration-desktop.nix,
         nixos-rebuild boot, nix-collect-garbage -d
         -> nixos-<desktop>.qcow2
```

The base is built once and reused. That is the whole point: `nixos-install`
copies and unpacks a NixOS closure and takes minutes per disk, while
`nixos-rebuild` on an already-installed system only has to add the desktop.

The two steps differ in one more way that matters: `nixos-install` reads the
ISO's own store and needs **no network**, while `nixos-rebuild` downloads the
desktop closure from **cache.nixos.org**. A bake that cannot reach the cache
fails in step 2 and not in step 1 - that is the difference the two scripts make
visible.

`configuration-desktop.nix` **imports** `configuration-minimal.nix`, so a
derived disk keeps the filesystems, bootloader and user the base was installed
with. Replacing the file without the import would produce a disk that cannot
boot.

## Six desktops

`DESKTOP` is substituted into `configuration-desktop.nix` at derive time:

| desktop | display manager | notes |
|---|---|---|
| `labwc` | greetd | wlroots; the only one with no session package of its own |
| `gnome` | gdm | |
| `kde` | sddm | |
| `cosmic` | cosmic-greeter | |
| `hyprland` | sddm | |
| `miracle` | sddm | Mir; no portal backend yet |

Wayland throughout. `labwc`, `hyprland` and `miracle-wm` ship no display
manager, but the first registers no session either, so it gets greetd handed a
raw command while the other two use the `sessionPackages` their modules
register.

## What is on a disk

```nix
environment.systemPackages = [ wl-clipboard kitty ];
```

Two tools and nothing else: no autostart, no launcher unit, no diagnostic
service, no sandbox daemon. A gold disk is a stock desktop. Anything that has to
run at boot is a separate layer applied later, by whoever builds their own
image.

## Verifying a bake

`nixos/smoke.sh` boots a produced disk and is the only thing that turns "it
booted" into "it painted a desktop":

* waits for `Reached target Login Prompts` (NixOS never prints
  `Reached target Multi-User System`, so waiting for that hangs),
* opens a terminal over the serial console - the test starting a client, not the
  image shipping one,
* takes a screenshot and rejects a blank framebuffer,
* checks the display manager started and a user session exists.

A compositor with no client paints a flat background, so a low colour count is
not by itself a failure - the check tolerates a nearly-uniform screen and relies
on the colour count instead.

## Workflow

`.github/workflows/bake-nixos.yml` runs base (once) then derive (per desktop,
in parallel), and can reuse a base artifact from an earlier run so that adding a
desktop does not rebake the base:

```yaml
mode: derive
base_artifact_id: <id from an earlier run>
base_run_id: <that run>
```

`.github/workflows/smoke-nixos-disk.yml` re-tests an existing disk in a few
minutes, so a change to the harness does not cost a full derive.
