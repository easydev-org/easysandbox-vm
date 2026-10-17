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
# The guest binaries (agent-worker + the easystream daemon) are NOT on the
# golden disk either: the guest fetches them from this container's nginx at
# host.lan:8090 on every boot, so upgrading them is an image change.
ARG REGISTRY=artifact.worker.svc.cluster.local/qemux
FROM ${REGISTRY}/qemu:750

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    no_proxy=${NO_PROXY}

# nginx serves the guest the worker/easystream binaries; curl fetches them from
# the releases at build time. apt uses the in-cluster artifact mirror (the
# image's own sources are unreachable from the build node).
ARG ARTIFACT=http://artifact.worker.svc.cluster.local
RUN set -eux; \
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true; \
    printf 'deb [trusted=yes] %s/artifacts/debian/debian trixie main\n' "${ARTIFACT}" > /etc/apt/sources.list.d/artifact.list; \
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
    mkdir -p /opt/agent-worker; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/agent-worker/agent-worker \
      "https://github.com/easydev-org/easyworker/releases/download/${WORKER_VERSION}/agent-worker-linux-amd64"; \
    curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o /opt/agent-worker/easystream \
      "https://github.com/easydev-org/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64"; \
    chmod 755 /opt/agent-worker/agent-worker /opt/agent-worker/easystream

# The REAL launch logic, served to the guest at :8090/oem.sh. The golden disk
# carries only bootstrap.sh, which fetches this on every boot — so a launch
# change is an image change, never a golden rebake.
COPY --chmod=644 oem.sh /opt/agent-worker/oem.sh

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

EXPOSE 48080 8006
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
