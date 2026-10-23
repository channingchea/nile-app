package com.nilestreaming.app

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Studio status link: battery and heat, sent to the Studio while this
        // phone is a camera (lib/services/camera_status.dart, DeviceStatus).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nile/device_status")
            .setMethodCallHandler { call, result ->
                if (call.method != "read") return@setMethodCallHandler result.notImplemented()
                val out = HashMap<String, Any>()
                val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                if (level in 0..100) out["battery"] = level
                out["charging"] = bm.isCharging
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    out["thermal"] = when (pm.currentThermalStatus) {
                        PowerManager.THERMAL_STATUS_NONE, PowerManager.THERMAL_STATUS_LIGHT -> "nominal"
                        PowerManager.THERMAL_STATUS_MODERATE -> "fair"
                        PowerManager.THERMAL_STATUS_SEVERE -> "serious"
                        else -> "critical"
                    }
                }
                result.success(out)
            }
    }
}
