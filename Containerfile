# easysandbox-vm — a native Linux desktop in a QEMU guest.
#
# WHY A VM: a full desktop needs a session manager and systemd-logind, which a
# container cannot provide. A real VM gives the desktop its own kernel, its own
# PID 1, and a real seat.
#
# WHICH DESKTOP: the golden disk decides, not this image. One image plus one
# GOLDEN_DISK_URL is a complete sandbox, so there are no per-desktop images and
# no per-desktop subdirectories in the artifact store - only one qcow2 per
# desktop.
#
# The disks are built by bake/nixos: one minimal NixOS base, then nixos-rebuild
# for each desktop. Six of them: labwc, gnome, kde, cosmic, hyprland, miracle.
#
# This image ships NO disk. The container downloads the golden qcow2 once per
# node and boots a per-sandbox overlay (golden-disk.sh), exactly like the
# windows/macos sandboxes.
#
# The guest binaries (easyworker + the easystream daemon) are NOT on the
# golden disk either: the guest fetches them from this container's nginx at
# host.lan:8090 on every boot, so upgrading them is an image change.
# ARG REGISTRY must come before the first FROM that uses it.
ARG REGISTRY=docker.io/qemux

# The golden disk, pulled by BuildKit straight from its published image.
#
# The pieces are copied into the qemu stage below and joined there, NOT here: the
# golden image is pure data (a tar of qcow2 chunks) with no /bin/sh, so `RUN cat`
# fails with
#   runc run failed: exec: "/bin/sh": stat /bin/sh: no such file or directory
#
# The disks are built by bake/nixos and published as ghcr images whose layers are
# 1 GiB pieces of the qcow2 (data.part000, data.part001, ...), tagged per desktop:
#
#   sandbox-disk-labwc      sandbox-disk-gnome    sandbox-disk-kde
#   sandbox-disk-cosmic     sandbox-disk-hyprland sandbox-disk-miracle
#
# The default here is a placeholder so the file builds; the publish step of
# bake-nixos.yml sets this to the disk it just produced.
ARG GOLDEN_DISK_IMAGE=ghcr.io/easydev-org/sandbox-disk-labwc:latest
FROM ${GOLDEN_DISK_IMAGE} AS golden

FROM ${REGISTRY}/qemu:7.50
# No proxy settings: this file describes the image, not the build environment.
# Egress configuration belongs to whoever runs the build.

# nginx serves the guest the worker/easystream binaries; curl fetches them from
# the releases at build time.
#
# apt uses Aliyun over HTTPS: reachable from a CI runner and from the cluster
# alike, and https because some egress proxies refuse plain http:// and report it
# misleadingly as a missing Release file.
RUN set -eux; \
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true; \
    printf 'deb https://mirrors.aliyun.com/debian trixie main\n' > /etc/apt/sources.list; \
    printf 'deb https://mirrors.aliyun.com/debian trixie-updates main\n' >> /etc/apt/sources.list; \
    APT_OK=0; \
    apt-get -o Acquire::Retries=10 update; \
    for i in 1 2 3 4 5 6; do \
      apt-get -o Acquire::Retries=10 install -y --no-install-recommends \
        nginx-light curl ca-certificates \
      && { APT_OK=1; break; } || { echo "apt retry $i"; sleep 3; }; \
    done; \
    [ "$APT_OK" = 1 ] || { echo "APT INSTALL FAILED" >&2; exit 1; }; \
    rm -rf /var/lib/apt/lists/*

# The guest binaries, placed here from the releases by build.sh. The guest
# boot-fetches them (nginx :8090 /worker and /easystream).
ARG WORKER_VERSION=v0.1.0
ARG EASYSTREAM_VERSION=v0.1.0
ARG RELEASE_PROXY
# RELEASE_CACHEBUST was referenced in the RUN below but never declared as an ARG,
# so it never reached the command and BuildKit happily reused the cached layer
# from an earlier build. The image then shipped the PREVIOUS easyworker while the
# build log said WORKER_VERSION=v0.3.9 - and because the binary looked healthy,
# the symptom (a worker with the old exit bug) was indistinguishable from a code
# problem. Declaring it makes every run rebuild this step.
ARG RELEASE_CACHEBUST=0
RUN set -eux; echo "release cachebust ${RELEASE_CACHEBUST:-0}"; \
    mkdir -p /opt/easyworker; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/easyworker/easyworker \
      "https://github.com/easydev-org/easyworker/releases/download/${WORKER_VERSION}/easyworker-linux-amd64"; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/easyworker/easystream \
      "https://github.com/easydev-org/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64"; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/easyworker/easystream-nixos \
      "https://github.com/easydev-org/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64-nixos"; \
    chmod 755 /opt/easyworker/easyworker /opt/easyworker/easystream /opt/easyworker/easystream-nixos

# The REAL launch logic, served to the guest at :8090/oem.sh. The golden disk
# carries only bootstrap.sh, which fetches this on every boot - so a launch
# change is an image change, never a golden rebake.
#
# oem-nixos.sh, and only that. The Debian script is gone along with the rest of
# the apt-based path: the disks are built from a NixOS minimal base plus
# nixos-rebuild, and oem-nixos.sh is the launch logic for all six desktops. It
# has no display manager to detect, the root filesystem is read-only outside
# /var, and the compositors reach the screen through wlroots protocols rather
# than xdg-desktop-portal.
ARG OEM_SCRIPT=oem-nixos.sh
# OEM_HASH exists so a change to the script actually reaches the image.
#
# BuildKit keys this COPY on its arguments, and the only argument is the FILE
# NAME, not the content. Editing the script therefore reused the previous layer
# and shipped the old one, which is exactly what happened:
# gnome-v21 was built after the portal-grant fix yet still contained the 189-line
# version with no grant section, so GNOME booted without a restore token, Start
# blocked on a consent dialog nobody can click, and the sandbox streamed nothing
# while every process looked healthy.
ARG OEM_HASH=0
RUN echo "oem ${OEM_HASH}"
COPY --chmod=644 ${OEM_SCRIPT} /opt/easyworker/oem.sh

# The runtime (boot scripts, vendored once). Its install.sh ends by calling
# startLinux(), which boots the PRE-BAKED disk and never installs — upstream
# would otherwise download an ISO and run a full unattended install.
#
# ENTRY_HASH must come BEFORE this COPY: buildkit keys a COPY layer on the
# build args in scope, so a bust placed after it would not invalidate it and the
# image kept the OLD runtime (with samba.sh) no matter what we edited.
ARG ENTRY_HASH=0
RUN echo "runtime ${ENTRY_HASH}"
COPY --chmod=755 vendor/run/ /run/
# Guest-facing routes on :8090. ENTRY_HASH busts this COPY layer whenever the
# files change — buildkit otherwise reuses a stale layer and the image keeps an
# OLD 00-token.conf (which is exactly why /oem.sh 404'd while /worker worked).
ARG ENTRY_HASH=0
RUN echo "config ${ENTRY_HASH}"
COPY --chmod=644 00-token.conf /etc/nginx/conf.d/00-token.conf
COPY --chmod=755 start.sh /run/start.sh
COPY --chmod=755 golden-disk.sh /run/golden-disk.sh

# The desktop flavor: the golden disk to boot (published by bake/) and the
# DISK_FILE the runtime expects.
ARG GOLDEN_DISK_URL
# Keep this block MINIMAL and mirror the windows/macos sandboxes, which override
# almost nothing at run time. Every extra knob I set here introduced a bug:
#   DHCP=Y   -> dnsmasq instead of plain NAT
#   WEB_PORT -> clashed with the runtime's own default
#   SAMBA/SHUTDOWN/WEB -> changed startup paths for no reason
# The runtime's defaults are the tested path.
# samba.sh is DELETED from the vendored runtime (see vendor/run/entry.sh): this
# image has no shared folders, and upstream's samba setup aborts entry.sh before
# server.sh runs (it needs unix2dos, which the base image lacks) — which is why
# nginx never started. With the file gone there is nothing to disable.
ENV VERSION=debian13 \
    APP=Linux \
    HOST=host.lan \
    SAMBA=N \
    DISK_FMT=qcow2 \
# Fallback-only port list. Normally unused: with NET_ADMIN the runtime creates a
# bridge, the guest gets a real IP, and the container's nginx proxies port 80 to
# it — no per-port forwarding exists to get wrong. USER_PORTS only applies when
# the bridge cannot be created and the runtime falls back to passt (user-mode),
# which has no guest IP and can only forward ports named here.
#
# The deployment therefore MUST grant NET_ADMIN. Without it the log says
#   Warning: failed to create bridge. Please add: --cap-add NET_ADMIN
#   ... falling back to user-mode networking!
# and the fallback silently drops any port not listed — which is exactly how the
# control channel (48079) became unreachable while /desktop/ still loaded.
    USER_PORTS=48080,48078,48079,22 \
    DISK_FILE=/storage/data.qcow2 \
    GOLDEN_DISK_URL=${GOLDEN_DISK_URL}

# DISPLAY=web: run the QEMU VNC server with the websocket bridge so noVNC can be
# served from nginx (:8006). We need it to GRANT the portal's screen-share
# permission ONCE by hand; after that the grant is baked into the golden disk
# (see bake/). The guest also gets a GPU (VGA) so GNOME Shell can create a
# Wayland output; `none` would leave it with no display at all.
# VGA=std,xres=... makes display.sh emit `-device VGA,xres=1024,yres=768`
# instead of the virtio-vga-gl default, so the desktop is 1024x768 like the rest.
ENV DISPLAY=web \
    VGA=std,xres=1024,yres=768

# --- the golden disk, LAST ON PURPOSE ---------------------------------------
#
# Everything above is cheap and fails fast. This step pulls 1.6-3.6 GiB and makes
# the largest layer, so it runs only once the build has proven it can succeed.
#
# The pieces are joined HERE rather than in the `golden` stage because that stage
# is the disk image itself: pure data, no /bin/sh to run `cat` with. One RUN keeps
# the finished disk in a single layer.
#
# The published layout is 1 GiB chunks named data.part000, data.part001, ... in
# the image root — the same convention the windows and macos disks use, produced
# by ghcr_push_disk.py. (The ORIGINAL personal package held a single
# disks/vNN.qcow2; after migration the chunks are what exists, and concatenating
# them in name order reproduces that file exactly — the manifest records its
# sha256.)
# A bind mount, NOT a COPY. `COPY` would put the pieces in one layer and the
# joined file in the next; `rm` cannot remove bytes from an immutable layer, so
# the image carried the disk twice:
#
#   layer[17] = 1.91 GiB   (the pieces, unreachable after the rm)
#   layer[18] = 1.91 GiB   (the joined file)
#
# source=/ is the golden stage's ROOT: that is where the pieces live
# (/data.part000, ...), not the path they were being copied to.
RUN --mount=type=bind,from=golden,source=/,target=/golden-ro,readonly \
    set -eux; \
    mkdir -p /opt/golden-disk; \
    cat /golden-ro/data.part* > /opt/golden-disk/data.qcow2; \
    ls -l /opt/golden-disk/data.qcow2

EXPOSE 48078 48079 48080 8006
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
