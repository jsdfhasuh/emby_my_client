package com.example.emby_my_client

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class DiagnosticExportPolicyTest {
    private val version = "1.0.183"
    private val build = "1832000"
    private fun full(body: String = "event=fixture password=<redacted>\n", platform: String = "Android") =
        "schema=emby-full-diagnostics/v1\ngeneratedAtUtc=2026-10-14T01:00:00.000Z\nappVersion=$version\nbuildNumber=$build\nplatform=$platform\nredaction=credentials-v1\ntruncated=false\nsha256=${DiagnosticExportPolicy.sha256(body.toByteArray())}\n$body"
    private fun record() = mapOf("atUtc" to "2026-10-14T01:00:00.000Z", "level" to "ERROR", "component" to "auth", "event" to "sign_in_failure", "stage" to "AUTHENTICATE", "reason" to "emby_api_failure", "errorType" to "EmbyApiException", "diagnosticCode" to "LOGIN-AUTH")
    private fun safe(): Map<String, Any?> = mapOf("schema" to "emby-safe-diagnostics/v1", "generatedAtUtc" to "2026-10-14T01:00:00.000Z", "appVersion" to version, "buildNumber" to build, "platform" to "Android", "recordCount" to 1, "truncated" to false, "records" to listOf(record()))
    @Test fun validFullPreservesExactVerifiedBytes() {
        assertArrayEquals(full().toByteArray(), DiagnosticExportPolicy.full(full(), version, build))
    }
    @Test fun fullRejectsTamperingDespiteValidSize() {
        assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.full(full() + "changed", version, build) }
    }
    @Test fun fullBindsInstalledVersionAndPlatform() {
        for (content in listOf(full(platform = "iPadOS"), full().replace(version, "1.0.182"), full().replace(build, "1830000"), full().replace("credentials-v1", "token-only-v1"))) {
            assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.full(content, version, build) }
        }
    }
    @Test fun fullRejectsOversizeAndControlCharacters() {
        for (body in listOf("a".repeat(DiagnosticExportPolicy.FULL_LIMIT), "foo\u0000bar", "foo\rbar")) {
            assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.full(full(body), version, build) }
        }
    }
    @Test fun credentialsRejectedEvenWithCorrectHash() {
        for (body in listOf("password=secret", "Authorization: Basic dGVzdA==", "Cookie: sid=secret", "https://a:b@host/a", "https://host/a?custom=secret", "password%253Dsecret", "password\\u003dsecret")) {
            assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.full(full(body), version, build) }
        }
    }
    @Test fun supportsVisibleDiagnosticAddressesAndMaskedCredentials() {
        DiagnosticExportPolicy.full(full("server=https://host/Items/42?key=<redacted> Authorization: <redacted>\n"), version, build)
    }
    @Test fun safeAcceptsStrictWhitelist() { DiagnosticExportPolicy.safe(safe(), version, build) }
    @Test fun safeRejectsExtraFieldsAndEnumPayloads() {
        for (row in listOf(record() + ("password" to "secret"), record() + ("event" to "https://host/secret"), record() + ("diagnosticCode" to "LOGIN-UNKNOWN"))) {
            assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.safe(safe() + ("records" to listOf(row)), version, build) }
        }
        assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.safe(safe() + ("extra" to "secret"), version, build) }
    }
    @Test fun safeChecksPlatformCountsAndTypes() {
        for (changed in listOf(safe() + ("platform" to "iPadOS"), safe() + ("recordCount" to 0), safe() + ("recordCount" to 1.0), safe() + ("truncated" to "false"), safe() + ("buildNumber" to "1822000"))) {
            assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.safe(changed, version, build) }
        }
    }
    @Test fun safeChecksRecordLimit() {
        assertThrows(IllegalArgumentException::class.java) { DiagnosticExportPolicy.safe(safe() + mapOf("records" to List(1001) { record() }, "recordCount" to 1001), version, build) }
    }
    @Test fun rejectsInvalidTimestampAndVersion() {
        assertThrows(Exception::class.java) { DiagnosticExportPolicy.timestamp("2026-02-31T01:00:00.000Z") }
        assertThrows(Exception::class.java) { DiagnosticExportPolicy.timestamp("2026-10-14T01:00:00+01:00") }
        assertThrows(Exception::class.java) { DiagnosticExportPolicy.metadata("../../private", build) }
    }
    @Test fun sessionRejectsDuplicatesAndCompletesExactlyOnce() {
        val session = DiagnosticExportSession<Any>()
        val first = Any()
        assertTrue(session.begin(first))
        assertFalse(session.begin(Any()))
        assertFalse(session.finish(Any()))
        assertTrue(session.finish(first))
        assertFalse(session.finish(first))
        assertTrue(session.begin(Any()))
    }
    @Test fun closeAndRecreationCannotAcceptLateCompletion() {
        val session = DiagnosticExportSession<Any>()
        val first = Any()
        assertTrue(session.begin(first))
        assertSame(first, session.close())
        assertFalse(session.finish(first))
        assertFalse(session.begin(Any()))
        val recreated = DiagnosticExportSession<Any>()
        assertNull(recreated.current())
        assertFalse(recreated.finish(first))
    }
    @Test fun saveReturnsOnlyAfterWriteFlushAndClose() {
        var flushed = false
        var closed = false
        val bytes = ByteArrayOutputStream()
        DiagnosticExportTransfer.save("report".toByteArray()) {
            object : OutputStream() {
                override fun write(value: Int) { bytes.write(value) }
                override fun flush() { flushed = true }
                override fun close() { closed = true }
            }
        }
        assertEquals("report", bytes.toString())
        assertTrue(flushed && closed)
    }
    @Test fun failedOpenWriteFlushOrCloseNeverSucceeds() {
        for (failure in listOf("open", "write", "flush", "close")) {
            assertThrows(IOException::class.java) {
                DiagnosticExportTransfer.save("report".toByteArray()) {
                    if (failure == "open") throw IOException()
                    object : OutputStream() {
                        override fun write(value: Int) { if (failure == "write") throw IOException() }
                        override fun flush() { if (failure == "flush") throw IOException() }
                        override fun close() { if (failure == "close") throw IOException() }
                    }
                }
            }
        }
    }
    @Test fun noShareTargetNeverLaunches() {
        var launched = false
        assertThrows(IllegalStateException::class.java) { DiagnosticExportTransfer.share({ false }) { launched = true } }
        assertFalse(launched)
    }
    @Test fun failedShareLaunchIsNotSuccess() {
        assertThrows(IllegalStateException::class.java) { DiagnosticExportTransfer.share({ true }) { throw IllegalStateException() } }
    }
    @Test fun privateFilesHaveNarrowPathsAndVerifiedBytes() {
        val cache = Files.createTempDirectory("emo-diagnostics-test").toFile()
        try {
            val store = DiagnosticExportFiles(cache)
            val bytes = "fixture".toByteArray()
            val file = store.write(bytes, true, build)
            assertEquals(File(cache, "diagnostic_exports").canonicalFile, file.parentFile!!.canonicalFile)
            assertArrayEquals(bytes, file.readBytes())
            assertThrows(IllegalArgumentException::class.java) { store.write(bytes, true, "../../private") }
            assertThrows(IllegalArgumentException::class.java) { store.write(ByteArray(DiagnosticExportPolicy.SAFE_LIMIT + 1), false, build) }
        } finally { cache.deleteRecursively() }
    }
    @Test fun cacheCleanupIsBoundedAndPreservesOtherApplicationFiles() {
        val cache = Files.createTempDirectory("emo-diagnostics-test").toFile()
        try {
            val unrelated = File(cache, "app_updates").apply { mkdir() }
            val apk = File(unrelated, "fixture.apk").apply { writeText("keep") }
            val store = DiagnosticExportFiles(cache)
            val expired = store.write("old".toByteArray(), true, build).apply { setLastModified(1) }
            store.cleanup()
            assertFalse(expired.exists())
            repeat(12) { store.write("new".toByteArray(), false, build) }
            assertTrue(File(cache, "diagnostic_exports").listFiles()!!.size <= 8)
            assertEquals("keep", apk.readText())
        } finally { cache.deleteRecursively() }
    }
    @Test fun writeFailureLeavesNoReport() {
        val cache = Files.createTempDirectory("emo-diagnostics-test").toFile()
        try {
            File(cache, "diagnostic_exports").writeText("blocked")
            assertThrows(IllegalStateException::class.java) { DiagnosticExportFiles(cache).write("fixture".toByteArray(), true, build) }
            assertEquals("blocked", File(cache, "diagnostic_exports").readText())
        } finally { cache.deleteRecursively() }
    }
}
