import AVFoundation
import ExpoModulesCore
import Photos
import UIKit

// Önizlemede arka kamera tam kare, ön kamera (yüz) sağ üst köşede küçük pencere.
// Kayıtta ise iki kamera iki ayrı video dosyası olur (kurguda yerleştirmek için).
private enum Pip {
  static let longSideRatio: CGFloat = 0.28 // karenin uzun kenarına oranla
  static let marginRatio: CGFloat = 0.045  // karenin kısa kenarına oranla
  static let cornerRatio: CGFloat = 0.06   // pencerenin uzun kenarına oranla
  static let borderRatio: CGFloat = 0.004  // karenin kısa kenarına oranla

  /// Kare içinde pencerenin yeri; y yukarıdan aşağı ölçülür (UIKit düzeni).
  static func rect(in frame: CGSize) -> CGRect {
    let long = max(frame.width, frame.height) * longSideRatio
    let size = frame.width >= frame.height
      ? CGSize(width: long, height: long * 9 / 16)
      : CGSize(width: long * 9 / 16, height: long)
    let margin = min(frame.width, frame.height) * marginRatio
    return CGRect(x: frame.width - margin - size.width, y: margin, width: size.width, height: size.height)
  }
}

enum DualCameraError: LocalizedError {
  case notSupported
  case noCamera
  case notRecording
  case tooShort
  case writerFailed(String)
  case photosDenied
  case saveFailed(String)

  var errorDescription: String? {
    switch self {
    case .notSupported: return "Bu cihaz aynı anda iki kamerayı desteklemiyor."
    case .noCamera: return "Kameralar açılamadı."
    case .notRecording: return "Kayıt yapılmıyor."
    case .tooShort: return "Kayıt çok kısa, hiç kare yakalanmadı."
    case .writerFailed(let m): return "Video yazılamadı: \(m)"
    case .photosDenied: return "Galeriye kaydetme izni yok. Ayarlar > DualCam > Fotoğraflar."
    case .saveFailed(let m): return "Galeriye kaydedilemedi: \(m)"
    }
  }
}

/// Tek bir kameranın video dosyası (görüntü + yaka mikrofonu sesi).
private final class Track {
  let url: URL
  private(set) var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private(set) var lastVideoTime: CMTime?

  init(name: String) {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dualcam-\(name)-\(UUID().uuidString).mov")
  }

  var isWriting: Bool { writer?.status == .writing }

  /// İlk karenin boyutuyla yazıcıyı kurar ve oturumu `start` anından başlatır.
  func start(firstFrame: CMSampleBuffer, at start: CMTime, audioSettings: [String: Any]?) throws {
    guard let image = CMSampleBufferGetImageBuffer(firstFrame) else { throw DualCameraError.tooShort }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: CVPixelBufferGetWidth(image),
      AVVideoHeightKey: CVPixelBufferGetHeight(image),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 16_000_000,
        AVVideoExpectedSourceFrameRateKey: 30,
      ],
    ])
    videoInput.expectsMediaDataInRealTime = true
    writer.add(videoInput)

    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = true
    if writer.canAdd(audioInput) {
      writer.add(audioInput)
      self.audioInput = audioInput
    }

    guard writer.startWriting() else {
      throw DualCameraError.writerFailed(writer.error?.localizedDescription ?? "başlatılamadı")
    }
    // İki dosya da aynı andan başlar; kurguda üst üste koyunca senkron olur.
    writer.startSession(atSourceTime: start)
    self.writer = writer
    self.videoInput = videoInput
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard isWriting, let input = videoInput, input.isReadyForMoreMediaData else { return }
    if input.append(sampleBuffer) {
      lastVideoTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard isWriting, let input = audioInput, input.isReadyForMoreMediaData else { return }
    input.append(sampleBuffer)
  }

  /// Yazıcı kurulamadıysa tekrar denenmesin diye işaretlenir.
  var failed = false

  /// Dosyayı kapatır; başarılıysa URL'yi döner.
  func finish(completion: @escaping (Result<URL, Error>) -> Void) {
    guard let writer, writer.status == .writing, lastVideoTime != nil else {
      discard()
      completion(.failure(writer?.error.map { DualCameraError.writerFailed($0.localizedDescription) }
        ?? DualCameraError.tooShort))
      return
    }
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    writer.finishWriting { [self] in
      if writer.status == .completed {
        completion(.success(url))
      } else {
        discard()
        completion(.failure(DualCameraError.writerFailed(writer.error?.localizedDescription ?? "bilinmiyor")))
      }
    }
  }

  func discard() {
    try? FileManager.default.removeItem(at: url)
  }
}

enum CameraMode: String {
  case both, back, front

  var usesBack: Bool { self != .front }
  var usesFront: Bool { self != .back }
}

private final class Recorder {
  let back: Track?
  let front: Track?
  var startTime: CMTime?

  init(mode: CameraMode) {
    back = mode.usesBack ? Track(name: "sahne") : nil
    front = mode.usesFront ? Track(name: "yuz") : nil
  }

  /// Galeriye kayıt sırası: önce sahne, sonra yüz.
  var tracks: [Track] { [back, front].compactMap { $0 } }

  /// Kaydın başlangıç anını bu kameranın ilk karesi belirler.
  var leader: Track? { back ?? front }
}

final class DualCameraView: ExpoView,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  let onReady = EventDispatcher()
  let onMicChange = EventDispatcher()
  let onCameraError = EventDispatcher()
  let onAutoStopped = EventDispatcher()

  private let session = AVCaptureMultiCamSession()
  private let sessionQueue = DispatchQueue(label: "dualcam.session")
  private let dataQueue = DispatchQueue(label: "dualcam.data")

  private let backPreview = AVCaptureVideoPreviewLayer()
  private let frontPreview = AVCaptureVideoPreviewLayer()
  private let frontContainer = UIView()

  private let backOutput = AVCaptureVideoDataOutput()
  private let frontOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()

  // sessionQueue üzerinde kullanılır.
  private var isConfigured = false
  private var captureOrientation: AVCaptureVideoOrientation = .portrait
  private var videoConnections: [AVCaptureConnection] = []
  private var mirroredConnections: [AVCaptureConnection] = []
  private var backConnections: [AVCaptureConnection] = []
  private var frontConnections: [AVCaptureConnection] = []
  private var activeMode: CameraMode = .both

  // Ana thread üzerinde kullanılır.
  private var isRecording = false
  private var isLandscape = false
  private var mode: CameraMode = .both

  // Yalnızca dataQueue üzerinde kullanılır.
  private var recorder: Recorder?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black
    clipsToBounds = true

    backPreview.videoGravity = .resizeAspect
    layer.addSublayer(backPreview)

    frontPreview.videoGravity = .resizeAspectFill
    frontContainer.layer.addSublayer(frontPreview)
    frontContainer.clipsToBounds = true
    frontContainer.layer.borderColor = UIColor.white.cgColor
    addSubview(frontContainer)

    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(routeChanged),
                   name: AVAudioSession.routeChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                   name: .AVCaptureSessionRuntimeError, object: session)
    nc.addObserver(self, selector: #selector(sessionInterrupted),
                   name: .AVCaptureSessionWasInterrupted, object: session)
    // Yatay sol <-> yatay sağ dönüşünde boyut değişmez, layoutSubviews çağrılmaz.
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    nc.addObserver(self, selector: #selector(deviceRotated),
                   name: UIDevice.orientationDidChangeNotification, object: nil)
  }

  @objc private func deviceRotated() {
    // Arayüz dönüşü bildirimden biraz sonra tamamlanır.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.setNeedsLayout()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Yerleşim

  override func layoutSubviews() {
    super.layoutSubviews()
    updateOrientation()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backPreview.frame = bounds
    backPreview.isHidden = !mode.usesBack
    frontContainer.isHidden = !mode.usesFront

    // Kaydedilen karenin (16:9 ya da 9:16) ekrandaki yeri.
    let aspect = isLandscape ? CGSize(width: 16, height: 9) : CGSize(width: 9, height: 16)
    let vr = AVMakeRect(aspectRatio: aspect, insideRect: bounds)
    if mode == .front {
      // Sadece yüz: ön kamera tüm kareyi kaplar.
      frontContainer.frame = vr
      frontContainer.layer.cornerRadius = 0
      frontContainer.layer.borderWidth = 0
    } else {
      let pip = Pip.rect(in: vr.size).offsetBy(dx: vr.minX, dy: vr.minY)
      frontContainer.frame = pip
      frontContainer.layer.cornerRadius = max(pip.width, pip.height) * Pip.cornerRatio
      frontContainer.layer.borderWidth = max(1, min(vr.width, vr.height) * Pip.borderRatio)
    }
    frontPreview.frame = frontContainer.bounds
    CATransaction.commit()
  }

  /// JS'ten gelen kamera seçimi: "both", "back" ya da "front". Kayıt sırasında değişmez.
  func setCameras(_ value: String) {
    guard !isRecording, let newMode = CameraMode(rawValue: value), newMode != mode else { return }
    mode = newMode
    setNeedsLayout()
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.activeMode = newMode
      self.applyCameraMode()
    }
  }

  /// sessionQueue üzerinde çağrılır. Kullanılmayan kameranın kare akışını kapatır (ısınma/pil).
  private func applyCameraMode() {
    backConnections.forEach { $0.isEnabled = activeMode.usesBack }
    frontConnections.forEach { $0.isEnabled = activeMode.usesFront }
  }

  /// Kamera yönünü arayüz yönüne eşitler. Kayıt sırasında değiştirmez (JS tarafı ekranı zaten kilitler).
  private func updateOrientation() {
    guard !isRecording, let scene = window?.windowScene else { return }
    let orientation: AVCaptureVideoOrientation
    switch scene.interfaceOrientation {
    case .landscapeLeft: orientation = .landscapeLeft
    case .landscapeRight: orientation = .landscapeRight
    case .portraitUpsideDown: orientation = .portraitUpsideDown
    default: orientation = .portrait
    }
    isLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
    sessionQueue.async { [weak self] in
      guard let self, self.captureOrientation != orientation else { return }
      self.captureOrientation = orientation
      self.applyOrientation()
    }
  }

  /// sessionQueue üzerinde çağrılır.
  private func applyOrientation() {
    // Yalnızca yüz önizlemesi ayna gibidir; kaydedilen yüz videosu düzdür.
    for conn in videoConnections {
      conn.videoOrientation = captureOrientation
      if conn.isVideoMirroringSupported {
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = mirroredConnections.contains(conn)
      }
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      UIApplication.shared.isIdleTimerDisabled = true
      sessionQueue.async { [weak self] in self?.startSession() }
    } else {
      UIApplication.shared.isIdleTimerDisabled = false
      finishRecording(auto: true)
      sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }
  }

  // MARK: - Oturum kurulumu

  private func startSession() {
    if !isConfigured {
      do {
        try configureSession()
        isConfigured = true
      } catch {
        emitError(error.localizedDescription)
        return
      }
    }
    if !session.isRunning {
      session.startRunning()
    }
    DispatchQueue.main.async { [weak self] in
      self?.onReady([:])
      self?.emitMic()
    }
  }

  private func configureSession() throws {
    guard AVCaptureMultiCamSession.isMultiCamSupported else { throw DualCameraError.notSupported }

    // Yaka mikrofonu takılıysa onu seçebilmek için ses oturumunu biz yönetiyoruz.
    session.automaticallyConfiguresApplicationAudioSession = false
    configureAudioSession()

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    guard
      let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    else { throw DualCameraError.noCamera }

    try addCamera(back, output: backOutput, preview: backPreview, mirrored: false)
    try addCamera(front, output: frontOutput, preview: frontPreview, mirrored: true)
    // İki kamera da 1080p; donanım kaldırmazsa önce yüz kamerasını 720p'ye düşür.
    try selectFormat(back, maxWidth: 1920)
    try selectFormat(front, maxWidth: 1920)
    if session.hardwareCost > 1.0 {
      try selectFormat(front, maxWidth: 1280)
    }
    if session.hardwareCost > 1.0 {
      try selectFormat(back, maxWidth: 1280)
    }
    try addMicrophone()
    applyCameraMode()
  }

  private func addCamera(
    _ device: AVCaptureDevice, output: AVCaptureVideoDataOutput,
    preview: AVCaptureVideoPreviewLayer, mirrored: Bool
  ) throws {
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw DualCameraError.noCamera }
    session.addInputWithNoConnections(input)

    guard let port = input.ports(
      for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position
    ).first else { throw DualCameraError.noCamera }

    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: dataQueue)
    guard session.canAddOutput(output) else { throw DualCameraError.noCamera }
    session.addOutputWithNoConnections(output)

    let outConn = AVCaptureConnection(inputPorts: [port], output: output)
    guard session.canAddConnection(outConn) else { throw DualCameraError.noCamera }
    session.addConnection(outConn)

    preview.setSessionWithNoConnection(session)
    let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
    guard session.canAddConnection(previewConn) else { throw DualCameraError.noCamera }
    session.addConnection(previewConn)

    videoConnections += [outConn, previewConn]
    if mirrored {
      mirroredConnections.append(previewConn)
      frontConnections += [outConn, previewConn]
    } else {
      backConnections += [outConn, previewConn]
    }
    applyOrientation()
  }

  /// Çoklu kamera destekli, 16:9, en fazla `maxWidth` genişlikte ve 30 fps yapabilen en büyük format.
  private func selectFormat(_ device: AVCaptureDevice, maxWidth: Int32) throws {
    let candidates = device.formats.filter { f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return f.isMultiCamSupported
        && d.width <= maxWidth
        && Int(d.width) * 9 == Int(d.height) * 16
        && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
    }
    guard let best = candidates.max(by: { a, b in
      let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
      let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
      return da.width < db.width
    }) else { return }

    try device.lockForConfiguration()
    device.activeFormat = best
    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    device.unlockForConfiguration()
  }

  private func addMicrophone() throws {
    guard let mic = AVCaptureDevice.default(for: .audio) else { return }
    let input = try AVCaptureDeviceInput(device: mic)
    guard session.canAddInput(input) else { return }
    session.addInputWithNoConnections(input)

    guard let port = input.ports.first(where: { $0.mediaType == .audio }) else { return }
    audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
    guard session.canAddOutput(audioOutput) else { return }
    session.addOutputWithNoConnections(audioOutput)

    let conn = AVCaptureConnection(inputPorts: [port], output: audioOutput)
    if session.canAddConnection(conn) {
      session.addConnection(conn)
    }
  }

  // MARK: - Mikrofon seçimi

  private func configureAudioSession() {
    let audio = AVAudioSession.sharedInstance()
    do {
      try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
      try audio.setActive(true)
    } catch {
      emitError("Ses oturumu açılamadı: \(error.localizedDescription)")
    }
    preferExternalMic()
  }

  /// Kablolu / Lightning / USB mikrofon varsa onu tercih et.
  private func preferExternalMic() {
    let audio = AVAudioSession.sharedInstance()
    let external: [AVAudioSession.Port] = [.headsetMic, .usbAudio, .lineIn]
    let preferred = audio.availableInputs?.first { external.contains($0.portType) }
      ?? audio.availableInputs?.first { $0.portType == .builtInMic }
    try? audio.setPreferredInput(preferred)
  }

  @objc private func routeChanged() {
    preferExternalMic()
    DispatchQueue.main.async { [weak self] in self?.emitMic() }
  }

  private func emitMic() {
    let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
    onMicChange([
      "name": input?.portName ?? "Mikrofon yok",
      "external": input.map { $0.portType != .builtInMic } ?? false,
    ])
  }

  // MARK: - Hatalar / kesintiler

  private func emitError(_ message: String) {
    DispatchQueue.main.async { [weak self] in self?.onCameraError(["message": message]) }
  }

  @objc private func sessionRuntimeError(_ note: Notification) {
    let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
    emitError("Kamera hatası: \(error?.localizedDescription ?? "bilinmiyor")")
    finishRecording(auto: true)
    sessionQueue.async { [weak self] in
      guard let self, self.isConfigured else { return }
      self.session.startRunning()
    }
  }

  @objc private func sessionInterrupted() {
    // Arama geldi, uygulama arka plana geçti vs. Kaydı kapatıp galeriye kaydet.
    finishRecording(auto: true)
  }

  // MARK: - Kayıt

  func startRecording() {
    isRecording = true
    let mode = self.mode
    dataQueue.async { [weak self] in
      guard let self, self.recorder == nil else { return }
      self.recorder = Recorder(mode: mode)
    }
  }

  func stopRecording(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    isRecording = false
    dataQueue.async { [weak self] in
      guard let self, let recorder = self.recorder else {
        DispatchQueue.main.async { completion(.failure(DualCameraError.notRecording)) }
        return
      }
      self.recorder = nil
      self.finish(recorder) { result in
        DispatchQueue.main.async { completion(result) }
      }
    }
  }

  private func finishRecording(auto: Bool) {
    DispatchQueue.main.async { [weak self] in self?.isRecording = false }
    dataQueue.async { [weak self] in
      guard let self, let recorder = self.recorder else { return }
      self.recorder = nil
      self.finish(recorder) { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success(var info):
            info["saved"] = true
            self?.onAutoStopped(info)
          case .failure(let error):
            self?.onAutoStopped(["saved": false, "error": error.localizedDescription])
          }
        }
      }
    }
  }

  /// dataQueue üzerinde çağrılır. Dosyaları kapatır ve galeriye kaydeder (önce sahne, sonra yüz).
  private func finish(_ recorder: Recorder, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    var duration = 0.0
    if let start = recorder.startTime, let end = recorder.leader?.lastVideoTime {
      duration = CMTimeGetSeconds(CMTimeSubtract(end, start))
    }

    let tracks = recorder.tracks
    var urls = [URL?](repeating: nil, count: tracks.count)
    var firstError: Error?
    let group = DispatchGroup()
    for (i, track) in tracks.enumerated() {
      group.enter()
      track.finish { [dataQueue = self.dataQueue] result in
        dataQueue.async {
          switch result {
          case .success(let url): urls[i] = url
          case .failure(let error): firstError = firstError ?? error
          }
          group.leave()
        }
      }
    }

    group.notify(queue: dataQueue) {
      let saved = urls.compactMap { $0 }
      guard !saved.isEmpty else {
        completion(.failure(firstError ?? DualCameraError.tooShort))
        return
      }
      Self.saveToPhotos(saved) { error in
        saved.forEach { try? FileManager.default.removeItem(at: $0) }
        if let error {
          completion(.failure(error))
        } else {
          completion(.success(["duration": duration, "files": saved.count]))
        }
      }
    }
  }

  private static func saveToPhotos(_ urls: [URL], completion: @escaping (Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(DualCameraError.photosDenied)
        return
      }
      PHPhotoLibrary.shared().performChanges({
        for url in urls {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
      }) { ok, error in
        completion(ok ? nil : DualCameraError.saveFailed(error?.localizedDescription ?? "bilinmiyor"))
      }
    }
  }

  // MARK: - Kareler (dataQueue)

  private var audioSettings: [String: Any]? {
    audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let recorder else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    if output === audioOutput {
      guard let start = recorder.startTime, CMTimeCompare(time, start) >= 0 else { return }
      recorder.tracks.forEach { $0.appendAudio(sampleBuffer) }
      return
    }

    let target = output === backOutput ? recorder.back : output === frontOutput ? recorder.front : nil
    guard let track = target else { return }

    if let start = recorder.startTime {
      // Diğer kamera da aynı andan başlar; kurguda senkron olur.
      guard CMTimeCompare(time, start) >= 0 else { return }
      if track.writer == nil {
        guard !track.failed else { return }
        do {
          try track.start(firstFrame: sampleBuffer, at: start, audioSettings: audioSettings)
        } catch {
          track.failed = true
          emitError("Kamera kaydedilemiyor: \(error.localizedDescription)")
          return
        }
      }
    } else {
      // Başlangıç anını öncü kameranın (sahne, yoksa yüz) ilk karesi belirler.
      guard track === recorder.leader else { return }
      do {
        try track.start(firstFrame: sampleBuffer, at: time, audioSettings: audioSettings)
        recorder.startTime = time
      } catch {
        track.discard()
        self.recorder = nil
        DispatchQueue.main.async { [weak self] in self?.isRecording = false }
        emitError(error.localizedDescription)
        return
      }
    }
    track.appendVideo(sampleBuffer)
  }
}
