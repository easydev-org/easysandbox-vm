# NixOS sandbox desktop, declared rather than assembled.
#
# One file builds every desktop: the bake substitutes @DESKTOP@ with one of
# labwc | gnome | kde | cosmic, and everything else stays identical. That is
# the point of using NixOS here - the disks differ by a few declarations, not
# by thousands of lines of installer scripting, and the whole system is
# reproducible from this file.
{ modulesPath, lib, pkgs, ... }:

let
  # One of labwc | gnome | kde | cosmic, substituted at bake time.
  #
  # "none" is also valid and means no desktop at all. That is not a leftover: the
  # cheapest way to make four desktop disks is to install this base ONCE and let
  # each flavour derive from it with nixos-rebuild (see derive.sh), because the
  # partition/format/unpack work is identical across flavours and nixos-install
  # pays for it every time. Every lib.mkIf below is false when desktop is "none",
  # so the branch costs nothing and needs no separate file.
  desktop = "@DESKTOP@";
in
{
  imports = [ "${modulesPath}/profiles/minimal.nix" ];

  # --- filesystem / boot -----------------------------------------------------
  #
  # A PARTITION, not the bare disk: grub-install refuses to embed core.img in
  # the MBR gap when a filesystem starts at sector 0, and says so with
  # "will not proceed with blocklists". The bake formats vda1, leaving the MBR
  # free. The root is addressed by LABEL because the UUID only exists at install
  # time and would pin the disk to one bake.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  boot.initrd.availableKernelModules = [
    "virtio_pci" "virtio_blk" "virtio_scsi" "ext4"
  ];
  boot.kernelModules = [ "virtio_pci" "virtio_blk" ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
    # Also send GRUB to the serial port. Without this the splash goes to the
    # emulated VGA buffer, which nothing in the bake can read, so the bake sees
    # "Welcome to GRUB!" and then silence whether the kernel started or GRUB
    # gave up.
    extraConfig = ''
      serial --unit=0 --speed=115200
      terminal_output serial
    '';
  };
  boot.loader.timeout = 0;
  boot.kernelParams = [ "console=ttyS0,115200n8" ];

  # --- accounts --------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
  };
  services.getty.autologinUser = "docker";

  users.users.docker = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "render" "input" "audio" ];
    password = "admin";
  };
  security.sudo.wheelNeedsPassword = false;

  # root needs a real password: the bake installs with --no-root-password,
  # which LOCKS the account, and when a boot goes wrong systemd then cannot
  # even open an emergency console ("the root account is locked").
  users.users.root.password = "admin";

  networking.hostName = "nixos";
  networking.firewall.enable = false;

  # Fixed on purpose: this records the release the system was FIRST installed
  # with, not the one it runs. Bumping it on every nixpkgs update would change
  # what state migrations the activation script applies.
  system.stateVersion = "26.05";

  # --- packages the sandbox needs regardless of desktop ----------------------
  environment.systemPackages = with pkgs; [
    # easystream reports clipboard=Wl only when wl-copy exists.
    wl-clipboard xclip
    curl vim htop
    # Used by oem-nixos.sh to resolve the prebuilt binaries and to talk to
    # PipeWire. binutils is not optional: without readelf the resolver returns
    # at its first line and the missing library is only noticed when easystream
    # fails to load.
    binutils findutils gnugrep gawk which
    pipewire pulseaudio
  ];

  # --- prebuilt binaries -----------------------------------------------------
  #
  # easystream and easyworker are ordinary dynamically linked ELF binaries. NixOS
  # has no /lib64/ld-linux-x86-64.so.2, so they fail with "cannot execute:
  # required file not found" even when the files are intact. nix-ld installs a
  # shim at the FHS location that execs the real interpreter. The libraries list
  # is what the shim preloads; it supplies the loader, not the libraries.
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      dbus libopus pipewire wayland x264 libyuv
      xorg.libxcb xorg.libXtst xorg.libX11 libxkbcommon
      stdenv.cc.cc.lib zlib openssl glib
    ];
  };

  # --- audio -----------------------------------------------------------------
  services.pipewire = { enable = true; alsa.enable = true; pulse.enable = true; };
  services.pipewire.wireplumber.enable = true;
  security.rtkit.enable = true;

  hardware.graphics = { enable = true; enable32Bit = false; };
  # --- the desktop ------------------------------------------------------------
  #
  # One branch per flavour. They differ only in which session the display
  # manager starts and which portal backend is loaded, which is exactly what
  # xdg-desktop-portal keys on: each .portal file declares UseIn=<desktop> and a
  # mismatched XDG_CURRENT_DESKTOP leaves the portal exposing only FileChooser
  # and Settings. oem-nixos.sh detects the desktop at runtime and restarts the
  # portal with the right value, so these declarations are the whole contract.
  services.xserver.enable = lib.mkIf (desktop == "gnome" || desktop == "kde") true;

  services.desktopManager.gnome.enable = lib.mkIf (desktop == "gnome") true;
  services.displayManager.gdm.enable = lib.mkIf (desktop == "gnome") true;
  # autoLogin lives under services.xserver.displayManager, not under the
  # services.displayManager alias: the alias forwards enable/package but the
  # session options stay where gdm.nix declares them, which is why
  # services.displayManager.gdm.autoLogin.enable is rejected as "does not exist".
  services.xserver.displayManager.gdm.autoLogin = lib.mkIf (desktop == "gnome") {
    enable = true;
    user = "docker";
  };
  # GNOME needs its own portal backend for ScreenCast AND RemoteDesktop; the
  # generic -gtk backend provides neither.

  services.desktopManager.plasma6.enable = lib.mkIf (desktop == "kde") true;
  services.displayManager.sddm.enable = lib.mkIf (desktop == "kde") true;
  # SDDM is the opposite of GDM here: its options were MIGRATED to
  # services.displayManager.sddm (sddm.nix registers mkRenamedOptionModule for
  # each one), while gdm still declares autoLogin under services.xserver. Having
  # both spellings in one file is nixpkgs mid-migration, not a mistake of ours.
  services.displayManager.sddm.autoLogin = lib.mkIf (desktop == "kde") {
    enable = true;
    user = "docker";
  };

  # COSMIC has a first-class module in nixpkgs and ships its own greeter and
  # portal. The portal is what matters for the sandbox: it is the only backend
  # here that implements org.freedesktop.impl.portal.RemoteDesktop, and COSMIC
  # does not implement wlroots virtual-pointer either, so without it both of
  # easystream input paths stay closed.
  services.desktopManager.cosmic.enable = lib.mkIf (desktop == "cosmic") true;
  services.displayManager.cosmic-greeter.enable = lib.mkIf (desktop == "cosmic") true;
  # COSMIC greeter reads the GENERIC autologin option, so unlike gdm/sddm this
  # one really is under services.displayManager.
  services.displayManager.autoLogin = lib.mkIf (desktop == "cosmic") {
    enable = true;
    user = "docker";
  };

  # labwc is the wlroots path: easystream captures it through
  # zwlr_screencopy and injects through zwlr_virtual_pointer, both direct
  # protocols, so no portal and no consent dialog is involved at all.
  programs.labwc.enable = lib.mkIf (desktop == "labwc") true;
  environment.sessionVariables = lib.mkIf (desktop == "labwc") {
    WLR_BACKENDS = "headless";
    WLR_HEADLESS_OUTPUTS = "1";
    WLR_LIBINPUT_NO_DEVICES = "1";
    XDG_RUNTIME_DIR = "/run/user/1000";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "wlroots";
  };

  # Portal backends.
  #
  # Only GNOME and COSMIC need adding here: plasma6.nix already sets
  # extraPortals to kdePackages.xdg-desktop-portal-kde plus the gtk one, and KDE
  # is the reason the KDE derivate is named under kdePackages rather than pkgs -
  # pkgs.xdg-desktop-portal-kde does not exist, which is exactly what the
  # validate job reported.
  # Only when there is a desktop to serve, and never on the base image:
  # with desktop=none extraPortals is empty, and NixOS asserts that
  # xdg.portal.enable=true requires at least one implementation. That
  # assertion is the correct behaviour - a portal with no backend is
  # useless - and it fired on the first base bake, which is what a
  # validation step is for.
  xdg.portal.enable = lib.mkIf (desktop != "none") true;
  xdg.portal.extraPortals =
    lib.optionals (desktop == "gnome") [ pkgs.xdg-desktop-portal-gnome ]
    ++ lib.optionals (desktop == "cosmic") [ pkgs.xdg-desktop-portal-cosmic ];
  xdg.portal.configPackages =
    lib.optionals (desktop == "gnome") [ pkgs.xdg-desktop-portal-gnome ]
    ++ lib.optionals (desktop == "cosmic") [ pkgs.xdg-desktop-portal-cosmic ];

  # --- launch logic -----------------------------------------------------------
  #
  # Only on a disk that actually has a desktop. The BASE image (desktop=none) is
  # an intermediate artefact: a plain NixOS system, nothing else. Putting this
  # service there was wrong in three ways - it ran on every boot of the base,
  # spent two minutes retrying a container that does not exist, logged
  # "FAILED: no sandbox container reachable", and shipped a sandbox-specific
  # unit inside what is supposed to be a clean system image.
  #
  # On a desktop disk the arrangement is: carry bootstrap.sh and nothing else, so
  # at boot it fetches oem.sh from the sandbox container and oem.sh fetches
  # easystream itself. Upgrading the daemon then stays an image change instead of
  # a golden rebake, the same arrangement the Debian disks use.
  systemd.services.easystream-bootstrap = lib.mkIf (desktop != "none") {
    description = "fetch oem.sh from the sandbox container and run it";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "dbus.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "/var/lib/easystream/bootstrap.sh";
      Restart = "on-failure";
      RestartSec = 10;
      # A system service inherits a minimal PATH; environment.systemPackages
      # only affects interactive logins, so without this bootstrap.sh exited
      # 127 on "curl: not found" while curl was plainly installed.
      Environment = [ "PATH=/run/current-system/sw/bin" ];
    };
  };
}
