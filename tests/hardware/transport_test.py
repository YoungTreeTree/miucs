"""Exercise the actual Swift serial transport against a pseudo-terminal device."""
import os
import pty
import select
import struct
import subprocess
import time
import zlib


def run(mode):
    master, slave = pty.openpty()
    process = subprocess.Popen(["build/hardware-tests/transport-tests", os.ttyname(slave), mode],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(0.15)
        for part in [b"MIUCS_DIS", b"PLAY 1 720 1280 262144", b"\n"]:
            os.write(master, part)
            time.sleep(0.02)
        received = bytearray()
        deadline = time.monotonic() + 5
        while len(received) < 30 and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                received.extend(os.read(master, 4096))
        assert len(received) == 30, received
        magic, version, kind, flags, sequence, length, crc, width, height = struct.unpack("<4sBBHIIIHH", received[:24])
        assert (magic, version, kind, flags, sequence, length, width, height) == (b"MIUC", 1, 1, 0, 42, 6, 720, 1280)
        assert zlib.crc32(received[24:]) == crc
        if mode == "ok":
            os.write(master, b"MIUCS_ACK 41 0 9\nMIUCS_ACK 42 ")
            time.sleep(0.03)
            os.write(master, b"0 17\n")
        elif mode == "disconnect":
            os.close(master)
            master = -1
        output, _ = process.communicate(timeout=6)
        assert process.returncode == 0, output
        print(output.strip())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if master >= 0:
            os.close(master)
        os.close(slave)


def read_exact(port, count):
    result = bytearray()
    deadline = time.monotonic() + 5
    while len(result) < count and time.monotonic() < deadline:
        if select.select([port], [], [], 0.1)[0]:
            result.extend(os.read(port, count - len(result)))
    assert len(result) == count, (len(result), count)
    return result


def baseline_size(jpeg):
    assert jpeg[:2] == b"\xff\xd8"
    offset = 2
    while offset + 4 <= len(jpeg) and jpeg[offset] == 0xFF:
        marker = jpeg[offset + 1]
        if marker == 0xC0:
            height, width = struct.unpack_from(">HH", jpeg, offset + 5)
            return width, height
        if marker == 0xDA:
            break
        offset += 2 + struct.unpack_from(">H", jpeg, offset + 2)[0]
    raise AssertionError("Expected a baseline JPEG SOF0 marker")


def expect_desk_isle_frame(port, slot, sequence, width, height, limit, alpha=False):
    header = read_exact(port, 24)
    magic, version, kind, card, seq, size, crc, w, h = struct.unpack("<4sBBHIIIHH", header)
    assert (magic, version, kind, card, seq, w, h) == (b"ISLE", 1, 5 if alpha else 1, slot, sequence, width, height)
    assert 4 <= size <= limit + (width * height + 4 if alpha else 0)
    payload = read_exact(port, size)
    assert zlib.crc32(payload) == crc
    jpeg = payload
    if alpha:
        jpeg_length = struct.unpack_from("<I", payload, size - 4)[0]
        assert 4 <= jpeg_length <= limit
        jpeg = payload[:jpeg_length]
        runs = payload[jpeg_length:-4]
        assert 0 < len(runs) < width * height and len(runs) % 2 == 0
        mask = b"".join(bytes([value]) * count for count, value in zip(runs[::2], runs[1::2]))
        assert len(mask) == width * height
        row = height // 2 * width
        assert mask[row + width // 6] == 0
        assert mask[row + width // 2] == 255
        assert mask[row + width * 5 // 6] == 128
    assert baseline_size(jpeg) == (width, height)


def run_desk_isle():
    master, slave = pty.openpty()
    process = subprocess.Popen(["build/hardware-tests/transport-tests", os.ttyname(slave), "desk-isle"],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(0.15)
        os.write(master, b"DESKISLE 2 7 512 288 JPEG 98304 3000\nDESKIS")
        time.sleep(0.02)
        os.write(master, b"LE 1 7 512 288 JPEG 98304 3000\n")
        expect_desk_isle_frame(master, 7, 42, 512, 288, 98_304)
        os.write(master, b"DESKISLE 1 7 512 288 JPEG 98304 3000\nMIUCS_ACK 42 0 9\nDESKISLE_ACK 41 0 9\nDESKISLE_ACK 42 ")
        time.sleep(0.02)
        os.write(master, b"0 17\n")

        keepalive = read_exact(master, 24)
        assert struct.unpack("<4sBBHIIIHH", keepalive) == (b"ISLE", 1, 2, 7, 43, 0, 0, 0, 0)
        os.write(master, b"DESKISLE_ACK 43 0 0\nDESKISLE_ALPHA 1 9\n"
                 b"DESKISLE_PET 1 9 6291456 98304 16384\n"
                 b"DESKISLE_PET 2 9 8388608 98304 16384\n"
                 b"DESKISLE 1 9 384 224 JPEG 16384 1200\n")
        expect_desk_isle_frame(master, 9, 45, 384, 224, 16_384, alpha=True)
        os.write(master, b"DESKISLE_ACK 45 0 19\n")

        output, _ = process.communicate(timeout=6)
        assert process.returncode == 0, output
        print(output.strip())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)


def run_desk_isle_pet(mode):
    master, slave = pty.openpty()
    process = subprocess.Popen(["build/hardware-tests/transport-tests", os.ttyname(slave), mode],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def expect_packet(kind, sequence, payload):
        header = read_exact(master, 24)
        assert struct.unpack("<4sBBHIIIHH", header) == (
            b"ISLE", 1, kind, 7, sequence, len(payload), zlib.crc32(payload), 0, 0)
        assert read_exact(master, len(payload)) == payload

    try:
        time.sleep(0.15)
        os.write(master, b"DESKISLE_PET 2 7 8388608 98304 16384\n")
        if mode == "desk-isle-resume":
            os.write(master, b"DESKISLE_PET 3 7 8388608 98304 16384\n")
        os.write(master, b"DESKISLE 1 7 512 288 JPEG 98304 3000\n")
        if mode == "desk-isle-resume":
            identity = struct.pack("<II", 12345, 0x12345678)
            expect_packet(14, 51, identity)
            os.write(master, b"DESKISLE_ACK 51 6 0\n")
            expect_packet(14, 52, identity)
            os.write(master, b"DESKISLE_ACK 51 6 0\nDESKISLE_ACK 52 0 2\n")
            expect_packet(15, 53, b"")
            os.write(master, b"DESKISLE_ACK 53 0 0\n")
        else:
            # Keep both ACKs back until both transitions and the next control message arrive.
            expect_packet(11, 41, b'{"event":"pressed"}')
            expect_packet(11, 42, b'{"event":"released"}')
            expect_packet(2, 43, b"")
            os.write(master, b"DESKISLE_ACK 41 1 0\nDESKISLE_ACK 42 0 0\nDESKISLE_ACK 43 0 17\n")

            expect_packet(11, 2**32 - 1, b"{}")
            expect_packet(11, 0, b"{}")
            os.write(master, b"DESKISLE_ACK 42 1 0\nDESKISLE_ACK 4294967295 0 0\nDESKISLE_ACK 0 5 0\n")
        output, _ = process.communicate(timeout=6)
        assert process.returncode == 0, output
        print(output.strip())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)


for scenario in ["ok", "timeout", "disconnect"]:
    run(scenario)
run_desk_isle()
run_desk_isle_pet("desk-isle-input")
run_desk_isle_pet("desk-isle-resume")
