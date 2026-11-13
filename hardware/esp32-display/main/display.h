#pragma once
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

esp_err_t miucs_display_init(void);
esp_err_t miucs_display_jpeg(const uint8_t *data, size_t length);
void miucs_stream_start(void);
