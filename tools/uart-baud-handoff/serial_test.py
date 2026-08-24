#!/usr/bin/env python3
"""Run a parameterized RAM-only U-Boot baud handoff from the Raspberry Pi."""

import argparse
import binascii
import os
import re
import select
import struct
import sys
import termios
import time
import tty


SOH = 0x01
STX = 0x02
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
CRC_REQUEST = ord("C")
STREAM_REQUEST = ord("G")
PROMPT = b"hisilicon #"
PARAM_OFFSET = 0x100
PARAM_MAGIC = 0x54524155
STUB_SIZE = 1024
APB_UART_CLOCK = 155_000_000
LOADER_ADDRESS = 0x83000000
LOADER_PARAM_OFFSET = 0x3000
LOADER_PARAM_MAGIC = 0x474D4459
LOADER_PARAM_VERSION = 1
LOADER_SIZE = 16 * 1024
RESTORE_ADDRESS = 0x83010000


def baud_divisors(clock, baud):
    if clock <= 0 or baud <= 0:
        raise ValueError("clock and baud must be positive")
    divisor_units = (clock * 4 + baud // 2) // baud
    ibrd, fbrd = divmod(divisor_units, 64)
    if not 1 <= ibrd <= 0xFFFF:
        raise ValueError(
            f"baud {baud} is outside the PL011 divisor range for a {clock} Hz clock"
        )
    actual_baud = clock * 4 / divisor_units
    return ibrd, fbrd, actual_baud


def make_profile(template, ibrd, fbrd, use_apb_clock):
    if len(template) != STUB_SIZE:
        raise ValueError(f"stub template must be exactly {STUB_SIZE} bytes")
    magic, template_ibrd, template_fbrd, template_clock = struct.unpack_from(
        "<IIII", template, PARAM_OFFSET
    )
    if magic != PARAM_MAGIC or any((template_ibrd, template_fbrd, template_clock)):
        raise ValueError("stub template has an unexpected parameter record")
    if not 1 <= ibrd <= 0xFFFF:
        raise ValueError("IBRD must be in the range 1..65535")
    if not 0 <= fbrd <= 63:
        raise ValueError("FBRD must be in the range 0..63")
    if not isinstance(use_apb_clock, bool):
        raise ValueError("clock selector must be a boolean")

    profile = bytearray(template)
    struct.pack_into(
        "<IIII", profile, PARAM_OFFSET, PARAM_MAGIC, ibrd, fbrd, int(use_apb_clock)
    )
    return bytes(profile)


def make_loader_profile(template, ibrd, fbrd, destination, length, expected_crc):
    if len(template) != LOADER_SIZE:
        raise ValueError(f"loader template must be exactly {LOADER_SIZE} bytes")
    values = struct.unpack_from("<IIIIIIII", template, LOADER_PARAM_OFFSET)
    if values[:2] != (LOADER_PARAM_MAGIC, LOADER_PARAM_VERSION) or any(values[2:]):
        raise ValueError("loader template has an unexpected parameter record")
    if not 1 <= ibrd <= 0xFFFF:
        raise ValueError("IBRD must be in the range 1..65535")
    if not 0 <= fbrd <= 63:
        raise ValueError("FBRD must be in the range 0..63")
    if not 0x82000000 <= destination < 0x83000000:
        raise ValueError("stream destination must be in 0x82000000..0x82ffffff")
    if length <= 0 or destination + length > 0x83000000:
        raise ValueError("stream payload does not fit below the loader")

    profile = bytearray(template)
    struct.pack_into(
        "<IIIIIIII",
        profile,
        LOADER_PARAM_OFFSET,
        LOADER_PARAM_MAGIC,
        LOADER_PARAM_VERSION,
        ibrd,
        fbrd,
        1,
        destination,
        length,
        expected_crc,
    )
    return bytes(profile)


def visible(data):
    return "".join(
        chr(byte) if 32 <= byte < 127 or byte in (10, 13) else f"<{byte:02x}>"
        for byte in data
    )


class Serial:
    def __init__(self, path, baud):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.buffer = bytearray()
        self.set_baud(baud)

    def close(self):
        os.close(self.fd)

    def set_baud(self, baud):
        speed = getattr(termios, f"B{baud}")
        tty.setraw(self.fd, termios.TCSANOW)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] &= ~(termios.IXON | termios.IXOFF | getattr(termios, "IXANY", 0))
        attrs[2] &= ~(
            termios.PARENB
            | termios.CSTOPB
            | termios.CSIZE
            | getattr(termios, "CRTSCTS", 0)
        )
        attrs[2] |= termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = speed
        attrs[5] = speed
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        print(f"[host] UART set to {baud} 8N1, no flow control", flush=True)

    def write(self, data):
        view = memoryview(data)
        while view:
            _, writable, _ = select.select([], [self.fd], [], 2)
            if not writable:
                raise TimeoutError("UART write timed out")
            count = os.write(self.fd, view)
            view = view[count:]
        termios.tcdrain(self.fd)

    def write_stream(self, data):
        """Keep the tty fed continuously while watching for receiver cancellation."""
        view = memoryview(data)
        while view:
            readable, writable, _ = select.select([self.fd], [self.fd], [], 2)
            if not readable and not writable:
                raise TimeoutError("UART streaming write timed out")
            if readable:
                chunk = os.read(self.fd, 4096)
                self.buffer.extend(chunk)
                if CAN in chunk:
                    raise RuntimeError("receiver cancelled the YMODEM-G stream")
            if writable:
                count = os.write(self.fd, view)
                view = view[count:]

    def fill(self, timeout):
        readable, _, _ = select.select([self.fd], [], [], timeout)
        if readable:
            chunk = os.read(self.fd, 4096)
            self.buffer.extend(chunk)
            return chunk
        return b""

    def drain_input(self):
        self.buffer.clear()
        while self.fill(0):
            self.buffer.clear()

    def take_until(self, needle, timeout):
        deadline = time.monotonic() + timeout
        while True:
            index = self.buffer.find(needle)
            if index >= 0:
                end = index + len(needle)
                result = bytes(self.buffer[:end])
                del self.buffer[:end]
                return result
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                captured = bytes(self.buffer)
                self.buffer.clear()
                raise TimeoutError(f"did not receive {needle!r}; captured {visible(captured)!r}")
            self.fill(remaining)

    def read_for(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            self.fill(remaining)
        result = bytes(self.buffer)
        self.buffer.clear()
        return result

    def wait_control(self, accepted, timeout):
        deadline = time.monotonic() + timeout
        while True:
            for index, byte in enumerate(self.buffer):
                if byte == CAN:
                    del self.buffer[: index + 1]
                    raise RuntimeError("receiver cancelled the YMODEM transfer")
                if byte in accepted:
                    del self.buffer[: index + 1]
                    return byte
            self.buffer.clear()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for protocol byte {accepted}")
            self.fill(remaining)


def packet(marker, number, payload, length):
    if len(payload) > length:
        raise ValueError("YMODEM payload exceeds packet length")
    body = payload.ljust(length, b"\0")
    crc = binascii.crc_hqx(body, 0)
    return bytes((marker, number, 0xFF - number)) + body + crc.to_bytes(2, "big")


def send_packet(link, frame):
    for attempt in range(1, 11):
        link.write(frame)
        try:
            response = link.wait_control({ACK, NAK}, 10)
        except TimeoutError:
            print(f"[host] packet ACK timed out; retrying ({attempt}/10)", flush=True)
            continue
        if response == ACK:
            return
        print(f"[host] receiver requested packet retry ({attempt}/10)", flush=True)
    raise RuntimeError("YMODEM packet retry limit exceeded")


def ymodem_send(link, name, data):
    link.wait_control({CRC_REQUEST}, 10)
    transfer_start = time.monotonic()
    header = name.encode("ascii") + b"\0" + str(len(data)).encode("ascii") + b"\0"
    send_packet(link, packet(SOH, 0, header, 128))
    link.wait_control({CRC_REQUEST}, 10)

    data_start = time.monotonic()
    number = 1
    for offset in range(0, len(data), 1024):
        send_packet(link, packet(STX, number, data[offset : offset + 1024], 1024))
        number = (number + 1) & 0xFF
    data_end = time.monotonic()

    for _ in range(10):
        link.write(bytes((EOT,)))
        try:
            response = link.wait_control({ACK, NAK}, 10)
        except TimeoutError:
            continue
        if response == ACK:
            break
    else:
        raise RuntimeError("YMODEM EOT was not acknowledged")

    link.wait_control({CRC_REQUEST}, 10)
    send_packet(link, packet(SOH, 0, b"", 128))
    transfer_end = time.monotonic()
    return {
        "total_seconds": transfer_end - transfer_start,
        "data_seconds": data_end - data_start,
    }


def ymodem_g_send(link, name, data):
    link.wait_control({STREAM_REQUEST}, 6)
    transfer_start = time.monotonic()
    header = name.encode("ascii") + b"\0" + str(len(data)).encode("ascii") + b"\0"
    link.write(packet(SOH, 0, header, 128))
    link.wait_control({ACK}, 3)
    link.wait_control({STREAM_REQUEST}, 3)

    data_start = time.monotonic()
    number = 1
    stream = bytearray()
    for offset in range(0, len(data), 1024):
        stream.extend(packet(STX, number, data[offset : offset + 1024], 1024))
        number = (number + 1) & 0xFF
    print(f"[host] streaming {len(stream)} wire bytes without block pauses", flush=True)
    link.write_stream(stream)
    data_end = time.monotonic()

    link.write(bytes((EOT,)))
    link.wait_control({ACK}, 4)
    link.wait_control({STREAM_REQUEST}, 3)
    link.write(packet(SOH, 0, b"", 128))
    link.wait_control({ACK}, 3)
    transfer_end = time.monotonic()
    return {
        "total_seconds": transfer_end - transfer_start,
        "data_seconds": data_end - data_start,
    }


def command(link, text, timeout=5):
    link.drain_input()
    link.write(b" " + text.encode("ascii") + b"\r")
    output = link.take_until(PROMPT, timeout)
    print(visible(output), flush=True)
    return output


def expect_crc(link, address, length, expected):
    output = command(link, f"crc32 {address:08x} {length:x}")
    matches = re.findall(rb"==>\s*([0-9a-fA-F]{8})", output)
    if not matches:
        raise RuntimeError("U-Boot crc32 output did not contain a result")
    actual = int(matches[-1], 16)
    if actual != expected:
        raise RuntimeError(
            f"CRC mismatch at 0x{address:08x}: expected {expected:08x}, got {actual:08x}"
        )
    print(f"[host] CRC verified at 0x{address:08x}: {actual:08x}", flush=True)


def read_register(link, address):
    output = command(link, f"md.l {address:08x} 1")
    matches = re.findall(fr"{address:08x}:\s*([0-9a-fA-F]{{8}})".encode("ascii"), output)
    if not matches:
        raise RuntimeError(f"register read at 0x{address:08x} did not contain a value")
    value = int(matches[-1], 16)
    print(f"[host] register 0x{address:08x} = 0x{value:08x}", flush=True)
    return value


def expect_register(link, address, expected):
    actual = read_register(link, address)
    if actual != expected:
        raise RuntimeError(
            f"register mismatch at 0x{address:08x}: expected 0x{expected:08x}, got 0x{actual:08x}"
        )


def load(link, address, name, data):
    print(f"[host] loading {name} ({len(data)} bytes) at 0x{address:08x}", flush=True)
    link.drain_input()
    link.write(f" loady {address:08x}\r".encode("ascii"))
    ready = link.take_until(b"bps...\r\n", 5)
    print(visible(ready), flush=True)
    metrics = ymodem_send(link, name, data)
    result = link.take_until(PROMPT, 10)
    print(visible(result), flush=True)
    return metrics


def go_and_switch(link, address, baud):
    print(f"[host] invoking 0x{address:08x} and switching to {baud}", flush=True)
    link.drain_input()
    link.write(f" go {address:08x}\r".encode("ascii"))
    started = link.take_until(b" ...\r\n", 5)
    print(visible(started), flush=True)
    link.set_baud(baud)
    returned = link.take_until(PROMPT, 8)
    print(visible(returned), flush=True)
    if b"rc = 0x0" not in returned:
        raise RuntimeError("stub did not return success through U-Boot go")


def probe(path):
    link = Serial(path, 115200)
    try:
        link.drain_input()
        link.write(b"\r")
        output = link.read_for(3)
        print(visible(output), flush=True)
        return 0 if PROMPT in output else 2
    finally:
        link.close()


def run_commands(path, commands):
    link = Serial(path, 115200)
    try:
        link.drain_input()
        link.write(b"\r")
        synced = link.take_until(PROMPT, 3)
        print(visible(synced), flush=True)
        for text in commands:
            command(link, text)
    finally:
        link.close()


def run(path, stub_path, target_baud, payload_size, payload_address, reset_after):
    with open(stub_path, "rb") as stub_file:
        template = stub_file.read()
    canary_ibrd, canary_fbrd, canary_actual = baud_divisors(APB_UART_CLOCK, 115200)
    target_ibrd, target_fbrd, target_actual = baud_divisors(APB_UART_CLOCK, target_baud)
    canary = make_profile(template, canary_ibrd, canary_fbrd, True)
    target = make_profile(template, target_ibrd, target_fbrd, True)
    restore = make_profile(template, 1, 40, False)
    pattern = bytes(range(256))
    payload = (pattern * ((payload_size + len(pattern) - 1) // len(pattern)))[:payload_size]
    canary_crc = binascii.crc32(canary)
    target_crc = binascii.crc32(target)
    restore_crc = binascii.crc32(restore)
    payload_crc = binascii.crc32(payload)

    print(
        f"[host] APB 115200 profile: IBRD={canary_ibrd} FBRD={canary_fbrd} "
        f"actual={canary_actual:.3f} baud CRC={canary_crc:08x}",
        flush=True,
    )
    print(
        f"[host] APB {target_baud} profile: IBRD={target_ibrd} FBRD={target_fbrd} "
        f"actual={target_actual:.3f} baud CRC={target_crc:08x}",
        flush=True,
    )
    print(f"[host] 3 MHz restoration profile CRC: {restore_crc:08x}", flush=True)
    print(f"[host] payload CRC: {payload_crc:08x}", flush=True)

    link = Serial(path, 115200)
    try:
        link.drain_input()
        link.write(b"\r")
        synced = link.take_until(PROMPT, 3)
        print(visible(synced), flush=True)

        original_crg = read_register(link, 0x200300E4)
        if not original_crg & 0x2000:
            raise RuntimeError("original UART clock-select bit 13 is not set")
        expect_register(link, 0x20080024, 1)
        expect_register(link, 0x20080028, 40)
        original_lcr = read_register(link, 0x2008002C)
        expect_register(link, 0x20080030, 0x301)

        load(link, 0x82000000, "uart-apb-115200.bin", canary)
        expect_crc(link, 0x82000000, len(canary), canary_crc)
        load(link, 0x82001000, f"uart-apb-{target_baud}.bin", target)
        expect_crc(link, 0x82001000, len(target), target_crc)
        load(link, 0x82002000, "uart-3mhz-115200.bin", restore)
        expect_crc(link, 0x82002000, len(restore), restore_crc)

        print("[host] running APB-clock 115200 canary", flush=True)
        go_and_switch(link, 0x82000000, 115200)
        expect_register(link, 0x200300E4, original_crg & ~0x2000)
        expect_register(link, 0x20080024, canary_ibrd)
        expect_register(link, 0x20080028, canary_fbrd)
        expect_register(link, 0x2008002C, original_lcr)
        expect_register(link, 0x20080030, 0x301)

        go_and_switch(link, 0x82001000, target_baud)
        expect_register(link, 0x200300E4, original_crg & ~0x2000)
        expect_register(link, 0x20080024, target_ibrd)
        expect_register(link, 0x20080028, target_fbrd)
        expect_crc(link, 0x82001000, len(target), target_crc)
        metrics = load(link, payload_address, f"uart-payload-{payload_size}.bin", payload)
        expect_crc(link, payload_address, len(payload), payload_crc)
        total_rate = len(payload) * 8 / metrics["total_seconds"] / 1000
        data_rate = len(payload) * 8 / metrics["data_seconds"] / 1000
        total_kib = len(payload) / metrics["total_seconds"] / 1024
        print(
            f"[host] YMODEM timing: total={metrics['total_seconds']:.6f}s "
            f"data={metrics['data_seconds']:.6f}s",
            flush=True,
        )
        print(
            f"[host] effective payload rate: {total_rate:.3f} kb/s "
            f"({total_kib:.3f} KiB/s); data-block phase={data_rate:.3f} kb/s",
            flush=True,
        )

        go_and_switch(link, 0x82002000, 115200)
        expect_register(link, 0x200300E4, original_crg)
        expect_register(link, 0x20080024, 1)
        expect_register(link, 0x20080028, 40)
        expect_register(link, 0x2008002C, original_lcr)
        expect_register(link, 0x20080030, 0x301)
        expect_crc(link, 0x82002000, len(restore), restore_crc)

        if reset_after:
            print("[host] resetting the DVR from restored 115200", flush=True)
            link.drain_input()
            link.write(b" reset\r")
            print(visible(link.read_for(4)), flush=True)
        else:
            print("[host] leaving the DVR at the restored 115200 U-Boot prompt", flush=True)
    finally:
        link.close()


def run_stream(path, stub_path, loader_path, target_baud, payload, payload_address):
    with open(stub_path, "rb") as stub_file:
        stub_template = stub_file.read()
    with open(loader_path, "rb") as loader_file:
        loader_template = loader_file.read()

    target_ibrd, target_fbrd, target_actual = baud_divisors(
        APB_UART_CLOCK, target_baud
    )
    payload_crc = binascii.crc32(payload)
    loader = make_loader_profile(
        loader_template,
        target_ibrd,
        target_fbrd,
        payload_address,
        len(payload),
        payload_crc,
    )
    restore = make_profile(stub_template, 1, 40, False)
    loader_crc = binascii.crc32(loader)
    restore_crc = binascii.crc32(restore)

    print(
        f"[host] streaming receiver: IBRD={target_ibrd} FBRD={target_fbrd} "
        f"actual={target_actual:.3f} baud CRC={loader_crc:08x}",
        flush=True,
    )
    print(
        f"[host] payload: {len(payload)} bytes to 0x{payload_address:08x} "
        f"CRC={payload_crc:08x}",
        flush=True,
    )
    print(f"[host] independent 115200 restoration stub CRC={restore_crc:08x}", flush=True)

    link = Serial(path, 115200)
    switched = False
    completed = False
    try:
        link.drain_input()
        link.write(b"\r")
        synced = link.take_until(PROMPT, 3)
        print(visible(synced), flush=True)

        original_crg = read_register(link, 0x200300E4)
        if not original_crg & 0x2000:
            raise RuntimeError("original UART clock-select bit 13 is not set")
        expect_register(link, 0x20080024, 1)
        expect_register(link, 0x20080028, 40)
        original_lcr = read_register(link, 0x2008002C)
        expect_register(link, 0x20080030, 0x301)

        load(link, LOADER_ADDRESS, "uart-ymodem-g-loader.bin", loader)
        expect_crc(link, LOADER_ADDRESS, len(loader), loader_crc)
        load(link, RESTORE_ADDRESS, "uart-3mhz-115200.bin", restore)
        expect_crc(link, RESTORE_ADDRESS, len(restore), restore_crc)

        print(
            f"[host] invoking receiver at 0x{LOADER_ADDRESS:08x}; "
            f"it will restore 115200 before returning",
            flush=True,
        )
        link.drain_input()
        link.write(f" go {LOADER_ADDRESS:08x}\r".encode("ascii"))
        started = link.take_until(b" ...\r\n", 5)
        print(visible(started), flush=True)
        link.set_baud(target_baud)
        switched = True
        metrics = ymodem_g_send(link, "stream.bin", payload)

        # The final ACK is sent at the target rate. The receiver then restores
        # the exact saved UART registers, delays, and returns to U-Boot.
        link.set_baud(115200)
        switched = False
        returned = link.take_until(PROMPT, 6)
        print(visible(returned), flush=True)
        if b"rc = 0x0" not in returned:
            raise RuntimeError("stream receiver did not return success through U-Boot go")
        completed = True

        expect_register(link, 0x200300E4, original_crg)
        expect_register(link, 0x20080024, 1)
        expect_register(link, 0x20080028, 40)
        expect_register(link, 0x2008002C, original_lcr)
        expect_register(link, 0x20080030, 0x301)
        expect_crc(link, LOADER_ADDRESS, len(loader), loader_crc)
        expect_crc(link, RESTORE_ADDRESS, len(restore), restore_crc)
        expect_crc(link, payload_address, len(payload), payload_crc)

        total_rate = len(payload) * 8 / metrics["total_seconds"] / 1000
        data_rate = len(payload) * 8 / metrics["data_seconds"] / 1000
        print(
            f"[host] YMODEM-G timing: total={metrics['total_seconds']:.6f}s "
            f"data={metrics['data_seconds']:.6f}s",
            flush=True,
        )
        print(
            f"[host] effective payload rate: {total_rate:.3f} kb/s; "
            f"data-block phase={data_rate:.3f} kb/s",
            flush=True,
        )
        print("[host] leaving the DVR at the restored 115200 U-Boot prompt", flush=True)
    except Exception:
        if switched:
            # On a protocol error the receiver sends CAN at the target rate,
            # restores the saved registers, and returns after its delay.
            link.set_baud(115200)
            switched = False
            recovered = link.read_for(5)
            if recovered:
                print(f"[host] recovery output: {visible(recovered)}", flush=True)
        raise
    finally:
        if switched:
            link.set_baud(115200)
        link.close()
        if not completed:
            print(
                f"[host] transfer incomplete; restoration stub remains at "
                f"0x{RESTORE_ADDRESS:08x}",
                flush=True,
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("probe", "commands", "run", "stream"))
    parser.add_argument("--device", default="/dev/serial0")
    parser.add_argument("--stub", default="/tmp/uart-stub-template.bin")
    parser.add_argument("--loader", default="/tmp/uart-ymodem-g-loader.bin")
    parser.add_argument("--target-baud", type=int, default=230400)
    parser.add_argument("--payload-size", type=int, default=1024)
    parser.add_argument(
        "--payload-address", type=lambda value: int(value, 0), default=0x82003000
    )
    parser.add_argument("--reset-after", action="store_true")
    parser.add_argument("--payload-file")
    parser.add_argument("--command", dest="commands", action="append", default=[])
    args = parser.parse_args()
    if args.action == "probe":
        return probe(args.device)
    if args.action == "commands":
        if not args.commands:
            parser.error("commands requires at least one --command")
        run_commands(args.device, args.commands)
        return 0
    if args.payload_size <= 0:
        parser.error("--payload-size must be positive")
    if not hasattr(termios, f"B{args.target_baud}"):
        parser.error(f"the Pi termios implementation does not support {args.target_baud} baud")
    try:
        baud_divisors(APB_UART_CLOCK, args.target_baud)
    except ValueError as error:
        parser.error(str(error))
    if args.action == "stream":
        if args.reset_after:
            parser.error("stream does not support --reset-after")
        if args.payload_file:
            with open(args.payload_file, "rb") as payload_file:
                payload = payload_file.read()
        else:
            pattern = bytes(range(256))
            payload = (
                pattern * ((args.payload_size + len(pattern) - 1) // len(pattern))
            )[: args.payload_size]
        run_stream(
            args.device,
            args.stub,
            args.loader,
            args.target_baud,
            payload,
            args.payload_address,
        )
    else:
        if args.payload_file:
            parser.error("--payload-file is only valid with stream")
        run(
            args.device,
            args.stub,
            args.target_baud,
            args.payload_size,
            args.payload_address,
            args.reset_after,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
