package com.lunarjjo.pondok

import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SELinux
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
                    "deviceInfo" -> {
                        // Diagnostics context (D-17): model/ABI/SELinux state
                        // decorate every bug report. Page size goes through
                        // reflection so the build never depends on an
                        // android.system API level.
                        val info = mutableMapOf<String, String>()
                        info["model"] = Build.MODEL ?: "?"
                        info["manufacturer"] = Build.MANUFACTURER ?: "?"
                        info["android"] = Build.VERSION.RELEASE ?: "?"
                        info["sdk"] = Build.VERSION.SDK_INT.toString()
                        info["abis"] = Build.SUPPORTED_ABIS.joinToString(",")
                        info["pageSize"] = try {
                            val os = Class.forName("android.system.Os")
                            val constants = Class.forName("android.system.OsConstants")
                            val sc = constants.getField("_SC_PAGESIZE").get(null)
                            os.getMethod("sysconf", Int::class.javaPrimitiveType)
                                .invoke(null, sc).toString()
                        } catch (t: Throwable) {
                            "unknown"
                        }
                        info["selinuxEnforcing"] = try {
                            SELinux.isSELinuxEnforced().toString()
                        } catch (t: Throwable) {
                            "unknown"
                        }
                        result.success(info)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
