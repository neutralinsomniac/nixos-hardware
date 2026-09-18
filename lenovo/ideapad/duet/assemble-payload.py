#!/usr/bin/env python3
# Assemble the krane depthcharge payload image (pre-vboot-signing).
#
# Layout (LOAD-BEARING):
#
#   0x0000  64-byte arm64 Image header (code0 = b +0x40, image_size,
#           flags bit3, magic at 0x38 — the booting.rst contract that
#           depthcharge's src/arch/arm/boot64.c implements)
#   0x0040  entry shim from uboot-wrapper.S: a single `b`, patched here
#           to U-Boot's _start. depthcharge jumps to payload+0x40, but
#           U-Boot's PIE fixup needs a 4K-aligned entry, so the shim
#           hands off to payload+0x1000. It must not touch ANY register:
#           x0 carries depthcharge's handoff FDT.
#   0x1000  u-boot.bin contiguous (NO interior padding)

import argparse
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uboot", required=True, help="u-boot.bin")
    parser.add_argument("--symbols", required=True, help="u-boot.sym")
    parser.add_argument("--wrapper", required=True, help="assembled uboot-wrapper.S")
    parser.add_argument("--output", required=True, help="payload image to write")
    # Where depthcharge loads the kernel buffer; the runtime address of
    # _start is checked for 4K alignment against it.
    parser.add_argument("--load-address", type=lambda s: int(s, 0), default=0x40000000)
    args = parser.parse_args()

    with open(args.uboot, "rb") as f:
        uboot = f.read()
    with open(args.wrapper, "rb") as f:
        wrapper = bytearray(f.read())

    # u-boot.bin starts at __image_copy_start (the lowest output VMA);
    # _start's file offset is its delta from that base. The PIE fixup in
    # start.S loads the link base from _TEXT_BASE and the run base from
    # adr _start, so _start MUST equal __image_copy_start (a 4-byte
    # linker fill sneaks in when CONFIG_TEXT_BASE is not 8-aligned —
    # start.o's .text input section is 8-aligned — and then every
    # relocated pointer is skewed by 4). Fail loudly instead.
    copy_vma = None
    start_vma = None
    with open(args.symbols) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[-1] == "__image_copy_start":
                copy_vma = int(parts[0], 16)
            elif len(parts) >= 2 and parts[-1] == "_start":
                start_vma = int(parts[0], 16)
    if copy_vma is None or start_vma is None:
        raise SystemExit("symbols not found in %s" % args.symbols)
    if start_vma != copy_vma:
        raise SystemExit(
            "_start 0x%x != __image_copy_start 0x%x: CONFIG_TEXT_BASE is not "
            "8-aligned and a linker fill shifted _start" % (start_vma, copy_vma)
        )
    if start_vma % 0x1000:
        raise SystemExit("link _start 0x%x not 4K-aligned" % start_vma)

    start_file_off = start_vma - copy_vma
    wrap_off = 0x40
    uboot_off = 0x1000
    while (uboot_off + start_file_off) % 0x1000:
        uboot_off += 0x1000
    pad = uboot_off - wrap_off - len(wrapper)
    if pad < 0:
        raise SystemExit("entry shim does not fit below 0x%x" % uboot_off)
    total = uboot_off + len(uboot)
    if (args.load_address + uboot_off + start_file_off) % 0x1000:
        raise SystemExit("runtime _start not 4K-aligned")

    hdr = bytearray(64)
    hdr[0:4] = struct.pack("<I", (0x40 >> 2) | 0x14000000)  # code0: b +0x40
    struct.pack_into("<Q", hdr, 0x10, total)  # image_size
    struct.pack_into("<Q", hdr, 0x18, 1 << 3)  # flags: bit3
    hdr[0x38:0x3C] = b"ARM\x64"  # magic

    # Patch the shim's `b .` — searched, NOT assumed to be the last
    # instruction (the shim must stay a single branch; patching blind
    # would clobber anything following it).
    hits = [
        i
        for i in range(0, len(wrapper), 4)
        if struct.unpack_from("<I", wrapper, i)[0] == 0x14000000
    ]
    if len(hits) != 1:
        raise SystemExit("expected exactly one `b .` in the shim, found %d" % len(hits))
    br_off = wrap_off + hits[0]
    imm = (uboot_off + start_file_off - br_off) // 4
    wrapper[hits[0] : hits[0] + 4] = struct.pack("<I", (imm & 0x03FFFFFF) | 0x14000000)

    with open(args.output, "wb") as f:
        f.write(hdr)
        f.write(wrapper)
        f.write(bytes(pad))
        f.write(uboot)

    print(
        "layout: header 64, shim %d (0x40..0x%x), uboot %d @0x%x, "
        "total %d, runtime _start 0x%x"
        % (
            len(wrapper),
            uboot_off,
            len(uboot),
            uboot_off,
            total,
            args.load_address + uboot_off + start_file_off,
        )
    )


if __name__ == "__main__":
    main()
