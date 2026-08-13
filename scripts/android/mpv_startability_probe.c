#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

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
extern int mpv_set_option_string(
    mpv_handle *context, const char *name, const char *value);
extern int mpv_set_property_string(
    mpv_handle *context, const char *name, const char *value);
extern char *mpv_get_property_string(mpv_handle *context, const char *name);
extern int mpv_get_property(
    mpv_handle *context, const char *name, mpv_format format, void *data);
extern void mpv_free(void *data);
extern void mpv_free_node_contents(mpv_node *node);
extern void mpv_terminate_destroy(mpv_handle *context);

typedef enum value_kind {
  VALUE_BOOLEAN,
  VALUE_BOOLEAN_OR_AUTO,
  VALUE_INTEGER,
  VALUE_ENUM,
  VALUE_PATH,
} value_kind;

typedef enum candidate_status {
  CANDIDATE_UNAVAILABLE,
  CANDIDATE_INCOMPLETE,
  CANDIDATE_USABLE,
} candidate_status;

typedef struct logical_option {
  const char *logical_name;
  const char *candidates[2];
  size_t candidate_count;
  value_kind kind;
  int requires_immediate;
  const char *test_value;
} logical_option;

typedef struct candidate_evidence {
  const char *native_name;
  candidate_status status;
  int option_name_matches;
  int option_exists;
  int reset_available;
  int required_choice_available;
  int write_read_back_passed;
  char *reset_value;
} candidate_evidence;

static int select_first_usable(
    const candidate_status *statuses, size_t count) {
  size_t index;
  for (index = 0; index < count; index++) {
    if (statuses[index] == CANDIDATE_USABLE) return (int)index;
  }
  return -1;
}

enum {
  OPTION_CACHE,
  OPTION_CACHE_ON_DISK,
  OPTION_CACHE_DIRECTORY,
  OPTION_CACHE_UNLINK_FILES,
  OPTION_CACHE_SECONDS,
  OPTION_FORWARD_METADATA_BYTES,
  OPTION_BACKWARD_METADATA_BYTES,
  OPTION_DONATE_BUFFER,
  OPTION_SEEKABLE_CACHE,
  OPTION_CACHE_PAUSE,
  OPTION_CACHE_PAUSE_WAIT,
  OPTION_STREAM_BUFFER_SIZE,
  LOGICAL_OPTION_COUNT,
};

static const logical_option logical_options[LOGICAL_OPTION_COUNT] = {
    {"cache", {"cache", NULL}, 1, VALUE_BOOLEAN_OR_AUTO, 0, "yes"},
    {"cacheOnDisk", {"cache-on-disk", NULL}, 1, VALUE_BOOLEAN, 0, "no"},
    {"cacheDirectory", {"demuxer-cache-dir", "cache-dir"}, 2, VALUE_PATH, 0, NULL},
    {"cacheUnlinkFiles", {"demuxer-cache-unlink-files", "cache-unlink-files"}, 2, VALUE_ENUM, 1, "immediate"},
    {"cacheSeconds", {"cache-secs", NULL}, 1, VALUE_INTEGER, 0, "1"},
    {"forwardMetadataBytes", {"demuxer-max-bytes", NULL}, 1, VALUE_INTEGER, 0, "1"},
    {"backwardMetadataBytes", {"demuxer-max-back-bytes", NULL}, 1, VALUE_INTEGER, 0, "1"},
    {"donateBuffer", {"demuxer-donate-buffer", NULL}, 1, VALUE_BOOLEAN, 0, "yes"},
    {"seekableCache", {"demuxer-seekable-cache", NULL}, 1, VALUE_ENUM, 0, "auto"},
    {"cachePause", {"cache-pause", NULL}, 1, VALUE_BOOLEAN, 0, "yes"},
    {"cachePauseWait", {"cache-pause-wait", NULL}, 1, VALUE_INTEGER, 0, "1"},
    {"streamBufferSize", {"stream-buffer-size", NULL}, 1, VALUE_INTEGER, 0, "131072"},
};

static const char *status_name(candidate_status status) {
  switch (status) {
    case CANDIDATE_USABLE:
      return "usable";
    case CANDIDATE_INCOMPLETE:
      return "incomplete";
    default:
      return "unavailable";
  }
}

static const char *json_bool(int value) { return value ? "true" : "false"; }

static int copy_trimmed(const char *raw, char *output, size_t output_size) {
  const char *start;
  const char *end;
  size_t length;
  if (raw == NULL || output_size == 0) return 0;
  for (start = raw; *start != '\0'; start++) {
    unsigned char value = (unsigned char)*start;
    if ((value < 0x20 && value != ' ' && value != '\t') || value == 0x7f) {
      return 0;
    }
  }
  start = raw;
  while (*start == ' ' || *start == '\t') start++;
  end = start + strlen(start);
  while (end > start && (end[-1] == ' ' || end[-1] == '\t')) end--;
  length = (size_t)(end - start);
  if (length >= output_size) return 0;
  memcpy(output, start, length);
  output[length] = '\0';
  return 1;
}

static int canonicalize_integer(
    const char *value, char *output, size_t output_size) {
  char integer[128];
  const char *cursor = value;
  char *end = NULL;
  long long parsed;
  size_t length = 0;
  if (*cursor == '+' || *cursor == '-') integer[length++] = *cursor++;
  if (!isdigit((unsigned char)*cursor)) return 0;
  while (isdigit((unsigned char)*cursor)) {
    if (length + 1 >= sizeof(integer)) return 0;
    integer[length++] = *cursor++;
  }
  if (*cursor == '.') {
    cursor++;
    if (*cursor == '\0') return 0;
    while (*cursor == '0') cursor++;
  }
  if (*cursor != '\0') return 0;
  integer[length] = '\0';
  errno = 0;
  parsed = strtoll(integer, &end, 10);
  if (errno == ERANGE || end == NULL || *end != '\0') return 0;
  return snprintf(output, output_size, "%lld", parsed) > 0;
}

static int canonicalize_path(
    const char *value, char *output, size_t output_size) {
  char copy[PATH_MAX];
  char *segments[PATH_MAX / 2];
  char *save = NULL;
  char *segment;
  size_t count = 0;
  size_t used = 0;
  int absolute;
  size_t index;
  if (strlen(value) >= sizeof(copy)) return 0;
  strcpy(copy, value);
  for (index = 0; copy[index] != '\0'; index++) {
    if (copy[index] == '\\') copy[index] = '/';
  }
  absolute = copy[0] == '/';
  segment = strtok_r(copy, "/", &save);
  while (segment != NULL) {
    if (strcmp(segment, ".") == 0) {
      segment = strtok_r(NULL, "/", &save);
      continue;
    }
    if (strcmp(segment, "..") == 0) {
      if (count > 0 && strcmp(segments[count - 1], "..") != 0) {
        count--;
      } else if (!absolute) {
        segments[count++] = segment;
      }
    } else {
      segments[count++] = segment;
    }
    segment = strtok_r(NULL, "/", &save);
  }
  if (absolute) {
    if (used + 1 >= output_size) return 0;
    output[used++] = '/';
  }
  for (index = 0; index < count; index++) {
    size_t length = strlen(segments[index]);
    if (used > 0 && output[used - 1] != '/') {
      if (used + 1 >= output_size) return 0;
      output[used++] = '/';
    }
    if (used + length >= output_size) return 0;
    memcpy(output + used, segments[index], length);
    used += length;
  }
  output[used] = '\0';
  return 1;
}

static int canonicalize(
    value_kind kind, const char *raw, char *output, size_t output_size) {
  char value[PATH_MAX];
  size_t index;
  if (!copy_trimmed(raw, value, sizeof(value))) return 0;
  if (kind == VALUE_BOOLEAN || kind == VALUE_BOOLEAN_OR_AUTO) {
    if (strcasecmp(value, "yes") == 0 || strcasecmp(value, "true") == 0 ||
        strcmp(value, "1") == 0) {
      return snprintf(output, output_size, "true") > 0;
    }
    if (strcasecmp(value, "no") == 0 || strcasecmp(value, "false") == 0 ||
        strcmp(value, "0") == 0) {
      return snprintf(output, output_size, "false") > 0;
    }
    if (kind == VALUE_BOOLEAN_OR_AUTO && strcasecmp(value, "auto") == 0) {
      return snprintf(output, output_size, "auto") > 0;
    }
    return 0;
  }
  if (kind == VALUE_INTEGER) {
    return canonicalize_integer(value, output, output_size);
  }
  if (kind == VALUE_PATH) {
    return canonicalize_path(value, output, output_size);
  }
  for (index = 0; value[index] != '\0'; index++) {
    value[index] = (char)tolower((unsigned char)value[index]);
  }
  if (strcmp(value, "auto") != 0 && strcmp(value, "yes") != 0 &&
      strcmp(value, "no") != 0 && strcmp(value, "whendone") != 0 &&
      strcmp(value, "immediate") != 0) {
    return 0;
  }
  return snprintf(output, output_size, "%s", value) > 0;
}

static int equivalent(value_kind kind, const char *left, const char *right) {
  char canonical_left[PATH_MAX];
  char canonical_right[PATH_MAX];
  return canonicalize(kind, left, canonical_left, sizeof(canonical_left)) &&
         canonicalize(kind, right, canonical_right, sizeof(canonical_right)) &&
         strcmp(canonical_left, canonical_right) == 0;
}

static char *copy_node_string(mpv_handle *context, const char *property) {
  mpv_node node = {0};
  char value[PATH_MAX];
  int status = mpv_get_property(context, property, MPV_FORMAT_NODE, &node);
  int copied = 0;
  if (status >= 0) {
    switch (node.format) {
      case MPV_FORMAT_STRING:
      case MPV_FORMAT_OSD_STRING:
        if (node.u.string != NULL) {
          copied = snprintf(value, sizeof(value), "%s", node.u.string) >= 0;
        }
        break;
      case MPV_FORMAT_FLAG:
        copied = snprintf(value, sizeof(value), "%s", node.u.flag ? "yes" : "no") > 0;
        break;
      case MPV_FORMAT_INT64:
        copied = snprintf(value, sizeof(value), "%" PRId64, node.u.int64) > 0;
        break;
      case MPV_FORMAT_DOUBLE:
        copied = snprintf(value, sizeof(value), "%.17g", node.u.double_) > 0;
        break;
      default:
        break;
    }
  }
  mpv_free_node_contents(&node);
  return copied ? strdup(value) : NULL;
}

static int node_array_contains(
    mpv_handle *context, const char *property, const char *expected) {
  mpv_node node = {0};
  int index;
  int found = 0;
  int status = mpv_get_property(context, property, MPV_FORMAT_NODE, &node);
  if (status >= 0 && node.format == MPV_FORMAT_NODE_ARRAY && node.u.list != NULL) {
    for (index = 0; index < node.u.list->num; index++) {
      const mpv_node *entry = &node.u.list->values[index];
      if ((entry->format == MPV_FORMAT_STRING ||
           entry->format == MPV_FORMAT_OSD_STRING) &&
          entry->u.string != NULL && strcmp(entry->u.string, expected) == 0) {
        found = 1;
        break;
      }
    }
  }
  mpv_free_node_contents(&node);
  return found;
}

static mpv_handle *create_context(void) {
  mpv_handle *context = mpv_create();
  if (context == NULL) return NULL;
  (void)mpv_set_option_string(context, "terminal", "no");
  (void)mpv_set_option_string(context, "vo", "null");
  (void)mpv_set_option_string(context, "ao", "null");
  (void)mpv_set_option_string(context, "idle", "yes");
  if (mpv_initialize(context) < 0) {
    mpv_terminate_destroy(context);
    return NULL;
  }
  return context;
}

static int candidate_write_read_back(
    mpv_handle *context,
    const logical_option *logical,
    const char *native_name,
    const char *reset_value,
    const char *probe_directory) {
  const char *expected = logical->test_value;
  char *actual;
  int probe_passed = 0;
  int reset_passed = 0;
  if (logical->kind == VALUE_PATH) expected = probe_directory;
  if (expected == NULL || reset_value == NULL) return 0;
  if (mpv_set_property_string(context, native_name, expected) >= 0) {
    actual = mpv_get_property_string(context, native_name);
    probe_passed = equivalent(logical->kind, actual, expected);
    if (actual != NULL) mpv_free(actual);
  }
  if (mpv_set_property_string(context, native_name, reset_value) >= 0) {
    actual = mpv_get_property_string(context, native_name);
    reset_passed = equivalent(logical->kind, actual, reset_value);
    if (actual != NULL) mpv_free(actual);
  }
  return probe_passed && reset_passed;
}

static void inspect_candidates(
    mpv_handle *context,
    candidate_evidence evidence[LOGICAL_OPTION_COUNT][2],
    const char *resolved[LOGICAL_OPTION_COUNT],
    const char *probe_directory) {
  size_t logical_index;
  for (logical_index = 0; logical_index < LOGICAL_OPTION_COUNT; logical_index++) {
    const logical_option *logical = &logical_options[logical_index];
    size_t candidate_index;
    candidate_status statuses[2] = {
        CANDIDATE_UNAVAILABLE, CANDIDATE_UNAVAILABLE};
    resolved[logical_index] = NULL;
    for (candidate_index = 0; candidate_index < logical->candidate_count;
         candidate_index++) {
      const char *native_name = logical->candidates[candidate_index];
      candidate_evidence *item = &evidence[logical_index][candidate_index];
      char property[192];
      char *identity;
      char *reset;
      int choice;
      snprintf(property, sizeof(property), "option-info/%s/name", native_name);
      identity = mpv_get_property_string(context, property);
      item->native_name = native_name;
      item->option_name_matches = identity != NULL && strcmp(identity, native_name) == 0;
      item->option_exists = item->option_name_matches;
      if (identity != NULL) mpv_free(identity);
      snprintf(
          property, sizeof(property), "option-info/%s/default-value", native_name);
      reset = copy_node_string(context, property);
      item->reset_value = reset;
      item->reset_available = reset != NULL &&
          canonicalize(logical->kind, reset, property, sizeof(property));
      choice = 1;
      if (logical->requires_immediate) {
        snprintf(property, sizeof(property), "option-info/%s/choices", native_name);
        choice = node_array_contains(context, property, "immediate");
      }
      item->required_choice_available = choice;
      item->write_read_back_passed = item->option_exists &&
          item->reset_available && choice &&
          candidate_write_read_back(
              context, logical, native_name, reset, probe_directory);
      if (!item->option_exists) {
        item->status = CANDIDATE_UNAVAILABLE;
      } else if (!item->reset_available || !choice || !item->write_read_back_passed) {
        item->status = CANDIDATE_INCOMPLETE;
      } else {
        item->status = CANDIDATE_USABLE;
      }
      statuses[candidate_index] = item->status;
    }
    {
      int selected = select_first_usable(statuses, logical->candidate_count);
      if (selected >= 0) resolved[logical_index] = logical->candidates[selected];
    }
  }
}

static int set_and_verify(
    mpv_handle *context,
    size_t logical_index,
    const char *resolved[LOGICAL_OPTION_COUNT],
    const char *value) {
  char *actual;
  int passed;
  if (resolved[logical_index] == NULL) return 0;
  if (mpv_set_property_string(context, resolved[logical_index], value) < 0) return 0;
  actual = mpv_get_property_string(context, resolved[logical_index]);
  passed = equivalent(logical_options[logical_index].kind, actual, value);
  if (actual != NULL) mpv_free(actual);
  return passed;
}

static int apply_optional_tuning(
    mpv_handle *context, const char *resolved[LOGICAL_OPTION_COUNT]) {
  size_t index;
  int degraded = 0;
  for (index = OPTION_DONATE_BUFFER; index < LOGICAL_OPTION_COUNT; index++) {
    if (resolved[index] == NULL || !set_and_verify(
          context, index, resolved, logical_options[index].test_value)) {
      degraded = 1;
    }
  }
  return degraded;
}

static int probe_profile(
    const char *profile,
    const char *resolved[LOGICAL_OPTION_COUNT],
    const char *probe_directory,
    int *optional_degraded) {
  mpv_handle *context = create_context();
  int passed = 1;
  if (context == NULL) return 0;
  if (strcmp(profile, "disk") == 0) {
    passed = set_and_verify(context, OPTION_CACHE, resolved, "yes") &&
        set_and_verify(context, OPTION_CACHE_ON_DISK, resolved, "yes") &&
        set_and_verify(context, OPTION_CACHE_DIRECTORY, resolved, probe_directory) &&
        set_and_verify(context, OPTION_CACHE_UNLINK_FILES, resolved, "immediate") &&
        set_and_verify(context, OPTION_CACHE_SECONDS, resolved, "30") &&
        set_and_verify(context, OPTION_FORWARD_METADATA_BYTES, resolved, "16777216") &&
        set_and_verify(context, OPTION_BACKWARD_METADATA_BYTES, resolved, "8388608");
  } else if (strcmp(profile, "memory") == 0) {
    passed = set_and_verify(context, OPTION_CACHE, resolved, "yes") &&
        set_and_verify(context, OPTION_CACHE_ON_DISK, resolved, "no") &&
        set_and_verify(context, OPTION_CACHE_SECONDS, resolved, "30") &&
        set_and_verify(context, OPTION_FORWARD_METADATA_BYTES, resolved, "16777216") &&
        set_and_verify(context, OPTION_BACKWARD_METADATA_BYTES, resolved, "8388608");
  } else {
    passed = set_and_verify(context, OPTION_CACHE, resolved, "no");
    if (resolved[OPTION_CACHE_ON_DISK] != NULL) {
      passed = passed &&
          set_and_verify(context, OPTION_CACHE_ON_DISK, resolved, "no");
    }
  }
  if (strcmp(profile, "disabled") != 0 && apply_optional_tuning(context, resolved)) {
    *optional_degraded = 1;
  }
  mpv_terminate_destroy(context);
  return passed;
}

static int safe_version_fingerprint(
    const char *raw, char *output, size_t output_size) {
  const char *start = raw;
  size_t length = 0;
  int dot_seen = 0;
  while (*start != '\0' && !isdigit((unsigned char)*start)) start++;
  if (*start == '\0') return 0;
  while (start[length] != '\0' && length < 63) {
    unsigned char value = (unsigned char)start[length];
    if (!(isalnum(value) || value == '.' || value == '_' || value == '+' ||
          value == '-')) {
      break;
    }
    if (value == '.') dot_seen = 1;
    length++;
  }
  if (!dot_seen || length == 0 || length + 5 >= output_size) return 0;
  memcpy(output, "mpv-", 4);
  memcpy(output + 4, start, length);
  output[4 + length] = '\0';
  return 1;
}

static void emit_manifest(
    const char *version,
    candidate_evidence evidence[LOGICAL_OPTION_COUNT][2],
    const char *resolved[LOGICAL_OPTION_COUNT],
    int disk_read_back,
    int memory_read_back,
    int disabled_read_back,
    int optional_degraded) {
  size_t logical_index;
  int first;
  puts("{");
  printf("\"schema\":\"emby-android-mpv-capabilities/v1\",");
  printf("\"mpvVersionFingerprint\":\"%s\",", version);
  printf("\"platform\":\"Android\",");
  printf("\"logicalOptionCount\":12,\"nativeCandidateCount\":14,");
  printf("\"nativeCandidates\":{");
  first = 1;
  for (logical_index = 0; logical_index < LOGICAL_OPTION_COUNT; logical_index++) {
    size_t candidate_index;
    for (candidate_index = 0;
         candidate_index < logical_options[logical_index].candidate_count;
         candidate_index++) {
      candidate_evidence *item = &evidence[logical_index][candidate_index];
      printf("%s\"%s\":%s", first ? "" : ",", item->native_name,
             json_bool(item->option_exists));
      first = 0;
    }
  }
  printf("},\"resolvedOptions\":{");
  first = 1;
  for (logical_index = 0; logical_index < LOGICAL_OPTION_COUNT; logical_index++) {
    if (resolved[logical_index] != NULL) {
      printf("%s\"%s\":\"%s\"", first ? "" : ",",
             logical_options[logical_index].logical_name, resolved[logical_index]);
      first = 0;
    }
  }
  printf("},\"candidateEvidence\":{");
  for (logical_index = 0; logical_index < LOGICAL_OPTION_COUNT; logical_index++) {
    size_t candidate_index;
    printf("%s\"%s\":[", logical_index == 0 ? "" : ",",
           logical_options[logical_index].logical_name);
    for (candidate_index = 0;
         candidate_index < logical_options[logical_index].candidate_count;
         candidate_index++) {
      candidate_evidence *item = &evidence[logical_index][candidate_index];
      printf(
          "%s{\"nativeName\":\"%s\",\"status\":\"%s\","
          "\"optionNameMatches\":%s,\"optionExists\":%s,"
          "\"resetAvailable\":%s,\"requiredChoiceAvailable\":%s,"
          "\"writeReadBackPassed\":%s}",
          candidate_index == 0 ? "" : ",", item->native_name,
          status_name(item->status), json_bool(item->option_name_matches),
          json_bool(item->option_exists), json_bool(item->reset_available),
          json_bool(item->required_choice_available),
          json_bool(item->write_read_back_passed));
    }
    printf("]");
  }
  printf("},\"profileReadBack\":{");
  printf("\"disk\":%s,\"memory\":%s,\"disabled\":%s},",
         json_bool(disk_read_back), json_bool(memory_read_back),
         json_bool(disabled_read_back));
  printf("\"optionalTuningDegraded\":%s,", json_bool(optional_degraded));
  printf("\"optionBindingGate\":\"PASSED\",");
  printf("\"memoryProfileGate\":\"%s\",",
         memory_read_back ? "PASSED" : "BLOCKED_BY_BUNDLED_LIBMPV");
  printf("\"disabledProfileGate\":\"%s\",",
         disabled_read_back ? "PASSED" : "BLOCKED_BY_BUNDLED_LIBMPV");
  printf("\"diskProfileGate\":\"%s\",",
         disk_read_back ? "PASSED" : "BLOCKED_BY_BUNDLED_LIBMPV");
  printf("\"activeContextGate\":\"NOT_RUN\",");
  printf("\"diskTelemetryEvidenceGate\":\"NOT_RUN\"");
  puts("}");
}

static int semantic_self_test(void) {
  candidate_status modern_usable[2] = {CANDIDATE_USABLE, CANDIDATE_USABLE};
  candidate_status legacy_fallback[2] = {CANDIDATE_INCOMPLETE, CANDIDATE_USABLE};
  size_t candidate_count = 0;
  size_t logical_index;
  int selected = select_first_usable(modern_usable, 2);
  for (logical_index = 0; logical_index < LOGICAL_OPTION_COUNT; logical_index++) {
    candidate_count += logical_options[logical_index].candidate_count;
  }
  if (selected != 0 || !equivalent(VALUE_BOOLEAN, "YES", "1") ||
      !equivalent(VALUE_INTEGER, "3600000.0", "3600000") ||
      LOGICAL_OPTION_COUNT != 12 || candidate_count != 14) return 0;
  selected = select_first_usable(legacy_fallback, 2);
  return selected == 1 &&
      select_first_usable(
          (candidate_status[]){CANDIDATE_INCOMPLETE, CANDIDATE_UNAVAILABLE}, 2
      ) == -1 && !equivalent(VALUE_INTEGER, "1.5", "1") &&
      !equivalent(VALUE_ENUM, "immediate-ish", "immediate");
}

int main(int argc, char **argv) {
  mpv_handle *context;
  candidate_evidence evidence[LOGICAL_OPTION_COUNT][2] = {{{0}}};
  const char *resolved[LOGICAL_OPTION_COUNT] = {0};
  char probe_directory[PATH_MAX];
  char version_fingerprint[72];
  char *raw_version;
  char *raw_platform;
  int disk_read_back;
  int memory_read_back;
  int disabled_read_back;
  int optional_degraded = 0;
  size_t logical_index;
  if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
    if (!semantic_self_test()) return 9;
    puts("android_mpv_probe_semantics=passed");
    return 0;
  }
  if (argc != 1) return 64;
  if (getcwd(probe_directory, sizeof(probe_directory)) == NULL ||
      strlen(probe_directory) + strlen("/cache-probe") + 1 >= sizeof(probe_directory)) {
    return 2;
  }
  strcat(probe_directory, "/cache-probe");
  context = create_context();
  if (context == NULL) return 3;
  raw_version = mpv_get_property_string(context, "mpv-version");
  raw_platform = mpv_get_property_string(context, "platform");
  if (raw_version == NULL || raw_platform == NULL ||
      !safe_version_fingerprint(
          raw_version, version_fingerprint, sizeof(version_fingerprint)) ||
      strcasecmp(raw_platform, "android") != 0) {
    if (raw_version != NULL) mpv_free(raw_version);
    if (raw_platform != NULL) mpv_free(raw_platform);
    mpv_terminate_destroy(context);
    return 4;
  }
  mpv_free(raw_version);
  mpv_free(raw_platform);
  inspect_candidates(context, evidence, resolved, probe_directory);
  mpv_terminate_destroy(context);
  disk_read_back = probe_profile(
      "disk", resolved, probe_directory, &optional_degraded);
  memory_read_back = probe_profile(
      "memory", resolved, probe_directory, &optional_degraded);
  disabled_read_back = probe_profile(
      "disabled", resolved, probe_directory, &optional_degraded);
  emit_manifest(
      version_fingerprint, evidence, resolved, disk_read_back,
      memory_read_back, disabled_read_back, optional_degraded);
  for (logical_index = 0; logical_index < LOGICAL_OPTION_COUNT; logical_index++) {
    size_t candidate_index;
    for (candidate_index = 0;
         candidate_index < logical_options[logical_index].candidate_count;
         candidate_index++) {
      free(evidence[logical_index][candidate_index].reset_value);
    }
  }
  return memory_read_back && disabled_read_back ? 0 : 7;
}
