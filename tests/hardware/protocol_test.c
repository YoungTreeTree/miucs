#include "protocol.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned calls, good;
static void received(void *unused, uint32_t sequence, const uint8_t *jpeg, size_t size, bool valid)
{
    assert(sequence == 0x01020304);
    assert(size == 37);
    if (valid) { assert(jpeg[0] == 0xff && jpeg[36] == 0xd9); ++good; }
    ++calls;
}
static void le32(uint8_t *into, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i) into[i] = (uint8_t)(value >> (i * 8));
}
int main(void)
{
    assert(miucs_crc32((const uint8_t *)"123456789", 9) == 0xcbf43926);
    // Independent zlib vector at the maximum accepted JPEG payload size.
    uint8_t *maximum = malloc(MIUCS_MAX_JPEG);
    assert(maximum);
    for (size_t i = 0; i < MIUCS_MAX_JPEG; ++i) maximum[i] = (uint8_t)i;
    assert(miucs_crc32(maximum, MIUCS_MAX_JPEG) == 0xc790bff6u);
    free(maximum);
    uint8_t packet[24 + 37] = {'M','I','U','C',1,1,0,0};
    le32(packet + 8, 0x01020304); le32(packet + 12, 37);
    packet[20] = 0xd0; packet[21] = 2; packet[23] = 5;
    packet[24] = 0xff; packet[60] = 0xd9;
    le32(packet + 16, miucs_crc32(packet + 24, 37));
    miucs_parser parser = {.payload = malloc(MIUCS_MAX_JPEG), .on_frame = received};
    assert(parser.payload);
    // Every split boundary, including a one-byte-at-a-time USB stream.
    for (size_t chunk = 1; chunk <= sizeof(packet); ++chunk) {
        miucs_parser_reset(&parser); unsigned before = calls;
        miucs_parser_feed(&parser, (const uint8_t *)"garbageMIUC", 11);
        for (size_t i = 0; i < sizeof(packet); i += chunk)
            miucs_parser_feed(&parser, packet + i, chunk < sizeof(packet) - i ? chunk : sizeof(packet) - i);
        assert(calls == before + 1 && calls == good);
    }
    // An oversized/corrupt header must not allocate or consume the next valid frame.
    uint8_t invalid[24]; memcpy(invalid, packet, 24); le32(invalid + 12, UINT32_MAX);
    miucs_parser_feed(&parser, invalid, sizeof(invalid));
    miucs_parser_feed(&parser, packet, sizeof(packet));
    assert(calls == 62 && good == 62);
    packet[30] ^= 1;
    miucs_parser_feed(&parser, packet, sizeof(packet));
    assert(calls == 63 && good == 62);
    packet[30] ^= 1;
    miucs_parser_feed(&parser, packet, 40);
    miucs_parser_reset(&parser); // A cable loss discards the partial JPEG.
    miucs_parser_feed(&parser, packet, sizeof(packet));
    miucs_parser_feed(&parser, packet, sizeof(packet));
    assert(calls == 65 && good == 64);
    free(parser.payload);
    puts("PASS USB frame parser: fragmentation, garbage, oversize, CRC, partial reconnect, consecutive frames");
}
