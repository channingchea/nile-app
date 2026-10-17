Pod::Spec.new do |s|
  s.name             = 'nile_realsync'
  s.version          = '0.1.0'
  s.summary          = 'RealSync playout-delay hook for Nile.'
  s.description      = 'Sets WebRTC jitter-buffer minimum delay on a remote receiver (iOS/macOS).'
  s.homepage         = 'https://joinnile.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Nile' => 'support@joinnile.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  # No dependency on flutter_webrtc / WebRTC-SDK on purpose: RealSync finds
  # both at runtime (dlsym, NSClassFromString), and a pod dependency on
  # flutter_webrtc trips CocoaPods' static-framework check on iOS.
  s.platform = :ios, '13.0'
  s.library = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
end
