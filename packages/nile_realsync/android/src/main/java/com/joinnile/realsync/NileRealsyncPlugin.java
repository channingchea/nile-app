package com.joinnile.realsync;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * RealSync (Studio master host, phase 7a) — Android. Finds flutter_webrtc's
 * receiver by id and sets its jitter-buffer minimum delay through
 * nile_realsync.cpp. Everything flutter_webrtc doesn't make public is reached by
 * reflection; consumer-rules.pro keeps those names through R8.
 */
public class NileRealsyncPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  static {
    System.loadLibrary("nile_realsync");
  }

  private static native String nativeCheck(long receiverPtr);

  private static native void nativeSetDelay(long receiverPtr, double seconds, boolean clear);

  private MethodChannel channel;

  /** Receivers whose slots passed nativeCheck — checked once per receiver. */
  private final Map<Long, Boolean> checked = new HashMap<>();

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), "nile_realsync");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    switch (call.method) {
      case "selfTest": {
        String failure = reflectionFailure();
        Map<String, Object> out = new HashMap<>();
        out.put("ok", failure == null);
        out.put("reason", failure);
        result.success(out);
        return;
      }
      case "setMinimumPlayoutDelay": {
        String receiverId = call.argument("receiverId");
        Number seconds = call.argument("seconds");
        try {
          Long ptr = receiverId == null ? null : nativeReceiver(receiverId);
          if (ptr == null || ptr == 0) {
            result.success(false);
            return;
          }
          Boolean ok = checked.get(ptr);
          if (ok == null) {
            ok = nativeCheck(ptr) == null;
            checked.put(ptr, ok);
          }
          if (!ok) {
            result.success(false);
            return;
          }
          double s = seconds == null ? 0 : Math.max(0, Math.min(10, seconds.doubleValue()));
          nativeSetDelay(ptr, s, seconds == null);
          result.success(true);
        } catch (Throwable t) {
          result.success(false);
        }
        return;
      }
      default:
        result.notImplemented();
    }
  }

  private static Object field(Object target, String name) throws Exception {
    Field f = target.getClass().getDeclaredField(name);
    f.setAccessible(true);
    return f.get(target);
  }

  /** Why the reflection path is broken, or null when it works. */
  private static String reflectionFailure() {
    try {
      Class<?> plugin = Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin");
      plugin.getField("sharedSingleton");
      plugin.getDeclaredField("methodCallHandler");
      Class.forName("com.cloudwebrtc.webrtc.MethodCallHandlerImpl")
          .getDeclaredField("mPeerConnectionObservers");
      Class.forName("com.cloudwebrtc.webrtc.PeerConnectionObserver").getMethod("getPeerConnection");
      Class.forName("org.webrtc.RtpReceiver").getDeclaredField("nativeRtpReceiver");
      Class.forName("org.webrtc.PeerConnection").getMethod("getReceivers");
      return null;
    } catch (Throwable t) {
      return "flutter_webrtc internals changed: " + t.getClass().getSimpleName();
    }
  }

  private static Long nativeReceiver(String receiverId) throws Exception {
    Object plugin =
        Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin").getField("sharedSingleton").get(null);
    if (plugin == null) return null;
    Object handler = field(plugin, "methodCallHandler");
    if (handler == null) return null;
    Map<?, ?> observers = (Map<?, ?>) field(handler, "mPeerConnectionObservers");
    for (Object observer : observers.values()) {
      Object pc = observer.getClass().getMethod("getPeerConnection").invoke(observer);
      if (pc == null) continue;
      Method getReceivers = pc.getClass().getMethod("getReceivers");
      for (Object receiver : (List<?>) getReceivers.invoke(pc)) {
        Object id = receiver.getClass().getMethod("id").invoke(receiver);
        if (receiverId.equals(id)) {
          Field f = receiver.getClass().getDeclaredField("nativeRtpReceiver");
          f.setAccessible(true);
          return f.getLong(receiver);
        }
      }
    }
    return null;
  }
}
