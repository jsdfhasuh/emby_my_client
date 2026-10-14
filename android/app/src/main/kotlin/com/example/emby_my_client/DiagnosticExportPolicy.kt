package com.example.emby_my_client

import java.io.File
import java.io.OutputStream
import java.net.URLDecoder
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/** Android export-only validation; never reads or rewrites the original log. */
internal object DiagnosticExportPolicy {
    const val FULL_LIMIT = 750 * 1024
    const val SAFE_LIMIT = 256 * 1024
    private val versionPattern = Regex("[0-9]+\\.[0-9]+\\.[0-9]+")
    private val buildPattern = Regex("[0-9]+")
    private val stages = setOf("PREFLIGHT", "SESSION_READ", "DEVICE_ID_READ", "DEVICE_ID_WRITE", "AUTHENTICATE", "SESSION_PREPARE", "SESSION_SAVE", "ACTIVATE", "SESSION_DELETE", "ROLLBACK")
    private val reasons = setOf("secure_storage_missing_entitlement", "secure_storage_unavailable", "secure_storage_access_denied", "secure_storage_unexpected", "session_prepare_failed", "session_save_failed", "activation_failed", "already_in_progress", "already_signed_in", "emby_api_failure", "unknown")

    fun metadata(version: String, build: String) {
        require(version.length <= 64 && versionPattern.matches(version))
        require(build.length <= 32 && buildPattern.matches(build))
    }

    fun timestamp(value: Any?) {
        require(value is String && Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}([0-9]{3})?Z").matches(value))
        val parser = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
            isLenient = false
        }
        val date = parser.parse(value.take(19)) ?: throw IllegalArgumentException()
        require(parser.format(date) == value.take(19))
    }

    fun full(content: String, version: String, build: String): ByteArray {
        metadata(version, build)
        val bytes = content.toByteArray(Charsets.UTF_8)
        require(bytes.size <= FULL_LIMIT && bytes.toString(Charsets.UTF_8) == content)
        require(content.none { (it.code < 32 && it != '\n' && it != '\t') || it.code == 127 })
        val lines = content.split('\n')
        val keys = listOf("schema", "generatedAtUtc", "appVersion", "buildNumber", "platform", "redaction", "truncated", "sha256")
        require(lines.size >= 9)
        val header = keys.mapIndexed { index, key ->
            require(lines[index].startsWith("$key="))
            lines[index].substring(key.length + 1)
        }
        require(header[0] == "emby-full-diagnostics/v1")
        timestamp(header[1])
        require(header[2] == version && header[3] == build)
        require(header[4] == "Android" && header[5] == "credentials-v1")
        require(header[6] in setOf("true", "false"))
        val body = lines.drop(8).joinToString("\n")
        require(header[7] == sha256(body.toByteArray(Charsets.UTF_8)))
        require(!containsCredentials(body))
        return bytes
    }

    private val fields = Regex("""(?i)(?<![a-z0-9_-])(?:password|passwd|pwd|pw|secret|client_secret|credential|credentials|token|access_token|accesstoken|refresh_token|x-emby-token|api_key|apikey|signature|sig|session_id|sessionid|authorization|proxy-authorization|cookie|set-cookie)["']?\s*[:=]\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\s&,;}\]"']+))""")
    private val query = Regex("""[?&;][a-zA-Z0-9_%.-]+=([^\s&#"'<>\]}]+)""")
    private val userInfo = Regex("""(?i)https?://([^/\s@]+)@""")
    private val basic = Regex("""(?i)\b(?:Basic|Bearer)\s+([a-z0-9+/=_-]+)""")
    fun containsCredentials(body: String): Boolean {
        var text = body
        while (true) {
            for (pattern in listOf(fields, query, userInfo, basic)) {
                if (pattern.findAll(text).any { match ->
                    match.groupValues.drop(1).any { it.isNotEmpty() && it.trim() !in setOf("<redacted>", "<redacted-token>") }
                }) return true
            }
            val decoded = try { URLDecoder.decode(text.replace("+", "%2B"), "UTF-8") } catch (_: IllegalArgumentException) { text }
            val next = Regex("\\\\u([0-9a-fA-F]{4})").replace(decoded) { it.groupValues[1].toInt(16).toChar().toString() }
                .replace("\\\"", "\"").replace("\\/", "/").replace("\\\\", "\\")
            if (next == text) return false
            text = next
        }
    }

    fun safe(report: Map<String, Any?>, version: String, build: String) {
        metadata(version, build)
        require(report.keys == setOf("schema", "generatedAtUtc", "appVersion", "buildNumber", "platform", "recordCount", "truncated", "records"))
        require(report["schema"] == "emby-safe-diagnostics/v1" && report["platform"] == "Android")
        require(report["appVersion"] == version && report["buildNumber"] == build)
        timestamp(report["generatedAtUtc"])
        require(report["truncated"] is Boolean)
        val records = report["records"] as? List<*> ?: throw IllegalArgumentException()
        require(records.size <= 1000 && report["recordCount"] is Int && report["recordCount"] == records.size)
        for (value in records) {
            val row = value as? Map<*, *> ?: throw IllegalArgumentException()
            require(row.keys == setOf("atUtc", "level", "component", "event", "stage", "reason", "errorType", "diagnosticCode"))
            require(row.values.all { it is String && it.none { c -> c.code < 32 || c.code == 127 } })
            timestamp(row["atUtc"])
            require(row["level"] in setOf("INFO", "ERROR"))
            require(row["component"] in setOf("auth", "storage"))
            require(row["event"] in setOf("sign_in_stage_start", "sign_in_stage_success", "sign_in_failure", "session_restore_failure", "session_delete_failure"))
            require(row["stage"] in stages && row["reason"] in reasons)
            require(row["errorType"] in setOf("SecureStorageFailure", "SignInFailure", "EmbyApiException", "Unknown"))
            require(row["diagnosticCode"] == diagnosticCode(row["stage"] as String, row["reason"] as String))
        }
    }

    private fun diagnosticCode(stage: String, reason: String): String {
        val prefix = mapOf("DEVICE_ID_READ" to "LOGIN-DID-READ", "DEVICE_ID_WRITE" to "LOGIN-DID-WRITE", "SESSION_SAVE" to "LOGIN-SESSION-SAVE")[stage]
        val suffix = mapOf("secure_storage_missing_entitlement" to "MISSING", "secure_storage_unavailable" to "UNAVAILABLE", "secure_storage_access_denied" to "DENIED", "secure_storage_unexpected" to "UNEXPECTED")[reason]
        if (prefix != null && suffix != null) return "$prefix-KC-$suffix"
        return when {
            stage == "SESSION_PREPARE" -> "LOGIN-SESSION-PREPARE"
            stage == "ACTIVATE" -> "LOGIN-ACTIVATE"
            stage == "AUTHENTICATE" && reason == "emby_api_failure" -> "LOGIN-AUTH"
            else -> "LOGIN-UNKNOWN"
        }
    }

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

/** One operation survives only its owning activity; late callbacks cannot win. */
internal class DiagnosticExportSession<T : Any> {
    private var current: T? = null
    private var closed = false
    @Synchronized fun begin(value: T): Boolean {
        if (closed || current != null) return false
        current = value
        return true
    }
    @Synchronized fun current(): T? = current
    @Synchronized fun finish(value: T): Boolean {
        if (current !== value) return false
        current = null
        return true
    }
    @Synchronized fun close(): T? {
        closed = true
        val value = current
        current = null
        return value
    }
}

internal object DiagnosticExportTransfer {
    fun save(bytes: ByteArray, open: () -> OutputStream) {
        open().use { stream -> stream.write(bytes); stream.flush() }
    }
    fun share(hasTarget: () -> Boolean, launch: () -> Unit) {
        check(hasTarget())
        launch()
    }
}

/** Only a narrow cache child is shared. No caller-provided path is accepted. */
internal class DiagnosticExportFiles(cache: File) {
    private val parent = cache.canonicalFile
    private val root = File(parent, "diagnostic_exports")
    private fun checkedRoot(): File {
        require(root.canonicalFile.parentFile == parent && root.canonicalFile.name == "diagnostic_exports")
        check(root.isDirectory || root.mkdir())
        return root.canonicalFile
    }
    fun cleanup(now: Long = System.currentTimeMillis()) {
        val base = checkedRoot()
        val files = base.listFiles().orEmpty().filter { it.isFile && it.canonicalFile.parentFile == base && it.canonicalFile == it.absoluteFile }
        for (file in files) if (now - file.lastModified() > 24 * 60 * 60 * 1000L) file.delete()
        for (file in files.filter { it.exists() }.sortedByDescending { it.lastModified() }.drop(7)) file.delete()
    }
    fun write(bytes: ByteArray, full: Boolean, build: String): File {
        require(bytes.size <= if (full) DiagnosticExportPolicy.FULL_LIMIT else DiagnosticExportPolicy.SAFE_LIMIT)
        require(Regex("[0-9]{1,32}").matches(build))
        cleanup()
        val base = checkedRoot()
        val kind = if (full) "full" else "safe"
        val extension = if (full) "txt" else "json"
        val file = File(base, "emby-$kind-diagnostics-b$build-${UUID.randomUUID()}.$extension")
        require(file.canonicalFile.parentFile == base)
        check(file.createNewFile())
        try {
            file.outputStream().use { it.write(bytes); it.flush() }
            check(file.readBytes().contentEquals(bytes))
            return file
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }
}
