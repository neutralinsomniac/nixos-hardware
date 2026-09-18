# The krane U-Boot packed as a ChromeOS kernel image, so that
# depthcharge (in the stock SPI firmware, which is never touched) loads
# it from the first GPT partition exactly like a ChromeOS kernel.
#
# The image is signed with the ChromeOS *devkeys*, so the device has to
# be in developer mode to boot it.
{
  lib,
  stdenv,
  buildPackages,
  callPackage,
  uboot ? callPackage ./u-boot.nix { },
}:

stdenv.mkDerivation {
  pname = "krane-uboot-depthcharge-payload";
  inherit (uboot) version;

  dontUnpack = true;

  nativeBuildInputs = [
    buildPackages.python3
    buildPackages.depthcharge-tools
    buildPackages.vboot-utils # futility, and the devkeys below
  ];

  buildPhase = ''
    runHook preBuild

    # 1. the entry shim: a single branch, patched by the assembler below
    ${stdenv.cc.targetPrefix}gcc -c ${./uboot-wrapper.S} -o uboot-wrapper.o
    ${stdenv.cc.targetPrefix}objcopy -O binary uboot-wrapper.o uboot-wrapper.bin

    # 2. arm64 Image header + shim + u-boot.bin
    python3 ${./assemble-payload.py} \
      --uboot ${uboot}/u-boot.bin \
      --symbols ${uboot}/u-boot.sym \
      --wrapper uboot-wrapper.bin \
      --output krane-uboot-wrap.img

    # 3. pack as a signed ChromeOS kernel.
    #
    # PATH shim: mkdepthcharge's decompress heuristic runs every
    # decompressor over the kernel image, and xz-utils' `lzma` compat
    # wrapper can exit 0 with EMPTY output on non-lzma data, silently
    # packing a 0-byte kernel that still verifies. An lzma that always
    # fails makes decompress() keep the file as-is.
    mkdir -p shims
    printf '%s\n' '#!/bin/sh' \
      'echo "lzma disabled (mkdepthcharge would truncate raw images)" >&2' \
      'exit 1' > shims/lzma
    chmod +x shims/lzma
    PATH="$PWD/shims:$PATH" mkdepthcharge \
      --arch arm64 \
      --keydir ${buildPackages.vboot-utils}/share/vboot/devkeys \
      --output krane-uboot-payload.bin \
      --name "krane u-boot payload" \
      --vmlinuz krane-uboot-wrap.img \
      --dtbs ${uboot}/u-boot.dtb

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    futility vbutil_kernel --verify krane-uboot-payload.bin
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 krane-uboot-payload.bin \
      $out/share/krane/krane-uboot-payload.bin
    runHook postInstall
  '';

  passthru = { inherit uboot; };

  meta = {
    description = "Depthcharge payload booting U-Boot on the Lenovo IdeaPad Duet Chromebook";
    license = lib.licenses.gpl2Plus;
    platforms = [ "aarch64-linux" ];
  };
}
