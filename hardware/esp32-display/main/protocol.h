#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MIUCS_HEADER_SIZE 24
#define MIUCS_MAX_JPEG (256 * 1024)
#define MIUCS_WIDTH 720
#define MIUCS_HEIGHT 1280

typedef void (*miucs_frame_fn)(void *context, uint32_t sequence,
                              const uint8_t *jpeg, size_t length, bool crc_valid);
typedef struct {
    uint8_t header[MIUCS_HEADER_SIZE];
    size_t header_used, payload_used, payload_size;
    uint32_t sequence, expected_crc;
    uint8_t *payload;
    miucs_frame_fn on_frame;
    void *context;
} miucs_parser;

uint32_t miucs_crc32(const uint8_t *data, size_t size);
void miucs_parser_reset(miucs_parser *parser);
void miucs_parser_feed(miucs_parser *parser, const uint8_t *data, size_t size);
