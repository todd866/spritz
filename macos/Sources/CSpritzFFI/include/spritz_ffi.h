#ifndef SPRITZ_FFI_H
#define SPRITZ_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpritzEngine SpritzEngine;

typedef struct SpritzCallbacks {
    void *ctx;
    void (*on_state_changed)(void *ctx);
    void (*on_copy_toast)(void *ctx, const char *text);
    void (*on_touchbar_notify)(void *ctx, const char *payload_json);
    void (*on_insert_after_yield)(void *ctx, const char *text, bool keep_open);
    void (*on_open_settings)(void *ctx);
} SpritzCallbacks;

void spritz_free_cstr(char *ptr);
char *spritz_cli_telemetry_report(void);

SpritzEngine *spritz_engine_create(
    SpritzCallbacks callbacks,
    const char *instance_id,
    int32_t initial_login_status
);
void spritz_engine_destroy(SpritzEngine *engine);

char *spritz_snapshot_json(const SpritzEngine *engine);
char *spritz_preview_snapshot_json(bool with_alternatives);

void spritz_poll_permissions(SpritzEngine *engine);
void spritz_on_app_activated(SpritzEngine *engine, int32_t pid, const char *bundle_id);
void spritz_on_space_changed(SpritzEngine *engine);
void spritz_on_sleep_or_resign(SpritzEngine *engine);
void spritz_set_chatgpt_running(SpritzEngine *engine, bool running);
void spritz_set_login_status(SpritzEngine *engine, int32_t status);
void spritz_set_ui_suspended(SpritzEngine *engine, bool suspended);

void spritz_toggle_browser(SpritzEngine *engine);
void spritz_show_browser(SpritzEngine *engine);
void spritz_collapse_browser(SpritzEngine *engine);
void spritz_begin_search(SpritzEngine *engine);
void spritz_set_query(SpritzEngine *engine, const char *query);
void spritz_select_mode(SpritzEngine *engine, const char *mode_raw);
void spritz_select_category(SpritzEngine *engine, const char *category);
void spritz_pick_hex(SpritzEngine *engine, const char *hex, bool keep_open);

void spritz_resolve_drag_and_drop(
    SpritzEngine *engine,
    const char *source_hex,
    double point_x,
    double point_y,
    const char *frames_json
);

bool spritz_handle_local_cgevent(SpritzEngine *engine, const void *cgevent);
void spritz_post_synthetic_text(const SpritzEngine *engine, size_t delete_chars, const char *text);

void spritz_pause_for_secs(SpritzEngine *engine, double secs);
void spritz_resume(SpritzEngine *engine);
void spritz_set_skin_tone(SpritzEngine *engine, const char *tone);
void spritz_set_globe_enabled(SpritzEngine *engine, bool enabled);
void spritz_set_replace_system_picker(SpritzEngine *engine, bool enabled);
void spritz_set_launch_at_login(SpritzEngine *engine, bool enabled);
void spritz_set_refinement_provider(SpritzEngine *engine, const char *raw);

void spritz_analyse_focused_text(SpritzEngine *engine);
void spritz_select_dictation_choice(SpritzEngine *engine, size_t index);
void spritz_choose_dictation_choice(SpritzEngine *engine, size_t index, bool keep_open);

void spritz_publish_touchbar(SpritzEngine *engine, bool force);
void spritz_handle_touchbar_request(
    SpritzEngine *engine,
    const char *request_json,
    bool has_login_result,
    int32_t login_status,
    const char *login_error
);

void spritz_flush_telemetry(SpritzEngine *engine);
char *spritz_telemetry_report(const SpritzEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* SPRITZ_FFI_H */
