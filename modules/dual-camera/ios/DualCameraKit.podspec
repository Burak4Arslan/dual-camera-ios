Pod::Spec.new do |s|
  s.name           = 'DualCameraKit'
  s.version        = '1.0.0'
  s.summary        = 'Ön + arka kamerayı aynı anda kaydeden Expo modülü'
  s.description    = 'AVCaptureMultiCamSession ile resim-içinde-resim video kaydı'
  s.author         = ''
  s.homepage       = 'https://example.com'
  s.license        = 'MIT'
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true
  s.swift_version  = '5.9'

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = '**/*.{h,m,swift}'
end
