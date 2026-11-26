Pod::Spec.new do |s|
  s.name             = 'eyzflow_player'
  s.version          = '0.9.0'
  s.summary          = 'Native playback for the EYZFlow player.'
  s.description      = <<-DESC
AVPlayer-based playback for eyzflow_player: HLS, FairPlay, AirPlay, Picture-in-Picture
and Now Playing. Based on better_native_video_player (MIT).
                       DESC
  s.homepage         = 'https://github.com/eyzflow/eyzflow-player-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'EYZ Media' => 'https://eyzflow.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'eyzflow_player/Sources/eyzflow_player/**/*.swift'
  s.resource_bundles = { 'eyzflow_player_privacy' => ['eyzflow_player/Sources/eyzflow_player/Resources/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
