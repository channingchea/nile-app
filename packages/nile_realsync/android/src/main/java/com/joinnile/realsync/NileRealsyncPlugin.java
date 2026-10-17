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
 * RealSync (Studio master host, phase 7) — Android. Finds flutter_webrtc's
 * senders/receivers by id and hands their native pointers to
 * nile_realsync.cpp: the jitter-buffer minimum delay, and the capture-stamp
 * transformers (src/realsync_stamp.cc). Everything flutter_webrtc doesn't make
 * public is reached by reflection; consumer-rules.pro keeps those names.
 */
public class NileRealsyncPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  static {
    System.loadLibrary("nile_realsync");
  }

  private static native String nativeCheck(long receiverPtr);

  private static native void nativeSetDelay(long receiverPtr, double seconds, boolean clear);

  private static native String nativeStampCheck(long ptr, boolean sender);

  private static native boolean nativeStampSender(String id, long ptr, boolean audio, int opusPt, int redPt);

  private static native boolean nativeReadReceiver(String id, long ptr, boolean audio);

  private static native void nativeForget(String id);

  /** [median age ms, count], or null when no stamped frame arrived in the window. */
  private static native double[] nativeAge(String id, int windowMs);

  private static native long nativeStampedCount(String id);

  private MethodChannel channel;

  /** Native objects whose slots passed their check — checked once each. */
  private final Map<String, Boolean> checked = new HashMap<>();

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
    try {
      switch (call.method) {
        case "selfTest":
        case "stampSelfTest": {
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
          Object receiver = receiverId == null ? null : find(receiverId, false);
          long ptr = receiver == null ? 0 : nativePtr(receiver, false);
          if (ptr == 0 || !passes("delay:" + ptr, nativeCheck(ptr))) {
            result.success(false);
            return;
          }
          double s = seconds == null ? 0 : Math.max(0, Math.min(10, seconds.doubleValue()));
          nativeSetDelay(ptr, s, seconds == null);
          result.success(true);
          return;
        }
        case "stampSender":
        case "readReceiver": {
          boolean sender = call.method.equals("stampSender");
          String id = call.argument("id");
          boolean audio = Boolean.TRUE.equals(call.argument("audio"));
          Object obj = id == null ? null : find(id, sender);
          long ptr = obj == null ? 0 : nativePtr(obj, sender);
          if (ptr == 0 || !passes((sender ? "send:" : "recv:") + ptr, nativeStampCheck(ptr, sender))) {
            result.success(false);
            return;
          }
          result.success(sender
              ? nativeStampSender(id, ptr, audio, audio ? payloadType(obj, "opus") : -1,
                  audio ? payloadType(obj, "red") : -1)
              : nativeReadReceiver(id, ptr, audio));
          return;
        }
        case "forget": {
          String id = call.argument("id");
          if (id != null) nativeForget(id);
          result.success(null);
          return;
        }
        case "ages": {
          List<?> ids = call.argument("ids");
          Number window = call.argument("windowMs");
          Map<String, Object> out = new HashMap<>();
          if (ids != null) {
            for (Object id : ids) {
              if (!(id instanceof String)) continue;
              double[] age = nativeAge((String) id, window == null ? 1500 : window.intValue());
              if (age == null) continue;
              Map<String, Object> entry = new HashMap<>();
              entry.put("ageMs", age[0]);
              entry.put("count", (int) age[1]);
              out.put((String) id, entry);
            }
          }
          result.success(out);
          return;
        }
        case "stampedCount": {
          String id = call.argument("id");
          result.success(id == null ? -1L : nativeStampedCount(id));
          return;
        }
        default:
          result.notImplemented();
      }
    } catch (Throwable t) {
      result.success(call.method.equals("ages") ? new HashMap<>() : false);
    }
  }

  private boolean passes(String key, String failure) {
    Boolean ok = checked.get(key);
    if (ok == null) {
      ok = failure == null;
      checked.put(key, ok);
    }
    return ok;
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
      Class.forName("org.webrtc.RtpSender").getDeclaredField("nativeRtpSender");
      Class.forName("org.webrtc.PeerConnection").getMethod("getReceivers");
      Class.forName("org.webrtc.PeerConnection").getMethod("getSenders");
      return null;
    } catch (Throwable t) {
      return "flutter_webrtc internals changed: " + t.getClass().getSimpleName();
    }
  }

  /** flutter_webrtc's org.webrtc.RtpSender/RtpReceiver with this id, across every peer connection. */
  private static Object find(String id, boolean sender) throws Exception {
    Object plugin =
        Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin").getField("sharedSingleton").get(null);
    if (plugin == null) return null;
    Object handler = field(plugin, "methodCallHandler");
    if (handler == null) return null;
    Map<?, ?> observers = (Map<?, ?>) field(handler, "mPeerConnectionObservers");
    for (Object observer : observers.values()) {
      Object pc = observer.getClass().getMethod("getPeerConnection").invoke(observer);
      if (pc == null) continue;
      Method list = pc.getClass().getMethod(sender ? "getSenders" : "getReceivers");
      for (Object o : (List<?>) list.invoke(pc)) {
        if (id.equals(o.getClass().getMethod("id").invoke(o))) return o;
      }
    }
    return null;
  }

  private static long nativePtr(Object o, boolean sender) throws Exception {
    Field f = o.getClass().getDeclaredField(sender ? "nativeRtpSender" : "nativeRtpReceiver");
    f.setAccessible(true);
    return f.getLong(o);
  }

  /** The sender's negotiated payload type for a codec name, or -1. */
  private static int payloadType(Object sender, String name) {
    try {
      Object params = sender.getClass().getMethod("getParameters").invoke(sender);
      for (Object c : (List<?>) params.getClass().getField("codecs").get(params)) {
        if (name.equalsIgnoreCase((String) c.getClass().getField("name").get(c))) {
          return c.getClass().getField("payloadType").getInt(c);
        }
      }
    } catch (Throwable ignored) {
    }
    return -1;
  }
}
