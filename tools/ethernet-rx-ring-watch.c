// SPDX-License-Identifier: GPL-2.0-or-later
/* Sample the Hi3531 GMAC1 RX descriptors and receive-path registers. */

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

#define GMAC_BASE 0x101c0000UL
#define GMAC_LENGTH 0x8000UL
#define DMA_RX_DESC_LIST 0x110cUL
#define DMA_STATUS 0x1114UL
#define DMA_OP_MODE 0x1118UL
#define DMA_INTR_ENA 0x111cUL
#define DMA_CUR_RX_DESC 0x114cUL
#define DMA_CUR_RX_BUF 0x1154UL
#define GMAC_DEBUG 0x4024UL
#define DESC_OWN 0x80000000U

static uint64_t monotonic_ns(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now)) {
		perror("clock_gettime");
		exit(1);
	}
	return (uint64_t)now.tv_sec * UINT64_C(1000000000) + now.tv_nsec;
}

static unsigned long parse(const char *text, const char *name)
{
	char *end;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 0);
	if (errno || !value || *end) {
		fprintf(stderr, "%s must be a positive integer: %s\n", name, text);
		exit(2);
	}
	return value;
}

int main(int argc, char **argv)
{
	volatile uint32_t *registers;
	volatile uint32_t *descriptors;
	uint64_t start, duration_ns, interval_ns, next;
	unsigned long ring_entries, descriptor_bytes, seconds, interval_ms;
	unsigned long page_size, descriptor_base, descriptor_offset, map_length;
	void *register_map, *descriptor_map;
	int fd;

	if (argc != 5) {
		fprintf(stderr, "usage: %s RING_ENTRIES DESCRIPTOR_BYTES INTERVAL_MS SECONDS\n",
			argv[0]);
		return 2;
	}
	ring_entries = parse(argv[1], "ring entries");
	descriptor_bytes = parse(argv[2], "descriptor bytes");
	interval_ms = parse(argv[3], "interval milliseconds");
	seconds = parse(argv[4], "seconds");
	if (descriptor_bytes != 16 && descriptor_bytes != 32) {
		fprintf(stderr, "descriptor bytes must be 16 (vendor) or 32 (mainline enhanced)\n");
		return 2;
	}

	fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}
	register_map = mmap(NULL, GMAC_LENGTH, PROT_READ, MAP_SHARED, fd, GMAC_BASE);
	if (register_map == MAP_FAILED) {
		perror("mmap GMAC");
		return 1;
	}
	registers = register_map;
	descriptor_base = registers[DMA_RX_DESC_LIST / sizeof(*registers)];
	page_size = sysconf(_SC_PAGESIZE);
	descriptor_offset = descriptor_base % page_size;
	map_length = descriptor_offset + ring_entries * descriptor_bytes;
	descriptor_map = mmap(NULL, map_length, PROT_READ, MAP_SHARED, fd,
			      descriptor_base - descriptor_offset);
	if (descriptor_map == MAP_FAILED) {
		perror("mmap RX descriptors");
		return 1;
	}
	descriptors = (volatile uint32_t *)((uint8_t *)descriptor_map + descriptor_offset);

	printf("elapsed_s,dma_owned,cpu_owned,csr3,csr5,csr6,csr7,csr19,csr21,debug\n");
	start = monotonic_ns();
	duration_ns = seconds * UINT64_C(1000000000);
	interval_ns = interval_ms * UINT64_C(1000000);
	next = start;
	while (monotonic_ns() - start < duration_ns) {
		uint64_t now = monotonic_ns();
		unsigned long index, dma_owned = 0;

		if (now < next)
			continue;
		for (index = 0; index < ring_entries; index++)
			if (descriptors[index * descriptor_bytes / sizeof(*descriptors)] & DESC_OWN)
				dma_owned++;
		printf("%.6f,%lu,%lu,%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32
		       ",%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32 "\n",
		       (double)(now - start) / 1000000000, dma_owned,
		       ring_entries - dma_owned, registers[DMA_RX_DESC_LIST / 4],
		       registers[DMA_STATUS / 4], registers[DMA_OP_MODE / 4],
		       registers[DMA_INTR_ENA / 4], registers[DMA_CUR_RX_DESC / 4],
		       registers[DMA_CUR_RX_BUF / 4], registers[GMAC_DEBUG / 4]);
		fflush(stdout);
		next += interval_ns;
	}
	return 0;
}
