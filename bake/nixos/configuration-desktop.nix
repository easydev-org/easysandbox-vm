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

  # labwc is the wlroots path: nothing starts a session by itself, so a bare
  # labwc disk ends at a getty. That is expected, not a fault - the session is
  # started by whatever launches the sandbox.
  programs.labwc.enable = lib.mkIf (desktop == "labwc") true;
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
