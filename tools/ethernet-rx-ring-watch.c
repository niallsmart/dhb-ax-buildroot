// SPDX-License-Identifier: GPL-2.0-or-later
/* Poll the Hi3531 GMAC1 DMA receive-process state through /dev/mem.
 *
 * The interval trades resolution against the bus bandwidth the poll loop
 * takes from the DMA it is watching.  Suspended episodes have measured from
 * tens of microseconds to 26 milliseconds, so the default catches all but the
 * shortest.  The default busy-polls so this diagnostic can deliberately
 * perturb the interrupt timing; a nonzero interval yields between reads.
 *
 * Sleeping below the timer tick needs CONFIG_HIGH_RES_TIMERS in the kernel;
 * without it every interval rounds up to 1/CONFIG_HZ.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DMA_STATUS_PHYS UINT64_C(0x101c1114)
#define DMA_STATUS_RS_MASK UINT32_C(0x000e0000)
#define DMA_STATUS_RS_SHIFT 17
#define DMA_STATUS_RU UINT32_C(0x00000080)
#define DMA_STATUS_RPS UINT32_C(0x00000100)
#define DMA_RX_SUSPENDED 4
#define DEFAULT_INTERVAL_NS 0L

static volatile sig_atomic_t stopping;

static void stop(int signal_number)
{
	(void)signal_number;
	stopping = 1;
}

static uint64_t monotonic_ns(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now)) {
		perror("clock_gettime");
		exit(1);
	}
	return (uint64_t)now.tv_sec * UINT64_C(1000000000) + now.tv_nsec;
}

static unsigned long parse_seconds(const char *text)
{
	char *end;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 0);
	if (errno || !value || *end) {
		fprintf(stderr, "seconds must be a positive integer: %s\n", text);
		exit(2);
	}
	return value;
}

static long parse_interval(const char *text)
{
	char *end;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 0);
	if (errno || *end || value > 1000000) {
		fprintf(stderr,
			"interval must be from 0 to 1000000 microseconds: %s\n",
			text);
		exit(2);
	}
	return (long)value * 1000L;
}

static timer_t arm_timer(unsigned long seconds)
{
	struct sigevent event = { 0 };
	struct itimerspec timeout = { 0 };
	timer_t timer;

	event.sigev_notify = SIGEV_SIGNAL;
	event.sigev_signo = SIGALRM;
	if (timer_create(CLOCK_MONOTONIC, &event, &timer)) {
		perror("timer_create");
		exit(1);
	}
	timeout.it_value.tv_sec = seconds;
	if (timer_settime(timer, 0, &timeout, NULL)) {
		perror("timer_settime");
		exit(1);
	}
	return timer;
}

static unsigned int receive_state(uint32_t status)
{
	return (status & DMA_STATUS_RS_MASK) >> DMA_STATUS_RS_SHIFT;
}

static void print_event(uint64_t start_ns, uint64_t now_ns, const char *event,
			uint32_t status)
{
	printf("%.9f,%s,%u,%u,%u,%08" PRIx32 "\n",
	       (double)(now_ns - start_ns) / 1000000000.0, event,
	       receive_state(status), !!(status & DMA_STATUS_RU),
	       !!(status & DMA_STATUS_RPS), status);
}

int main(int argc, char **argv)
{
	static char output_buffer[64 * 1024];
	volatile uint32_t *dma_status;
	uint64_t entries = 0, longest_ns = 0, polls = 0, state4_polls = 0;
	uint64_t start_ns, state4_enter_ns = 0, state4_ns = 0, stop_ns;
	struct timespec interval = { .tv_nsec = DEFAULT_INTERVAL_NS };
	unsigned long page_offset, page_size, seconds;
	struct sigaction action = { .sa_handler = stop };
	unsigned int state;
	void *register_map;
	uint32_t status;
	timer_t timer;
	int fd;
	int rps_seen = 0, ru_seen = 0, state4_active;

	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: %s SECONDS [INTERVAL_US]\n", argv[0]);
		return 2;
	}
	seconds = parse_seconds(argv[1]);
	if (argc == 3)
		interval.tv_nsec = parse_interval(argv[2]);

	if (sigemptyset(&action.sa_mask) || sigaction(SIGALRM, &action, NULL) ||
	    sigaction(SIGINT, &action, NULL) ||
	    sigaction(SIGTERM, &action, NULL)) {
		perror("sigaction");
		return 1;
	}

	page_size = sysconf(_SC_PAGESIZE);
	if (!page_size || page_size == (unsigned long)-1) {
		perror("sysconf(_SC_PAGESIZE)");
		return 1;
	}
	page_offset = DMA_STATUS_PHYS % page_size;
	if (page_offset + sizeof(*dma_status) > page_size) {
		fprintf(stderr, "DMA status register crosses a page boundary\n");
		return 1;
	}

	fd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}
	register_map = mmap(NULL, page_size, PROT_READ, MAP_SHARED, fd,
			    DMA_STATUS_PHYS - page_offset);
	if (register_map == MAP_FAILED) {
		perror("mmap DMA status");
		close(fd);
		return 1;
	}
	close(fd);
	dma_status = (volatile uint32_t *)((uint8_t *)register_map + page_offset);

	setvbuf(stdout, output_buffer, _IOFBF, sizeof(output_buffer));
	printf("elapsed_s,event,rx_state,ru,rps,csr5\n");
	printf("# requested_seconds=%lu\n", seconds);
	printf("# interval_us=%ld\n", interval.tv_nsec / 1000);

	start_ns = monotonic_ns();
	timer = arm_timer(seconds);
	status = *dma_status;
	polls = 1;
	state = receive_state(status);
	ru_seen = !!(status & DMA_STATUS_RU);
	rps_seen = !!(status & DMA_STATUS_RPS);
	state4_active = state == DMA_RX_SUSPENDED;
	if (state4_active) {
		entries = 1;
		state4_polls = 1;
		state4_enter_ns = monotonic_ns();
	}
	print_event(start_ns, monotonic_ns(), "initial", status);

	while (!stopping) {
		if (interval.tv_nsec)
			nanosleep(&interval, NULL);
		status = *dma_status;
		polls++;
		state = receive_state(status);
		ru_seen |= !!(status & DMA_STATUS_RU);
		rps_seen |= !!(status & DMA_STATUS_RPS);
		if (state == DMA_RX_SUSPENDED) {
			uint64_t now_ns;

			state4_polls++;
			if (state4_active)
				continue;
			now_ns = monotonic_ns();
			entries++;
			state4_enter_ns = now_ns;
			state4_active = 1;
			print_event(start_ns, now_ns, "state4-enter", status);
		} else if (state4_active) {
			uint64_t episode_ns, now_ns = monotonic_ns();

			episode_ns = now_ns - state4_enter_ns;
			state4_ns += episode_ns;
			if (episode_ns > longest_ns)
				longest_ns = episode_ns;
			state4_active = 0;
			print_event(start_ns, now_ns, "state4-exit", status);
		}
	}

	stop_ns = monotonic_ns();
	if (state4_active) {
		uint64_t episode_ns = stop_ns - state4_enter_ns;

		state4_ns += episode_ns;
		if (episode_ns > longest_ns)
			longest_ns = episode_ns;
	}

	printf("# elapsed_s=%.9f\n", (double)(stop_ns - start_ns) / 1000000000.0);
	printf("# polls=%" PRIu64 "\n", polls);
	printf("# polls_per_second=%.0f\n",
	       (double)polls * 1000000000.0 / (double)(stop_ns - start_ns));
	printf("# state4_entries=%" PRIu64 "\n", entries);
	printf("# state4_polls=%" PRIu64 "\n", state4_polls);
	printf("# state4_s=%.9f\n", (double)state4_ns / 1000000000.0);
	printf("# longest_state4_s=%.9f\n", (double)longest_ns / 1000000000.0);
	printf("# state4_percent=%.6f\n",
	       100.0 * (double)state4_ns / (double)(stop_ns - start_ns));
	printf("# ru_seen=%d\n", ru_seen);
	printf("# rps_seen=%d\n", rps_seen);

	timer_delete(timer);
	munmap(register_map, page_size);
	return 0;
}
