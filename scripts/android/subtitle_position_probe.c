// Additive bitmap positioning gate. The original 40-frame gate is unchanged.
// Compile like subtitle_render_probe.c; same argv plus optional --host-lavf.
#define main baseline_render_probe_main
#include "subtitle_render_probe.c"
#undef main


static void position_diagnostics(const char *stage, int input, int cycle) {
    fprintf(stderr, "position_probe_failure stage=%s input=%d cycle=%d "
            "verified=%d native_errors=%d render_failed=%d\n",
            stage, input, cycle, verified_frames, native_errors,
            atomic_load(&render_failed));
    const char *properties[] = {"file-format", "demuxer", "track-list/count",
        "track-list", "time-pos", "seeking", "pause", "sid", "sub-pos",
        "sub-visibility", "sub-text"};
    for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
        char *value = mpv_get_property_string(player, properties[i]);
        fprintf(stderr, "position_probe_property %s=%s\n", properties[i],
                value ? value : "<unavailable>");
        mpv_free(value);
    }
}

static int set_sub_position(const char *value) {
    double actual = -1, expected = atof(value);
    return mpv_set_property_string(player, "sub-pos", value) >= 0 &&
        mpv_get_property(player, "sub-pos", 5, &actual) >= 0 &&
        actual >= expected - 0.000001 && actual <= expected + 0.000001;
}

static int shifted_match(int mask, int top) {
    for (int y = 0; y < HEIGHT; y++) {
        for (int x = 0; x < WIDTH; x++) {
            int white = x >= 70 && x < 70 + MASK_W &&
                y >= top && y < top + MASK_H &&
                masks[mask][(y - top) * MASK_W + x - 70];
            for (int c = 0; c < 3; c++) {
                int value = pixels[(y * WIDTH + x) * 4 + c];
                if (white ? value < 245 : value > 10) return 0;
            }
        }
    }
    return 1;
}

static int position_frame(const char *sid, const char *position,
                          int must_move_up, const char *output, int *found_top) {
    if (!set("sub-visibility", "no") || !set("sid", sid) ||
        !set_sub_position(position) || !set("sub-visibility", "yes")) {
        position_diagnostics("select-properties", -1, -1);
        return 0;
    }
    poll_events();
    unsigned restart_before = restart_count;
    pthread_mutex_lock(&pixels_lock);
    unsigned before = frame_count;
    pthread_mutex_unlock(&pixels_lock);
    if (!command("seek", "3", "absolute+exact")) {
        position_diagnostics("seek-command", -1, -1);
        return 0;
    }
    double deadline = now() + 8;
    while (now() < deadline) {
        poll_events();
        int seeking = 1;
        double actual = -1;
        int ready = restart_count > restart_before &&
            mpv_get_property(player, "seeking", 3, &seeking) >= 0 && !seeking &&
            mpv_get_property(player, "time-pos", 5, &actual) >= 0 &&
            actual >= 2.85 && actual <= 3.15 && property_is("sub-text", "");
        pthread_mutex_lock(&pixels_lock);
        int top = -1;
        if (ready && frame_count > before && frame_count > restart_frame_floor) {
            for (int y = 0; y <= HEIGHT - MASK_H; y++) {
                if (shifted_match(0, y)) { top = y; break; }
            }
        }
        int matched = must_move_up ? top >= 0 && top < 140 : top == 140;
        if (matched) matched = save_frame(output, "position", verified_frames);
        pthread_mutex_unlock(&pixels_lock);
        if (matched) {
            *found_top = top;
            verified_frames++;
            return 1;
        }
        if (native_errors || atomic_load(&render_failed)) break;
        delay_ms(10);
    }
    pthread_mutex_lock(&pixels_lock);
    (void)save_frame(output, "position-failure", verified_frames);
    pthread_mutex_unlock(&pixels_lock);
    position_diagnostics("position-frame", -1, -1);
    fprintf(stderr, "bitmap_position_failed sub-pos=%s stage=%d\n",
            position, verified_frames);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 7 && !(argc == 8 && !strcmp(argv[7], "--host-lavf"))) {
        fputs("position_probe_usage local http alpha beta srt output [--host-lavf]\n", stderr);
        return 64;
    }
    const int host_lavf = argc == 8;
    FILE *mask = fopen(argv[3], "rb");
    if (!mask) { perror("position_probe_alpha_mask_open"); return 65; }
    size_t read = fread(masks[0], 1, sizeof(masks[0]), mask);
    fclose(mask);
    if (read != sizeof(masks[0])) { fputs("position_probe_short_alpha_mask\n", stderr); return 65; }
    player = mpv_create();
    if (!player) { fputs("position_probe_mpv_create_failed\n", stderr); return 3; }
    const char *options[][2] = {
        {"config", "no"}, {"vo", "libmpv"}, {"ao", "null"}, {"audio", "no"},
        {"idle", "yes"}, {"keep-open", "yes"}, {"hwdec", "no"}, {"pause", "yes"},
        {"sub-ass", "no"}, {"sub-visibility", "no"}, {"framedrop", "no"},
        {"hr-seek-framedrop", "no"}, {"hr-seek-demuxer-offset", "1"},
        {"secondary-sub-visibility", "no"}, {"osd-level", "0"}, {"sub-auto", "no"},
        {"audio-file-auto", "no"}
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
        int code = mpv_set_option_string(player, options[i][0], options[i][1]);
        if (code < 0) {
            fprintf(stderr, "position_probe_option_failed name=%s code=%d\n", options[i][0], code);
            mpv_terminate_destroy(player);
            return 4;
        }
    }
    // Explicit host diagnostic mode: prevent host mpv's image demuxer from
    // choosing the MJPEG synthetic fixture as a still image. Android stays as-is.
    if (host_lavf && mpv_set_option_string(player, "demuxer", "lavf") < 0) {
        fputs("position_probe_host_demux_option_failed\n", stderr);
        mpv_terminate_destroy(player);
        return 4;
    }
    if (mpv_initialize(player) < 0) {
        fputs("position_probe_initialize_failed\n", stderr);
        mpv_terminate_destroy(player);
        return 5;
    }
    mpv_request_log_messages(player, "error");
    int advanced = 1;
    mpv_render_param params[] = {{1, "sw"}, {10, &advanced}, {0, NULL}};
    if (mpv_render_context_create(&renderer, player, params) < 0) {
        fputs("position_probe_render_context_failed\n", stderr);
        mpv_terminate_destroy(player);
        return 6;
    }
    mpv_render_context_set_update_callback(renderer, render_updated, NULL);
    pthread_t thread;
    if (pthread_create(&thread, NULL, render_thread, NULL)) {
        fputs("position_probe_render_thread_failed\n", stderr);
        mpv_render_context_set_update_callback(renderer, NULL, NULL);
        mpv_render_context_free(renderer);
        mpv_terminate_destroy(player);
        return 7;
    }
    int ok = 1, minimum_top = 140;
    for (int input = 1; input <= 2 && ok; input++) {
        for (int cycle = 0; cycle < 2 && ok; cycle++) {
            unsigned loaded_before = loaded_count;
            ok = set("sub-visibility", "no") && command("loadfile", argv[input], NULL);
            double deadline = now() + 8;
            while (ok && (loaded_count <= loaded_before ||
                   !property_is("track-list/count", "5")) && now() < deadline) {
                poll_events(); delay_ms(10);
            }
            ok = ok && loaded_count > loaded_before &&
                 property_is("track-list/count", "5");
            if (!ok) {
                position_diagnostics("load-track-list", input, cycle);
                break;
            }
            char *sid = mpv_get_property_string(player, "track-list/2/id");
            int normal_top = -1, shifted_top = -1, restored_top = -1;
            ok = ok && sid && position_frame(sid, "100", 0, argv[6], &normal_top) &&
                position_frame(sid, "75", 1, argv[6], &shifted_top) &&
                position_frame(sid, "100", 0, argv[6], &restored_top);
            if (!ok) position_diagnostics("position-sequence", input, cycle);
            mpv_free(sid);
            if (shifted_top < minimum_top) minimum_top = shifted_top;
            ok = ok && normal_top == restored_top && command("stop", NULL, NULL);
        }
    }
    poll_events();
    if (!ok || native_errors || atomic_load(&render_failed) || verified_frames != 12)
        position_diagnostics("final-gate", -1, -1);
    atomic_store(&stopping, 1);
    render_updated(NULL);
    pthread_join(thread, NULL);
    mpv_render_context_set_update_callback(renderer, NULL, NULL);
    mpv_render_context_free(renderer);
    mpv_terminate_destroy(player);
    if (!ok || native_errors || atomic_load(&render_failed) || verified_frames != 12)
        return 8;
    printf("{\"schema\":\"emby-android-bitmap-position/v1\","
           "\"platform\":\"%s\",\"nativeSoftwarePixels\":\"PASSED\","
           "\"subPos100To75To100\":\"PASSED\",\"verifiedFrames\":12,"
           "\"minimumMaskTop\":%d,\"flutterTexture\":\"NOT_RUN\","
           "\"physicalPhone\":\"NOT_RUN\"}\n",
#ifdef __ANDROID__
           "android",
#else
           "host",
#endif
           minimum_top);
    return 0;
}
