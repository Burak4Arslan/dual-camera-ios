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

/// Mesajlar JS tarafında kullanıcının dilinde gösterilir (src/i18n); buradan yalnızca `code`
/// ve varsa sistemin verdiği ayrıntı gider.
enum DualCameraError: LocalizedError {
  case notSupported
  case noCamera
  case notRecording
  case tooShort
  case writerFailed(String)
  case photosDenied
  case saveFailed(String)
  case photoFailed
  case torchUnavailable
  case torchFailed(String)
  case audioSession(String)
  case runtime(String)
  case recordFailed(String)

  var code: String {
    switch self {
    case .notSupported: return "notSupported"
    case .noCamera: return "noCamera"
    case .notRecording: return "notRecording"
    case .tooShort: return "tooShort"
    case .writerFailed: return "writerFailed"
    case .photosDenied: return "photosDenied"
    case .saveFailed: return "saveFailed"
    case .photoFailed: return "photoFailed"
    case .torchUnavailable: return "torchUnavailable"
    case .torchFailed: return "torchFailed"
    case .audioSession: return "audioSession"
    case .runtime: return "runtime"
    case .recordFailed: return "recordFailed"
    }
  }

  var detail: String? {
    switch self {
    case .writerFailed(let d), .saveFailed(let d), .torchFailed(let d), .audioSession(let d),
      .runtime(let d), .recordFailed(let d):
      return d.isEmpty ? nil : d
    default:
      return nil
    }
  }

  var errorDescription: String? { [code, detail].compactMap { $0 }.joined(separator: ": ") }
}

extension Error {
  /// JS'e giden hata: çeviri için `code`, varsa `detail`.
  var jsPayload: [String: Any] {
    guard let error = self as? DualCameraError else {
      return ["code": "unknown", "detail": localizedDescription]
    }
    return error.detail.map { ["code": error.code, "detail": $0] } ?? ["code": error.code]
  }
}

/// Tek bir kameranın video dosyası (görüntü + varsa mikrofon sesi).
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

    // Mikrofon izni yoksa ses ayarı da yoktur; video sessiz kaydedilir.
    if let audioSettings {
      let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audioInput.expectsMediaDataInRealTime = true
      if writer.canAdd(audioInput) {
        writer.add(audioInput)
        self.audioInput = audioInput
      }
    }

    guard writer.startWriting() else {
      throw DualCameraError.writerFailed(writer.error?.localizedDescription ?? "")
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
        completion(.failure(DualCameraError.writerFailed(writer.error?.localizedDescription ?? "")))
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

/// Çekim türü: video (16:9) ya da foto (4:3, yüksek çözünürlük).
enum CaptureKind: String {
  case video, photo
}

/// Bir kameranın oturumdaki bağlantıları.
private struct CameraLinks {
  let device: AVCaptureDevice
  let video: AVCaptureConnection // kayıt kareleri
  let photo: AVCaptureConnection
  let preview: AVCaptureConnection
}

/// Bir deklanşör basışı: seçili her kameradan bir foto. Sıra `outputs` sırasıdır (önce sahne, sonra yüz).
private final class PhotoShot: NSObject, AVCapturePhotoCaptureDelegate {
  private let outputs: [AVCapturePhotoOutput]
  private let queue: DispatchQueue
  private let completion: (PhotoShot, [Data], Error?) -> Void

  // Yalnızca `queue` üzerinde kullanılır.
  private var photos: [Data?]
  private var remaining: Int
  private var firstError: Error?

  init(
    outputs: [AVCapturePhotoOutput], queue: DispatchQueue,
    completion: @escaping (PhotoShot, [Data], Error?) -> Void
  ) {
    self.outputs = outputs
    self.queue = queue
    self.completion = completion
    photos = Array(repeating: nil, count: outputs.count)
    remaining = outputs.count
    super.init()
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    let data = error == nil ? photo.fileDataRepresentation() : nil
    queue.async { [self] in
      if let data, let i = outputs.firstIndex(where: { $0 === output }) {
        photos[i] = data
      } else {
        firstError = firstError ?? error ?? DualCameraError.photoFailed
      }
    }
  }

  /// Her çekim isteği için en son bu çağrılır (hata olsa da).
  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
    error: Error?
  ) {
    queue.async { [self] in
      if let error { firstError = firstError ?? error }
      remaining -= 1
      if remaining == 0 {
        completion(self, photos.compactMap { $0 }, firstError)
      }
    }
  }
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
  private let backPhotoOutput = AVCapturePhotoOutput()
  private let frontPhotoOutput = AVCapturePhotoOutput()
  private let audioOutput = AVCaptureAudioDataOutput()

  // sessionQueue üzerinde kullanılır.
  private var isConfigured = false
  private var captureOrientation: AVCaptureVideoOrientation = .portrait
  private var back: CameraLinks?
  private var front: CameraLinks?
  private var audioConnection: AVCaptureConnection?
  private var activeMode: CameraMode = .both
  private var activeKind: CaptureKind = .video
  private var torchWanted = false
  private var shots = Set<PhotoShot>() // çekimi süren fotolar (çıkış yalnızca zayıf tutar)

  // Ana thread üzerinde kullanılır.
  private var isRecording = false
  private var isLandscape = false
  private var mode: CameraMode = .both
  private var kind: CaptureKind = .video
  /// Kameranın verdiği karenin yataydaki en/boy oranı: videoda 16:9, fotoda 4:3.
  private var frameRatio: CGFloat = 16 / 9
  private var geometryObservation: NSKeyValueObservation?

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
    nc.addObserver(self, selector: #selector(sessionInterruptionEnded),
                   name: .AVCaptureSessionInterruptionEnded, object: session)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Yerleşim

  override func layoutSubviews() {
    super.layoutSubviews()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updateOrientation()
    backPreview.frame = bounds
    backPreview.isHidden = !mode.usesBack
    frontContainer.isHidden = !mode.usesFront

    // Kaydedilen karenin (video 16:9, foto 4:3; dikeyde tersi) ekrandaki yeri.
    let aspect = isLandscape ? CGSize(width: frameRatio, height: 1) : CGSize(width: 1, height: frameRatio)
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
    // Çerçeve aynı kalsa bile önizleme, görüntüyü yeni yöne göre yeniden yerleştirsin.
    backPreview.setNeedsLayout()
    frontPreview.setNeedsLayout()
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
      self.applyTorch()
    }
  }

  /// JS'ten gelen çekim türü: "video" ya da "photo". Kayıt sırasında değişmez.
  func setCaptureMode(_ value: String) {
    guard !isRecording, let newKind = CaptureKind(rawValue: value), newKind != kind else { return }
    kind = newKind
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.activeKind = newKind
      guard self.isConfigured else { return }
      self.session.beginConfiguration()
      do {
        try self.applyFormats()
      } catch {
        self.emitError(error)
      }
      self.applyCameraMode()
      self.session.commitConfiguration()
      // Format değişince ışık sönebiliyor.
      self.applyTorch()
    }
  }

  /// JS'ten gelen ışık (arka kamera feneri) isteği. Kayıt sırasında da değişebilir.
  func setTorch(_ on: Bool) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.torchWanted = on
      self.applyTorch()
    }
  }

  /// sessionQueue üzerinde çağrılır. Işık yalnızca arka kamerada var; arka kamera kapalıyken söner.
  private func applyTorch() {
    guard let device = back?.device, device.hasTorch, session.isRunning else { return }
    let on = torchWanted && activeMode.usesBack
    if on && !device.isTorchAvailable {
      emitError(DualCameraError.torchUnavailable)
      return
    }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if on {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }
    } catch {
      emitError(DualCameraError.torchFailed(error.localizedDescription))
    }
  }

  /// sessionQueue üzerinde çağrılır. Kullanılmayan kameranın ve o çekim türünde gerekmeyen çıkışların
  /// akışını kapatır (ısınma/pil). Fotoda mikrofon da kapanır.
  private func applyCameraMode() {
    for (links, used) in [(back, activeMode.usesBack), (front, activeMode.usesFront)] {
      guard let links else { continue }
      links.preview.isEnabled = used
      links.video.isEnabled = used && activeKind == .video
      links.photo.isEnabled = used && activeKind == .photo
    }
    audioConnection?.isEnabled = activeKind == .video
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
    // Önizleme yönü ana thread'de, çerçeveyle aynı anda değişmeli. Arka planda değişince
    // görüntü eski (dikey) yerleşimde kalıp köşede küçücük görünüyordu.
    for preview in [backPreview, frontPreview] {
      if let conn = preview.connection, conn.videoOrientation != orientation {
        conn.videoOrientation = orientation
      }
    }
    sessionQueue.async { [weak self] in
      guard let self, self.captureOrientation != orientation else { return }
      self.captureOrientation = orientation
      self.applyOrientation()
    }
  }

  /// sessionQueue üzerinde çağrılır. Kaydedilen video ve fotoların yönü.
  private func applyOrientation() {
    for links in [back, front].compactMap({ $0 }) {
      links.video.videoOrientation = captureOrientation
      links.photo.videoOrientation = captureOrientation
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Arayüz her döndüğünde yeniden yerleş. Yatay sol <-> sağ dönüşünde boyut değişmediği için
    // layoutSubviews kendiliğinden çağrılmaz; sahnenin geometrisi ise her dönüşte değişir.
    geometryObservation = window?.windowScene?.observe(\.effectiveGeometry) { [weak self] _, _ in
      DispatchQueue.main.async { self?.setNeedsLayout() }
    }
    if window != nil {
      // Pencereye girmeden yapılan yerleşim yönü bilemez (varsayılan dikey); şimdi doğrusunu yap.
      setNeedsLayout()
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
        emitError(error)
        return
      }
    }
    if !session.isRunning {
      session.startRunning()
    }
    // Oturum durunca ışık da söner; yeniden açılınca geri yak.
    applyTorch()
    DispatchQueue.main.async { [weak self] in
      // Önizleme bağlantıları artık var; yönlerini ana thread'de ayarla.
      self?.setNeedsLayout()
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
      let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    else { throw DualCameraError.noCamera }

    back = try addCamera(
      backCamera, output: backOutput, photoOutput: backPhotoOutput, preview: backPreview, mirrored: false)
    front = try addCamera(
      frontCamera, output: frontOutput, photoOutput: frontPhotoOutput, preview: frontPreview, mirrored: true)
    applyOrientation()
    try applyFormats()
    // Mikrofon izni yoksa kamera yine açılır, video sessiz kaydedilir.
    try? addMicrophone()
    applyCameraMode()
  }

  /// sessionQueue üzerinde, oturum yapılandırılırken çağrılır. Video: 16:9 1080p; foto: 4:3, en yüksek
  /// foto çözünürlüğü. Donanım iki kamerayı kaldırmazsa önce yüz kamerasını küçültür.
  private func applyFormats() throws {
    guard let back, let front else { return }
    let photo = activeKind == .photo
    try selectFormat(back.device, photo: photo, maxWidth: 1920)
    try selectFormat(front.device, photo: photo, maxWidth: 1920)
    if session.hardwareCost > 1.0 {
      try selectFormat(front.device, photo: photo, maxWidth: 1280)
    }
    if session.hardwareCost > 1.0 {
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
    DispatchQueue.main.async { [weak self] in
      self?.frameRatio = ratio
      self?.setNeedsLayout()
    }
  }

  private func addCamera(
    _ device: AVCaptureDevice, output: AVCaptureVideoDataOutput, photoOutput: AVCapturePhotoOutput,
    preview: AVCaptureVideoPreviewLayer, mirrored: Bool
  ) throws -> CameraLinks {
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

    guard session.canAddOutput(photoOutput) else { throw DualCameraError.noCamera }
    session.addOutputWithNoConnections(photoOutput)
    let photoConn = AVCaptureConnection(inputPorts: [port], output: photoOutput)
    guard session.canAddConnection(photoConn) else { throw DualCameraError.noCamera }
    session.addConnection(photoConn)

    preview.setSessionWithNoConnection(session)
    let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
    guard session.canAddConnection(previewConn) else { throw DualCameraError.noCamera }
    session.addConnection(previewConn)

    // Yalnızca yüz önizlemesi ayna gibidir; kaydedilen yüz videosu ve fotosu düzdür.
    for conn in [outConn, photoConn, previewConn] where conn.isVideoMirroringSupported {
      conn.automaticallyAdjustsVideoMirroring = false
      conn.isVideoMirrored = mirrored && conn === previewConn
    }

    return CameraLinks(device: device, video: outConn, photo: photoConn, preview: previewConn)
  }

  /// Çoklu kamera destekli, 30 fps yapabilen, en fazla `maxWidth` genişlikte format.
  /// Video: 16:9, en genişi. Foto: 4:3, en büyük foto çekebileni.
  private func selectFormat(_ device: AVCaptureDevice, photo: Bool, maxWidth: Int32) throws {
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
      audioConnection = conn
    }
  }

  // MARK: - Mikrofon seçimi

  private func configureAudioSession() {
    let audio = AVAudioSession.sharedInstance()
    do {
      try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
      try audio.setActive(true)
    } catch {
      emitError(DualCameraError.audioSession(error.localizedDescription))
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

  private func emitError(_ error: Error) {
    let payload = error.jsPayload
    DispatchQueue.main.async { [weak self] in self?.onCameraError(payload) }
  }

  @objc private func sessionRuntimeError(_ note: Notification) {
    let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
    emitError(DualCameraError.runtime(error?.localizedDescription ?? ""))
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

  @objc private func sessionInterruptionEnded() {
    sessionQueue.async { [weak self] in self?.applyTorch() }
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
            var payload = error.jsPayload
            payload["saved"] = false
            self?.onAutoStopped(payload)
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
      Self.saveToPhotos({
        for url in saved {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
      }) { error in
        saved.forEach { try? FileManager.default.removeItem(at: $0) }
        if let error {
          completion(.failure(error))
        } else {
          completion(.success(["duration": duration, "files": saved.count]))
        }
      }
    }
  }

  private static func saveToPhotos(_ changes: @escaping () -> Void, completion: @escaping (Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(DualCameraError.photosDenied)
        return
      }
      PHPhotoLibrary.shared().performChanges(changes) { ok, error in
        completion(ok ? nil : DualCameraError.saveFailed(error?.localizedDescription ?? ""))
      }
    }
  }

  // MARK: - Foto

  /// Seçili kameralarla birer foto çeker ve ayrı ayrı galeriye kaydeder (önce sahne, sonra yüz).
  func takePhoto(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let outputs = [
        self.activeMode.usesBack ? self.backPhotoOutput : nil,
        self.activeMode.usesFront ? self.frontPhotoOutput : nil,
      ].compactMap { $0 }
      guard self.session.isRunning, self.activeKind == .photo, !outputs.isEmpty else {
        DispatchQueue.main.async { completion(.failure(DualCameraError.photoFailed)) }
        return
      }
      let shot = PhotoShot(outputs: outputs, queue: self.sessionQueue) { [weak self] shot, photos, error in
        self?.shots.remove(shot)
        guard !photos.isEmpty else {
          DispatchQueue.main.async { completion(.failure(error ?? DualCameraError.photoFailed)) }
          return
        }
        Self.saveToPhotos({
          for data in photos {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
          }
        }) { error in
          DispatchQueue.main.async {
            if let error {
              completion(.failure(error))
            } else {
              completion(.success(["files": photos.count]))
            }
          }
        }
      }
      self.shots.insert(shot)
      for output in outputs {
        output.capturePhoto(with: Self.photoSettings(for: output), delegate: shot)
      }
    }
  }

  private static func photoSettings(for output: AVCapturePhotoOutput) -> AVCapturePhotoSettings {
    let settings = output.availablePhotoCodecTypes.contains(.hevc)
      ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
      : AVCapturePhotoSettings()
    settings.maxPhotoDimensions = output.maxPhotoDimensions
    return settings
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
          emitError(DualCameraError.recordFailed(error.localizedDescription))
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
        emitError(error)
        return
      }
    }
    track.appendVideo(sampleBuffer)
  }
}
