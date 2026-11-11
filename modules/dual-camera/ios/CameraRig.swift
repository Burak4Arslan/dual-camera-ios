import AVFoundation

/// Kameraların donanım tarafı: oturum, girişler, çıkışlar ve önizleme katmanları. Tek ve ortak:
/// uygulama açılır açılmaz (`prewarm`, arayüz kodu yüklenirken) kameralar kurulup çalıştırılır,
/// ekrandaki DualCameraView geldiğinde hazır oturumu devralır. Önceden kamera ancak ekran
/// çizildikten sonra açılmaya başlıyordu. Bütün durum `queue` üzerinde kullanılır.
final class CameraRig {
  static let shared = CameraRig()

  let session = AVCaptureMultiCamSession()
  let queue = DispatchQueue(label: "dualcam.session")

  let backPreview = AVCaptureVideoPreviewLayer()
  let frontPreview = AVCaptureVideoPreviewLayer()
  let backOutput = AVCaptureVideoDataOutput()
  let frontOutput = AVCaptureVideoDataOutput()
  let backPhotoOutput = AVCapturePhotoOutput()
  let frontPhotoOutput = AVCapturePhotoOutput()
  let audioOutput = AVCaptureAudioDataOutput()

  /// Oturumun tamamı (ses ve mikrofon dahil) DualCameraView tarafından kuruldu.
  var isConfigured = false
  /// Kameralar bağlı (ön ısıtmada ya da görünümün kurulumunda).
  var camerasReady = false
  var back: CameraLinks?
  var front: CameraLinks?
  var activeKind: CaptureKind = .video
  /// Arka kameranın görüntü oranı; değişince `onFrameRatio` (görünüm yerleşimini günceller).
  var frameRatio: CGFloat = 16 / 9
  var onFrameRatio: ((CGFloat) -> Void)?

  /// Son çekim türü (foto/video), ön ısıtmada doğru formatla açılmak için.
  static let kindKey = "dualcam.lastCaptureKind"

  /// Uygulama açılırken çağrılır: izin zaten verildiyse kameraları kurup çalıştırır. İzin yoksa,
  /// cihaz desteklemiyorsa ya da bir şey ters giderse hiçbir şey yapmaz; görünüm her zamanki gibi kurar.
  func prewarm() {
    guard AVCaptureMultiCamSession.isMultiCamSupported,
      AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    else { return }
    queue.async { [self] in
      guard !camerasReady else { return }
      if let saved = UserDefaults.standard.string(forKey: Self.kindKey), let kind = CaptureKind(rawValue: saved) {
        activeKind = kind
      }
      // Ses oturumunu görünüm yönetir (yaka mikrofonu seçimi); oturum kendi başına dokunmasın.
      session.automaticallyConfiguresApplicationAudioSession = false
      session.beginConfiguration()
      do {
        try configureCameras()
      } catch {
        // Yarıda kaldıysa (ör. ön kamera bağlandı, arka olmadı) temizle; görünüm baştan kursun.
        for links in [back, front].compactMap({ $0 }) { removeCamera(links) }
        back = nil
        front = nil
        session.commitConfiguration()
        return
      }
      session.commitConfiguration()
      session.startRunning()
    }
  }

  /// `queue` üzerinde, beginConfiguration/commitConfiguration arasında çağrılır. Ön kamera ve
  /// donanıma sığan en iyi arka kamerayı bağlar.
  func configureCameras() throws {
    guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    else { throw DualCameraError.noCamera }
    front = try addCamera(
      frontCamera, output: frontOutput, photoOutput: frontPhotoOutput, preview: frontPreview, mirrored: true)

    // Arka kamera: önce lensler arasında kendiliğinden geçen sanal kameralar (0,5x ultra geniş,
    // 3x tele), olmazsa tek geniş açı lens. Sanal kamera ön kamerayla birlikte 1080p'de donanıma
    // sığmıyorsa bir sonrakine geçilir; tek lens gerekirse 720p'ye düşer.
    var lastError: Error = DualCameraError.noCamera
    for candidate in backCandidates(with: frontCamera) {
      let fallback = candidate.deviceType == .builtInWideAngleCamera
      do {
        let links = try addCamera(
          candidate, output: backOutput, photoOutput: backPhotoOutput, preview: backPreview, mirrored: false)
        back = links
        if try applyFormats(allowDowngrade: fallback) || fallback {
          break
        }
        removeCamera(links)
      } catch {
        lastError = error
      }
      back = nil
    }
    guard back != nil else { throw lastError }
    camerasReady = true
  }

  /// Ön kamerayla birlikte çift kamera oturumunda kullanılabilen arka kameralar, tercih sırasıyla.
  func backCandidates(with front: AVCaptureDevice) -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
    let sets = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
      .supportedMultiCamDeviceSets
    return types
      .compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }
      .filter { device in sets.contains { $0.contains(device) && $0.contains(front) } }
  }

  /// sessionQueue üzerinde, oturum yapılandırılırken çağrılır. Video: 16:9 1080p; foto: 4:3, en yüksek
  /// foto çözünürlüğü. Donanım iki kamerayı kaldırmazsa ve `allowDowngrade` ise önce yüz, sonra sahne
  /// kamerasını küçültür. Donanım sınırı aşılmıyorsa true döner.
  @discardableResult
  func applyFormats(allowDowngrade: Bool = true) throws -> Bool {
    guard let back, let front else { return false }
    let photo = activeKind == .photo
    try selectFormat(back.device, photo: photo, maxWidth: 1920)
    try selectFormat(front.device, photo: photo, maxWidth: 1920)
    if allowDowngrade && session.hardwareCost > 1.0 {
      try selectFormat(front.device, photo: photo, maxWidth: 1280)
    }
    if allowDowngrade && session.hardwareCost > 1.0 {
      try selectFormat(back.device, photo: photo, maxWidth: 1280)
    }
    // Foto, kameranın o anki formatının izin verdiği en büyük boyutta çekilsin.
    for (links, output) in [(back, backPhotoOutput), (front, frontPhotoOutput)] {
      if let dims = links.device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
        output.maxPhotoDimensions = dims
      }
    }
    let d = CMVideoFormatDescriptionGetDimensions(back.device.activeFormat.formatDescription)
    let ratio = CGFloat(d.width) / CGFloat(d.height)
    frameRatio = ratio
    onFrameRatio?(ratio)
    return session.hardwareCost <= 1.0
  }

  /// Kamerayı oturuma bağlar; yarıda kalırsa eklediği girişi geri alır (bir sonraki aday denensin).
  func addCamera(
    _ device: AVCaptureDevice, output: AVCaptureVideoDataOutput, photoOutput: AVCapturePhotoOutput,
    preview: AVCaptureVideoPreviewLayer, mirrored: Bool
  ) throws -> CameraLinks {
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw DualCameraError.noCamera }
    session.addInputWithNoConnections(input)
    var added: [AVCaptureConnection] = []

    func connect(_ conn: AVCaptureConnection) throws {
      guard session.canAddConnection(conn) else { throw DualCameraError.noCamera }
      session.addConnection(conn)
      added.append(conn)
    }

    do {
      guard let port = input.ports(
        for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position
      ).first else { throw DualCameraError.noCamera }

      // Çıkışlar önceki denemeden kalmış olabilir.
      output.alwaysDiscardsLateVideoFrames = true
      for out in [output, photoOutput] as [AVCaptureOutput] where !session.outputs.contains(out) {
        guard session.canAddOutput(out) else { throw DualCameraError.noCamera }
        session.addOutputWithNoConnections(out)
      }

      let outConn = AVCaptureConnection(inputPorts: [port], output: output)
      try connect(outConn)
      let photoConn = AVCaptureConnection(inputPorts: [port], output: photoOutput)
      try connect(photoConn)
      // Foto her zaman en yüksek kalitede (oturum başlamadan ayarlanmalı).
      photoOutput.maxPhotoQualityPrioritization = .quality
      preview.setSessionWithNoConnection(session)
      let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
      try connect(previewConn)

      // Yalnızca yüz önizlemesi ayna gibidir; kaydedilen yüz videosu ve fotosu düzdür.
      for conn in [outConn, photoConn, previewConn] where conn.isVideoMirroringSupported {
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = mirrored && conn === previewConn
      }

      return CameraLinks(device: device, input: input, video: outConn, photo: photoConn, preview: previewConn)
    } catch {
      added.forEach { session.removeConnection($0) }
      session.removeInput(input)
      throw error
    }
  }

  func removeCamera(_ links: CameraLinks) {
    [links.video, links.photo, links.preview].forEach { session.removeConnection($0) }
    session.removeInput(links.input)
  }

  /// Çoklu kamera destekli, 30 fps yapabilen, en fazla `maxWidth` genişlikte format.
  /// Video: 16:9, en genişi. Foto: 4:3, en büyük foto çekebileni.
  func selectFormat(_ device: AVCaptureDevice, photo: Bool, maxWidth: Int32) throws {
    let (w, h) = photo ? (4, 3) : (16, 9)
    let candidates = device.formats.filter { f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return f.isMultiCamSupported
        && d.width <= maxWidth
        && Int(d.width) * h == Int(d.height) * w
        && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
    }
    func score(_ f: AVCaptureDevice.Format) -> (Int32, Int32) {
      let photoWidth = f.supportedMaxPhotoDimensions.map(\.width).max() ?? 0
      return (photo ? photoWidth : 0, CMVideoFormatDescriptionGetDimensions(f.formatDescription).width)
    }
    guard let best = candidates.max(by: { score($0) < score($1) }) else { return }

    try device.lockForConfiguration()
    device.activeFormat = best
    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    device.unlockForConfiguration()
  }
}
