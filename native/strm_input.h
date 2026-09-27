#ifndef EMBY_STRM_INPUT_H
#define EMBY_STRM_INPUT_H
#include <stdint.h>
typedef struct Context Context;
Context *strm_create(void *mpv, void *register_symbol);
int strm_add(Context *, int64_t id, int64_t size);
int strm_poll(Context *, int64_t *event);
void strm_complete(Context *, int64_t id, int64_t sequence, const char *, int64_t count);
void strm_release(Context *, int64_t id);
void strm_destroy(Context *);
#endif
