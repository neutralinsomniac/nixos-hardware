/*
 * krane payload entry shim — runs at 0x40000040 right after the
 * depthcharge handoff (MMU off, caches off; position-independent:
 * immediate-encoded addresses only).
 *
 * Minimal variant: the only job is to jump to U-Boot's _start at
 * payload+0x1000 (PIE fixup requires a 4K-aligned entry, which
 * payload+0x40 is not). Everything else was removed:
 *   - display revival (OVL_EN / backlight GPIOs): U-Boot does the full
 *     cold bring-up itself (VIDEO_MT8183_DISPLAY),
 *   - EL1 drop: U-Boot, GRUB, the kernel and the PSCI-woken secondaries
 *     all run at EL2 (the shim's all-EL2 variant),
 *   - EL check / UART debug char: it clobbered x0, which depthcharge
 *     loads with its handoff FDT (boot_arm64_linux_jump) — the FDT
 *     whose /memory was rebuilt from the coreboot memory tables and
 *     which dram_init() now decodes.
 *
 * No register may be touched: x0 carries the depthcharge FDT pointer
 * into U-Boot's save_boot_params().
 */

	.text
	.globl _start
_start:
	b	.			/* PATCHED: branch to U-Boot entry */
