import unittest

from run_player_route_ui import CLEANUP, STAGES, RouteProtocol


class PlayerRouteProtocolTests(unittest.TestCase):
    def stage(self, name):
        offline = name.startswith(("download-", "offline-"))
        shown = name != "download-list" and not name.endswith("closed")
        return {"stage": name, "productionPlayerScreen": True, "nativeBackend": True,
                "routeShown": shown, "entryPoint": "downloads" if offline else "direct-http",
                "downloadListShown": name == "download-list" or (name.startswith("offline-") and name.endswith("closed")),
                "offlineItem": offline and shown,
                "networkAttempts": 0 if offline else None,
                "offlineFileExists": offline, "sidecarFileExists": offline,
                "localPlaybackPathMatches": offline and shown,
                "cue": "TEXT_CUE" if name.endswith("ass-visible") else
                       "EXTERNAL_CUE" if name.endswith("srt-visible") else None}

    def complete(self):
        return {"stage": "complete", "schema": "emby-android-player-route/v1",
                "platform": "android", "scope": "production-player-route",
                "productionPlayerScreen": True, "nativeBackend": True,
                "physicalPhone": "NOT_RUN", "nativePixelGate": "SEPARATE_REQUIRED",
                "cleanup": {key: True for key in CLEANUP}, "verifiedStages": len(STAGES)}

    def test_full_route_sequence_and_cleanup_are_required(self):
        p = RouteProtocol()
        for name in STAGES:
            p.accept(self.stage(name))
        with self.assertRaises(ValueError):
            p.finish()
        p.accept(self.complete())
        p.finish()

    def test_duplicate_missing_and_wrong_scope_never_complete(self):
        for altered in ("duplicate", "missing", "scope", "cleanup"):
            with self.subTest(altered=altered):
                p = RouteProtocol()
                with self.assertRaises(ValueError):
                    if altered == "duplicate":
                        p.accept(self.stage(STAGES[0]))
                        p.accept(self.stage(STAGES[0]))
                    elif altered == "missing":
                        p.accept(self.complete())
                    else:
                        for name in STAGES:
                            p.accept(self.stage(name))
                        terminal = self.complete()
                        if altered == "scope":
                            terminal["scope"] = "engine-texture"
                        else:
                            terminal["cleanup"]["routesClosed"] = False
                        p.accept(terminal)
                with self.assertRaises(ValueError):
                    p.finish()

    def test_offline_requires_download_entry_local_files_and_no_network(self):
        for patch in ({"entryPoint": "direct-http"}, {"offlineItem": False},
                      {"localPlaybackPathMatches": False}, {"networkAttempts": 1},
                      {"networkAttempts": False}, {"offlineFileExists": False},
                      {"sidecarFileExists": False}, {"downloadListShown": True}):
            with self.subTest(patch=patch):
                p = RouteProtocol()
                for name in STAGES:
                    if name == "offline-0-opened":
                        break
                    p.accept(self.stage(name))
                with self.assertRaises(ValueError):
                    p.accept(self.stage("offline-0-opened") | patch)
                with self.assertRaises(ValueError):
                    p.finish()

    def test_return_to_downloads_and_reopen_cannot_be_skipped(self):
        p = RouteProtocol()
        for name in STAGES:
            if name == "offline-0-closed":
                break
            p.accept(self.stage(name))
        with self.assertRaisesRegex(ValueError, "download list presence"):
            p.accept(self.stage("offline-0-closed") | {"downloadListShown": False})
        p = RouteProtocol()
        for name in STAGES[:STAGES.index("offline-1-opened")]:
            p.accept(self.stage(name))
        with self.assertRaises(ValueError):
            p.accept(self.complete())

    def test_diagnostics_never_count_as_acceptance(self):
        p = RouteProtocol()
        with self.assertRaises(ValueError):
            p.accept({"scope": "diagnostic-not-acceptance", "nodes": [], "stage": "diagnostic"})
        self.assertEqual(p.count, 0)
        with self.assertRaises(ValueError):
            p.finish()

    def test_first_ui_failure_is_retained(self):
        p = RouteProtocol()
        with self.assertRaises(ValueError):
            p.accept(self.stage("unexpected"))
        first = p.first_failure
        with self.assertRaises(ValueError):
            p.accept(self.complete())
        self.assertEqual(first, p.first_failure)
