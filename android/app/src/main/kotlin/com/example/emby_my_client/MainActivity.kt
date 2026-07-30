package com.example.emby_my_client

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "emby_my_client/picture_in_picture"
        private const val ACTION_TOGGLE = "emby_my_client.PIP_TOGGLE"
        private const val ACTION_CLOSE = "emby_my_client.PIP_CLOSE"
    }

    private var channel: MethodChannel? = null
    private var isPlaying = false
    private val pipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_TOGGLE -> channel?.invokeMethod("pipAction", "toggle")
                ACTION_CLOSE -> {
                    channel?.invokeMethod("pipAction", "close")
                    moveTaskToBack(true)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter().apply {
            addAction(ACTION_TOGGLE)
            addAction(ACTION_CLOSE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(pipReceiver, filter)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O,
                    )
                    "enter" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(false)
                        } else {
                            result.success(
                                enterPictureInPictureMode(buildPipParams()),
                            )
                        }
                    }
                    "updatePlaying" -> {
                        isPlaying = call.arguments as? Boolean ?: false
                        if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            isInPictureInPictureMode
                        ) {
                            setPictureInPictureParams(buildPipParams())
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipModeChanged", isInPictureInPictureMode)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(pipReceiver)
        } catch (_: IllegalArgumentException) {
        }
        channel = null
        super.onDestroy()
    }

    private fun buildPipParams(): PictureInPictureParams {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            throw IllegalStateException("Picture-in-picture requires Android 8.0")
        }
        val toggleIcon = if (isPlaying) {
            android.R.drawable.ic_media_pause
        } else {
            android.R.drawable.ic_media_play
        }
        val toggleTitle = if (isPlaying) "暂停" else "播放"
        return PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .setActions(
                listOf(
                    remoteAction(
                        ACTION_TOGGLE,
                        toggleIcon,
                        toggleTitle,
                        1,
                    ),
                    remoteAction(
                        ACTION_CLOSE,
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "关闭",
                        2,
                    ),
                ),
            )
            .build()
    }

    private fun remoteAction(
        action: String,
        iconResource: Int,
        title: String,
        requestCode: Int,
    ): RemoteAction {
        val intent = Intent(action).setPackage(packageName)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return RemoteAction(
            Icon.createWithResource(this, iconResource),
            title,
            title,
            pendingIntent,
        )
    }
}
