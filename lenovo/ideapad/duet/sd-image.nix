# A bootable image for the Lenovo IdeaPad Duet Chromebook, to be
# written to a USB stick (or to the internal eMMC, which overwrites
# ChromeOS).
#
# Disk layout (GPT):
#
#   1  depthcharge  16M   raw    U-Boot payload, ChromeOS kernel type,
#                                priority 15 / tries 15 / successful 1
#   2  ESP         128M   vfat   systemd-boot + kernel + initrd
#   3  NIXOS_SD    rest   ext4   the NixOS system
#
# The device must be in developer mode, and booting from USB has to be
# enabled once from a ChromeOS shell: `crossystem dev_boot_usb=1`.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  cgpt = "${pkgs.buildPackages.vboot-utils}/bin/cgpt";
  payload = "${config.hardware.lenovo.ideapad.duet.uboot.package}/share/krane/krane-uboot-payload.bin";

  # The depthcharge partition, in 512-byte sectors: 1 MiB in, 16 MiB
  # long, so the ESP starts exactly at sdImage.firmwarePartitionOffset.
  payloadStart = 2048;
  payloadSectors = 32768;
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ./default.nix
  ];

  hardware.lenovo.ideapad.duet.uboot.enable = true;

  # The first-boot resize runs sfdisk, partprobe and resize2fs against
  # the live boot medium, ordered before sysinit.target, so a stall in
  # it stalls the whole boot -- on a device that shows no systemd output
  # on its panel until stage 2 is up, and whose boot medium is usually a
  # USB card reader carrying a GPT whose backup header sits at the end
  # of the *image* rather than of the card. Bound it: a resize that
  # fails costs the unallocated tail of the card, one that hangs costs
  # the boot.
  systemd.services.expand-root-partition = lib.mkIf config.sdImage.expandOnBoot {
    serviceConfig.TimeoutStartSec = "60s";
  };

  # sd-image mounts the firmware partition at /boot/firmware; for this
  # board it is the ESP, and that is where the bootloader belongs.
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  image.baseName = lib.mkDefault "nixos-image-lenovo-ideapad-duet-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";

  sdImage = {
    firmwarePartitionName = "ESP";
    firmwarePartitionOffset = (payloadStart + payloadSectors) / 2048; # MiB
    firmwareSize = 128;

    # The bootloader is normally installed by `nixos-rebuild` on the
    # running system; the image has to ship a working one, so lay out
    # systemd-boot and a single entry by hand. The first `nixos-rebuild
    # switch` replaces this with proper generation entries.
    populateFirmwareCommands =
      let
        systemdBoot = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootaa64.efi";
        kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
        initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
        kernelParams = lib.concatStringsSep " " config.boot.kernelParams;
      in
      ''
        mkdir -p firmware/EFI/BOOT firmware/EFI/systemd firmware/EFI/nixos
        mkdir -p firmware/loader/entries

        # U-Boot's "bootefi bootmgr" has no persistent boot entries, so
        # it falls back to the removable media path.
        cp ${systemdBoot} firmware/EFI/BOOT/BOOTAA64.EFI
        cp ${systemdBoot} firmware/EFI/systemd/systemd-bootaa64.efi

        cp ${kernel} firmware/EFI/nixos/kernel.efi
        cp ${initrd} firmware/EFI/nixos/initrd

        cat > firmware/loader/loader.conf <<EOF
        default nixos
        timeout 3
        EOF

        # No devicetree line: U-Boot hands its own fixed-up FDT to the
        # kernel through the EFI configuration table.
        cat > firmware/loader/entries/nixos.conf <<EOF
        title NixOS
        linux /EFI/nixos/kernel.efi
        initrd /EFI/nixos/initrd
        options init=${config.system.build.toplevel}/init ${kernelParams}
        EOF
      '';

    populateRootCommands = "";

    postBuildCommands = ''
      # Keep the partitions sd-image laid out, but re-label the disk as
      # GPT with the depthcharge partition in front of them.
      eval $(partx "$img" -o START,SECTORS --nr 1 --pairs)
      ESP_START=$START
      ESP_SECTORS=$SECTORS
      eval $(partx "$img" -o START,SECTORS --nr 2 --pairs)
      ROOT_START=$START
      ROOT_SECTORS=$SECTORS

      # room for the backup GPT header and entries at the end
      truncate -s '+2M' "$img"

      sfdisk "$img" <<EOF
          label: gpt
          unit: sectors
          sector-size: 512

          start=${toString payloadStart}, size=${toString payloadSectors}, name="depthcharge", type=FE3A2A5D-4F32-41A7-B725-ACCC3285A309
          start=$ESP_START,  size=$ESP_SECTORS,  name="ESP",  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
          start=$ROOT_START, size=$ROOT_SECTORS, name="root", type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
      EOF

      dd if=${payload} of="$img" bs=512 seek=${toString payloadStart} conv=notrunc

      # depthcharge ignores kernel partitions without these attributes.
      ${cgpt} add -i 1 -t kernel -S 1 -T 15 -P 15 "$img"
      ${cgpt} show "$img"
    '';
  };
}
