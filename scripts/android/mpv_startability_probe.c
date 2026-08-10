#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_node mpv_node;
typedef struct mpv_node_list mpv_node_list;

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

typedef union mpv_node_union {
  char *string;
  int flag;
  int64_t int64;
  double double_;
  mpv_node_list *list;
  void *ba;
} mpv_node_union;

struct mpv_node {
  mpv_node_union u;
  mpv_format format;
};

struct mpv_node_list {
  int num;
  mpv_node *values;
  char **keys;
};

extern mpv_handle *mpv_create(void);
extern int mpv_initialize(mpv_handle *context);
extern char *mpv_get_property_string(mpv_handle *context, const char *name);
extern int mpv_get_property(
    mpv_handle *context,
    const char *name,
    mpv_format format,
    void *data);
extern void mpv_free(void *data);
extern void mpv_free_node_contents(mpv_node *node);
extern void mpv_terminate_destroy(mpv_handle *context);

static const char *required_options[] = {
    "cache",
    "cache-on-disk",
    "demuxer-cache-dir",
    "demuxer-cache-unlink-files",
    "cache-secs",
    "demuxer-max-bytes",
    "demuxer-max-back-bytes",
    "demuxer-donate-buffer",
    "demuxer-seekable-cache",
    "cache-pause",
    "cache-pause-wait",
    "stream-buffer-size",
};

static int node_array_contains(const mpv_node *node, const char *expected) {
  int index;
  if (node->format != MPV_FORMAT_NODE_ARRAY || node->u.list == NULL) {
    return 0;
  }
  for (index = 0; index < node->u.list->num; index++) {
    const mpv_node *value = &node->u.list->values[index];
    if ((value->format == MPV_FORMAT_STRING ||
         value->format == MPV_FORMAT_OSD_STRING) &&
        value->u.string != NULL && strcmp(value->u.string, expected) == 0) {
      return 1;
    }
  }
  return 0;
}

static int require_node_choice(
    mpv_handle *context,
    const char *property,
    const char *expected) {
  mpv_node node = {0};
  int status = mpv_get_property(context, property, MPV_FORMAT_NODE, &node);
  int found = status >= 0 && node_array_contains(&node, expected);
  if (status >= 0) {
    mpv_free_node_contents(&node);
  }
  return found;
}

int main(void) {
  size_t index;
  mpv_handle *context = mpv_create();
  if (context == NULL) {
    fputs("android_mpv_create=false\n", stderr);
    return 2;
  }
  if (mpv_initialize(context) < 0) {
    fputs("android_mpv_initialize=false\n", stderr);
    mpv_terminate_destroy(context);
    return 3;
  }

  char *version = mpv_get_property_string(context, "mpv-version");
  char *platform = mpv_get_property_string(context, "platform");
  if (version == NULL || platform == NULL) {
    fputs("android_mpv_identity=false\n", stderr);
    mpv_free(version);
    mpv_free(platform);
    mpv_terminate_destroy(context);
    return 4;
  }
  printf("android_mpv_version=%s\n", version);
  printf("android_mpv_platform=%s\n", platform);
  mpv_free(version);
  mpv_free(platform);

  for (index = 0; index < sizeof(required_options) / sizeof(required_options[0]);
       index++) {
    char property[128];
    char *name;
    snprintf(property, sizeof(property), "option-info/%s/name",
             required_options[index]);
    name = mpv_get_property_string(context, property);
    if (name == NULL || strcmp(name, required_options[index]) != 0) {
      fprintf(stderr, "android_mpv_option_%s=false\n", required_options[index]);
      mpv_free(name);
      mpv_terminate_destroy(context);
      return 5;
    }
    printf("android_mpv_option_%s=true\n", required_options[index]);
    mpv_free(name);
  }
  if (!require_node_choice(
          context,
          "option-info/demuxer-cache-unlink-files/choices",
          "immediate")) {
    fputs("android_mpv_unlink_immediate=false\n", stderr);
    mpv_terminate_destroy(context);
    return 6;
  }
  puts("android_mpv_unlink_immediate=true");
  puts("android_mpv_initialize=true");
  mpv_terminate_destroy(context);
  return 0;
}
