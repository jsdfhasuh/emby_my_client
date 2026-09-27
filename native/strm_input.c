// Small synchronous libmpv stream_cb bridge. Network policy lives in Dart.
// Never calls libmpv from a callback; never lets Dart touch a native read buffer.
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
#define API __declspec(dllexport)
typedef CRITICAL_SECTION Mutex;
typedef CONDITION_VARIABLE Cond;
#define lock(m) EnterCriticalSection(m)
#define unlock(m) LeaveCriticalSection(m)
#define wake(c) WakeAllConditionVariable(c)
static void init(Mutex *m, Cond *c) { InitializeCriticalSection(m); InitializeConditionVariable(c); }
static int wait_read(Cond *c, Mutex *m) { return SleepConditionVariableCS(c, m, 30000) != 0; }
#else
#include <pthread.h>
#include <time.h>
#define API __attribute__((visibility("default"), used))
typedef pthread_mutex_t Mutex;
typedef pthread_cond_t Cond;
#define lock(m) pthread_mutex_lock(m)
#define unlock(m) pthread_mutex_unlock(m)
#define wake(c) pthread_cond_broadcast(c)
static void init(Mutex *m, Cond *c) { pthread_mutex_init(m, NULL); pthread_cond_init(c, NULL); }
static int wait_read(Cond *c, Mutex *m) {
  struct timespec t; clock_gettime(CLOCK_REALTIME, &t); t.tv_sec += 30;
  return pthread_cond_timedwait(c, m, &t) == 0;
}
#endif

// ABI from the locked mpv stream_cb.h (client API >= 1.106).
typedef struct {
  void *cookie;
  int64_t (*read_fn)(void *, char *, uint64_t);
  int64_t (*seek_fn)(void *, int64_t);
  int64_t (*size_fn)(void *);
  void (*close_fn)(void *);
  void (*cancel_fn)(void *);
} StreamInfo;
typedef int (*Register)(void *, const char *, void *, int (*)(void *, char *, StreamInfo *));
typedef struct Context Context;
typedef struct Input {
  Context *ctx;
  struct Input *next;
  int64_t id, size, offset, sequence, requested, result;
  int opened, cancelled, retired, pending, dispatched;
  char *data;
} Input;
struct Context { Mutex mutex; Cond changed; Input *inputs; };

static Input *find(Context *c, int64_t id) {
  for (Input *i = c->inputs; i; i = i->next) if (i->id == id) return i;
  return NULL;
}
static int64_t read_cb(void *cookie, char *buffer, uint64_t count) {
  Input *i = cookie; Context *c = i->ctx; lock(&c->mutex);
  if (i->cancelled) { unlock(&c->mutex); return -1; }
  if (i->offset >= i->size || count == 0) { unlock(&c->mutex); return 0; }
  i->requested = count > 262144 ? 262144 : (int64_t)count;
  if (i->requested > i->size - i->offset) i->requested = i->size - i->offset;
  i->sequence++; i->pending = 1; i->dispatched = 0;
  while (i->pending && !i->cancelled) {
    if (!wait_read(&c->changed, &c->mutex)) i->cancelled = 1;
  }
  int64_t result = i->cancelled ? -1 : i->result;
  if (result > 0) { memcpy(buffer, i->data, (size_t)result); i->offset += result; }
  free(i->data); i->data = NULL; i->pending = 0;
  unlock(&c->mutex); return result;
}
static int64_t seek_cb(void *cookie, int64_t offset) {
  Input *i = cookie; lock(&i->ctx->mutex);
  int64_t result = -1;
  if (!i->cancelled && offset >= 0 && offset <= i->size) result = i->offset = offset;
  unlock(&i->ctx->mutex); return result;
}
static int64_t size_cb(void *cookie) { return ((Input *)cookie)->size; }
static void cancel_cb(void *cookie) {
  Input *i = cookie; lock(&i->ctx->mutex); i->cancelled = 1;
  wake(&i->ctx->changed); unlock(&i->ctx->mutex);
}
static void close_cb(void *cookie) {
  Input *i = cookie; lock(&i->ctx->mutex); i->cancelled = 1; i->opened = 0;
  wake(&i->ctx->changed); unlock(&i->ctx->mutex);
}
static int open_cb(void *opaque, char *uri, StreamInfo *info) {
  Context *c = opaque; int64_t id = 0; char tail = 0;
  if (sscanf(uri, "embyinput://%" SCNd64 "%c", &id, &tail) != 1) return -13;
  lock(&c->mutex); Input *i = find(c, id);
  if (!i || i->opened || i->cancelled || i->retired) { unlock(&c->mutex); return -13; }
  i->opened = 1;
  *info = (StreamInfo){i, read_cb, seek_cb, size_cb, close_cb, cancel_cb};
  unlock(&c->mutex); return 0;
}
API Context *strm_create(void *mpv, void *register_symbol) {
  Register reg = (Register)register_symbol;
  Context *c = calloc(1, sizeof(*c)); if (!c) return NULL;
  init(&c->mutex, &c->changed);
  if (reg(mpv, "embyinput", c, open_cb) < 0) {
#ifdef _WIN32
    DeleteCriticalSection(&c->mutex);
#else
    pthread_cond_destroy(&c->changed); pthread_mutex_destroy(&c->mutex);
#endif
    free(c); return NULL;
  }
  return c;
}
API int strm_add(Context *c, int64_t id, int64_t size) {
  if (size <= 0 || id <= 0) return 0;
  Input *i = calloc(1, sizeof(*i)); if (!i) return 0;
  i->ctx = c; i->id = id; i->size = size;
  lock(&c->mutex);
  if (find(c, id)) { unlock(&c->mutex); free(i); return 0; }
  i->next = c->inputs; c->inputs = i; unlock(&c->mutex); return 1;
}
// Nonblocking poll. Each event has (id, sequence, offset, count).
API int strm_poll(Context *c, int64_t *event) {
  lock(&c->mutex);
  Input **link = &c->inputs;
  while (*link) {
    Input *i = *link;
    if (i->retired && !i->opened) { *link = i->next; free(i->data); free(i); continue; }
    if (i->pending && !i->dispatched && !i->cancelled) {
      i->dispatched = 1;
      event[0] = i->id; event[1] = i->sequence; event[2] = i->offset; event[3] = i->requested;
      unlock(&c->mutex); return 1;
    }
    link = &i->next;
  }
  unlock(&c->mutex); return 0;
}
API void strm_complete(Context *c, int64_t id, int64_t sequence, const char *data, int64_t count) {
  lock(&c->mutex); Input *i = find(c, id);
  if (i && i->pending && !i->cancelled && i->sequence == sequence) {
    i->result = -1;
    if (count > 0 && count <= i->requested && data) {
      i->data = malloc((size_t)count);
      if (i->data) { memcpy(i->data, data, (size_t)count); i->result = count; }
    }
    i->pending = 0; wake(&c->changed);
  }
  unlock(&c->mutex);
}
API void strm_release(Context *c, int64_t id) {
  lock(&c->mutex); Input *i = find(c, id);
  if (i) { i->retired = 1; i->cancelled = 1; wake(&c->changed); }
  unlock(&c->mutex);
}
// Call ONLY after mpv core destruction has actually completed.
API void strm_destroy(Context *c) {
  Input *i = c->inputs;
  while (i) { Input *next = i->next; free(i->data); free(i); i = next; }
#ifdef _WIN32
  DeleteCriticalSection(&c->mutex);
#else
  pthread_cond_destroy(&c->changed); pthread_mutex_destroy(&c->mutex);
#endif
  free(c);
}
