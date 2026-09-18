{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/profiles/installation-device.nix"
    ./sd-image.nix
  ];

  # The installation media is also the installation target,
  # so we don't want to provide the installation configuration.nix.
  installer.cloneConfig = false;

  # The image boots from a USB key that is not the installation target,
  # and the first-boot resize runs sfdisk and partprobe against that live
  # medium -- the one component of this board that a boot cannot afford
  # to disturb.
  sdImage.expandOnBoot = false;

  # If stage 1 cannot find the root filesystem, systemd drops to an
  # emergency shell on /dev/console -- which on this board is the panel.
  # Without this the initrd's root account is locked, so that shell
  # prompts for a password that does not exist and the failure is a dead
  # end. The installation media already boots with an empty root
  # password.
  boot.initrd.systemd.emergencyAccess = true;
}
