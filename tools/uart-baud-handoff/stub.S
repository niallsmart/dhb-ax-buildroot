	.syntax unified
	.cpu cortex-a9
	.arm

	.section .text.entry, "ax", %progbits
	.balign 4
	.global _start
	.type _start, %function
_start:
	/*
	 * Validate the little-endian parameter record at image offset 0x100:
	 * magic "UART", IBRD, FBRD, APB-clock flag.
	 */
	adr	r12, .Lparams
	ldr	r0, [r12]
	movw	r2, #0x4155
	movt	r2, #0x5452
	cmp	r0, r2
	bne	3f
	ldr	r0, [r12, #4]
	cmp	r0, #1
	blo	3f
	movw	r2, #0xffff
	cmp	r0, r2
	bhi	3f
	ldr	r0, [r12, #8]
	cmp	r0, #63
	bhi	3f
	ldr	r0, [r12, #12]
	cmp	r0, #1
	bhi	3f

	/* UART0 base: 0x20080000. */
	movw	r1, #0x0000
	movt	r1, #0x2008

	/* Do not disable the transmitter while U-Boot still has output in flight. */
1:
	ldr	r2, [r1, #0x18]
	tst	r2, #0x08
	bne	1b

	/* Preserve the line format, then commit the replacement divisors. */
	ldr	r3, [r1, #0x2c]
	mov	r2, #0
	str	r2, [r1, #0x30]
	dsb	sy

	/* CRG + 0xe4 bit 13 selects the live 3 MHz source when set. */
	movw	r0, #0x00e4
	movt	r0, #0x2003
	ldr	r2, [r12, #12]
	cmp	r2, #1
	ldr	r2, [r0]
	biceq	r2, r2, #0x2000
	orrne	r2, r2, #0x2000
	str	r2, [r0]
	dsb	sy

	ldr	r2, [r12, #4]
	str	r2, [r1, #0x24]
	ldr	r2, [r12, #8]
	str	r2, [r1, #0x28]
	str	r3, [r1, #0x2c]
	dsb	sy
	movw	r2, #0x0301
	str	r2, [r1, #0x30]
	dsb	sy

	/*
	 * Timer0 is already a decrementing free-running counter at 310 MHz / 2 /
	 * 256. Wait two seconds (1,210,938 ticks), including counter wrap.
	 */
	movw	r1, #0x0004
	movt	r1, #0x2000
	ldr	r2, [r1]
	movw	r0, #0x7a3a
	movt	r0, #0x0012
2:
	ldr	r3, [r1]
	sub	r3, r2, r3
	cmp	r3, r0
	blo	2b

	/* U-Boot's go command treats r0 as the application's return value. */
	mov	r0, #0
	bx	lr

3:
	mov	r0, #1
	bx	lr
	.size _start, . - _start

	/* The controller patches this record without modifying executable code. */
	.org 0x100, 0
.Lparams:
	.word 0x54524155
	.word 0
	.word 0
	.word 0
