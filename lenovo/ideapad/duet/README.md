# Lenovo IdeaPad Duet Chromebook (MT8183 "kukui-krane")

The IdeaPad Duet Chromebook (CT-X636F, board `kukui-krane`, SKU 176) is a
MediaTek MT8183 detachable tablet. This profile boots NixOS on it
**without touching the SPI flash**: the stock ChromeOS firmware stays as
it is, and the whole chain hangs off a U-Boot payload placed in a
ChromeOS kernel partition.

```
BootROM → coreboot → TF-A → depthcharge
        → U-Boot payload (GPT partition 1, ChromeOS kernel type)
        → U-Boot EFI boot manager → systemd-boot (ESP) → Linux
```

The device tree Linux boots with is the one U-Boot hands over through
the EFI configuration table, not a `.dtb` from the ESP.

## Before you start

The payload is signed with the ChromeOS **devkeys**, so the device has
to be in developer mode, and booting external media has to be enabled
once from a ChromeOS shell:

```sh
crossystem dev_boot_usb=1
```

At the "OS verification is OFF" screen, <kbd>Ctrl</kbd>+<kbd>U</kbd>
boots external media, <kbd>Ctrl</kbd>+<kbd>D</kbd> the internal eMMC.

A serial console is available on the pogo-pin connector at 115200 baud,
and is the only console that survives a failed display bring-up.

## Building a bootable image

[`sd-image-installer.nix`](sd-image-installer.nix) builds a USB/SD image
with the layout this board needs (16M depthcharge partition, 128M ESP,
ext4 root):

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixos-hardware.url = "github:NixOS/nixos-hardware";

  outputs = { nixpkgs, nixos-hardware, ... }: {
    nixosConfigurations.duet-installer = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        "${nixos-hardware}/lenovo/ideapad/duet/sd-image-installer.nix"
        { system.stateVersion = "25.11"; }
      ];
    };
  };
}
```

```sh
nix build .#nixosConfigurations.duet-installer.config.system.build.sdImage
zstd -d < result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Building U-Boot and the payload from source is part of this — there is
no binary cache for them.

## Using the profile for an installed system

```nix
{
  imports = [ nixos-hardware.nixosModules.lenovo-ideapad-duet ];

  # Needed to install or update the bootloader from the device itself.
  hardware.lenovo.ideapad.duet.uboot.enable = true;
}
```

The profile enables `boot.loader.systemd-boot`, because U-Boot's
`bootefi bootmgr` has no persistent boot entries and falls back to the
removable media path (`/EFI/BOOT/BOOTAA64.EFI`) that systemd-boot
installs. It expects the ESP at `/boot`.

## Installing to the internal eMMC

This overwrites ChromeOS. Partition `/dev/mmcblk0` like the image above
— a 16 MiB partition of type `FE3A2A5D-4F32-41A7-B725-ACCC3285A309`
first, then the ESP, then the root filesystem — install NixOS the usual
way, and write the bootloader payload:

```sh
sudo krane-install-uboot /dev/mmcblk0          # partition 1 by default
```

`krane-install-uboot` (from `hardware.lenovo.ideapad.duet.uboot.enable`)
writes the payload and sets the GPT attributes depthcharge insists on
(`successful=1`, `tries=15`, `priority=15`); a kernel partition without
them is skipped. Use it the same way to update U-Boot later.

## Notes and known issues

- **The device tree handoff is what keeps USB alive.** The `mtu3` node
  is a `simple-mfd` in the shape U-Boot needs, so its xHCI child device
  exists from early boot, but only the parent powers the host IP through
  the shared IPPC block. A child that binds first probes with
  `has_ippc=false`, finds a dead IP and fails without retrying, losing
  USB for the whole boot. U-Boot's `bootcmd` therefore hands Linux the
  upstream shape — no `simple-mfd`, child reshaped to mac-only — so the
  kernel only creates the xHCI device once `mtu3` has probed. The
  profile also orders the initrd modules and adds a `softdep`, but note
  that **those are no-ops on the stock NixOS kernel**, which builds
  `mtu3`, `xhci-mtk-hcd`, `mtk-sd`, `usb-storage` and the PMIC chain in
  (`=y`): nothing is copied into the initrd and modprobe has no load
  order left to impose. Do not rely on them.
- **The console must be routed to the panel.** The last `console=` on
  the kernel command line becomes `/dev/console`, and everything that
  goes only there — systemd's status output, the stage-1 and stage-2
  emergency shells — is lost on a tablet with nothing on the pogo pins.
  The profile lists `console=ttyS0,115200` first and `console=tty0`
  last for that reason. The serial port still receives every kernel and
  systemd message; swap the order if you boot with a cable attached and
  want the emergency shell there instead.
- **U-Boot's framebuffer must not become `fb0`.** The pipeline and the
  backlight are quiesced at `ExitBootServices`, but the EFI stub still
  hands that framebuffer to the kernel through `screen_info`. Left
  alone, `sysfb` turns it into a `simple-framebuffer`, `simpledrm` binds
  it as `fb0` and fbcon takes over a framebuffer nothing scans out —
  and `mediatek-drm` does not evict conflicting framebuffers, so the
  console never moves to the live one. The symptom is a backlight that
  comes on partway through boot and a screen that then shows nothing
  ever again, whether or not the boot itself succeeded. The profile
  passes `initcall_blacklist=sysfb_init` to keep the dead framebuffer
  from being created at all.
- **The display must not use the GCE command queue.** `mediatek-drm`
  routes its register updates through the GCE mailbox (CMDQ) whenever
  that mailbox is registered when the CRTC is created, and falls back
  to CPU writes otherwise. On this boot chain the GCE never executes
  the packet: `mtk_crtc 0 CMDQ execute command timeout!` followed by
  `flip_done timed out` every ten seconds, and a lit panel that never
  shows a frame — while the system is otherwise fully up. Whether the
  mailbox is there in time is a stage-2 udev race with `mtk_mdp3`,
  which links against it, decided by ~100 ms either way; the same
  system can boot fine once and then never again. The profile keeps
  `mtk_cmdq_mailbox` out with an `install` command (a plain blacklist
  does not stop a module loaded as a dependency) and blacklists
  `mtk_mdp3`, so the CPU path is taken on every boot. Why the GCE does
  not run here is not understood yet.
- **Everything defers on the MT6358 regulators** — eMMC, USB, the GPU,
  the power domains and the display. The PMIC chain
  (`mtk_pmic_wrap` → `mt6397` → `mt6358_regulator`) is loaded explicitly
  from the initrd.
- The panel is mounted rotated 270° in the chassis; U-Boot's console is
  rotated to match, and Linux picks the rotation up from the panel node.
- The internal keyboard/trackpad of the detachable dock are USB devices
  behind two hubs on the pogo connector.

## Debugging a boot that stops

`krane-bootcmd-v4` is echoed by `bootcmd` on every boot: if you do not
see it, the payload on the boot medium is older than its patch series.

Both the loader entry and the kernel command line live on the ESP, so
the fastest iteration does not involve rebuilding anything — mount
partition 2 of the boot medium on another machine and edit
`/loader/entries/nixos.conf`. Useful additions to its `options` line:

```
loglevel=7                    # kernel messages on the panel, not just errors
systemd.log_level=debug       # stage-1 and stage-2 systemd, verbosely
rd.systemd.unit=emergency     # stop in the initrd, before mounting root
boot.shell_on_fail            # (script initrd only) shell instead of a hang
```

A boot that reaches the initrd but not the root filesystem waits
~90 seconds for the root device before dropping to an emergency shell;
the installation image enables `boot.initrd.systemd.emergencyAccess` so
that shell is actually usable.

## Credits

The U-Boot board port and the patch series in [`patches/`](patches) are
by Valentin Haudiquet, from <https://github.com/vhaudiquet/krane>; see
<https://vhaudiquet.fr/blog/duet-ubuntu> for the write-up they came
from.
