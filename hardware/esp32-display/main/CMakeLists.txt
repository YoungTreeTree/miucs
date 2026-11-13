idf_component_register(SRCS "display.c" "stream.c" "protocol.c" INCLUDE_DIRS "."
    REQUIRES esp_lcd esp_driver_gpio esp_hw_support esp_timer esp_psram
             esp_driver_jpeg esp_tinyusb)
