package com.example.emby_my_client

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DebugNativeReferenceCleanupTest {
    @get:Rule val temporary = TemporaryFolder()
    private val pid = 3960
    private val name = "com.alexmercerind.media_kit.NativeReferenceHolder.$pid"

    @Test fun coldProcessRemovesOnlyItsExactPointerAndInterruptedWrite() {
        val root = temporary.newFolder("files")
        val stale = File(root, name).apply { writeText("132740259906448") }
        val staging = File(root, ".$name.src").apply { writeText("132740259906448") }
        val keep = listOf("$name.extra", "$name.1", "$name.history", ".$name.src.extra",
            "com.alexmercerind.media_kit.NativeReferenceHolder.3961", "user-settings")
            .map { File(root, it).apply { writeText("keep") } }
        DebugNativeReferenceCleanup().prepare(root, pid)
        assertFalse(stale.exists())
        assertFalse(staging.exists())
        keep.forEach { assertEquals("keep", it.readText()) }
    }

    @Test fun sameProcessReentryPreservesItsLivePointerAndStagingFile() {
        val root = temporary.newFolder("files")
        val cleanup = DebugNativeReferenceCleanup()
        cleanup.prepare(root, pid)
        val live = File(root, name).apply { writeText("123456789") }
        val staging = File(root, ".$name.src").apply { writeText("123456789") }
        cleanup.prepare(root, pid)
        assertEquals("123456789", live.readText())
        assertEquals("123456789", staging.readText())
    }

    @Test fun newProcessWithReusedPidClearsPreviousProcessesPointer() {
        val root = temporary.newFolder("files")
        DebugNativeReferenceCleanup().prepare(root, pid)
        val old = File(root, name).apply { writeText("123456789") }
        DebugNativeReferenceCleanup().prepare(root, pid)
        assertFalse(old.exists())
    }

    @Test fun invalidPidCannotChooseOrDeleteAFile() {
        val root = temporary.newFolder("files")
        val stale = File(root, name).apply { writeText("keep") }
        for (invalid in listOf(0, -1, Int.MIN_VALUE)) {
            assertThrows(IllegalArgumentException::class.java) {
                DebugNativeReferenceCleanup().prepare(root, invalid)
            }
        }
        assertEquals("keep", stale.readText())
    }

    @Test fun directoryInFixedSetFailsBeforeDeletingTheOtherCandidate() {
        val root = temporary.newFolder("files")
        val stale = File(root, name).apply { writeText("keep") }
        File(root, ".$name.src").mkdir()
        assertThrows(IllegalStateException::class.java) {
            DebugNativeReferenceCleanup().prepare(root, pid)
        }
        assertEquals("keep", stale.readText())
    }

    @Test fun symlinkCannotDeleteAFileOutsideThePrivateDirectory() {
        // Windows requires a separate OS privilege to create the fixture. CI
        // and the Linux JVM verification execute this case without skipping.
        assumeFalse(System.getProperty("os.name").startsWith("Windows"))
        val root = temporary.newFolder("files")
        val outside = temporary.newFile("outside").apply { writeText("keep") }
        Files.createSymbolicLink(File(root, name).toPath(), outside.toPath())
        assertThrows(IllegalStateException::class.java) {
            DebugNativeReferenceCleanup().prepare(root, pid)
        }
        assertEquals("keep", outside.readText())
        assertTrue(Files.isSymbolicLink(File(root, name).toPath()))
    }
}
