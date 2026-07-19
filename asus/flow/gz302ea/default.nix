{
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) mkDefault;
in
{

  imports = [
    ../../../common/cpu/amd
    ../../../common/cpu/amd/pstate.nix
    ../../../common/gpu/amd
    ../../../common/pc/laptop
    ../../../common/pc/ssd
  ];

  boot = {
    # kernel >7.2-rc1 where ism was rewritten. Additionally pinned to a
    # mainline snapshot past 7.2-rc3 for the rc4-bound DCN display fixes
    # (8382cd234981 "consolidate DCN vblank/flip handling onto
    # vupdate_no_lock", 48ab86360af1 "check GRPH_FLIP status before sending
    # event"); drop the snapshot pin once linuxPackages_testing >= 7.2-rc4.
    kernelPackages = lib.mkIf (lib.versionOlder pkgs.linux.version "7.2") (
      if lib.versionOlder pkgs.linux_testing.version "7.2-rc4" then
        pkgs.linuxPackagesFor (
          pkgs.linux_testing.override {
            argsOverride = {
              version = "7.2-rc3";
              modDirVersion = "7.2.0-rc3";
              src = pkgs.fetchFromGitHub {
                owner = "torvalds";
                repo = "linux";
                rev = "f2ec6312bf711369561bdcb22f8a63c0b118c479";
                hash = "sha256-Ia6+cjsq6B5C+U611JaUgw6zT49CUwf4Mni+c3KqWmM=";
              };
            };
          }
        )
      else
        pkgs.linuxPackages_testing
    );
    kernelModules = [ "kvm-amd" ];
    kernelParams = [
      "pcie_aspm.policy=powersupersave"
    ];
  };

  # linux-firmware pinned past the 20260622 release for the DMCUB
  # 0.1.67.0 update (1168e26f, 2026-07-17, includes dcn_3_5_1; its "improve
  # lock mechanism with HW lock mgr" change touches the DCN35 IPS entry/exit
  # path). The first release containing it will be dated >= 20260717, at
  # which point this pin stands down.
  nixpkgs.overlays = [
    (final: prev: {
      linux-firmware =
        if lib.versionOlder prev.linux-firmware.version "20260717" then
          prev.linux-firmware.overrideAttrs {
            version = "20260622-unstable-2026-07-17";
            src = final.fetchFromGitLab {
              owner = "kernel-firmware";
              repo = "linux-firmware";
              rev = "1168e26f77312e0f55a763891fb57b66d405b5f3";
              hash = "sha256-hcIHJWjlsrWaAPPOYhYkpgM3N2v+u+ZDzzpnOmaLdVc=";
            };
          }
        else
          prev.linux-firmware;
    })
  ];

  hardware.bluetooth.enable = mkDefault true;

  services = {
    asusd.enable = mkDefault true;

    # services.asusd enables supergfxd, and we only have one gpu
    supergfxd.enable = false;

    udev.extraRules = ''
      # The GZ302EA folio touchpad is USB-attached, so systemd's input_id builtin
      # tags it as an *external* touchpad and libinput then hides "disable while
      # typing" support. Force the touchpad to be internal.
      ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHPAD}=="1", ENV{ID_VENDOR_ID}=="0b05", ENV{ID_MODEL_ID}=="1a30", ENV{ID_INPUT_TOUCHPAD_INTEGRATION}="internal"
    '';
  };

  # for screen auto-rotate
  hardware.sensor.iio.enable = mkDefault true;
}
