// SPDX-License-Identifier: GPL-2.0-only
/*
 * Small TCA9535 LED test utility.
 *
 * The proven pre-DRAM diagnostic maps LED 0..7 to TCA9535 port 0 bits 0..7
 * and LED 8..15 to port 1 bits 0..7.  The LED sinks are active low.
 */

#define _DEFAULT_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_BUS "/dev/i2c-0"
#define TCA9535_ADDRESS 0x20
#define TCA9535_OUTPUT0 0x02
#define TCA9535_OUTPUT1 0x03
#define TCA9535_CONFIG0 0x06
#define TCA9535_CONFIG1 0x07

static volatile sig_atomic_t running = 1;
static int i2c_fd = -1;

static void stop_animation(int signal_number)
{
	(void)signal_number;
	running = 0;
}

static void report_errno(const char *operation)
{
	fprintf(stderr, "ledtest: %s: %s\n", operation, strerror(errno));
}

static int write_register(uint8_t reg, uint8_t value)
{
	uint8_t message[2] = { reg, value };
	ssize_t written = write(i2c_fd, message, sizeof(message));

	if (written == (ssize_t)sizeof(message))
		return 0;

	if (written < 0)
		report_errno("I2C register write");
	else
		fprintf(stderr, "ledtest: short I2C register write\n");
	return -1;
}

/* on_mask uses the diagnostic's LED numbering; hardware outputs are active low. */
static int set_led_mask(uint16_t on_mask)
{
	uint16_t output = (uint16_t)~on_mask;

	if (write_register(TCA9535_OUTPUT0, (uint8_t)(output & 0xff)) < 0)
		return -1;
	return write_register(TCA9535_OUTPUT1, (uint8_t)(output >> 8));
}

static int initialise_tca9535(void)
{
	if (set_led_mask(0) < 0 ||
	    write_register(TCA9535_CONFIG0, 0x00) < 0 ||
	    write_register(TCA9535_CONFIG1, 0x00) < 0)
		return -1;
	return set_led_mask(0);
}

static int sleep_ms(unsigned int milliseconds)
{
	struct timespec delay = {
		.tv_sec = milliseconds / 1000,
		.tv_nsec = (long)(milliseconds % 1000) * 1000000L,
	};

	while (running && nanosleep(&delay, &delay) < 0) {
		if (errno != EINTR) {
			report_errno("nanosleep");
			return -1;
		}
	}
	return 0;
}

struct activity_state {
	uint32_t rng;
	uint16_t mask;
	unsigned int cursor;
	unsigned int level;
	unsigned int burst_ticks;
	unsigned int idle_ticks;
	unsigned int burst_level;
};

static uint32_t activity_random(struct activity_state *state)
{
	uint32_t value = state->rng;

	/* xorshift32: small, fast, and sufficient for synthetic panel activity. */
	value ^= value << 13;
	value ^= value >> 17;
	value ^= value << 5;
	state->rng = value;
	return value;
}

static unsigned int activity_random_below(struct activity_state *state,
						 unsigned int limit)
{
	return activity_random(state) % limit;
}

static unsigned int activity_led_count(uint16_t mask)
{
	unsigned int count = 0;

	while (mask) {
		count += mask & 1;
		mask >>= 1;
	}
	return count;
}

static unsigned int activity_choose_bit(struct activity_state *state,
						int want_on)
{
	for (unsigned int attempt = 0; attempt < 10; attempt++) {
		unsigned int bit;

		if (activity_random_below(state, 100) < 75) {
			int candidate = (int)state->cursor +
				(int)activity_random_below(state, 5) - 2;

			candidate = (candidate + 32) % 16;
			bit = (unsigned int)candidate;
		} else {
			bit = activity_random_below(state, 16);
		}

		if (((state->mask >> bit) & 1U) != (unsigned int)want_on)
			return bit;
	}

	/* Fall back to a deterministic scan only when the preferred polarity is rare. */
	for (unsigned int offset = 0; offset < 16; offset++) {
		unsigned int bit = (state->cursor + offset) % 16;

		if (((state->mask >> bit) & 1U) != (unsigned int)want_on)
			return bit;
	}
	return state->cursor;
}

static uint32_t activity_seed(void)
{
	struct timespec now;
	uint32_t seed;

	seed = (uint32_t)getpid() ^ (uint32_t)(uintptr_t)&now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
		seed ^= (uint32_t)now.tv_sec ^ (uint32_t)now.tv_nsec;
	return seed ? seed : 0x6d696e69U;
}

static void activity_schedule(struct activity_state *state,
				      unsigned int *changes,
				      unsigned int *delay_ms,
				      unsigned int *effective_level)
{
	if (state->idle_ticks) {
		state->idle_ticks--;
		*effective_level = 5 + activity_random_below(state, 13);
		*changes = activity_random_below(state, 100) < 25 ? 1 : 0;
		*delay_ms = 260 + activity_random_below(state, 180);
		return;
	}

	if (state->burst_ticks) {
		state->burst_ticks--;
		*effective_level = state->burst_level;
		*changes = 3 + activity_random_below(state, 5);
		*delay_ms = 25 + activity_random_below(state, 50);
		return;
	}

	/* Slowly drift the ordinary workload instead of selecting a new frame. */
	{
		int drift = (int)activity_random_below(state, 7) - 3;
		int next_level = (int)state->level + drift;

		if (next_level < 12)
			next_level = 12;
		if (next_level > 72)
			next_level = 72;
		state->level = (unsigned int)next_level;
	}

	/* Rare mode changes create pauses and bursts with different time scales. */
	{
		unsigned int event = activity_random_below(state, 100);

		if (event < 4) {
			state->idle_ticks = 6 + activity_random_below(state, 8);
			*effective_level = 5 + activity_random_below(state, 13);
			*changes = 0;
			*delay_ms = 260 + activity_random_below(state, 180);
			return;
		}
		if (event < 11) {
			state->burst_ticks = 7 + activity_random_below(state, 10);
			state->burst_level = 72 + activity_random_below(state, 29);
			*effective_level = state->burst_level;
			*changes = 3 + activity_random_below(state, 5);
			*delay_ms = 25 + activity_random_below(state, 50);
			return;
		}
	}

	*effective_level = state->level;
	*changes = 1;
	if (activity_random_below(state, 100) < state->level)
		(*changes)++;
	if (state->level > 50 && activity_random_below(state, 100) < 70)
		(*changes)++;
	if (activity_random_below(state, 100) < 12)
		(*changes)++;
	*delay_ms = 70 + activity_random_below(state, 190);
}

static int run_activity(void)
{
	struct activity_state state = {
		.rng = activity_seed(),
		.mask = 0,
		.cursor = 0,
		.level = 32,
	};

	state.level += activity_random_below(&state, 25);
	state.cursor = activity_random_below(&state, 16);
	while (running) {
		unsigned int changes;
		unsigned int delay_ms;
		unsigned int effective_level;
		unsigned int target;

		activity_schedule(&state, &changes, &delay_ms, &effective_level);
		target = (effective_level * 16 + 50) / 100;
		for (unsigned int i = 0; i < changes && running; i++) {
			unsigned int count = activity_led_count(state.mask);
			int want_on;
			unsigned int bit;

			if (count < target)
				want_on = 1;
			else if (count > target)
				want_on = 0;
			else if (count == 0)
				want_on = 1;
			else if (count == 16)
				want_on = 0;
			else
				want_on = (int)(activity_random(&state) & 1U);

			bit = activity_choose_bit(&state, want_on);
			if (want_on)
				state.mask |= (uint16_t)1 << bit;
			else
				state.mask &= ~((uint16_t)1 << bit);
			state.cursor = bit;
		}

		if (changes && set_led_mask(state.mask) < 0)
			return -1;
		if (sleep_ms(delay_ms) < 0)
			return -1;
	}
	return 0;
}

static int run_blink(void)
{
	while (running) {
		if (set_led_mask(0xffff) < 0 || sleep_ms(350) < 0 ||
		    set_led_mask(0) < 0 || sleep_ms(350) < 0)
			return -1;
	}
	return 0;
}

static int run_chase(void)
{
	while (running) {
		for (unsigned int led = 0; led < 16 && running; led++) {
			if (set_led_mask((uint16_t)1 << led) < 0 || sleep_ms(80) < 0)
				return -1;
		}
	}
	return 0;
}

static int run_bounce(void)
{
	while (running) {
		for (int led = 0; led < 16 && running; led++) {
			if (set_led_mask((uint16_t)1 << led) < 0 || sleep_ms(70) < 0)
				return -1;
		}
		for (int led = 14; led > 0 && running; led--) {
			if (set_led_mask((uint16_t)1 << led) < 0 || sleep_ms(70) < 0)
				return -1;
		}
	}
	return 0;
}

static void usage(const char *program)
{
	fprintf(stderr,
		"Usage: %s [-b /dev/i2c-X] MODE\n"
		"\n"
		"Modes: all-on all-off checker blink chase bounce activity\n"
		"Animations run until interrupted.\n",
		program);
}

int main(int argc, char **argv)
{
	const char *bus = DEFAULT_BUS;
	const char *mode;
	int arg = 1;
	int result = 0;
	int cleanup = 0;

	if (argc >= 3 && (!strcmp(argv[arg], "-b") ||
				  !strcmp(argv[arg], "--bus"))) {
		bus = argv[arg + 1];
		arg += 2;
	}
	if (argc != arg + 1) {
		usage(argv[0]);
		return EXIT_FAILURE;
	}
	mode = argv[arg];

	i2c_fd = open(bus, O_RDWR);
	if (i2c_fd < 0) {
		report_errno(bus);
		return EXIT_FAILURE;
	}
	if (ioctl(i2c_fd, I2C_SLAVE, TCA9535_ADDRESS) < 0) {
		report_errno("selecting TCA9535 address 0x20");
		close(i2c_fd);
		return EXIT_FAILURE;
	}
	if (initialise_tca9535() < 0) {
		close(i2c_fd);
		return EXIT_FAILURE;
	}

	signal(SIGINT, stop_animation);
	signal(SIGTERM, stop_animation);
	if (!strcmp(mode, "all-on"))
		result = set_led_mask(0xffff);
	else if (!strcmp(mode, "all-off"))
		result = set_led_mask(0);
	else if (!strcmp(mode, "checker"))
		result = set_led_mask(0xaaaa);
	else if (!strcmp(mode, "blink")) {
		cleanup = 1;
		result = run_blink();
	} else if (!strcmp(mode, "chase")) {
		cleanup = 1;
		result = run_chase();
	} else if (!strcmp(mode, "bounce")) {
		cleanup = 1;
		result = run_bounce();
	} else if (!strcmp(mode, "activity")) {
		cleanup = 1;
		result = run_activity();
	} else {
		usage(argv[0]);
		result = -1;
	}

	if (cleanup && set_led_mask(0) < 0)
		result = -1;
	close(i2c_fd);
	return result < 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}
