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

  # greetd for the compositors that ship no display manager of their own.
  #
  # labwc, hyprland, niri and miracle-wm install packages and nothing else:
  # no seat and no session, so a bare disk comes up at a text console.
  #
  # One conditional covers all four; only the session command differs.
  services.greetd = lib.mkIf (builtins.elem desktop [ "labwc" "hyprland" "niri" "miracle" ]) {
    enable = true;
    settings.default_session = {
      user = "docker";
      command =
        if desktop == "hyprland" then "${pkgs.hyprland}/bin/Hyprland"
        else if desktop == "niri" then "${pkgs.niri}/bin/niri-session"
        else if desktop == "miracle" then "${pkgs.miracle-wm}/bin/miracle-wm"
        else "${pkgs.writeShellScript "labwc-session" ''
          export XDG_RUNTIME_DIR=/run/user/1000
          export XDG_SESSION_TYPE=wayland
          export XDG_CURRENT_DESKTOP=wlroots
          # DRM, not headless: headless output is never drawn to the framebuffer.
          export WLR_BACKENDS=drm
          export WLR_LIBINPUT_NO_DEVICES=1
          # pixman: wlroots wants a DRM render node; this guest has card0 only.
          export WLR_RENDERER=pixman
          # A window manager with no clients paints nothing; give it a terminal.
          ( sleep 4; ${pkgs.foot}/bin/foot & ) &
          exec ${pkgs.labwc}/bin/labwc
        ''}";
    };
  };
  programs.labwc.enable = lib.mkIf (desktop == "labwc") true;
  # --- three more compositors, each with its own standard module ----------------
  #
  # hyprland: forked from wlroots and now its own compositor, but it still
  # implements zwlr_screencopy and zwlr_virtual_pointer for the ecosystem, and it
  # also speaks libei. Either of easystream's paths could work here.
  #
  # niri: Smithay based, like COSMIC, so libei is the likely path and
  # xdg-desktop-portal-gnome is what its module wires up.
  #
  # miracle-wm: Mir based. Its module says plainly "No portal support yet", so if
  # anything works it will be a wlr protocol.
  programs.hyprland.enable = lib.mkIf (desktop == "hyprland") true;
  programs.niri.enable = lib.mkIf (desktop == "niri") true;
  programs.wayland.miracle-wm.enable = lib.mkIf (desktop == "miracle") true;

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
