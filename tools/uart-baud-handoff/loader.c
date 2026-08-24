/* Freestanding RAM-only YMODEM-G receiver for the Hi3531 PL011 console. */
typedef unsigned char u8;
typedef unsigned int u32;

#define UART_BASE 0x20080000u
#define UART_DR 0x00u
#define UART_ECR 0x04u
#define UART_FR 0x18u
#define UART_IBRD 0x24u
#define UART_FBRD 0x28u
#define UART_LCR_H 0x2cu
#define UART_CR 0x30u
#define UART_FR_BUSY 0x08u
#define UART_FR_RXFE 0x10u
#define UART_FR_TXFF 0x20u
#define UART_DR_ERROR 0x0f00u

#define CRG_UART 0x200300e4u
#define CRG_UART_SLOW_CLOCK 0x2000u
#define TIMER_VALUE 0x20000004u
#define TIMER_HZ 605469u
#define BYTE_TIMEOUT_TICKS (3u * TIMER_HZ)
#define HANDOFF_DELAY_TICKS (2u * TIMER_HZ)

#define SOH 0x01u
#define STX 0x02u
#define EOT 0x04u
#define ACK 0x06u
#define CAN 0x18u
#define STREAM_REQUEST 0x47u

#define PARAM_MAGIC 0x474d4459u /* "YDMG" in little-endian memory. */
#define PARAM_VERSION 1u
#define LOADER_START 0x83000000u
#define LOADER_END 0x83004000u
#define DESTINATION_START 0x82000000u
#define DESTINATION_END 0x83000000u

enum result {
	RESULT_OK = 0,
	RESULT_PARAMS = 1,
	RESULT_BASELINE = 2,
	RESULT_TIMEOUT = 3,
	RESULT_UART = 4,
	RESULT_MARKER = 5,
	RESULT_SEQUENCE = 6,
	RESULT_BLOCK_CRC = 7,
	RESULT_LENGTH = 8,
	RESULT_IMAGE_CRC = 9,
	RESULT_FINAL_HEADER = 10,
};

struct params {
	u32 magic;
	u32 version;
	u32 ibrd;
	u32 fbrd;
	u32 use_apb_clock;
	u32 destination;
	u32 length;
	u32 expected_crc32;
};

struct saved_uart {
	u32 crg;
	u32 ibrd;
	u32 fbrd;
	u32 lcr_h;
	u32 cr;
};

__attribute__((section(".params"), used))
struct params loader_params = {
	PARAM_MAGIC,
	PARAM_VERSION,
	0,
	0,
	0,
	0,
	0,
	0,
};

static volatile u32 *reg(u32 address)
{
	return (volatile u32 *)address;
}

static void barrier(void)
{
	__asm__ volatile("dsb sy" ::: "memory");
}

static u32 timer_read(void)
{
	return *reg(TIMER_VALUE);
}

static u32 elapsed(u32 start)
{
	return start - timer_read();
}

static void delay_ticks(u32 ticks)
{
	u32 start = timer_read();

	while (elapsed(start) < ticks)
		;
}

static int wait_tx_idle(void)
{
	u32 start = timer_read();

	while (*reg(UART_BASE + UART_FR) & UART_FR_BUSY) {
		if (elapsed(start) >= BYTE_TIMEOUT_TICKS)
			return RESULT_TIMEOUT;
	}
	return RESULT_OK;
}

static int put_byte(u8 value)
{
	u32 start = timer_read();

	while (*reg(UART_BASE + UART_FR) & UART_FR_TXFF) {
		if (elapsed(start) >= BYTE_TIMEOUT_TICKS)
			return RESULT_TIMEOUT;
	}
	*reg(UART_BASE + UART_DR) = value;
	return RESULT_OK;
}

static int get_byte(u8 *value)
{
	u32 start = timer_read();
	u32 data;

	while (*reg(UART_BASE + UART_FR) & UART_FR_RXFE) {
		if (elapsed(start) >= BYTE_TIMEOUT_TICKS)
			return RESULT_TIMEOUT;
	}
	data = *reg(UART_BASE + UART_DR);
	if (data & UART_DR_ERROR) {
		*reg(UART_BASE + UART_ECR) = 0;
		return RESULT_UART;
	}
	*value = (u8)data;
	return RESULT_OK;
}

static void drain_rx(void)
{
	while (!(*reg(UART_BASE + UART_FR) & UART_FR_RXFE))
		(void)*reg(UART_BASE + UART_DR);
	*reg(UART_BASE + UART_ECR) = 0;
}

static u32 crc16_byte(u32 crc, u8 value)
{
	u32 bit;

	crc ^= (u32)value << 8;
	for (bit = 0; bit < 8; ++bit) {
		if (crc & 0x8000u)
			crc = (crc << 1) ^ 0x1021u;
		else
			crc <<= 1;
	}
	return crc & 0xffffu;
}

static u32 crc32_byte(u32 crc, u8 value)
{
	u32 bit;

	crc ^= value;
	for (bit = 0; bit < 8; ++bit) {
		if (crc & 1u)
			crc = (crc >> 1) ^ 0xedb88320u;
		else
			crc >>= 1;
	}
	return crc;
}

static int receive_packet(u8 marker, u8 expected_sequence, u8 *destination,
			  u32 keep, u32 *image_crc, u8 *scratch)
{
	u32 block_size;
	u32 block_crc = 0;
	u32 received_crc;
	u32 index;
	u8 sequence;
	u8 complement;
	u8 value;
	int result;

	if (marker == SOH)
		block_size = 128;
	else if (marker == STX)
		block_size = 1024;
	else
		return RESULT_MARKER;

	result = get_byte(&sequence);
	if (result)
		return result;
	result = get_byte(&complement);
	if (result)
		return result;
	if (sequence != expected_sequence || (u8)(sequence + complement) != 0xffu)
		return RESULT_SEQUENCE;

	for (index = 0; index < block_size; ++index) {
		result = get_byte(&value);
		if (result)
			return result;
		block_crc = crc16_byte(block_crc, value);
		if (scratch)
			scratch[index] = value;
		if (destination && index < keep) {
			destination[index] = value;
			*image_crc = crc32_byte(*image_crc, value);
		}
	}

	result = get_byte(&value);
	if (result)
		return result;
	received_crc = (u32)value << 8;
	result = get_byte(&value);
	if (result)
		return result;
	received_crc |= value;
	if (block_crc != received_crc)
		return RESULT_BLOCK_CRC;
	return RESULT_OK;
}

static int parse_header_length(const u8 *header, u32 *length)
{
	u32 index = 0;
	u32 value = 0;
	u32 digits = 0;

	if (header[0] == 0)
		return RESULT_LENGTH;
	while (index < 128 && header[index] != 0)
		++index;
	if (index == 128)
		return RESULT_LENGTH;
	++index;
	while (index < 128 && header[index] >= '0' && header[index] <= '9') {
		u32 digit = header[index++] - '0';

		if (value > 0xffffffffu / 10u)
			return RESULT_LENGTH;
		value *= 10u;
		if (value > 0xffffffffu - digit)
			return RESULT_LENGTH;
		value += digit;
		++digits;
	}
	if (!digits)
		return RESULT_LENGTH;
	*length = value;
	return RESULT_OK;
}

static int validate_params(const struct params *parameters)
{
	u32 end;

	if (parameters->magic != PARAM_MAGIC || parameters->version != PARAM_VERSION)
		return RESULT_PARAMS;
	if (parameters->ibrd < 1 || parameters->ibrd > 0xffffu || parameters->fbrd > 63)
		return RESULT_PARAMS;
	if (parameters->use_apb_clock != 1)
		return RESULT_PARAMS;
	if (parameters->destination < DESTINATION_START || parameters->length == 0)
		return RESULT_PARAMS;
	end = parameters->destination + parameters->length;
	if (end < parameters->destination || end > DESTINATION_END)
		return RESULT_PARAMS;
	if (parameters->destination < LOADER_END && end > LOADER_START)
		return RESULT_PARAMS;
	return RESULT_OK;
}

static int switch_uart(const struct params *parameters, struct saved_uart *saved)
{
	int result;

	saved->crg = *reg(CRG_UART);
	saved->ibrd = *reg(UART_BASE + UART_IBRD);
	saved->fbrd = *reg(UART_BASE + UART_FBRD);
	saved->lcr_h = *reg(UART_BASE + UART_LCR_H);
	saved->cr = *reg(UART_BASE + UART_CR);
	if (!(saved->crg & CRG_UART_SLOW_CLOCK) || saved->ibrd != 1 ||
	    saved->fbrd != 40 || saved->cr != 0x301u)
		return RESULT_BASELINE;

	result = wait_tx_idle();
	if (result)
		return result;
	drain_rx();
	*reg(UART_BASE + UART_CR) = 0;
	barrier();
	*reg(CRG_UART) = saved->crg & ~CRG_UART_SLOW_CLOCK;
	barrier();
	*reg(UART_BASE + UART_IBRD) = parameters->ibrd;
	*reg(UART_BASE + UART_FBRD) = parameters->fbrd;
	*reg(UART_BASE + UART_LCR_H) = saved->lcr_h;
	barrier();
	*reg(UART_BASE + UART_CR) = saved->cr;
	barrier();
	return RESULT_OK;
}

static void restore_uart(const struct saved_uart *saved)
{
	(void)wait_tx_idle();
	*reg(UART_BASE + UART_CR) = 0;
	barrier();
	*reg(CRG_UART) = saved->crg;
	barrier();
	*reg(UART_BASE + UART_IBRD) = saved->ibrd;
	*reg(UART_BASE + UART_FBRD) = saved->fbrd;
	*reg(UART_BASE + UART_LCR_H) = saved->lcr_h;
	barrier();
	*reg(UART_BASE + UART_CR) = saved->cr;
	barrier();
}

static void cancel_transfer(void)
{
	u32 count;

	for (count = 0; count < 8; ++count)
		(void)put_byte(CAN);
	(void)wait_tx_idle();
}

static int receive_image(const struct params *parameters)
{
	u8 header[128];
	u8 marker;
	u8 sequence = 1;
	u8 *destination = (u8 *)parameters->destination;
	u32 remaining = parameters->length;
	u32 announced_length;
	u32 image_crc = 0xffffffffu;
	int result;

	result = put_byte(STREAM_REQUEST);
	if (result)
		return result;
	result = get_byte(&marker);
	if (result)
		return result;
	if (marker != SOH)
		return RESULT_MARKER;
	result = receive_packet(marker, 0, 0, 0, 0, header);
	if (result)
		return result;
	result = parse_header_length(header, &announced_length);
	if (result || announced_length != parameters->length)
		return RESULT_LENGTH;
	result = put_byte(ACK);
	if (result)
		return result;
	result = put_byte(STREAM_REQUEST);
	if (result)
		return result;

	while (remaining) {
		u32 block_size;
		u32 keep;

		result = get_byte(&marker);
		if (result)
			return result;
		block_size = marker == SOH ? 128u : marker == STX ? 1024u : 0u;
		if (!block_size)
			return RESULT_MARKER;
		keep = remaining < block_size ? remaining : block_size;
		result = receive_packet(marker, sequence, destination, keep,
					&image_crc, 0);
		if (result)
			return result;
		destination += keep;
		remaining -= keep;
		++sequence;
	}

	result = get_byte(&marker);
	if (result)
		return result;
	if (marker != EOT)
		return RESULT_MARKER;
	if ((image_crc ^ 0xffffffffu) != parameters->expected_crc32)
		return RESULT_IMAGE_CRC;
	result = put_byte(ACK);
	if (result)
		return result;
	result = put_byte(STREAM_REQUEST);
	if (result)
		return result;
	result = get_byte(&marker);
	if (result)
		return result;
	if (marker != SOH)
		return RESULT_FINAL_HEADER;
	result = receive_packet(marker, 0, 0, 0, 0, header);
	if (result || header[0] != 0)
		return RESULT_FINAL_HEADER;
	result = put_byte(ACK);
	if (result)
		return result;
	return wait_tx_idle();
}

__attribute__((section(".text.entry"), used))
int loader_entry(void)
{
	struct saved_uart saved;
	int result;

	result = validate_params(&loader_params);
	if (result)
		return result;
	result = switch_uart(&loader_params, &saved);
	if (result)
		return result;
	delay_ticks(HANDOFF_DELAY_TICKS);
	result = receive_image(&loader_params);
	if (result)
		cancel_transfer();
	restore_uart(&saved);
	delay_ticks(HANDOFF_DELAY_TICKS);
	return result;
}
