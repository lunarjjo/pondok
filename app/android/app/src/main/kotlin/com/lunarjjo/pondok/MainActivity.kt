package com.lunarjjo.pondok

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "pondok/assets"
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyAsset" -> {
                        val name = call.argument<String>("name")
                        val dest = call.argument<String>("dest")
                        if (name.isNullOrEmpty() || dest.isNullOrEmpty()) {
                            result.error("bad_args", "name and dest are required", null)
                            return@setMethodCallHandler
                        }
                        // The pack is ~150-250 MB: stream it off the main
                        // thread so neither the UI nor the heap ever holds
                        // more than a 64 KiB buffer.
                        Thread {
                            try {
                                var copied = 0L
                                assets.open(name).use { input ->
                                    File(dest).outputStream().use { out ->
                                        copied = input.copyTo(out, 1 shl 16)
                                    }
                                }
                                mainHandler.post { result.success(copied) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("copy_failed", e.message, null)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
