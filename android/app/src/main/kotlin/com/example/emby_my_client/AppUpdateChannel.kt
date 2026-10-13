package com.example.emby_my_client

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile

/** No network, credential access, silent installation, or signature bypass. */
internal class AppUpdateChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "emby_my_client/app_updates")
    private val worker = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    init { channel.setMethodCallHandler(::handle) }

    @Suppress("DEPRECATION")
    private fun packageFlags(): Int = if (Build.VERSION.SDK_INT >= 28) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) {
        info.longVersionCode
    } else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) {
            info.signingInfo?.apkContentsSigners
        } else info.signatures
        return signatures?.map { signature ->
            hex(MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()))
        }?.toSet() ?: emptySet()
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    @Suppress("DEPRECATION")
    private fun installed(): PackageInfo = activity.packageManager.getPackageInfo(
        activity.packageName, packageFlags(),
    )

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "metadata" -> {
                    val info = installed()
                    result.success(mapOf(
                        "version" to info.versionName,
                        "buildNumber" to versionCode(info),
                        "abis" to Build.SUPPORTED_ABIS.toList(),
                    ))
                }
                "allowInstalls" -> {
                    if (Build.VERSION.SDK_INT >= 26) {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                    }
                    result.success(null)
                }
                "validate", "install" -> {
                    if (!busy.compareAndSet(false, true)) {
                        result.error("installer", "Update operation already in progress", null)
                        return
                    }
                    worker.execute {
                        try {
                            val file = validate(call)
                            activity.runOnUiThread {
                                try {
                                    if (!closed.get()) {
                                        if (call.method == "install") handOff(file, result)
                                        else result.success(null)
                                    }
                                } catch (_: Exception) {
                                    result.error("installer", "Cannot open installer", null)
                                } finally { busy.set(false) }
                            }
                        } catch (error: Exception) {
                            activity.runOnUiThread {
                                if (!closed.get()) result.error(
                                    (error as? UpdateRejected)?.reason ?: "package",
                                    "Package verification failed", null,
                                )
                                busy.set(false)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            busy.set(false)
            result.error(if (call.method == "metadata") "metadata" else "installer",
                "Update operation unavailable", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun validate(call: MethodCall): File {
        val path = call.argument<String>("path") ?: throw UpdateRejected("package")
        val expectedHash = call.argument<String>("sha256") ?: throw UpdateRejected("checksum")
        val size = call.argument<Number>("size")?.toLong() ?: throw UpdateRejected("size")
        val release = call.argument<Number>("release")?.toInt() ?: throw UpdateRejected("package")
        val root = File(activity.cacheDir, "app_updates").canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith(root.path + File.separator) || file.name != "update.apk" ||
            !file.isFile) throw UpdateRejected("package")
        if (size <= 0 || size > 512L * 1024 * 1024 || file.length() != size) throw UpdateRejected("size")
        if (!Regex("[0-9a-f]{64}").matches(expectedHash)) throw UpdateRejected("checksum")
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                if (Thread.currentThread().isInterrupted) throw UpdateRejected("cancelled")
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        if (hex(digest.digest()) != expectedHash) throw UpdateRejected("checksum")
        val candidate = activity.packageManager.getPackageArchiveInfo(file.path, packageFlags())
            ?: throw UpdateRejected("package")
        val current = installed()
        val abis = ZipFile(file).use { zip ->
            Build.SUPPORTED_ABIS.filter { abi ->
                zip.getEntry("lib/$abi/libflutter.so") != null
            }.toSet()
        }
        ApkUpdatePolicy.verify(
            UpdatePackageIdentity(current.packageName, versionCode(current), current.versionName ?: "",
                0, signers(current), emptySet()),
            UpdatePackageIdentity(candidate.packageName, versionCode(candidate), candidate.versionName ?: "",
                candidate.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE, signers(candidate), abis),
            Build.VERSION.SDK_INT, Build.SUPPORTED_ABIS.toSet(), release,
        )
        return file
    }

    private fun handOff(file: File, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            result.success("permission")
            return
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.app_updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("Application update", uri)
        }
        activity.startActivity(intent)
        // A handoff is not evidence that the user completed installation.
        result.success("opened")
    }

    fun close() {
        closed.set(true)
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
