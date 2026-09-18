# U-Boot for the MediaTek MT8183 "kukui-krane" (Lenovo IdeaPad Duet
# Chromebook), built as a depthcharge payload rather than as firmware:
# see ./depthcharge-payload.nix for the packaging and ./README.md for
# the boot chain.
#
# The series in ./patches is applied with fuzz, not `git am`: patch
# 0007's boot/image-fdt.c context drifted inside the v2026.10-rc4 tag
# it is based on.
{
  lib,
  buildUBoot,
  fetchFromGitHub,
}:

buildUBoot {
  defconfig = "mt8183_kukui_krane_defconfig";

  version = "2026.10-rc4";
  src = fetchFromGitHub {
    owner = "u-boot";
    repo = "u-boot";
    rev = "v2026.10-rc4";
    hash = "sha256-RGLGsZv12vmwt+1eXmm7p3lXThxlR6uztR/rJYs7DF8=";
  };

  extraPatches = map (name: ./patches + "/${name}") (
    lib.naturalSort (builtins.attrNames (builtins.readDir ./patches))
  );
  patchFlags = [
    "-p1"
    "-l"
    "--fuzz=3"
  ];

  # u-boot.sym is consumed by the payload assembly, which has to know
  # where _start ended up relative to the start of u-boot.bin.
  filesToInstall = [
    "u-boot.bin"
    "u-boot.sym"
    "u-boot.dtb"
  ];

  extraMeta = {
    description = "U-Boot for the MT8183 kukui-krane (Lenovo IdeaPad Duet Chromebook)";
    platforms = [ "aarch64-linux" ];
  };
}
