#ifndef MIUCS_PLUGINS_H
#define MIUCS_PLUGINS_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32) && defined(MIUCS_EXPORTS)
#define MIUCS_API __declspec(dllexport)
#elif defined(_WIN32)
#define MIUCS_API __declspec(dllimport)
#else
#define MIUCS_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* All buffers remain caller-owned. Handles must be destroyed on their creating UI thread.
   post() never waits for Lua; render() uses the newest complete acknowledged scene.
   Native surface is CAMetalLayer* on macOS and HWND on Windows. NULL enables CPU-only export. */
MIUCS_API uint32_t miucs_plugin_api_version(void);
MIUCS_API void* miucs_plugin_open(const char* worker, const char* directory);
/* Optional development interfaces: fixed seed and an on-demand JSON diagnostic snapshot.
   No inspection work occurs on the production frame path unless explicitly requested. */
MIUCS_API void* miucs_plugin_open_seeded(const char* worker, const char* directory, uint64_t seed);
MIUCS_API size_t miucs_plugin_inspect(void*, char* destination, size_t capacity);
MIUCS_API int miucs_plugin_post(void*, const uint8_t* messagepack, size_t length);
MIUCS_API int miucs_plugin_ready(void*);
MIUCS_API uint64_t miucs_plugin_completed(void*);
MIUCS_API size_t miucs_plugin_error(void*, char* destination, size_t capacity);
/* Invalidates the handle immediately; bounded dispose/worker teardown continues off the UI thread. */
MIUCS_API void miucs_plugin_close(void*);
MIUCS_API void* miucs_surface_create(void* plugin, void* native_surface, const char* output);
MIUCS_API int miucs_surface_draw(void*, uint32_t width, uint32_t height, double scale);
MIUCS_API int miucs_surface_pixels(void*, uint32_t width, uint32_t height, uint8_t* bgra, size_t length);
MIUCS_API int miucs_surface_backend(void*); /* 1 GPU, 0 CPU */
MIUCS_API void miucs_surface_destroy(void*);
/* Configuration boundaries use JSON once at scan time. Returns required UTF-8 bytes incl. NUL. */
MIUCS_API size_t miucs_plugin_catalog(const char* builtin, const char* user, char*, size_t);
#ifdef __cplusplus
}
#endif
#endif
