#ifndef PlaybackCacheMpv_h
#define PlaybackCacheMpv_h

#include <stdint.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_event mpv_event;
typedef struct mpv_node_list mpv_node_list;
typedef struct mpv_byte_array mpv_byte_array;

typedef enum mpv_format {
  MPV_FORMAT_NONE = 0,
  MPV_FORMAT_STRING = 1,
  MPV_FORMAT_OSD_STRING = 2,
  MPV_FORMAT_FLAG = 3,
  MPV_FORMAT_INT64 = 4,
  MPV_FORMAT_DOUBLE = 5,
  MPV_FORMAT_NODE = 6,
  MPV_FORMAT_NODE_ARRAY = 7,
  MPV_FORMAT_NODE_MAP = 8,
  MPV_FORMAT_BYTE_ARRAY = 9,
} mpv_format;

// Named libmpv errors used by the active-context telemetry reader.
#define MPV_ERROR_PROPERTY_NOT_FOUND (-8)
#define MPV_ERROR_PROPERTY_UNAVAILABLE (-10)

typedef union mpv_node_union {
  char *string;
  int flag;
  int64_t int64;
  double double_;
  mpv_node_list *list;
  mpv_byte_array *ba;
} mpv_node_union;

typedef struct mpv_node {
  mpv_node_union u;
  mpv_format format;
} mpv_node;

struct mpv_node_list {
  int num;
  mpv_node *values;
  char **keys;
};

mpv_handle *mpv_create(void);
int mpv_initialize(mpv_handle *context);
void mpv_terminate_destroy(mpv_handle *context);
int mpv_set_option_string(
    mpv_handle *context,
    const char *name,
    const char *value);
int mpv_set_property_string(
    mpv_handle *context,
    const char *name,
    const char *value);
char *mpv_get_property_string(mpv_handle *context, const char *name);
int mpv_get_property(
    mpv_handle *context,
    const char *name,
    mpv_format format,
    void *data);
void mpv_free(void *data);
void mpv_free_node_contents(mpv_node *node);
int mpv_command(mpv_handle *context, const char *const arguments[]);
mpv_event *mpv_wait_event(mpv_handle *context, double timeout);

#endif
