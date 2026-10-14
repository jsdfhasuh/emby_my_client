package com.example.emby_my_client

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.util.concurrent.Executors

internal class DiagnosticExportChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val safe = MethodChannel(messenger, "emby_my_client/safe_diagnostic_export")
    private val full = MethodChannel(messenger, "emby_my_client/full_diagnostic_export")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val session = DiagnosticExportSession<Operation>()
    private val files by lazy { DiagnosticExportFiles(activity.cacheDir) }
    private var closed = false
    private class Operation(val full: Boolean, val save: Boolean, val reply: MethodChannel.Result) {
        var bytes = byteArrayOf()
        var build = ""
        var replied = false
        fun success(value: String) { if (!replied) { replied = true; reply.success(value) } }
        fun error(reason: String) { if (!replied) { replied = true; reply.error("${if (full) "FULL-DIAG" else "DIAG-EXPORT"}-$reason", "Diagnostic export could not complete", null) } }
    }
    companion object {
        private const val SAVE_REQUEST = 48651
        private const val SHARE_REQUEST = 48652
    }
    init {
        safe.setMethodCallHandler { call, result -> handle(call, result, false) }
        full.setMethodCallHandler { call, result -> handle(call, result, true) }
        worker.execute { try { files.cleanup() } catch (_: Exception) { /* No raw paths in errors. */ } }
    }

    @Suppress("DEPRECATION")
    private fun metadata(): Pair<String, String> {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        val build = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        val version = info.versionName ?: ""
        DiagnosticExportPolicy.metadata(version, build.toString())
        return version to build.toString()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, isFull: Boolean) {
        if (closed) { result.error("${if (isFull) "FULL-DIAG" else "DIAG-EXPORT"}-SHARE", "Exporter is closed", null); return }
        if (!isFull && call.method == "metadata") {
            try {
                val (version, build) = metadata()
                result.success(mapOf("appVersion" to version, "buildNumber" to build, "platform" to "Android"))
            } catch (_: Exception) { result.error("DIAG-EXPORT-UNSAFE", "Cannot read app metadata", null) }
            return
        }
        val save = call.method == if (isFull) "fullSave" else "save"
        if (!save && call.method != if (isFull) "fullShare" else "share") { result.notImplemented(); return }
        val operation = Operation(isFull, save, result)
        if (!session.begin(operation)) { operation.error("BUSY"); return }
        val arguments = call.arguments as? Map<*, *>
        val content = arguments?.get("content") as? String
        if (content == null || arguments?.keys != setOf("content", "x", "y", "width", "height") ||
            content.length > if (isFull) DiagnosticExportPolicy.FULL_LIMIT else DiagnosticExportPolicy.SAFE_LIMIT) {
            session.finish(operation); operation.error("UNSAFE"); return
        }
        worker.execute {
            try {
                val (version, build) = metadata()
                operation.build = build
                operation.bytes = if (isFull) DiagnosticExportPolicy.full(content, version, build) else {
                    require(content.toByteArray(Charsets.UTF_8).size <= DiagnosticExportPolicy.SAFE_LIMIT)
                    val tokener = JSONTokener(content)
                    val json = tokener.nextValue() as? JSONObject ?: throw IllegalArgumentException()
                    require(tokener.nextClean() == '\u0000')
                    @Suppress("UNCHECKED_CAST")
                    val map = jsonValue(json) as Map<String, Any?>
                    DiagnosticExportPolicy.safe(map, version, build)
                    // Export only the validated whitelist, never the raw JSON.
                    JSONObject(map).toString().toByteArray(Charsets.UTF_8).also { require(it.size <= DiagnosticExportPolicy.SAFE_LIMIT) }
                }
                main.post { if (session.current() === operation) present(operation) }
            } catch (_: Exception) {
                main.post { if (session.finish(operation)) operation.error("UNSAFE") }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun present(operation: Operation) {
        try {
            if (operation.save) {
                val extension = if (operation.full) "txt" else "json"
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = if (operation.full) "text/plain" else "application/json"
                    putExtra(Intent.EXTRA_TITLE, "emby-${if (operation.full) "full" else "safe"}-diagnostics-b${operation.build}.$extension")
                }
                activity.startActivityForResult(intent, SAVE_REQUEST)
            } else {
                worker.execute {
                    try {
                        if (session.current() !== operation) return@execute
                        val file = files.write(operation.bytes, operation.full, operation.build)
                        main.post {
                            if (session.current() !== operation) { file.delete(); return@post }
                            try {
                                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.diagnostic_exports", file)
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = if (operation.full) "text/plain" else "application/json"
                                    putExtra(Intent.EXTRA_STREAM, uri)
                                    clipData = ClipData.newRawUri("Diagnostic report", uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                DiagnosticExportTransfer.share(
                                    hasTarget = { activity.packageManager.queryIntentActivities(send, 0).isNotEmpty() },
                                    launch = { activity.startActivityForResult(Intent.createChooser(send, "分享诊断文件"), SHARE_REQUEST) },
                                )
                                // Opening a chooser is not proof of delivery or acceptance.
                                operation.success("opened")
                            } catch (_: Exception) {
                                file.delete()
                                session.finish(operation); operation.error("SHARE")
                            }
                        }
                    } catch (_: Exception) {
                        main.post { if (session.finish(operation)) operation.error("WRITE") }
                    }
                }
            }
        } catch (_: Exception) {
            session.finish(operation); operation.error("SHARE")
        }
    }

    fun onActivityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != SAVE_REQUEST && request != SHARE_REQUEST) return false
        val operation = session.current() ?: return true
        if (request == SHARE_REQUEST) { session.finish(operation); return true }
        if (!operation.save) return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            session.finish(operation); operation.success("cancelled"); return true
        }
        if (uri.scheme != "content") { session.finish(operation); operation.error("WRITE"); return true }
        worker.execute {
            try {
                if (session.current() !== operation) return@execute
                DiagnosticExportTransfer.save(operation.bytes) {
                    activity.contentResolver.openOutputStream(uri, "wt") ?: throw IllegalStateException()
                }
                main.post { if (session.finish(operation)) operation.success("saved") }
            } catch (_: Exception) {
                // A failed provider write must never become a successful export.
                main.post { if (session.finish(operation)) operation.error("WRITE") }
            }
        }
        return true
    }

    fun close() {
        closed = true
        session.close()?.success("cancelled")
        safe.setMethodCallHandler(null)
        full.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { jsonValue(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}
