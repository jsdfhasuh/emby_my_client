// Executes the APK's real libmpv on Android. This is a native software-render
// pixel gate, not a claim about the phone's Flutter texture or hardware decoder.
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;
typedef struct { int type; void *data; } mpv_render_param;
typedef struct { int event_id; int error; uint64_t reply; void *data; } mpv_event;
typedef struct {
    const char *prefix; const char *level; const char *text; int log_level;
} mpv_event_log_message;
extern mpv_handle *mpv_create(void);
extern int mpv_initialize(mpv_handle *);
extern int mpv_set_option_string(mpv_handle *, const char *, const char *);
extern int mpv_set_property_string(mpv_handle *, const char *, const char *);
extern char *mpv_get_property_string(mpv_handle *, const char *);
extern int mpv_get_property(mpv_handle *, const char *, int, void *);
extern int mpv_command(mpv_handle *, const char *const *);
extern int mpv_request_log_messages(mpv_handle *, const char *);
extern mpv_event *mpv_wait_event(mpv_handle *, double);
extern void mpv_free(void *);
extern void mpv_terminate_destroy(mpv_handle *);
extern int mpv_render_context_create(mpv_render_context **, mpv_handle *,
                                     mpv_render_param *);
extern uint64_t mpv_render_context_update(mpv_render_context *);
extern int mpv_render_context_render(mpv_render_context *, mpv_render_param *);
extern void mpv_render_context_free(mpv_render_context *);
extern void mpv_render_context_set_update_callback(mpv_render_context *,
                                                  void (*)(void *), void *);
extern void mpv_render_context_report_swap(mpv_render_context *);

enum { WIDTH = 320, HEIGHT = 180, MASK_W = 180, MASK_H = 24 };
static _Alignas(64) uint8_t pixels[WIDTH * HEIGHT * 4];
static uint8_t masks[2][MASK_W * MASK_H];
static pthread_mutex_t pixels_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int stopping, render_failed;
static pthread_mutex_t render_wakeup_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t render_wakeup = PTHREAD_COND_INITIALIZER;
static int render_pending;
#ifndef EMBY_RENDER_DELAY_MS
#define EMBY_RENDER_DELAY_MS 0
#endif
static unsigned frame_count, loaded_count, restart_count, restart_frame_floor;
static mpv_handle *player;
static mpv_render_context *renderer;
static int native_errors, verified_frames;

static void delay_ms(long ms) {
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000};
    nanosleep(&t, NULL);
}
static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0;
}
// Advanced control requires callbacks, including updates with no new frame.
// The callback only wakes the renderer; it never calls into libmpv.
static void render_updated(void *unused) {
    (void)unused;
    pthread_mutex_lock(&render_wakeup_lock);
    render_pending = 1;
    pthread_cond_signal(&render_wakeup);
    pthread_mutex_unlock(&render_wakeup_lock);
}
static void *render_thread(void *unused) {
    (void)unused;
    int size[2] = {WIDTH, HEIGHT}, block = 1;
    size_t stride = WIDTH * 4;
    mpv_render_param params[] = {
        {17, size}, {18, "rgb0"}, {19, &stride}, {20, pixels}, {12, &block},
        {0, NULL}
    };
    while (!atomic_load(&stopping)) {
        pthread_mutex_lock(&render_wakeup_lock);
        while (!render_pending && !atomic_load(&stopping))
            pthread_cond_wait(&render_wakeup, &render_wakeup_lock);
        render_pending = 0;
        pthread_mutex_unlock(&render_wakeup_lock);
        if (atomic_load(&stopping)) break;
        // Compile-time scheduling stress for this synthetic-media probe only.
        if (EMBY_RENDER_DELAY_MS) delay_ms(EMBY_RENDER_DELAY_MS);
        // A slow consumer may miss the 200 ms presentation window. libmpv
        // then retains the current frame but clears UPDATE_FRAME. Redrawing
        // on this wake-up still renders that real frame, including its OSD.
        (void)mpv_render_context_update(renderer);
        pthread_mutex_lock(&pixels_lock);
        if (mpv_render_context_render(renderer, params) < 0)
            atomic_store(&render_failed, 1);
        mpv_render_context_report_swap(renderer);
        frame_count++;
        pthread_mutex_unlock(&pixels_lock);
    }
    return NULL;
}
static void poll_events(void) {
    for (int i = 0; i < 100; i++) {
        mpv_event *event = mpv_wait_event(player, 0);
        if (event->event_id == 0) return;
        if (event->event_id == 8) loaded_count++;
        if (event->event_id == 21) {
            restart_count++;
            pthread_mutex_lock(&pixels_lock);
            restart_frame_floor = frame_count;
            pthread_mutex_unlock(&pixels_lock);
            // Capture must be redrawn after this seek completed, never from
            // an earlier subtitle-visibility update or a previous seek.
            render_updated(NULL);
        }
        if (event->event_id == 2) {
            mpv_event_log_message *log = event->data;
            if (!strcmp(log->level, "fatal") || !strcmp(log->level, "error")) {
                native_errors++;
                // Only generated fixture data is used by this executable.
                fprintf(stderr, "native_error=%s:%s", log->prefix, log->text);
            }
        }
    }
}
static int property_is(const char *name, const char *expected) {
    char *actual = mpv_get_property_string(player, name);
    int equal = actual && !strcmp(actual, expected);
    mpv_free(actual);
    return equal;
}
static int set(const char *name, const char *value) {
    return mpv_set_property_string(player, name, value) >= 0 &&
        property_is(name, value);
}
static int command(const char *a, const char *b, const char *c) {
    const char *args[] = {a, b, c, NULL};
    return mpv_command(player, args) >= 0;
}
static int frame_matches(int mask) {
    for (int y = 0; y < HEIGHT; y++) {
        for (int x = 0; x < WIDTH; x++) {
            int white = mask >= 0 && x >= 70 && x < 70 + MASK_W &&
                y >= 140 && y < 140 + MASK_H &&
                masks[mask][(y - 140) * MASK_W + x - 70];
            for (int c = 0; c < 3; c++) {
                int value = pixels[(y * WIDTH + x) * 4 + c];
                if (white ? value < 245 : value > 10) return 0;
            }
        }
    }
    return 1;
}
static int save_frame(const char *directory, const char *prefix, int number) {
    char path[1024];
    if (snprintf(path, sizeof(path), "%s/%s-%02d.ppm", directory, prefix, number)
        >= (int)sizeof(path)) return 0;
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    fprintf(f, "P6\n%d %d\n255\n", WIDTH, HEIGHT);
    for (int i = 0; i < WIDTH * HEIGHT; i++) {
        if (fwrite(pixels + i * 4, 1, 3, f) != 3) { fclose(f); return 0; }
    }
    return fclose(f) == 0;
}
static int wait_frame(int mask, unsigned before, const char *text,
                      const char *output, double target,
                      unsigned restart_before) {
    double deadline = now() + 8;
    while (now() < deadline) {
        poll_events();
        int seeking = 1;
        double position = -1;
        int ready = restart_count > restart_before &&
                    mpv_get_property(player, "seeking", 3, &seeking) >= 0 &&
                    !seeking && mpv_get_property(player, "time-pos", 5, &position) >= 0 &&
                    position >= target - 0.15 && position <= target + 0.15 &&
                    (!text || property_is("sub-text", text));
        pthread_mutex_lock(&pixels_lock);
        int match = ready && frame_count > before &&
                    frame_count > restart_frame_floor && frame_matches(mask);
        if (match) match = save_frame(output, "frame", verified_frames);
        pthread_mutex_unlock(&pixels_lock);
        if (match) { verified_frames++; return 1; }
        if (native_errors || atomic_load(&render_failed)) break;
        delay_ms(10);
    }
    const char *properties[] = {"time-pos", "seeking", "pause", "sid",
        "sub-visibility", "sub-text", "file-format", "track-list"};
    for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
        char *value = mpv_get_property_string(player, properties[i]);
        fprintf(stderr, "pixel_failure_property %s=%s\n", properties[i],
                value ? value : "<unavailable>");
        mpv_free(value);
    }
    pthread_mutex_lock(&pixels_lock);
    fprintf(stderr, "pixel_failure_frame stage=%d target=%.3f before=%u after=%u "
            "alpha=%d beta=%d black=%d native_errors=%d render_failed=%d\n",
            verified_frames, target, before, frame_count, frame_matches(0),
            frame_matches(1), frame_matches(-1), native_errors,
            atomic_load(&render_failed));
    if (!save_frame(output, "failure", verified_frames))
        fputs("pixel_failure_capture_failed\n", stderr);
    pthread_mutex_unlock(&pixels_lock);
    return 0;
}
static int select_seek(const char *sid, int mask, const char *seconds,
                       const char *text, const char *output) {
    if (!set("sub-visibility", "no") || !set("sid", sid) ||
        !set("sub-visibility", mask >= 0 ? "yes" : "no")) return 0;
    poll_events();
    unsigned restart_before = restart_count;
    pthread_mutex_lock(&pixels_lock);
    unsigned before = frame_count;
    pthread_mutex_unlock(&pixels_lock);
    if (!command("seek", seconds, "absolute+exact")) return 0;
    if (!wait_frame(mask, before, text, output, atof(seconds), restart_before)) {
        fprintf(stderr, "pixel_gate_failed sid=%s mask=%d stage=%d\n",
                sid, mask, verified_frames);
        return 0;
    }
    return 1;
}
static int verify_input(const char *source, const char *external,
                        const char *output) {
    for (int reopen = 0; reopen < 2; reopen++) {
        poll_events();
        unsigned loaded_before = loaded_count;
        if (!set("sub-visibility", "no") ||
            !command("loadfile", source, NULL)) return 0;
        double deadline = now() + 8;
        while ((loaded_count <= loaded_before ||
                !property_is("track-list/count", "5")) && now() < deadline) {
            poll_events(); delay_ms(10);
        }
        if (loaded_count <= loaded_before ||
            !property_is("track-list/count", "5")) return 0;
        // IDs are read from the actual native list, not server ordinals.
        char *a = mpv_get_property_string(player, "track-list/2/id");
        char *b = mpv_get_property_string(player, "track-list/3/id");
        char *text = mpv_get_property_string(player, "track-list/4/id");
        if (!a || !b || !text) { mpv_free(a); mpv_free(b); mpv_free(text); return 0; }
        int ok = select_seek(a, 0, "2", "", output) &&
            select_seek(b, 1, "4", "", output) &&
            select_seek(a, 0, "6", "", output) &&
            select_seek("no", -1, "7", NULL, output) &&
            select_seek("no", -1, "8", NULL, output) &&
            select_seek(a, 0, "3", "", output) &&
            select_seek(text, -1, "3", "TEXT_CUE", output) &&
            select_seek(b, 1, "5", "", output);
        // Test external text after a bitmap and then return to the bitmap.
        if (ok) {
            ok = set("sub-visibility", "no") &&
                command("sub-add", external, "select");
            poll_events();
            unsigned restart_before = restart_count;
            pthread_mutex_lock(&pixels_lock);
            unsigned before = frame_count;
            pthread_mutex_unlock(&pixels_lock);
            ok = ok && command("seek", "3", "absolute+exact") &&
                wait_frame(-1, before, "EXTERNAL_CUE", output, 3,
                           restart_before) &&
                select_seek(a, 0, "2", "", output);
        }
        mpv_free(a); mpv_free(b); mpv_free(text);
        if (!ok || !command("stop", NULL, NULL)) return 0;
    }
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 7) return 64;
    for (int i = 0; i < 2; i++) {
        FILE *f = fopen(argv[3 + i], "rb");
        if (!f) return 65;
        size_t count = fread(masks[i], 1, sizeof(masks[i]), f);
        fclose(f);
        if (count != sizeof(masks[i])) return 65;
    }
    typedef const void *(*find_decoder_fn)(const char *);
    find_decoder_fn decoder = (find_decoder_fn)dlsym(RTLD_DEFAULT,
        "avcodec_find_decoder_by_name");
    if (!decoder || !decoder("pgssub") || !decoder("ass") ||
        !decoder("srt")) {
        fputs("required_subtitle_decoder_missing\n", stderr); return 2;
    }
    player = mpv_create();
    if (!player) return 3;
    const char *options[][2] = {
        {"config", "no"}, {"vo", "libmpv"}, {"ao", "null"}, {"audio", "no"},
        {"idle", "yes"}, {"keep-open", "yes"}, {"hwdec", "no"}, {"pause", "yes"},
        {"sub-ass", "no"}, {"sub-visibility", "no"},
        {"framedrop", "no"}, {"hr-seek-framedrop", "no"},
        // Subtitle refresh seeks can omit the boundary frame in this generated
        // indexless MKV. Decode from one second earlier to the exact target.
        {"hr-seek-demuxer-offset", "1"},
        {"secondary-sub-visibility", "no"}, {"osd-level", "0"},
        {"sub-auto", "no"}, {"audio-file-auto", "no"}
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++)
        if (mpv_set_option_string(player, options[i][0], options[i][1]) < 0)
            return 4;
    if (mpv_initialize(player) < 0) return 5;
    mpv_request_log_messages(player, "error");
    int advanced = 1;
    mpv_render_param params[] = {{1, "sw"}, {10, &advanced}, {0, NULL}};
    if (mpv_render_context_create(&renderer, player, params) < 0) return 6;
    mpv_render_context_set_update_callback(renderer, render_updated, NULL);
    pthread_t thread;
    if (pthread_create(&thread, NULL, render_thread, NULL)) return 7;
    int ok = verify_input(argv[1], argv[5], argv[6]) &&
             verify_input(argv[2], argv[5], argv[6]);
    poll_events();
    atomic_store(&stopping, 1);
    render_updated(NULL);
    pthread_join(thread, NULL);
    mpv_render_context_set_update_callback(renderer, NULL, NULL);
    mpv_render_context_free(renderer);
    mpv_terminate_destroy(player);
    if (!ok || native_errors || atomic_load(&render_failed) ||
        verified_frames != 40) return 8;
    printf("{\"schema\":\"emby-android-subtitle-render/v1\","
           "\"decoderRegistration\":\"PASSED\","
           "\"nativeSoftwarePixels\":\"PASSED\","
           "\"localFile\":\"PASSED\",\"loopbackHttp\":\"PASSED\","
           "\"switchDisableSeekReopen\":\"PASSED\","
           "\"bitmapTextSwitch\":\"PASSED\",\"verifiedFrames\":%d,"
           "\"flutterTexture\":\"NOT_RUN\",\"physicalPhone\":\"NOT_RUN\"}\n",
           verified_frames);
    return 0;
}
