#include <inttypes.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/jpeg_decode.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tinyusb_cdc_acm.h"
#include "tusb.h"
#include "protocol.h"
#include "display.h"

static TaskHandle_t receiver;
static int64_t last_frame;
static unsigned frames;

static void reply(const char *text, size_t size)
{
    if (!tud_cdc_n_connected(TINYUSB_CDC_ACM_0)) return;
    tinyusb_cdcacm_write_queue(TINYUSB_CDC_ACM_0, (const uint8_t *)text, size);
    tinyusb_cdcacm_write_flush(TINYUSB_CDC_ACM_0, pdMS_TO_TICKS(50));
}

static void receive_callback(int port, cdcacm_event_t *event)
{
    if (receiver) xTaskNotifyGive(receiver);
}

static void display_frame(void *context, uint32_t sequence, const uint8_t *jpeg,
                          size_t length, bool crc_valid)
{
    int64_t started = esp_timer_get_time();
    esp_err_t result = crc_valid ? miucs_display_jpeg(jpeg, length) : ESP_ERR_INVALID_CRC;
    char response[96];
    int n = snprintf(response, sizeof(response), "MIUCS_ACK %" PRIu32 " %d %" PRId64 "\n",
                     sequence, result, (esp_timer_get_time() - started) / 1000);
    reply(response, n);
    if (result == ESP_OK) {
        last_frame = esp_timer_get_time();
        if (++frames % 100 == 1) ESP_LOGI("MIUCS", "FRAME_OK sequence=%" PRIu32 " bytes=%u frames=%u stack_free=%u", sequence, (unsigned)length, frames, (unsigned)uxTaskGetStackHighWaterMark(NULL));
    } else {
        ESP_LOGW("MIUCS", "FRAME_REJECTED sequence=%" PRIu32 " error=%s", sequence, esp_err_to_name(result));
    }
}

static void stream_task(void *arg)
{
    jpeg_decode_memory_alloc_cfg_t config = {.buffer_direction = JPEG_DEC_ALLOC_INPUT_BUFFER};
    size_t capacity;
    miucs_parser parser = {.payload = jpeg_alloc_decoder_mem(MIUCS_MAX_JPEG, &config, &capacity), .on_frame = display_frame};
    if (!parser.payload) abort();
    // This task calls the JPEG driver and logging from inside the parser callback.
    // Keep the USB scratch buffer in BSS rather than consuming 4 KiB of that stack.
    static uint8_t chunk[4096];
    int64_t last_rx = 0, last_hello = 0;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
        int64_t now = esp_timer_get_time();
        if (!tud_cdc_n_connected(TINYUSB_CDC_ACM_0)) {
            miucs_parser_reset(&parser);
            continue;
        }
        // Discard a partial packet after cable loss; the next header starts cleanly.
        if ((parser.header_used || parser.payload_size) && now - last_rx > 2000000) miucs_parser_reset(&parser);
        size_t n = 0;
        do {
            if (tinyusb_cdcacm_read(TINYUSB_CDC_ACM_0, chunk, sizeof(chunk), &n) != ESP_OK) break;
            if (n) {
                last_rx = esp_timer_get_time();
                miucs_parser_feed(&parser, chunk, n);
            }
        } while (n);
        now = esp_timer_get_time();
        if (now - last_frame > 1500000 && now - last_hello > 1000000) {
            const char hello[] = "MIUCS_DISPLAY 1 720 1280 262144\n";
            reply(hello, sizeof(hello) - 1);
            last_hello = now;
        }
    }
}

void miucs_stream_start(void)
{
    const tinyusb_config_t config = TINYUSB_DEFAULT_CONFIG();
    ESP_ERROR_CHECK(tinyusb_driver_install(&config));
    tinyusb_config_cdcacm_t cdc = {.cdc_port = TINYUSB_CDC_ACM_0, .callback_rx = receive_callback};
    ESP_ERROR_CHECK(tinyusb_cdcacm_init(&cdc));
    BaseType_t ok = xTaskCreate(stream_task, "miucs_stream", 8192, NULL, 5, &receiver);
    if (ok != pdPASS) abort();
    ESP_LOGI("MIUCS", "USB_STREAM_READY protocol=1 max_jpeg=%u", MIUCS_MAX_JPEG);
}
