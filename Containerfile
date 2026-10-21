# easysandbox-vm — a Linux desktop (GNOME / KDE Plasma, Wayland) in a QEMU guest.
#
# WHY A VM: gnome-shell and KDE Plasma need a session manager that needs
# systemd-logind, which a container cannot provide. A real VM gives the NATIVE
# desktops from Debian's own packages — not a vendor respin.
#
# This image ships NO disk. The guest disk is a PRE-BAKED golden qcow2 published
# to the artifact store (see bake/): the container downloads it once per node
# and boots a per-sandbox overlay (golden-disk.sh), exactly like the
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
ARG GOLDEN_DISK_IMAGE=ghcr.io/easydev-org/golden-disk-linux-desktop:gnome-v17
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
RUN set -eux; echo "release cachebust ${RELEASE_CACHEBUST:-0}"; \
    mkdir -p /opt/easyworker; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/easyworker/easyworker \
      "https://github.com/easydev-org/easyworker/releases/download/${WORKER_VERSION}/easyworker-linux-amd64"; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/easyworker/easystream \
      "https://github.com/easydev-org/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64"; \
    chmod 755 /opt/easyworker/easyworker /opt/easyworker/easystream

# The REAL launch logic, served to the guest at :8090/oem.sh. The golden disk
# carries only bootstrap.sh, which fetches this on every boot — so a launch
# change is an image change, never a golden rebake.
COPY --chmod=644 oem.sh /opt/easyworker/oem.sh

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
    USER_PORTS=48080,22 \
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
COPY --from=golden /disks/ /tmp/golden/
RUN set -eux; \
    mkdir -p /opt/golden-disk; \
    # The published image holds disks/<version>.qcow2; take whichever one it is.
    f="$(ls /tmp/golden/*.qcow2 | head -1)"; \
    cp "$f" /opt/golden-disk/data.qcow2; \
    rm -rf /tmp/golden; \
    ls -l /opt/golden-disk/data.qcow2

EXPOSE 48080 8006
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
