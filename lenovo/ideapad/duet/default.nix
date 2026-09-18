# Lenovo IdeaPad Duet Chromebook (MediaTek MT8183 "kukui-krane").
#
# The stock ChromeOS firmware is kept: depthcharge loads a U-Boot
# payload from the first GPT partition, U-Boot's EFI loader boots the
# NixOS bootloader from the ESP, and the device tree Linux boots with is
# the one U-Boot hands over through the EFI configuration table.
#
# See ./README.md for installation, and ./sd-image.nix for a ready-made
# bootable image.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.lenovo.ideapad.duet;
in
{
  options.hardware.lenovo.ideapad.duet = {
    uboot = {
      enable = lib.mkEnableOption ''
        the krane U-Boot depthcharge payload and the
        {command}`krane-install-uboot` helper that writes it to a
        ChromeOS kernel partition. Building it compiles U-Boot from
        source; enable it when you want to install or update the
        bootloader from the running system
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./depthcharge-payload.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./depthcharge-payload.nix { }";
        description = "Depthcharge payload (signed U-Boot) to install.";
      };
    };
  };

  config = {
    boot = {
      initrd = {
        # Loaded in this order, before udev coldplugs anything -- on a
        # kernel that builds these as modules. The stock NixOS aarch64
        # kernel builds every one of them in (CONFIG_MTK_PMIC_WRAP,
        # CONFIG_REGULATOR_MT6358, CONFIG_USB_MTU3, CONFIG_USB_XHCI_MTK,
        # CONFIG_MMC_MTK, CONFIG_USB_STORAGE are all =y), so there both
        # this list and the softdep below are no-ops: nothing from them
        # lands in the initrd and modprobe has no load order left to
        # impose. (The display chain below is genuinely modular, and
        # does land there.)
        #
        # They are therefore NOT what keeps USB alive. The mtu3/xHCI
        # bring-up is serialised in the device tree U-Boot hands over:
        # its bootcmd drops "simple-mfd" from the ssusb compatible, so
        # the kernel only creates the xHCI child once mtu3 has probed
        # and powered the host IP. That is the mitigation that survives
        # the drivers being built in; see the U-Boot patch series.
        kernelModules = [
          # Everything on this SoC defers on the MT6358 regulators:
          # eMMC (ldo_vio18), USB (ldo_vusb), the GPU, and the whole
          # power-domain and display forest. Load the PMIC chain
          # explicitly instead of hoping udev gets to it.
          "mtk_pmic_wrap"
          "mt6397"
          "mt6358_regulator"
          # The mtu3 wrapper owns the shared IPPC block that powers the
          # host IP. A child bound first probes with has_ippc=false,
          # finds a dead IP and fails hard without a retry, killing USB
          # for the whole boot.
          "mtu3"
          "xhci_mtk_hcd"
          # The GCE command-queue mailbox, so it is registered before
          # mediatek-drm creates its CRTC and the display takes the CMDQ
          # path on every boot. Without it the driver falls back to CPU
          # register writes from the OVL frame-complete interrupt, which
          # have to land inside a ~240 us vertical blank; CPU idle exit
          # latencies on this SoC are longer than that, so the CPU path
          # tears and flickers on every cursor move. The GCE only works
          # with clk_ignore_unused below.
          "mtk_cmdq_mailbox"
        ];

        availableKernelModules = [
          # eMMC. The host driver is built in; the block layer is not.
          "mtk_sd"
          "mmc_block"
          # USB (the rootfs usually lives on a USB stick)
          "phy_mtk_tphy"
          "xhci_plat_hcd"
          "usb_storage"
          "uas"
          # Native display chain, so the panel stays lit when the kernel
          # takes over from U-Boot's scanout instead of going dark for
          # the length of the initrd.
          "mtk_mmsys"
          "mtk_mutex"
          "mediatek_drm"
          "phy_mtk_mipi_dsi_drv"
          "panel_boe_tv101wum_nl6"
          "pwm_mediatek"
          "pwm_bl"
        ];
      };

      # The on-board Genesys hub behind the USB-C port and the pogo
      # connector is declared in the device tree (hub@1, "usb5e3,610"),
      # which the onboard USB device driver matches. That driver is a
      # module and is not in the initrd, so it loads at stage-2 coldplug
      # -- and registering it makes USB core reprobe the hub, which
      # unconfigures it first and disconnects everything downstream: a
      # root filesystem on a USB stick dies right after "Coldplug All
      # udev Devices". The driver has nothing to do here anyway (the
      # node carries no reset line and no supply), so keep it out.
      blacklistedKernelModules = [
        "onboard_usb_dev"
      ];

      extraModprobeConfig = ''
        # Same ordering requirement as above, for the initrd variants
        # and boot stages that load these modules through udev rather
        # than from the list above. Inert, like the list, on a kernel
        # that builds mtu3 and xhci-mtk-hcd in.
        softdep xhci-mtk-hcd pre: mtu3

        # Same for the display: the CRTC only asks the mailbox for a
        # channel when it is created, so the mailbox has to be there
        # first on the boot paths that load mediatek-drm through udev.
        softdep mediatek_drm pre: mtk_cmdq_mailbox
      '';

      kernelParams = [
        # The pogo-pin UART, and the only console that survives a
        # display bring-up failure. It comes first on purpose: the LAST
        # console= on the command line is the one that becomes
        # /dev/console, and on a tablet that has no serial cable
        # attached, everything that only goes to /dev/console -- systemd
        # status output, the stage-1 and stage-2 emergency shells,
        # rescue prompts -- has to land on the panel or it is lost. The
        # serial port still receives every kernel and systemd message.
        "console=ttyS0,115200"
        "console=tty0"

        # U-Boot quiesces the display pipeline and turns the backlight
        # off at ExitBootServices (its framebuffer has no IOMMU mapping
        # once the kernel's M4U starts translating), but the EFI stub
        # still hands that framebuffer to the kernel through
        # screen_info. Without this, sysfb turns it into a
        # simple-framebuffer device, simpledrm binds it as fb0 and fbcon
        # takes over a framebuffer nothing scans out; mediatek-drm does
        # not evict conflicting framebuffers (no
        # aperture_remove_conflicting_devices call), so the console
        # stays on the dead fb for the rest of the boot while the panel
        # -- lit by the kernel's own cold bring-up -- shows an empty
        # one. The visible symptom is a backlight that comes on and a
        # screen that never displays anything again.
        "initcall_blacklist=sysfb_init"

        # With no firmware framebuffer there is nothing on this board
        # for fbcon to take over until mediatek-drm probes, and the
        # kernel defers the takeover until something is printed
        # (CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER). Deferring on
        # top of having nothing to defer to just loses everything
        # printed before the display comes up -- including, on a failed
        # boot, the message saying what went wrong and the rescue shell
        # prompt that follows it. Bind as soon as there is a framebuffer.
        "fbcon=nodefer"

        # The GCE (CMDQ command engine) only works when the kernel is
        # kept from gating clocks nothing claims. Without this,
        # clk_disable_unused runs about a second into boot and from then
        # on the engine never executes a packet ("mtk_crtc 0 CMDQ
        # execute command timeout!", "flip_done timed out", a lit panel
        # that never shows a frame) and, some minutes later, the block
        # stops answering on the bus: a driver probe that touches it then
        # hangs the whole SoC. Which clock is responsible is not known.
        # The gce node claims only CLK_INFRA_GCE; the obvious suspect,
        # CLK_INFRA_GCE_26M, was tested and is NOT it on its own -- gating
        # it, or every other unused infracfg gate, on a running GCE
        # changes nothing. The topckgen, apmixedsys and PLL candidates
        # could not be tested the same way (their registers are claimed
        # by drivers, so /dev/mem refuses them), and the dependency may
        # be at engine init rather than at run time.
        "clk_ignore_unused"

        # mediatek-drm takes every scanout buffer from CMA, and the
        # kernel's default 32 MiB pool holds three 1920x1200 framebuffers:
        # a compositor plus a browser exhausts it in seconds, after which
        # mtk_gem_create fails and the display freezes while the rest of
        # the system keeps running. A later cma= on the command line
        # overrides this.
        "cma=256M"
      ];

      loader = {
        # U-Boot boots through its EFI loader: "bootefi bootmgr", which
        # falls back to the removable media path that systemd-boot
        # installs at /EFI/BOOT/BOOTAA64.EFI.
        systemd-boot.enable = lib.mkDefault true;
        efi.efiSysMountPoint = lib.mkDefault "/boot";
        # The payload has no persistent environment (ENV_IS_NOWHERE), so
        # U-Boot's EFI variables do not survive a reboot.
        efi.canTouchEfiVariables = lib.mkDefault false;
        generic-extlinux-compatible.enable = lib.mkDefault false;
        # hardware.deviceTree.name is set below, which would otherwise
        # make every generation entry carry a `devicetree` line and boot
        # Linux with the kernel's own DTB (through U-Boot's DT fixup
        # protocol) instead of the tree bootcmd fixed up -- a different
        # boot path from the one the images ship with. Keep the two the
        # same.
        systemd-boot.installDeviceTree = lib.mkDefault false;
      };
    };

    # The device tree comes from U-Boot (it fixes up the SSUSB nodes
    # before handing it over). This is only the fallback for boot paths
    # that pass a dtb explicitly.
    hardware.deviceTree.name = lib.mkDefault "mediatek/mt8183-kukui-krane-sku176.dtb";

    # MT7663 WiFi/Bluetooth firmware.
    hardware.enableRedistributableFirmware = lib.mkDefault true;

    # Tablet: the accelerometer hangs off the ChromeOS EC.
    hardware.sensor.iio.enable = lib.mkDefault true;

    powerManagement.cpuFreqGovernor = lib.mkDefault "schedutil";

    environment.systemPackages = lib.mkIf cfg.uboot.enable [
      (pkgs.callPackage ./uboot-installer.nix { payload = cfg.uboot.package; })
    ];
  };
}
