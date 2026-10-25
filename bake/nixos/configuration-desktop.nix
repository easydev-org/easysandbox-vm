# NixOS desktop image: a normal desktop distribution, built from the minimal
# base by changing this file and running nixos-rebuild (derive.sh).
#
# DESKTOP is substituted at derive time: labwc | gnome | kde | cosmic.
#
# What belongs here is what a desktop distribution itself provides: the desktop
# session, its display manager, the audio stack, clipboard tools. What does NOT
# belong here is anything specific to the sandbox - no nix-ld, no prebuilt
# binaries, no launcher unit. Those are layered on afterwards, when a user
# builds their own image, so this disk stays a plain desktop system.
{ config, lib, pkgs, ... }:

let
  desktop = "@DESKTOP@";
in
{
  # Reuse the base image definition wholesale rather than restating filesystems,
  # boot loader, users and ssh. derive.sh replaces /etc/nixos/configuration.nix on
  # the installed base disk, so whatever this file does not import, the system
  # loses - and a lost fileSystems entry is an unbootable disk. Importing the
  # minimal configuration keeps the two in step by construction: the same file
  # builds the base and forms the foundation of every desktop.
  imports = [ ./configuration-minimal.nix ];
  # --- audio -----------------------------------------------------------------
  #
  # Part of the distribution, not of the sandbox: a desktop with no sound is not
  # a desktop. wireplumber is the session manager - without it pipewire starts
  # and no nodes are ever created - and rtkit is what lets those nodes take
  # realtime priority.
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  services.pipewire.wireplumber.enable = true;
  security.rtkit.enable = true;

  hardware.graphics = { enable = true; enable32Bit = false; };

  # The DRM kernel modules. hardware.graphics enables the userspace stack (mesa,
  # libdrm) but does not load a driver for the emulated display, and wlroots
  # aborts with
  #   Failed to find any DRM render node
  # when there is no /dev/dri to render into - which is exactly what a bare
  # labwc session showed on the first derived disk: the compositor started and
  # then died before painting anything.
  #
  # bochs covers QEMU's default VGA; virtio_gpu covers the -device virtio-gpu
  # variant; both are tiny.
  boot.initrd.availableKernelModules = [ "bochs" "virtio_gpu" "drm" ];
  boot.kernelModules = [ "bochs" "virtio_gpu" ];

  environment.systemPackages = with pkgs; [
    wl-clipboard xclip
    foot fuzzel
  ];

  # --- the desktop ------------------------------------------------------------
  #
  # These differ only in which session the display manager starts and which
  # portal backend is loaded, which is what xdg-desktop-portal keys on: each
  # .portal file declares UseIn=<desktop> and a mismatched XDG_CURRENT_DESKTOP
  # leaves the portal exposing only FileChooser and Settings.
  services.xserver.enable = lib.mkIf (desktop == "gnome" || desktop == "kde") true;

  services.desktopManager.gnome.enable = lib.mkIf (desktop == "gnome") true;
  services.displayManager.gdm.enable = lib.mkIf (desktop == "gnome") true;
  # autoLogin lives under services.xserver.displayManager: the
  # services.displayManager alias forwards enable/package but the session
  # options stay where gdm.nix declares them.
  services.xserver.displayManager.gdm.autoLogin = lib.mkIf (desktop == "gnome") {
    enable = true;
    user = "docker";
  };

  services.desktopManager.plasma6.enable = lib.mkIf (desktop == "kde") true;
  services.displayManager.sddm.enable = lib.mkIf (desktop == "kde") true;
  # KDE stays on Wayland, and needs llvmpipe to render on QEMU.
  #
  # plasma6.nix starts SDDM with kwin_wayland. That is the right architecture and
  # GNOME proves the platform works here: gdm on this same emulated VGA runs
  # mutter on Wayland and paints a full desktop. mutter falls back to llvmpipe by
  # itself; kwin does not, and dies with GL errors - four core dumps in the
  # console, a session that came up, a wallpaper painted on its way down, and no
  # panel because plasmashell went with it.
  #
  # So the fix is to give kwin the same software path mutter takes: force every
  # GL user through llvmpipe, and let kwin use its QPainter compositing backend.
  #
  # KWIN_COMPOSE lives in environment.variables rather than sessionVariables
  # because SDDM starts the session without a login shell.
  environment.variables = lib.mkIf (desktop == "kde") {
    LIBGL_ALWAYS_SOFTWARE = "1";
    KWIN_COMPOSE = "Q";
    # Qt's Wayland backend must not assume a hardware EGL device either.
    QT_QUICK_BACKEND = "software";
  };

  # A one-shot that reports what crashed, straight to the serial console.
  #
  # The KDE disk boots, starts a session, paints a wallpaper and dies: six core
  # dumps with nothing in the console naming the process. Interactive diagnosis
  # over the serial console does not work here - the console is muxed with the
  # QEMU monitor and the commands get lost - so the guest reports by itself.
  #
  # Runs late (after the session has had time to crash) and writes to ttyS0,
  # which is the console the smoke harness captures.
  systemd.services.sandbox-diag = lib.mkIf (desktop == "kde") {
    description = "report crash information to the serial console";
    wantedBy = [ "multi-user.target" ];
    after = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "sandbox-diag" ''
        sleep 60
        exec > /dev/ttyS0 2>&1
        echo === DIAG ===
        echo '--- coredumpctl ---'
        ${pkgs.systemd}/bin/coredumpctl list --no-pager 2>&1 | tail -15 || true
        echo '--- journal errors ---'
        ${pkgs.systemd}/bin/journalctl -b --no-pager -p err 2>&1 | tail -40 || true
        echo '--- plasmashell present? ---'
        pgrep -a plasmashell || echo 'plasmashell NOT running'
        pgrep -a kwin_wayland || echo 'kwin_wayland NOT running'
        echo === DIAGEND ===
      ''}";
    };
  };

  services.desktopManager.cosmic.enable = lib.mkIf (desktop == "cosmic") true;
  services.displayManager.cosmic-greeter.enable = lib.mkIf (desktop == "cosmic") true;
  # GENERIC autologin, shared by every greeter that reads it: SDDM and the
  # COSMIC greeter both do.
  #
  # Only gdm is different - it declares autoLogin under
  # services.xserver.displayManager.gdm, above.
  #
  # This is the option that matters for KDE. Its mdm-specific spelling
  # [services.displayManager.sddm.autoLogin] is registered in sddm.nix as a
  # rename to this one, so using it emitted a warning AND never logged anyone in:
  # the screenshot was SDDM's own login screen - time, docker avatar, Password
  # box - which is what every earlier "wallpaper but no panel" reading really was.
  services.displayManager.autoLogin =
    lib.mkIf (desktop == "cosmic" || desktop == "kde") {
      enable = true;
      user = "docker";
    };

  # labwc has no display manager of its own - NixOS only installs the packages -
  # so unlike the other three flavours nothing started a session and the disk
  # came up at a text console. greetd is the lightest option that does the job.
  #
  programs.labwc.enable = lib.mkIf (desktop == "labwc") true;
  services.greetd = lib.mkIf (desktop == "labwc") {
    enable = true;
    settings.default_session = {
      user = "docker";
      # A wrapper, not the bare binary: greetd starts the session directly, not
      # through a login shell, so environment.sessionVariables is not applied and
      # labwc would try the DRM backend on a guest that has no real display. The
      # variables are set explicitly here instead.
      #
      # exec so the compositor replaces the shell and greetd tracks its lifetime.
      command = "${pkgs.writeShellScript "labwc-session" ''
        export XDG_RUNTIME_DIR=/run/user/1000
        export XDG_SESSION_TYPE=wayland
        export XDG_CURRENT_DESKTOP=wlroots
        # DRM, not headless. The headless backend gives wlroots a virtual output
        # that screencopy can read but that is NEVER drawn to the framebuffer -
        # which is fine in the container, where easystream captures the buffer
        # directly, and useless on a bare disk where the only way to see the
        # desktop is QEMU's emulated VGA. With headless the guest booted, greetd
        # started, the session ran, and the screen stayed black: nothing was ever
        # painted to the thing being photographed.
        #
        # DRM drives card0, which QEMU's VGA provides, so the compositor's output
        # is what the screendump captures.
        export WLR_BACKENDS=drm
        export WLR_LIBINPUT_NO_DEVICES=1
        # pixman, explicitly. wlroots defaults to GLES2 and asks DRM for a render
        # node to render into; QEMU's emulated VGA provides /dev/dri/card0 but no
        # /dev/dri/renderD128, so the compositor aborted with
        #   Failed to find any DRM render node
        # and the disk booted to a black screen while every startup check passed.
        # Software rendering needs no GPU and is what a headless sandbox wants.
        export WLR_RENDERER=pixman
        # Start a terminal alongside the compositor.
        #
        # labwc is a window manager and nothing more: with no client running the
        # screen is a flat empty background, which on this guest is pure black.
        # That is correct behaviour, not a broken desktop - and the screenshot
        # check kept calling it a failure. A terminal gives the session something
        # to show, and makes "is anything rendered" answerable: if the window
        # appears then the compositor, the DRM backend and pixman are all fine,
        # and only the empty default looked wrong.
        #
        # Backgrounded, then exec labwc so greetd still tracks the compositor.
        ( sleep 4; ${pkgs.foot}/bin/foot & ) &
        exec ${pkgs.labwc}/bin/labwc
      ''}";
    };
  };
  # Portal backends. plasma6.nix already sets extraPortals for KDE (and its
  # packages live under kdePackages after the Plasma 6 move), so only GNOME and
  # COSMIC need naming here.
  xdg.portal.enable = true;
  xdg.portal.extraPortals =
    lib.optionals (desktop == "gnome") [ pkgs.xdg-desktop-portal-gnome ]
    ++ lib.optionals (desktop == "cosmic") [ pkgs.xdg-desktop-portal-cosmic ];
  xdg.portal.configPackages =
    lib.optionals (desktop == "gnome") [ pkgs.xdg-desktop-portal-gnome ]
    ++ lib.optionals (desktop == "cosmic") [ pkgs.xdg-desktop-portal-cosmic ];
}
