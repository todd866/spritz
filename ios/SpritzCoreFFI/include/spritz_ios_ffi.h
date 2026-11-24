#ifndef SPRITZ_IOS_FFI_H
#define SPRITZ_IOS_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpritzIosEngine SpritzIosEngine;

SpritzIosEngine *spritz_ios_create(const char *config_dir, const char *state_dir);
void spritz_ios_destroy(SpritzIosEngine *engine);
void spritz_ios_free_cstr(char *ptr);

size_t spritz_ios_lexicon_count(void);

char *spritz_ios_tap_key(
    SpritzIosEngine *engine,
    const char *ch,
    float x,
    float y,
    const char *context_before,
    bool system_known
);

char *spritz_ios_insert_direct(
    SpritzIosEngine *engine,
    const char *text,
    const char *context_before
);

char *spritz_ios_tap_space(
    SpritzIosEngine *engine,
    const char *context_before,
    bool system_known
);

char *spritz_ios_tap_return(
    SpritzIosEngine *engine,
    const char *context_before,
    bool system_known
);

char *spritz_ios_tap_backspace(
    SpritzIosEngine *engine,
    const char *context_before
);

char *spritz_ios_swipe_delete_word(
    SpritzIosEngine *engine,
    const char *context_before
);

char *spritz_ios_undo_last_delete(SpritzIosEngine *engine);

char *spritz_ios_finish_glide(
    SpritzIosEngine *engine,
    const float *xy_pairs,
    size_t point_count,
    const char *context_before
);

char *spritz_ios_accept_candidate(
    SpritzIosEngine *engine,
    size_t index,
    const char *context_before
);

void spritz_ios_set_shift(SpritzIosEngine *engine, int32_t state);

char *spritz_ios_sync_context(
    SpritzIosEngine *engine,
    const char *context_before,
    bool system_known
);

char *spritz_ios_emoji_snapshot(
    SpritzIosEngine *engine,
    const char *mode,
    const char *query,
    const char *context_before
);

char *spritz_ios_emoji_pick(SpritzIosEngine *engine, const char *hex);

char *spritz_ios_emoji_pin(
    SpritzIosEngine *engine,
    size_t slot_index,
    const char *hex
);

char *spritz_ios_get_config_json(SpritzIosEngine *engine);
bool spritz_ios_set_config_json(SpritzIosEngine *engine, const char *json);
bool spritz_ios_learn_word(SpritzIosEngine *engine, const char *word);
bool spritz_ios_forget_word(SpritzIosEngine *engine, const char *word);

#ifdef __cplusplus
}
#endif

#endif /* SPRITZ_IOS_FFI_H */
