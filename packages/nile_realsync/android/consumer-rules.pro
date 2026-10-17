# RealSync reaches flutter_webrtc's peer connections and libwebrtc's native
# receiver pointer by reflection. Keep the names it looks up.
-keep class com.cloudwebrtc.webrtc.FlutterWebRTCPlugin { *; }
-keep class com.cloudwebrtc.webrtc.MethodCallHandlerImpl { *; }
-keep class com.cloudwebrtc.webrtc.PeerConnectionObserver { *; }
-keep class org.webrtc.RtpReceiver { *; }
-keep class org.webrtc.PeerConnection { *; }
