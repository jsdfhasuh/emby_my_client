package com.example.emby_my_client

import android.app.Application
import android.os.Process

/** Protects shipped debug APKs before Dart initializes media_kit. */
class DebugMediaKitApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        processCleanup.prepare(filesDir, Process.myPid())
    }

    companion object {
        // Survives Dart hot restart; a new OS process gets a new instance.
        private val processCleanup = DebugNativeReferenceCleanup()
    }
}
