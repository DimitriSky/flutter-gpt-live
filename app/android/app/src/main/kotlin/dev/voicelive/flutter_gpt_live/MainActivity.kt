package dev.voicelive.flutter_gpt_live

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val callChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gpt_live/call_service")
        channel = callChannel
        callChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, CallService::class.java)
                        .setAction(CallService.ACTION_START)
                        .putExtra(CallService.EXTRA_TITLE, call.argument<String>("title"))
                        .putExtra(CallService.EXTRA_TEXT, call.argument<String>("text"))
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    } catch (error: Exception) {
                        // e.g. ForegroundServiceStartNotAllowedException if not in the foreground.
                        result.error("start_failed", error.message, null)
                    }
                }
                "update" -> {
                    val muted = call.argument<Boolean>("muted") ?: false
                    CallService.instance?.let { service -> runOnUiThread { service.setMuted(muted) } }
                    result.success(true)
                }
                "stop" -> {
                    // stopService is allowed from the background (startService is not).
                    stopService(Intent(this, CallService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        CallService.onEndRequested = {
            runOnUiThread { callChannel.invokeMethod("endCall", null) }
        }
        CallService.onMuteToggleRequested = {
            runOnUiThread { callChannel.invokeMethod("toggleMute", null) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        CallService.onEndRequested = null
        CallService.onMuteToggleRequested = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        // The engine and the WebRTC call die with the activity.
        if (isFinishing) stopService(Intent(this, CallService::class.java))
        super.onDestroy()
    }
}
