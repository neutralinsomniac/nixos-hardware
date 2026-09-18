# krane-install-uboot — write the U-Boot depthcharge payload to a
# ChromeOS kernel partition and mark it bootable.
#
# Works on a block device (/dev/mmcblk0, /dev/sda) or on a disk image.
{
  callPackage,
  coreutils,
  vboot-utils,
  writeShellApplication,
  payload ? callPackage ./depthcharge-payload.nix { },
}:

writeShellApplication {
  name = "krane-install-uboot";

  runtimeInputs = [
    coreutils
    vboot-utils
  ];

  text = ''
    payload=${payload}/share/krane/krane-uboot-payload.bin
    part=1

    usage() {
      cat <<EOF
    usage: krane-install-uboot [--payload FILE] [--partition N] <disk>

    Write the krane U-Boot depthcharge payload to a ChromeOS kernel
    partition of <disk> (a block device or a disk image) and set the
    partition attributes depthcharge requires (successful=1, tries=15,
    priority=15).

      --payload FILE    payload to write (default: $payload)
      --partition N     kernel partition number (default: 1)
    EOF
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --payload) payload="$2"; shift 2 ;;
        --partition) part="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 1 ;;
        *) break ;;
      esac
    done

    if [ $# -ne 1 ]; then
      usage >&2
      exit 1
    fi
    disk="$1"

    if [ ! -f "$payload" ]; then
      echo "krane-install-uboot: no payload at $payload" >&2
      exit 1
    fi

    start=$(cgpt show -i "$part" -b "$disk")
    sectors=$(cgpt show -i "$part" -s "$disk")
    payload_sectors=$(( ( $(stat -Lc %s "$payload") + 511 ) / 512 ))

    if [ "$payload_sectors" -gt "$sectors" ]; then
      echo "krane-install-uboot: payload ($payload_sectors sectors) does not fit" \
           "partition $part ($sectors sectors)" >&2
      exit 1
    fi

    echo "==> writing $payload to $disk partition $part (sector $start)"
    dd if="$payload" of="$disk" bs=512 seek="$start" conv=notrunc,fsync status=none

    # The type GUID must be the ChromeOS kernel one that vboot scans
    # for, and depthcharge ignores kernel partitions whose priority or
    # remaining tries are zero.
    echo "==> stamping partition $part (type kernel, successful=1 tries=15 priority=15)"
    cgpt add -i "$part" -t kernel -S 1 -T 15 -P 15 "$disk"
    cgpt show "$disk"
  '';

  meta.description = "Install the krane U-Boot payload into a ChromeOS kernel partition";
}
