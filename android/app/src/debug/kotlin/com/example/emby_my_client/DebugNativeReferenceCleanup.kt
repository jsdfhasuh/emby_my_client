package com.example.emby_my_client

import java.io.File
import java.io.IOException

/** media_kit 1.2.6 debug references are valid only in the allocating OS process. */
internal class DebugNativeReferenceCleanup {
    private var prepared = false

    @Synchronized
    fun prepare(filesDirectory: File, processId: Int) {
        if (prepared) return
        require(processId > 0) { "Invalid native reference process" }
        val root = filesDirectory.canonicalFile
        check(root.isDirectory) { "Native reference directory unavailable" }
        val name = "com.alexmercerind.media_kit.NativeReferenceHolder.$processId"
        // safe_local_storage 2.0.6 writes through this exact staging basename.
        val candidates = listOf(File(root, name), File(root, ".$name.src"))
        // Validate the complete, fixed set before removing anything. Never read
        // pointer contents, recurse, enumerate other PIDs, or clear app storage.
        for (file in candidates) {
            check(file.canonicalFile == file.absoluteFile) {
                "Native reference is not a direct private file"
            }
            check(!file.exists() || file.isFile) {
                "Native reference is not a regular file"
            }
        }
        for (file in candidates) {
            if (file.exists() && !file.delete()) {
                // Do not continue to dereference an unremoved stale pointer.
                throw IOException("Native reference cleanup failed")
            }
        }
        prepared = true
    }
}
