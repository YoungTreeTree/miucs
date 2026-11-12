/* Display timing and initialization adapted from OSPTEK's CC-BY-4.0 examples.
 * https://github.com/osptek/display-tft-5inch-720x1280
 * Verified wiring: OSPTEK P4C5 V1.3 + YDP500BT004-V1.
 */
#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "driver/gpio.h"
#include "driver/jpeg_decode.h"
#include "esp_log.h"
#include "esp_ldo_regulator.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_jd9365.h"
#include "jd9365_init_cmds.h"
#include "protocol.h"
#include "display.h"

#define WIDTH MIUCS_WIDTH
#define HEIGHT MIUCS_HEIGHT
#define LCD_RESET GPIO_NUM_5
#define BACKLIGHT GPIO_NUM_20
static const char *TAG = "MIUCS_DISPLAY";
static esp_lcd_panel_handle_t panel;
static uint16_t *frames[2];
static unsigned back = 1;
static SemaphoreHandle_t frame_done;
static jpeg_decoder_handle_t decoder;
static uint8_t *decoded;
static size_t decoded_capacity;
// IDF's BGR choice gives native little-endian RGB565 words for this LCD.
// Verified against the RGB888 reference across all 921,600 pixels on hardware.
static const jpeg_dec_rgb_element_order_t pixel_order = JPEG_DEC_RGB_ELEMENT_ORDER_BGR;

static bool on_frame_done(esp_lcd_panel_handle_t p, esp_lcd_dpi_panel_event_data_t *event, void *context)
{
    BaseType_t wake = pdFALSE;
    xSemaphoreGiveFromISR(frame_done, &wake);
    return wake == pdTRUE;
}

#define DISPLAY_TRY(expr) do { esp_err_t error = (expr); if (error != ESP_OK) { ESP_LOGE(TAG, "DISPLAY_FAILED step=%s error=%s", #expr, esp_err_to_name(error)); return error; } } while (0)

esp_err_t miucs_display_init(void)
{
    gpio_config_t bl = {.pin_bit_mask = 1ULL << BACKLIGHT, .mode = GPIO_MODE_OUTPUT};
    DISPLAY_TRY(gpio_config(&bl));
    DISPLAY_TRY(gpio_set_level(BACKLIGHT, 0));
    frame_done = xSemaphoreCreateBinary();
    if (!frame_done) return ESP_ERR_NO_MEM;
    esp_ldo_channel_handle_t phy_power;
    esp_ldo_channel_config_t ldo_cfg = {.chan_id = 3, .voltage_mv = 2500};
    DISPLAY_TRY(esp_ldo_acquire_channel(&ldo_cfg, &phy_power));
    esp_lcd_dsi_bus_handle_t bus;
    esp_lcd_dsi_bus_config_t bus_cfg = {
        .bus_id = 0, .num_data_lanes = 2,
        .phy_clk_src = 0, .lane_bit_rate_mbps = 870,
    };
    DISPLAY_TRY(esp_lcd_new_dsi_bus(&bus_cfg, &bus));
    esp_lcd_panel_io_handle_t io;
    esp_lcd_dbi_io_config_t io_cfg = {.virtual_channel = 0, .lcd_cmd_bits = 8, .lcd_param_bits = 8};
    DISPLAY_TRY(esp_lcd_new_panel_io_dbi(bus, &io_cfg, &io));
    esp_lcd_dpi_panel_config_t dpi_cfg = {
        .dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT, .dpi_clock_freq_mhz = 63,
        .virtual_channel = 0, .pixel_format = LCD_COLOR_PIXEL_FORMAT_RGB565, .num_fbs = 2,
        .video_timing = {
            .h_size = WIDTH, .v_size = HEIGHT,
            .hsync_back_porch = 42, .hsync_pulse_width = 8, .hsync_front_porch = 42,
            .vsync_back_porch = 12, .vsync_pulse_width = 4, .vsync_front_porch = 24,
        },
        .flags.use_dma2d = false,
    };
    jd9365_vendor_config_t vendor = {
        .init_cmds = lcd_init_cmds, .init_cmds_size = lcd_init_cmds_size,
        .mipi_config = {.dsi_bus = bus, .dpi_config = &dpi_cfg, .lane_num = 2},
    };
    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = LCD_RESET, .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16, .vendor_config = &vendor,
    };
    DISPLAY_TRY(esp_lcd_new_panel_jd9365(io, &panel_cfg, &panel));
    DISPLAY_TRY(esp_lcd_panel_reset(panel));
    DISPLAY_TRY(esp_lcd_panel_init(panel));
    DISPLAY_TRY(esp_lcd_dpi_panel_get_frame_buffer(panel, 2, (void **)&frames[0], (void **)&frames[1]));
    // A quiet light background while waiting for the desktop application.
    for (unsigned i = 0; i < WIDTH * HEIGHT; ++i) frames[0][i] = frames[1][i] = 0xf79e;
    esp_lcd_dpi_panel_event_callbacks_t callbacks = {.on_frame_buf_complete = on_frame_done};
    DISPLAY_TRY(esp_lcd_dpi_panel_register_event_callbacks(panel, &callbacks, NULL));
    DISPLAY_TRY(esp_lcd_panel_draw_bitmap(panel, 0, 0, WIDTH, HEIGHT, frames[0]));
    DISPLAY_TRY(esp_lcd_panel_disp_on_off(panel, true));
    DISPLAY_TRY(gpio_set_level(BACKLIGHT, 1));
    jpeg_decode_memory_alloc_cfg_t memory = {.buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER};
    decoded = jpeg_alloc_decoder_mem(WIDTH * HEIGHT * 3, &memory, &decoded_capacity);
    if (!decoded) return ESP_ERR_NO_MEM;
    jpeg_decode_engine_cfg_t engine = {.timeout_ms = 1000};
    DISPLAY_TRY(jpeg_new_decoder_engine(&engine, &decoder));
    ESP_LOGI(TAG, "DISPLAY_READY %dx%d", WIDTH, HEIGHT);
    return ESP_OK;
}

esp_err_t miucs_display_jpeg(const uint8_t *data, size_t length)
{
    jpeg_decode_picture_info_t info;
    esp_err_t result = jpeg_decoder_get_info(data, length, &info);
    if (result != ESP_OK) return result;
    if (info.width != WIDTH || info.height != HEIGHT) return ESP_ERR_INVALID_SIZE;
    jpeg_decode_cfg_t config = {
        .output_format = JPEG_DECODE_OUT_FORMAT_RGB565,
        .rgb_order = pixel_order,
        .conv_std = JPEG_YUV_RGB_CONV_STD_BT601,
    };
    uint32_t size = 0;
    uint16_t *frame = frames[back];
    if (decoded) {
        // On the first frame, verify the DMA byte order against the already-tested
        // RGB888 path. Subsequent frames decode directly into the LCD back buffer.
        jpeg_decode_cfg_t reference = config;
        reference.output_format = JPEG_DECODE_OUT_FORMAT_RGB888;
        reference.rgb_order = JPEG_DEC_RGB_ELEMENT_ORDER_BGR;
        result = jpeg_decoder_process(decoder, &reference, data, length, decoded, decoded_capacity, &size);
        if (result != ESP_OK) return result;
        if (size != WIDTH * HEIGHT * 3) return ESP_ERR_INVALID_SIZE;
    }
    result = jpeg_decoder_process(decoder, &config, data, length, (uint8_t *)frame, WIDTH * HEIGHT * 2, &size);
    if (result != ESP_OK) return result;
    if (size != WIDTH * HEIGHT * 2) return ESP_ERR_INVALID_SIZE;
    if (decoded) {
        uint32_t error = 0;
        for (unsigned i = 0; i < WIDTH * HEIGHT; ++i) {
            const uint8_t *p = decoded + i * 3;
            uint16_t v = frame[i];
            error += abs((int)(v >> 11) - (p[2] >> 3));
            error += abs((int)((v >> 5) & 63) - (p[1] >> 2));
            error += abs((int)(v & 31) - (p[0] >> 3));
        }
        ESP_LOGI(TAG, "RGB565_VERIFY error=%u pixels=%u", (unsigned)error, WIDTH * HEIGHT);
        if (error > WIDTH * HEIGHT * 3) return ESP_ERR_INVALID_STATE;
        free(decoded);
        decoded = NULL;
        ESP_LOGI(TAG, "RGB565_DIRECT_READY byte_order=%d", pixel_order);
    }
    while (xSemaphoreTake(frame_done, 0) == pdTRUE) {}
    result = esp_lcd_panel_draw_bitmap(panel, 0, 0, WIDTH, HEIGHT, frame);
    if (result != ESP_OK) return result;
    // Wait two DMA boundaries, including the possible interrupt racing draw_bitmap.
    // The former front buffer can then be reused without writing into an active scan.
    for (unsigned i = 0; i < 2; ++i) {
        if (xSemaphoreTake(frame_done, pdMS_TO_TICKS(150)) != pdTRUE) return ESP_ERR_TIMEOUT;
    }
    back ^= 1;
    return ESP_OK;
}

void app_main(void)
{
    ESP_ERROR_CHECK(miucs_display_init());
    miucs_stream_start();
}
