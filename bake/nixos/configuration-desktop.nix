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
  # SDDM is the opposite of GDM here: its options were MIGRATED to
  # services.displayManager.sddm, while gdm still declares autoLogin under
  # services.xserver. Both spellings in one file is nixpkgs mid-migration.
  services.displayManager.sddm.autoLogin = lib.mkIf (desktop == "kde") {
    enable = true;
    user = "docker";
  };

  services.desktopManager.cosmic.enable = lib.mkIf (desktop == "cosmic") true;
  services.displayManager.cosmic-greeter.enable = lib.mkIf (desktop == "cosmic") true;
  # The COSMIC greeter reads the GENERIC autologin option, unlike gdm/sddm.
  services.displayManager.autoLogin = lib.mkIf (desktop == "cosmic") {
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
  # greetd reads this to decide the session type, and labwc needs the headless
  # backend because the guest has no real display.
  environment.sessionVariables = lib.mkIf (desktop == "labwc") {
    WLR_BACKENDS = "headless";
    WLR_HEADLESS_OUTPUTS = "1";
    WLR_LIBINPUT_NO_DEVICES = "1";
    XDG_RUNTIME_DIR = "/run/user/1000";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "wlroots";
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
