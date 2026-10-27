# Baking the golden disks

One qcow2 per desktop, built once, published as an image, embedded in the VM
image. Rebaking is needed only when the OS or the desktop changes - a change to
how the desktop *starts* belongs in `../oem-nixos.sh`.

## Five distributions, one skeleton

```
bake/lib/qemu-bake.sh        boot a VM, tee the console, watchdog, compress
bake/lib/lint-kickstart.py   the two kickstart mistakes that cost a bake
bake/lib/lint-preseed.py     the preseed mistakes that cost a bake
bake/lib/lint-autoyast.py    the schema mistakes that cost a bake
bake/lib/test-watchdog.sh    the watchdog's own test - no KVM needed
bake/lib/test-volid.py       the ISO9660 volume-label reader
bake/lib/selftest-image.sh   can this container run a bake at all
bake/Containerfile.runner    qemux/qemu:7.50 with the entrypoint cleared
bake/nixos/                  ISO + typed install, then nixos-rebuild per desktop
bake/ubuntu/                 ISO + autoinstall (subiquity fetches user-data)
bake/fedora/                 ISO + kickstart  (anaconda fetches ks.cfg)
bake/debian/                 ISO + preseed     (debian-installer fetches preseed.cfg)
bake/opensuse/               DVD + AutoYaST    (YaST fetches autoinst.xml)
bake/cachyos/                live ISO + cachyos-installer --config (headless JSON)
```

The lib holds only what is not a distribution: `bake_qemu_install` (qemu, tee,
heartbeat, stall watchdog), `bake_assert_installed`, `bake_compress_disk`,
`bake_install_tools`. The one hook is `BAKE_STDIN` - NixOS is installed by
typing into the serial console so it passes its fifo of commands; Ubuntu and
Fedora pass nothing and let the installer fetch its own configuration.

That is why this is a factoring rather than a union of six scripts. The six ways
of saying "install this":

| | installer | told what to install by |
|---|---|---|
| NixOS | `nixos-install` | commands typed at the serial console |
| Ubuntu | subiquity | `autoinstall ds=nocloud-net;s=http://10.0.2.2:8000/` |
| Fedora | anaconda | `inst.ks=http://10.0.2.2:8000/ks.cfg` |
| Debian | debian-installer | `auto=true priority=critical preseed/url=http://10.0.2.2:8000/preseed.cfg` |
| openSUSE | YaST | `autoyast=http://10.0.2.2:8000/autoinst.xml` |
| CachyOS | cachyos-installer | `--config settings.json` with `headless_mode: true` |

Two need a human at the console: NixOS types its install, and CachyOS runs its
installer from a live shell. The other four are told on the kernel command line
and never need one.

## What each one cost, and what it taught

Every entry here was found from the guest's own console output, not from reading
documentation first. They are recorded because each is a plausible-looking thing
that does not work:

| | wrong assumption | what is true |
|---|---|---|
| Fedora | `text` in a kickstart | also sets the installed system's default target to multi-user, so a desktop disk boots to a console |
| Fedora | `Installation complete` | anaconda signals success by rebooting; that string never appears |
| Debian | preseed takes line continuations | one instruction per line; a trailing `\` is literal |
| Debian | `in-target wget` | the target is a bare base system with no wget; fetch in the installer |
| Debian | `custom.conf` for gdm | Debian 13 ships `daemon.conf` |
| Debian | `update-grub` works in the chroot | it needs /proc and /sys, and fails silently without them |
| openSUSE | `autoyast2=install` | not a parameter; the kernel said "Unknown kernel command line parameters" |
| openSUSE | `<serial>` inside `<bootloader><global>` | not in the schema; YaST rejects the whole profile and says "profile could not be found", which reads like a network fault |
| openSUSE | `console=ttyS0 console=tty0` | the initramfs takes the LAST console, so the log stops at "Loading initial ramdisk" |
| CachyOS | `systemd.autologin=ttyS0` | not a parameter; systemd accepts `systemd.unit=` and `systemd.setenv=` and nothing else |
| CachyOS | archiso finds its own root | it needs `archisolabel=` from the ISO9660 label, which is not in any boot config |
| CachyOS | post_install runs in a chroot | it runs on the live ISO, and the target is already unmounted |
| CachyOS | the display manager is sddm | it is `plasmalogin`; every /etc/sddm.conf.d/ file is read by nothing |

## The runner image

The bakes run in `bake/Containerfile.runner`, which is `qemux/qemu:7.50` with the
entrypoint cleared and nothing added - the same base `Containerfile` line 43
builds the production image from. Installing qemu with apt on a runner took 36
seconds one day and 374 the next for the same commit, entirely depending on which
mirror answered; `tools` is now 0 seconds.

It is private, so jobs name it with credentials:

```yaml
container:
  image: ghcr.io/easydev-org/sandbox-bake-runner:latest
  credentials:
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
  options: --device /dev/kvm
```

And every `run:` step inside one needs `shell: bash`: the container's `/bin/sh` is
dash, and every script here is bash.

## Changing the test without rebaking

`.github/workflows/smoke-only.yml` runs `nixos/smoke.sh` against a disk that
already exists. It takes the run id and artifact name of an earlier bake:

```yaml
disk_run_id: 40385961525      # the bake run
disk_artifact: fedora-workstation
desktop: fedora
```

This exists because fixing the test used to cost a full re-bake every round -
eight minutes for Ubuntu, thirteen for Fedora - while the thing under test was a
shell script.

It streams through `easyagent-github-ext/actions/log-stream`, so the run can be
followed live:

```
GET /repos/{owner}/{repo}/check-runs/{id}   ->   .output.text
```

The Actions log of a running job is not readable through any public API; a
check run's `output.text` is. The check run id is the job id.

## The disks, as they are

Six of them, self-contained qcow2, **zstd-compressed inside the file**:

| desktop | qcow2 | notes |
|---|---|---|
| hyprland | 5.98 GiB | largest; the compositor plus its toolchain |
| kde | 4.04 GiB | |
| cosmic | 3.80 GiB | |
| gnome | 3.11 GiB | |
| miracle | 2.53 GiB | |
| labwc | 2.42 GiB | smallest |
| **total** | **21.87 GiB** | was 53.46 GiB before compression |

Two things about that table matter more than the numbers:

**They are self-contained, not backing chains.** `derive.sh` copies the base and
`qemu-img convert`s its own file, so nothing points at a parent. Any disk can be
downloaded alone and booted alone.

**They did not used to be compressed at all.** `qemu-img convert -O qcow2` leaves
clusters sparse but does not compress, and the conversion was written without
`-c`. Every disk shipped at its full allocated size - 53.46 GiB for the six.
Adding `-c -o compression_type=zstd` cut that by 41%, consistently across all
desktops (40-43% each), which is what you would expect from six disks that are
mostly the same kind of thing: a kernel, systemd and a Nix store.

The cost is decompression on read, and it falls where it is cheapest: a golden
disk is read-mostly. The guest writes to the overlay `golden-disk.sh` creates,
never to this file.

## Publishing

`push-disk.sh` splits a qcow2 into 1 GiB pieces (`data.part000`, `data.part001`,
...) and pushes them as an OCI image, because that is the shape `../Containerfile`
pulls: it `FROM`s the image as a stage and joins the pieces with `cat`.

```sh
# what bake-nixos.yml does when `publish` is set
bash bake/nixos/push-disk.sh out/nixos-labwc.qcow2 \
  ghcr.io/easydev-org/sandbox-disk-labwc:latest
```

The layers are pushed with zstd, not gzip: the disk is already compressed
internally, so the extra gzip pass would spend minutes to save nothing.

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
