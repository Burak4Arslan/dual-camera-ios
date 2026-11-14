import AVFoundation
import AVKit
import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import ExpoModulesCore
import Photos
import UIKit
import Vision

// Önizlemede arka kamera tam kare, ön kamera (yüz) sağ üst köşede küçük pencere.
// Kayıtta iki kamera iki ayrı video dosyası olur (kurguda yerleştirmek için); ayarlarda
// "tek dosya" seçiliyse yüz, önizlemedeki gibi sahnenin köşesine yerleştirilip tek dosya yazılır
// (video da foto da).
private enum Pip {
  static let longSideRatio: CGFloat = 0.28 // karenin uzun kenarına oranla
  static let marginRatio: CGFloat = 0.045  // karenin kısa kenarına oranla
  static let cornerRatio: CGFloat = 0.06   // pencerenin uzun kenarına oranla
  static let borderRatio: CGFloat = 0.004  // karenin kısa kenarına oranla
  /// "Sahneye yerleştir"de kesilmiş kişi pencereden bu kadar büyük (çerçevesi yok, etrafı saydam).
  static let cutoutScale: CGFloat = 1.6

  /// Kare içinde pencerenin yeri; y yukarıdan aşağı ölçülür (UIKit düzeni). `center` pencere
  /// merkezinin kareye oranı (0–1, kullanıcı sürükleyerek seçer); nil ise sağ üst köşe.
  /// Pencere her zaman kenar boşluğu bırakarak karenin içinde kalır.
  static func rect(in frame: CGSize, center: CGPoint?, scale: CGFloat = 1) -> CGRect {
    let long = max(frame.width, frame.height) * longSideRatio * scale
    let size = frame.width >= frame.height
      ? CGSize(width: long, height: long * 9 / 16)
      : CGSize(width: long * 9 / 16, height: long)
    let margin = min(frame.width, frame.height) * marginRatio
    guard let center else {
      return CGRect(x: frame.width - margin - size.width, y: margin, width: size.width, height: size.height)
    }
    let x = min(max(center.x * frame.width - size.width / 2, margin), frame.width - margin - size.width)
    let y = min(max(center.y * frame.height - size.height / 2, margin), frame.height - margin - size.height)
    return CGRect(x: x, y: y, width: size.width, height: size.height)
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
  /// Galeriye aktarılamadı ama dosya duruyor; uygulama tekrar açılınca yeniden denenir.
  case savePending(String)

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
    case .savePending: return "savePending"
    }
  }

  var detail: String? {
    switch self {
    case .writerFailed(let d), .saveFailed(let d), .torchFailed(let d), .audioSession(let d),
      .runtime(let d), .recordFailed(let d), .savePending(let d):
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
  /// Kareler `PipCompositor` ile birleştirilip piksel tamponu olarak yazılır (tek video).
  let composited: Bool
  private(set) var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var audioInput: AVAssetWriterInput?
  private(set) var lastVideoTime: CMTime?
  /// Yazıcı hata verdi ama o ana kadarki kısım kurtarıldı.
  private(set) var salvaged = false

  init(name: String, composited: Bool = false) {
    url = PendingRecordings.newURL(name: name)
    self.composited = composited
  }

  var isWriting: Bool { writer?.status == .writing }

  /// İlk karenin boyutuyla yazıcıyı kurar ve oturumu `start` anından başlatır.
  func start(firstFrame: CMSampleBuffer, at start: CMTime, audioSettings: [String: Any]?) throws {
    guard let image = CMSampleBufferGetImageBuffer(firstFrame) else { throw DualCameraError.tooShort }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    // Video her 2 sn'de bir diske kesinleşir: uygulama çökse ya da yazıcı hata verse bile o ana
    // kadarki kısım oynatılabilir kalır (bir sonraki açılışta galeriye kurtarılır).
    writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    // Çekim tarihi, cihaz ve (izin varsa) konum: Fotoğraflar'daki tarih ve harita bunlardan.
    writer.metadata = CaptureMetadata.videoItems(date: Date(), location: LocationTracker.shared.current)
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 16_000_000,
        AVVideoExpectedSourceFrameRateKey: 30,
      ],
    ])
    videoInput.expectsMediaDataInRealTime = true
    writer.add(videoInput)
    if composited {
      adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ])
    }

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

  /// Tek video: sahne karesiyle yüzün son karesi, önizlemedeki düzenle birleştirilip yazılır.
  func appendVideo(
    _ sampleBuffer: CMSampleBuffer, face: CVPixelBuffer?, mask: CVPixelBuffer?, layout: CompositeLayout,
    compositor: PipCompositor
  ) {
    appendRendered(sampleBuffer) { scene, output in
      compositor.render(scene: scene, face: face, mask: mask, layout: layout, into: output)
    }
  }

  /// Tek kamera: o an açık kameranın karesi (kayıtta kamera çevrilebilir) dosyanın boyutuna oturtulur.
  func appendVideo(_ sampleBuffer: CMSampleBuffer, compositor: PipCompositor) {
    appendRendered(sampleBuffer) { frame, output in
      compositor.render(single: frame, into: output)
    }
  }

  /// `render` kaynak kareyi yazıcının havuzundan alınan çıkış tamponuna çizer.
  private func appendRendered(_ sampleBuffer: CMSampleBuffer, render: (CVPixelBuffer, CVPixelBuffer) -> Void) {
    guard isWriting, let input = videoInput, input.isReadyForMoreMediaData,
      let adaptor, let pool = adaptor.pixelBufferPool,
      let source = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    // Kamera çevrilirken iki kameranın kareleri karışabilir; zaman geri gidemez.
    if let last = lastVideoTime, CMTimeCompare(time, last) <= 0 { return }
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return }
    render(source, output)
    if adaptor.append(output, withPresentationTime: time) {
      lastVideoTime = time
    }
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard isWriting, let input = audioInput, input.isReadyForMoreMediaData else { return }
    input.append(sampleBuffer)
  }

  /// Yazıcı kurulamadıysa tekrar denenmesin diye işaretlenir.
  var failed = false

  /// Dosyayı kapatır ve URL'sini döner. Yazıcı hata verdiyse dosya silinmez: o ana kadar
  /// diske kesinleşen kısım kurtarılır (`salvaged`). Hiç kare yazılamadıysa hata döner.
  func finish(completion: @escaping (Result<URL, Error>) -> Void) {
    guard let writer, lastVideoTime != nil else {
      discard()
      completion(.failure(DualCameraError.tooShort))
      return
    }
    guard writer.status == .writing else {
      salvage(writer.error, completion: completion)
      return
    }
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    writer.finishWriting { [self] in
      if writer.status == .completed {
        completion(.success(url))
      } else {
        salvage(writer.error, completion: completion)
      }
    }
  }

  private func salvage(_ error: Error?, completion: @escaping (Result<URL, Error>) -> Void) {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > 0 {
      salvaged = true
      completion(.success(url))
    } else {
      discard()
      completion(.failure(DualCameraError.writerFailed(error?.localizedDescription ?? "")))
    }
  }

  /// Yalnızca içinde hiç kare olmayan dosya için.
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

extension UIInterfaceOrientation {
  /// JS tarafındaki ad (InterfaceOrientation).
  var jsName: String {
    switch self {
    case .landscapeLeft: return "landscapeLeft"
    case .landscapeRight: return "landscapeRight"
    case .portraitUpsideDown: return "portraitUpsideDown"
    case .portrait: return "portrait"
    default: return "unknown"
    }
  }
}

/// Ön+Arka'da iki kameranın ekrandaki ve tek videodaki yerleşimi.
enum DualLayout: String {
  /// Biri tam kare, diğeri küçük pencerede.
  case pip
  /// Yatayda yan yana, dikeyde üst üste iki yarı.
  case split
  /// Sahneye yerleştir: arka kamera tam kare, ön kameradaki kişi arka planı silinmiş olarak üstünde
  /// (çerçevesiz). Yalnızca tek videoyla anlamlı.
  case cutout
}

/// Tek videonun düzeni: önizlemedekiyle aynı (dataQueue'ya kopyalanır).
private struct CompositeLayout: Equatable {
  var layout: DualLayout = .pip
  /// Yüz büyük (pencerede ya da ilk yarıda), sahne küçük.
  var swapped = false
  /// Pencerenin yeri (merkezinin kareye oranı); nil = sağ üst köşe.
  var pip: CGPoint?
}

/// Bir kameranın oturumdaki bağlantıları.
struct CameraLinks {
  let device: AVCaptureDevice
  let input: AVCaptureDeviceInput
  let video: AVCaptureConnection // kayıt kareleri
  let photo: AVCaptureConnection
  let preview: AVCaptureConnection
}

/// Bir deklanşör basışı: seçili her kameradan bir foto. Sıra `outputs` sırasıdır (önce sahne, sonra yüz).
private final class PhotoShot: NSObject, AVCapturePhotoCaptureDelegate {
  private let outputs: [AVCapturePhotoOutput]
  /// Deklanşöre basıldığı andaki konum; fotonun EXIF'ine GPS olarak yazılır.
  private let location: LocationStamp?
  private let queue: DispatchQueue
  private let completion: (PhotoShot, [Data], Error?) -> Void

  // Yalnızca `queue` üzerinde kullanılır.
  private var photos: [Data?]
  private var remaining: Int
  private var firstError: Error?

  init(
    outputs: [AVCapturePhotoOutput], queue: DispatchQueue, location: CLLocation?,
    completion: @escaping (PhotoShot, [Data], Error?) -> Void
  ) {
    self.outputs = outputs
    self.location = location.map(LocationStamp.init)
    self.queue = queue
    self.completion = completion
    photos = Array(repeating: nil, count: outputs.count)
    remaining = outputs.count
    super.init()
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    let data = error == nil
      ? location.map { photo.fileDataRepresentation(with: $0) } ?? photo.fileDataRepresentation()
      : nil
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

/// Fotoğrafın kendi bilgilerine (tarih, cihaz, lens, pozlama) konumu ekler.
private final class LocationStamp: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
  private let gps: [String: Any]

  init(_ location: CLLocation) {
    gps = CaptureMetadata.gps(location)
  }

  func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
    var metadata = photo.metadata
    metadata[kCGImagePropertyGPSDictionary as String] = gps
    return metadata
  }
}

/// Ön+Arka tek video: iki kamerayı önizlemedeki düzenle tek kareye yerleştirir. Pencere düzeninde
/// küçük kamera, önizlemedeki pencerenin yerine ve biçimiyle (yuvarlak köşe, beyaz çerçeve);
/// bölünmüş düzende iki yarı. Yalnızca dataQueue üzerinde kullanılır.
private final class PipCompositor {
  private let context = CIContext(options: [.cacheIntermediates: false])
  // Kare boyutu ve pencerenin yeri değişmedikçe aynı kalan parçalar.
  private var frameSize: CGSize = .zero
  private var framePip: CGPoint?
  private var inner: CGRect = .zero
  private var border = CIImage.empty()
  private var mask = CIImage.empty()

  /// Çıkış karesi sahne karesiyle aynı boyuttadır. Yüz karesi henüz gelmediyse yalnızca sahne.
  /// `mask`: "sahneye yerleştir"de `face` karesindeki kişinin maskesi (yoksa yalnızca sahne).
  func render(
    scene: CVPixelBuffer, face: CVPixelBuffer?, mask personMask: CVPixelBuffer?, layout: CompositeLayout,
    into output: CVPixelBuffer
  ) {
    let image = compose(
      scene: CIImage(cvPixelBuffer: scene), face: face.map { CIImage(cvPixelBuffer: $0) },
      mask: personMask.map { CIImage(cvPixelBuffer: $0) }, layout: layout)
    context.render(image, to: output)
  }

  /// Video karesi ya da tam çözünürlüklü foto için ortak çizim. Sahnenin kapladığı alan (0,0)'dan
  /// başlamalı; sonuç o alana kırpılır.
  func compose(scene sceneImage: CIImage, face faceImage: CIImage?, mask personMask: CIImage?, layout: CompositeLayout)
    -> CIImage
  {
    let frame = sceneImage.extent
    var image = sceneImage
    if let faceImage {
      let (big, small) = layout.swapped ? (faceImage, sceneImage) : (sceneImage, faceImage)
      switch layout.layout {
      case .cutout:
        // Sahne tam kare; kişi arka planı silinmiş, çerçevesiz, pencerenin yerinde ve daha büyük.
        if let personMask {
          let r = Pip.rect(in: frame.size, center: layout.pip, scale: Pip.cutoutScale)
          let rect = CGRect(x: r.minX, y: frame.height - r.maxY, width: r.width, height: r.height)
          image = Self.fill(Self.cutout(faceImage, mask: personMask), into: rect).composited(over: sceneImage)
        }
      case .split:
        // Yatayda yan yana, dikeyde üst üste (Core Image'da y yukarı: üst yarı maxY tarafı).
        let (first, second) = frame.width >= frame.height
          ? frame.divided(atDistance: frame.width / 2, from: .minXEdge)
          : frame.divided(atDistance: frame.height / 2, from: .maxYEdge)
        image = Self.fill(big, into: first).composited(over: Self.fill(small, into: second))
      case .pip:
        prepare(for: frame.size, pip: layout.pip)
        let rounded = Self.fill(small, into: inner).applyingFilter("CIBlendWithMask", parameters: [
          kCIInputBackgroundImageKey: CIImage.empty(),
          kCIInputMaskImageKey: mask,
        ])
        image = rounded.composited(over: border.composited(over: Self.fill(big, into: frame)))
      }
    }
    return image.cropped(to: frame)
  }

  /// Kişiyi arka planından ayırır: maske kareye ölçeklenir, kenarları hafifçe yumuşatılır; kişinin
  /// dışı saydam kalır.
  static func cutout(_ face: CIImage, mask maskImage: CIImage) -> CIImage {
    let scaled = maskImage
      .transformed(by: CGAffineTransform(
        scaleX: face.extent.width / maskImage.extent.width, y: face.extent.height / maskImage.extent.height))
      .clampedToExtent()
      .applyingGaussianBlur(sigma: 2)
      .cropped(to: face.extent)
    return face.applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: CIImage.empty(),
      kCIInputMaskImageKey: scaled,
    ])
  }

  /// Tek kamera kaydı: kare, çıkış karesini dolduracak şekilde (çevrilen kameranın boyutu farklı
  /// olabilir) yazılır.
  func render(single: CVPixelBuffer, into output: CVPixelBuffer) {
    let frame = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
    context.render(Self.fill(CIImage(cvPixelBuffer: single), into: frame), to: output)
  }

  /// Görüntüyü alanı dolduracak kadar büyütür, ortalar, taşanı kırpar.
  static func fill(_ image: CIImage, into rect: CGRect) -> CIImage {
    let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return scaled
      .transformed(by: CGAffineTransform(translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY))
      .cropped(to: rect)
  }

  private func prepare(for size: CGSize, pip: CGPoint?) {
    guard size != frameSize || pip != framePip else { return }
    frameSize = size
    framePip = pip
    // Pip.rect UIKit düzeninde (y aşağı); Core Image'da y yukarı.
    let r = Pip.rect(in: size, center: pip)
    let outer = CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    let radius = max(outer.width, outer.height) * Pip.cornerRatio
    let borderWidth = max(1, min(size.width, size.height) * Pip.borderRatio)
    inner = outer.insetBy(dx: borderWidth, dy: borderWidth)
    border = roundedRect(outer, radius: radius)
    mask = roundedRect(inner, radius: max(radius - borderWidth, 0))
  }

  private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
    let generator = CIFilter.roundedRectangleGenerator()
    generator.extent = rect
    generator.radius = Float(radius)
    generator.color = .white
    return generator.outputImage ?? .empty()
  }
}

/// Ön+Arka tek foto: iki kameranın tam çözünürlüklü fotoğrafını ekrandaki düzenle (tek videodaki
/// gibi) tek fotoğrafta birleştirir. Ana thread dışında çağrılır; kişi ayırma ~1 sn sürebilir.
private enum PhotoCombiner {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  /// Olmazsa (ör. sahneye yerleştirde kişi bulunamadı) nil: fotoğraflar ayrı kaydedilir, kaybolmaz.
  static func combine(scene: Data, face: Data, layout: CompositeLayout) -> Data? {
    // Fotoğraflar yön bilgisiyle (EXIF) gelir; çekim yönüne çevrilir, alan (0,0)'dan başlar.
    guard let sceneImage = upright(scene), let faceImage = upright(face) else { return nil }
    var mask: CIImage?
    if layout.layout == .cutout {
      guard let personMask = personMask(in: faceImage) else { return nil }
      mask = personMask
    }
    // Birleştirilen görüntüde bilgi kalmaz; sahne fotosunun tarihi, cihazı ve konumu taşınır.
    let composed = PipCompositor().compose(scene: sceneImage, face: faceImage, mask: mask, layout: layout)
    let image = composed.settingProperties(
      CaptureMetadata.combinedProperties(from: sceneImage.properties, size: composed.extent.size))
    let space = sceneImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
    let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
    return context.heifRepresentation(of: image, format: .RGBA8, colorSpace: space, options: quality)
      ?? context.jpegRepresentation(of: image, colorSpace: space, options: quality)
  }

  private static func upright(_ data: Data) -> CIImage? {
    guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
    return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
  }

  /// Fotoğraf için en doğru kişi maskesi (önizlemedeki hızlı ayırmadan daha keskin).
  private static func personMask(in face: CIImage) -> CIImage? {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    guard (try? VNImageRequestHandler(ciImage: face).perform([request])) != nil,
      let mask = request.results?.first?.pixelBuffer
    else { return nil }
    return CIImage(cvPixelBuffer: mask)
  }
}

/// Hışırtı azaltma (spektral çıkarma). Sesi ~21 ms'lik, yarı yarıya örtüşen parçalara bölüp her
/// frekansta sürekli olan gürültüyü (mikrofonun ya da kablosuz alıcının hışırtısı) ölçer ve çıkarır;
/// konuşma sürekli değiştiği için korunur. Sessizlikte de konuşurken de çalışır. 2 × `hop` örneklik
/// gecikme, zaman damgası öne alınarak telafi edilir (dudak senkronu bozulmaz). Kamera açıkken
/// sürekli çalışır; yalnızca dataQueue üzerinde.
private final class NoiseReducer {
  private static let log2n: vDSP_Length = 10
  private static let size = 1024
  private static let hop = 512
  /// Yumuşatılmış gücün en düşük değeri ortalama gürültünün altında kalır; bu kadar büyütülür.
  private static let bias: Float = 2
  /// Gürültünün kaç katı çıkarılsın. Hışırtının anlık gücü rastgele dalgalanır; 2 katta tepelerin
  /// ~%13ü geçip yalnızca ~9 dB azaltıyordu, 4 katta ~%2si geçer (~17 dB). Konuşma hışırtının
  /// ~30 dB üstünde olduğu için etkilenmez.
  private static let overSubtraction: Float = 4
  /// Bir frekansın en fazla kısılacağı oran (~-24 dB); daha fazlası sesi "su altı" gibi yapar.
  private static let floorGain: Float = 0.06

  private final class Channel {
    /// Henüz bir parçaya yetmeyen giriş.
    var pending: [Float] = []
    /// Son `size` örnek (işlenen parça).
    var history = [Float](repeating: 0, count: NoiseReducer.size)
    /// Örtüşen parçaların toplandığı yer.
    var overlap = [Float](repeating: 0, count: NoiseReducer.size)
    /// Çıkışa hazır örnekler; bir `hop` sıfırla başlar, böylece her girişe yetecek çıkış olur.
    var ready = [Float](repeating: 0, count: NoiseReducer.hop)
    /// Frekans başına güç, zaman içinde yumuşatılmış (~50 ms): hışırtının anlık dalgalanması
    /// gürültü tahminini aşağı çekmesin.
    var smooth = [Float](repeating: 0, count: NoiseReducer.size / 2 + 1)
    /// Frekans başına gürültü gücü: yumuşatılmış güç daha düşükse hemen iner, yoksa yavaşça yükselir.
    var noise = [Float](repeating: .greatestFiniteMagnitude, count: NoiseReducer.size / 2 + 1)
    var gains = [Float](repeating: 1, count: NoiseReducer.size / 2 + 1)
  }

  private let fft: FFTSetup
  /// Karekök Hann: analiz × sentez = Hann, yarı örtüşmede toplamı 1 (ses bozulmadan geri kurulur).
  private let window: [Float]
  private var channels: [Channel] = []
  private var sampleRate: Double = 0

  init?() {
    guard let fft = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else { return nil }
    self.fft = fft
    let n = Self.size
    window = (0..<n).map { (0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(n))).squareRoot() }
  }

  deinit {
    vDSP_destroy_fftsetup(fft)
  }

  /// 16 bit ya da 32 bit float, iç içe (interleaved) LPCM; başka biçimde aynısını döner.
  func process(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
    guard let format = CMSampleBufferGetFormatDescription(buffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      asbd.mFormatID == kAudioFormatLinearPCM,
      asbd.mSampleRate > 0,
      let source = CMSampleBufferGetDataBuffer(buffer)
    else { return buffer }
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let bits = asbd.mBitsPerChannel
    guard (isFloat && bits == 32) || (!isFloat && (bits == 16 || bits == 32)) else { return buffer }
    // Kanallar iç içe (LRLR…) ya da art arda (LLL…RRR…) gelebilir.
    let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

    let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
    if channels.count != channelCount || sampleRate != asbd.mSampleRate {
      // Mikrofon değişti (ör. yaka mikrofonu takıldı): baştan ölç.
      channels = (0..<channelCount).map { _ in Channel() }
      sampleRate = asbd.mSampleRate
    }

    // Kameranın tamponu salt okunur olabilir; kopyası üzerinde çalış.
    let length = CMBlockBufferGetDataLength(source)
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &block) == kCMBlockBufferNoErr, let block
    else { return buffer }
    var data: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &data)
      == kCMBlockBufferNoErr, let data,
      CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length, destination: data) == kCMBlockBufferNoErr
    else { return buffer }

    let frames = CMSampleBufferGetNumSamples(buffer)
    let total = frames * channelCount
    guard total * Int(bits / 8) <= length else { return buffer }
    let index: (Int, Int) -> Int = interleaved ? { f, c in f * channelCount + c } : { f, c in c * frames + f }
    if isFloat {
      data.withMemoryRebound(to: Float.self, capacity: total) {
        run($0, frames: frames, index: index, read: { $0 }, write: { $0 })
      }
    } else if bits == 16 {
      data.withMemoryRebound(to: Int16.self, capacity: total) {
        run(
          $0, frames: frames, index: index,
          read: { Float($0) / 32768 }, write: { Int16(clamping: Int(($0 * 32767).rounded())) })
      }
    } else {
      data.withMemoryRebound(to: Int32.self, capacity: total) {
        run(
          $0, frames: frames, index: index,
          read: { Float($0) / 2_147_483_648 }, write: { Int32(clamping: Int64((Double($0) * 2_147_483_647).rounded())) })
      }
    }

    // Çıkış girişten 2 × hop geride; zaman damgasını o kadar öne al.
    let delay = CMTime(value: CMTimeValue(2 * Self.hop), timescale: CMTimeScale(asbd.mSampleRate))
    var out: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
      presentationTimeStamp: CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), delay),
      packetDescriptions: nil, sampleBufferOut: &out) == noErr, let out
    else { return buffer }
    return out
  }

  private func run<T>(
    _ samples: UnsafeMutablePointer<T>, frames: Int, index: (Int, Int) -> Int,
    read: (T) -> Float, write: (Float) -> T
  ) {
    // Gürültü tahmini (güç) saniyede ~3 dB yükselebilir.
    let rise = powf(10, 3 / 10 * Float(Self.hop) / Float(sampleRate))
    for (c, channel) in channels.enumerated() {
      for f in 0..<frames {
        channel.pending.append(read(samples[index(f, c)]))
      }
      while channel.pending.count >= Self.hop {
        channel.history.removeFirst(Self.hop)
        channel.history.append(contentsOf: channel.pending.prefix(Self.hop))
        channel.pending.removeFirst(Self.hop)
        processHop(channel, rise: rise)
      }
      for f in 0..<frames {
        samples[index(f, c)] = write(channel.ready[f])
      }
      channel.ready.removeFirst(frames)
    }
  }

  /// Bir parça: pencere → FFT → frekans başına kazanç → ters FFT → pencere → üst üste ekle.
  private func processHop(_ channel: Channel, rise: Float) {
    let n = Self.size
    let half = n / 2
    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(channel.history, 1, window, 1, &windowed, 1, vDSP_Length(n))

    var real = [Float](repeating: 0, count: half)
    var imag = [Float](repeating: 0, count: half)
    var restored = [Float](repeating: 0, count: n)
    real.withUnsafeMutableBufferPointer { realPointer in
      imag.withUnsafeMutableBufferPointer { imagPointer in
        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
        windowed.withUnsafeBufferPointer {
          $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
          }
        }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))

        // Paketli biçim: realp[0] = 0 Hz, imagp[0] = en yüksek frekans; diğerleri karmaşık.
        for k in 0...half {
          let re = k == 0 ? split.realp[0] : k == half ? split.imagp[0] : split.realp[k]
          let im = k == 0 || k == half ? 0 : split.imagp[k]
          let power = re * re + im * im
          let smoothed = channel.smooth[k] == 0 ? power : channel.smooth[k] * 0.8 + power * 0.2
          channel.smooth[k] = smoothed
          channel.noise[k] = smoothed < channel.noise[k] ? smoothed : channel.noise[k] * rise
          // Güç oranından kazanç; en fazla `floorGain` kadar kısılır.
          let noise = Self.bias * Self.overSubtraction * channel.noise[k]
          let target = max(1 - noise / max(power, 1e-12), Self.floorGain * Self.floorGain).squareRoot()
          // Açılış hızlı (konuşma başı kesilmesin), kapanış yumuşak ("cıvıltı" olmasın).
          let previous = channel.gains[k]
          let gain = previous + (target - previous) * (target > previous ? 0.8 : 0.35)
          channel.gains[k] = gain
          if k == 0 {
            split.realp[0] *= gain
          } else if k == half {
            split.imagp[0] *= gain
          } else {
            split.realp[k] *= gain
            split.imagp[k] *= gain
          }
        }

        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
        restored.withUnsafeMutableBufferPointer {
          $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
          }
        }
      }
    }

    // İleri + geri FFT 2n katı büyütür; sentez penceresiyle çarp ve üst üste ekle.
    var scale = 1 / Float(2 * n)
    var scaled = [Float](repeating: 0, count: n)
    vDSP_vsmul(restored, 1, &scale, &scaled, 1, vDSP_Length(n))
    var synthesized = [Float](repeating: 0, count: n)
    vDSP_vmul(scaled, 1, window, 1, &synthesized, 1, vDSP_Length(n))
    var summed = [Float](repeating: 0, count: n)
    vDSP_vadd(channel.overlap, 1, synthesized, 1, &summed, 1, vDSP_Length(n))

    channel.ready.append(contentsOf: summed[0..<Self.hop])
    channel.overlap = Array(summed[Self.hop...]) + [Float](repeating: 0, count: Self.hop)
  }
}

/// Ön kameradaki kişiyi arka plandan ayırır (Vision). Kare ve maskesi birlikte saklanır; hem önizleme
/// hem tek video kullanır. Meşgulken gelen kare atlanır, kamera akışı yavaşlamaz.
private final class PersonSegmenter {
  private let queue = DispatchQueue(label: "dualcam.segment")
  private let request: VNGeneratePersonSegmentationRequest = {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    return request
  }()
  // Yalnızca dataQueue üzerinde kullanılır.
  private var busy = false
  /// Son kare ve kişinin maskesi.
  var latest: (face: CVPixelBuffer, mask: CVPixelBuffer)?

  /// dataQueue üzerinde çağrılır; `done` da dataQueue üzerinde, yeni maske hazır olunca.
  func submit(_ frame: CVPixelBuffer, on dataQueue: DispatchQueue, done: @escaping () -> Void) {
    guard !busy else { return }
    busy = true
    queue.async { [self] in
      let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
      let mask = (try? handler.perform([request])) != nil ? request.results?.first?.pixelBuffer : nil
      dataQueue.async { [self] in
        busy = false
        guard let mask else { return }
        latest = (frame, mask)
        done()
      }
    }
  }
}

private final class Recorder {
  enum Style {
    /// Ön+Arka, iki ayrı dosya: sahne `back`te, yüz `front`ta.
    case separate
    /// Ön+Arka, tek dosya (`back`): yüz ayrı yazılmaz, son karesi sahneyle birleştirilir.
    case combined
    /// Tek kamera, tek dosya (`back`): kayıt sırasında kamera çevrilebilir; `source` hangi
    /// kameranın yazıldığını söyler.
    case single
  }

  let style: Style
  let back: Track?
  let front: Track?
  let compositor: PipCompositor?
  var latestFace: CVPixelBuffer?
  /// Tek kamerada yazılan kamera. Çevrilince yeni kameranın ilk karesi gelene kadar eskisi yazılır
  /// (`pendingSource`), videoda boşluk olmaz.
  var source: CameraMode
  var pendingSource: CameraMode?
  var startTime: CMTime?
  /// Duraklatma: `paused` iken gelen ilk örneğin zamanı `pauseStart` olur; devam edince aradaki
  /// süre `offset`e eklenir ve sonraki örneklerin zamanından düşülür (video kesintisiz tek parça).
  var paused = false
  var pauseStart: CMTime?
  var offset = CMTime.zero

  /// Duraklatmalarda geçen süre düşülmüş kopya; hiç duraklatılmadıysa aynısı.
  func retimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
    guard offset != .zero else { return buffer }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    for i in timing.indices {
      timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
      if timing[i].decodeTimeStamp.isValid {
        timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
      }
    }
    var copy: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing,
      sampleBufferOut: &copy)
    return copy ?? buffer
  }

  init(mode: CameraMode, combine: Bool) {
    source = mode
    switch mode {
    case .both where combine:
      style = .combined
      back = Track(name: "ikili", composited: true)
      front = nil
      compositor = PipCompositor()
    case .both:
      style = .separate
      back = Track(name: "sahne")
      front = Track(name: "yuz")
      compositor = nil
    case .back, .front:
      style = .single
      back = Track(name: "tek", composited: true)
      front = nil
      compositor = PipCompositor()
    }
  }

  /// Tek kamerada karenin yazılıp yazılmayacağı; yeni kameranın ilk karesiyle geçiş tamamlanır.
  func accepts(_ camera: CameraMode) -> Bool {
    if let pending = pendingSource, camera == pending {
      source = pending
      pendingSource = nil
    }
    return camera == source
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
  let onZoomRange = EventDispatcher()
  let onZoomChange = EventDispatcher()
  let onAudioLevel = EventDispatcher()
  let onPipMove = EventDispatcher()
  let onHardwareButton = EventDispatcher()
  let onOrientationChange = EventDispatcher()
  let onFocusLock = EventDispatcher()

  /// Donanım tarafı ortak ve açılışta hazırlanır (CameraRig.prewarm); aşağıdakiler ona bakar.
  private let rig = CameraRig.shared
  private var session: AVCaptureMultiCamSession { rig.session }
  private var sessionQueue: DispatchQueue { rig.queue }
  private let dataQueue = DispatchQueue(label: "dualcam.data")

  private var backPreview: AVCaptureVideoPreviewLayer { rig.backPreview }
  private var frontPreview: AVCaptureVideoPreviewLayer { rig.frontPreview }
  /// Tam kare (bölünmüş düzende bir yarı) ve küçük pencere (bölünmüşte diğer yarı). Hangi kameranın
  /// hangisinde olduğunu `swapped` belirler; önizleme katmanları kaplar arasında taşınır.
  private let mainContainer = UIView()
  private let pipContainer = UIView()
  /// Göz teması penceresi: ön kameranın lensin hemen yanındaki küçük kopyası. Yalnızca ekranda,
  /// kayda girmez. Çift kamera oturumu aynı kameraya ikinci önizleme bağlamaya izin vermediği için
  /// ön kameranın video kareleriyle beslenir. Yerini ve boyutunu JS verir.
  private let miniDisplay = AVSampleBufferDisplayLayer()
  /// "Sahneye yerleştir" önizlemesi: kesilmiş kişi (ayna), pencere kabının içinde, etrafı saydam.
  private let cutoutLayer = CALayer()
  private let miniContainer = UIView()
  private var miniFrame: CGRect?
  /// Ön ışık açıkken önizleme küçülür (kenarlar beyaz kalır); 1 = tam boy. Kayda etkisi yok.
  private var previewScale: CGFloat = 1

  private var backOutput: AVCaptureVideoDataOutput { rig.backOutput }
  private var frontOutput: AVCaptureVideoDataOutput { rig.frontOutput }
  private var backPhotoOutput: AVCapturePhotoOutput { rig.backPhotoOutput }
  private var frontPhotoOutput: AVCapturePhotoOutput { rig.frontPhotoOutput }
  private var audioOutput: AVCaptureAudioDataOutput { rig.audioOutput }

  // sessionQueue üzerinde kullanılır.
  private var isConfigured: Bool {
    get { rig.isConfigured }
    set { rig.isConfigured = newValue }
  }
  private var captureOrientation: AVCaptureVideoOrientation = .portrait
  private var back: CameraLinks? {
    get { rig.back }
    set { rig.back = newValue }
  }
  private var front: CameraLinks? {
    get { rig.front }
    set { rig.front = newValue }
  }
  private var audioConnection: AVCaptureConnection?
  private var activeMode: CameraMode = .both
  private var activeKind: CaptureKind {
    get { rig.activeKind }
    set { rig.activeKind = newValue }
  }
  private var torchWanted = false
  /// Her kamera kendi yakınlaştırmasını hatırlar; düğmeler ve iki parmak büyük görüntüdekini değiştirir.
  private var backZoom: CGFloat = 1
  private var frontZoom: CGFloat = 1
  /// Büyük görüntüde (yakınlaştırılan) ön kamera var: ön modu ya da Ön+Arka'da yer değiştirilmiş.
  private var zoomOnFront = false
  /// Tele lensi olmayan arka kamerada yakınlaştırma sınırı (tele varsa `backZoomCap`).
  private let maxZoom: CGFloat = 10
  /// Tele lensli arka kamerada sınır, iPhone'un Kamera uygulamasındaki gibi tele lensin bu katı:
  /// 3× tele → 15×, 5× tele → 25×.
  private let teleZoomMultiplier: CGFloat = 5
  /// Ön kamerada yakınlaştırma tamamen dijital (kırpma); ötesi çok bulanık.
  private let maxFrontZoom: CGFloat = 3
  private var shots = Set<PhotoShot>() // çekimi süren fotolar (çıkış yalnızca zayıf tutar)

  // Ana thread üzerinde kullanılır.
  private var isRecording = false
  private var combine = false
  private var isLandscape = false
  private var mode: CameraMode = .both
  private var kind: CaptureKind = .video
  /// Kameranın verdiği karenin yataydaki en/boy oranı: videoda 16:9, fotoda 4:3.
  private var frameRatio: CGFloat = 16 / 9
  private var geometryObservation: NSKeyValueObservation?
  /// Ön+Arka düzeni: yüz küçük pencerede (`pip`) ya da ekran ikiye bölünmüş (`split`).
  private var layout: DualLayout = .pip
  /// Pencereye dokununca yer değiştirir: yüz büyük, sahne küçük.
  private var swapped = false
  /// Pencerenin yeri: merkezinin kareye oranı (0–1); nil = sağ üst köşe. Kullanıcı sürükler.
  private var pipCenter: CGPoint?
  /// Kaydedilen karenin ekrandaki yeri (son yerleşimden).
  private var videoRect: CGRect = .zero
  private lazy var pipPan = UIPanGestureRecognizer(target: self, action: #selector(pipPanned(_:)))
  /// Yer değiştirme: pencere düzeninde küçük pencereye tek dokunuş, bölünmüşte bir yarıya çift dokunuş
  /// (tek dokunuş orada odaklar).
  private lazy var pipTap = UITapGestureRecognizer(target: self, action: #selector(swapTapped))
  private lazy var mainTap = UITapGestureRecognizer(target: self, action: #selector(swapTapped))
  /// Dokunarak odaklama ve pozlama (dokunulan görüntünün kamerasında); basılı tutmak kilitler.
  private lazy var mainFocusTap = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
  private lazy var pipFocusTap = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
  private lazy var mainFocusHold = UILongPressGestureRecognizer(target: self, action: #selector(focusHeld(_:)))
  private lazy var pipFocusHold = UILongPressGestureRecognizer(target: self, action: #selector(focusHeld(_:)))
  /// Kamera uygulamasındaki gibi sarı kare; kilitliyken ekranda kalır.
  private let focusSquare = UIView()
  private var focusLocked = false
  /// Kare kaybolmadan yeni dokunuş gelirse eski kaybolma iptal olsun.
  private var focusGeneration = 0
  /// İki parmakla yakınlaştırma; önizlemenin her yerinde (küçük pencerenin üstünde de).
  private lazy var zoomPinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
  /// Büyük görüntüdeki kameranın yakınlaştırması ve sınırları (ana thread kopyası); iki parmak buradan başlar.
  private var zoomShown: CGFloat = 1
  private var zoomLimits: (min: CGFloat, max: CGFloat) = (1, 10)
  private var pinchStartZoom: CGFloat = 1
  private var buttonInteraction: UIInteraction?
  private var lastOrientationName: String?

  // Yalnızca dataQueue üzerinde kullanılır.
  private var recorder: Recorder?
  private var lastLevelEmit: CFTimeInterval = 0
  /// Göz teması penceresi görünüyor mu (ön kameranın kareleri ona da gider).
  private var miniVisible = false
  /// Hışırtı azaltma (ayardan açıksa); kayıt yokken de çalışıp hışırtıyı öğrenir.
  private var denoiser: NoiseReducer?
  /// Tek videonun düzeni; ana thread'deki düzen, yer değiştirme ve pencere yerinin kopyası.
  private var recordingLayout = CompositeLayout()
  /// "Sahneye yerleştir" açıkken ön kameranın kareleri kişi ayırıcıya gider.
  private let segmenter = PersonSegmenter()
  private var segmentationOn = false
  /// Kesilmiş kişi önizlemesinin piksel boyutu (pencere kabının boyutu, en fazla ~720 px).
  private var cutoutPreviewSize: CGSize = .zero
  private let previewContext = CIContext(options: [.cacheIntermediates: false])

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    // Foto/video değişince kare oranı değişir; yerleşim ona göre.
    sessionQueue.async { [weak self, rig] in
      rig.onFrameRatio = { ratio in
        DispatchQueue.main.async {
          self?.frameRatio = ratio
          self?.setNeedsLayout()
        }
      }
    }
    // Karenin dışı saydam: arkadaki ekran rengi görünür (normalde siyah, ön ışıkta beyaz).
    backgroundColor = .clear
    clipsToBounds = true

    // Kapların oranı karenin oranıyla aynı ya da yarısı; doldurmak yalnızca bölünmüşte kırpar.
    for preview in [backPreview, frontPreview] {
      preview.videoGravity = .resizeAspectFill
    }
    for container in [mainContainer, pipContainer] {
      container.clipsToBounds = true
      container.layer.borderColor = UIColor.white.cgColor
      addSubview(container)
    }
    mainContainer.layer.addSublayer(backPreview)
    pipContainer.layer.addSublayer(frontPreview)
    pipContainer.addGestureRecognizer(pipPan)
    pipContainer.addGestureRecognizer(pipTap)
    mainContainer.addGestureRecognizer(mainTap)
    mainTap.numberOfTapsRequired = 2
    for (container, tap, hold) in [(mainContainer, mainFocusTap, mainFocusHold), (pipContainer, pipFocusTap, pipFocusHold)] {
      tap.delegate = self
      hold.minimumPressDuration = 0.6
      container.addGestureRecognizer(tap)
      container.addGestureRecognizer(hold)
    }
    focusSquare.layer.borderColor = UIColor.systemYellow.cgColor
    focusSquare.layer.borderWidth = 1.5
    focusSquare.isUserInteractionEnabled = false
    focusSquare.alpha = 0
    addSubview(focusSquare)
    // Pencere tek parmakla sürüklenir; iki parmak yakınlaştırmaya kalır.
    pipPan.maximumNumberOfTouches = 1
    addGestureRecognizer(zoomPinch)
    miniContainer.clipsToBounds = true
    miniContainer.layer.borderColor = UIColor.white.cgColor
    miniContainer.layer.borderWidth = 1
    miniContainer.layer.cornerRadius = 8
    miniContainer.isHidden = true
    miniContainer.isUserInteractionEnabled = false
    miniDisplay.videoGravity = .resizeAspectFill
    // Ana önizleme gibi ayna; kaydedilen kareler düz.
    miniDisplay.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
    miniDisplay.controlTimebase = Self.hostTimebase()
    miniContainer.layer.addSublayer(miniDisplay)
    cutoutLayer.contentsGravity = .resizeAspectFill
    cutoutLayer.isHidden = true
    // Ön kamera önizlemesi gibi ayna; kaydedilen kare düz.
    cutoutLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
    pipContainer.layer.addSublayer(cutoutLayer)
    addSubview(miniContainer)
    addCaptureButtons()

    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(routeChanged),
                   name: AVAudioSession.routeChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                   name: .AVCaptureSessionRuntimeError, object: session)
    nc.addObserver(self, selector: #selector(sessionInterrupted),
                   name: .AVCaptureSessionWasInterrupted, object: session)
    nc.addObserver(self, selector: #selector(subjectAreaChanged(_:)),
                   name: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionInterruptionEnded),
                   name: .AVCaptureSessionInterruptionEnded, object: session)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Yerleşim

  override func layoutSubviews() {
    super.layoutSubviews()
    // Yatay sol ↔ sağ (180°) dönüşünde ekranın boyutu değişmez; JS gerçek yönü buradan öğrenir
    // (tuşlar telefonun tutulduğu elin tarafına geçer).
    if let name = window?.windowScene?.interfaceOrientation.jsName, name != lastOrientationName {
      lastOrientationName = name
      onOrientationChange(["orientation": name])
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updateOrientation()

    // Kaydedilen karenin (video 16:9, foto 4:3; dikeyde tersi) ekrandaki yeri.
    let aspect = isLandscape ? CGSize(width: frameRatio, height: 1) : CGSize(width: 1, height: frameRatio)
    let full = AVMakeRect(aspectRatio: aspect, insideRect: bounds)
    let vr = full.insetBy(dx: full.width * (1 - previewScale) / 2, dy: full.height * (1 - previewScale) / 2)
    videoRect = vr

    // Tek kamerada o kamera tüm kareyi kaplar; Ön+Arka'da `swapped` hangisinin büyük olduğunu seçer.
    let dual = mode == .both
    // Sahneye yerleştirde yer değiştirme yok: sahne hep büyük, kişi kesilmiş olarak üstünde.
    let cutout = dual && layout == .cutout
    let (main, small) = (dual && swapped && !cutout) || mode == .front
      ? (frontPreview, backPreview) : (backPreview, frontPreview)
    if main.superlayer !== mainContainer.layer { mainContainer.layer.addSublayer(main) }
    if small.superlayer !== pipContainer.layer { pipContainer.layer.insertSublayer(small, at: 0) }
    pipContainer.isHidden = !dual
    small.isHidden = cutout
    cutoutLayer.isHidden = !cutout
    pipPan.isEnabled = dual && layout != .split
    pipTap.isEnabled = dual && !cutout
    pipTap.numberOfTapsRequired = layout == .split ? 2 : 1
    pipFocusTap.isEnabled = dual && layout == .split
    pipFocusHold.isEnabled = dual && layout == .split
    mainTap.isEnabled = dual && layout == .split

    if dual && layout == .split {
      // Yatayda yan yana, dikeyde üst üste; büyük kamera solda / üstte.
      let (first, second) = isLandscape
        ? vr.divided(atDistance: vr.width / 2, from: .minXEdge)
        : vr.divided(atDistance: vr.height / 2, from: .minYEdge)
      mainContainer.frame = first
      pipContainer.frame = second
      pipContainer.layer.cornerRadius = 0
      pipContainer.layer.borderWidth = 0
    } else {
      mainContainer.frame = vr
      let scale = cutout ? Pip.cutoutScale : 1
      let pip = Pip.rect(in: vr.size, center: pipCenter, scale: scale).offsetBy(dx: vr.minX, dy: vr.minY)
      pipContainer.frame = pip
      pipContainer.layer.cornerRadius = cutout ? 0 : max(pip.width, pip.height) * Pip.cornerRatio
      pipContainer.layer.borderWidth = cutout ? 0 : max(1, min(vr.width, vr.height) * Pip.borderRatio)
    }
    main.frame = mainContainer.bounds
    small.frame = pipContainer.bounds
    cutoutLayer.frame = pipContainer.bounds
    syncSegmentation(on: cutout, size: pipContainer.bounds.size)
    miniContainer.isHidden = miniFrame == nil
    if let miniFrame { miniContainer.frame = miniFrame }
    miniDisplay.frame = miniContainer.bounds
    // Çerçeve aynı kalsa bile önizleme, görüntüyü yeni yöne göre yeniden yerleştirsin.
    backPreview.setNeedsLayout()
    frontPreview.setNeedsLayout()
    CATransaction.commit()
  }

  // MARK: - Göz teması penceresi

  /// Kameranın zaman damgaları sistem saatine göre; kareler geldikleri anda gösterilsin.
  private static func hostTimebase() -> CMTimebase? {
    let clock = CMClockGetHostTimeClock()
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &timebase)
    guard let timebase else { return nil }
    CMTimebaseSetTime(timebase, time: CMClockGetTime(clock))
    CMTimebaseSetRate(timebase, rate: 1)
    return timebase
  }

  /// JS'ten: ön ışık açıkken önizleme bu oranda küçülür, etrafı beyaz kalır.
  func setPreviewScale(_ scale: Double) {
    let clamped = CGFloat(min(max(scale, 0.3), 1))
    guard clamped != previewScale else { return }
    previewScale = clamped
    setNeedsLayout()
  }

  /// JS'ten: pencerenin ekrandaki yeri (lensin hemen yanı); nil = gizli.
  func setMiniPreviewFrame(_ frame: CGRect?) {
    miniFrame = frame
    setNeedsLayout()
    let visible = frame != nil
    dataQueue.async { [weak self] in
      guard let self else { return }
      self.miniVisible = visible
      if !visible { self.flushMini() }
    }
  }

  /// dataQueue üzerinde çağrılır: ön kameranın karesi pencereye.
  private func showInMini(_ sampleBuffer: CMSampleBuffer) {
    if #available(iOS 17.0, *) {
      let renderer = miniDisplay.sampleBufferRenderer
      if renderer.status == .failed { renderer.flush() }
      if renderer.isReadyForMoreMediaData { renderer.enqueue(sampleBuffer) }
    } else {
      if miniDisplay.status == .failed { miniDisplay.flush() }
      if miniDisplay.isReadyForMoreMediaData { miniDisplay.enqueue(sampleBuffer) }
    }
  }

  /// Gizlenince eski kare kalmasın.
  private func flushMini() {
    if #available(iOS 17.0, *) {
      miniDisplay.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    } else {
      miniDisplay.flushAndRemoveImage()
    }
  }

  // MARK: - Ön+Arka düzeni, yer değiştirme, pencereyi taşıma

  /// JS'ten (ayarlardan): "pip" ya da "split". Tek videoya da aynı düzen yazılır.
  func setLayout(_ value: String) {
    guard let newLayout = DualLayout(rawValue: value), newLayout != layout else { return }
    releaseFocus()
    layout = newLayout
    setNeedsLayout()
    syncRecordingLayout()
    syncZoomTarget()
  }

  /// JS'ten (kaydedilmiş ayardan) pencerenin yeri; nil = sağ üst köşe. Sürüklerken yok sayılır.
  func setPipPosition(_ center: CGPoint?) {
    guard pipPan.state != .began, pipPan.state != .changed else { return }
    pipCenter = center
    setNeedsLayout()
    syncRecordingLayout()
  }

  // MARK: - Odak ve pozlama

  @objc private func focusTapped(_ tap: UITapGestureRecognizer) {
    guard let container = tap.view else { return }
    focus(in: container, at: tap.location(in: container), lock: false)
  }

  @objc private func focusHeld(_ hold: UILongPressGestureRecognizer) {
    guard hold.state == .began, let container = hold.view else { return }
    focus(in: container, at: hold.location(in: container), lock: true)
  }

  /// Kaptaki görüntü ön kameranın mı (yerleşimdeki seçimle aynı).
  private func showsFront(_ container: UIView) -> Bool {
    let frontInMain = (mode == .both && swapped && layout != .cutout) || mode == .front
    return container === mainContainer ? frontInMain : !frontInMain
  }

  /// Ana thread. Noktayı önizlemenin (doldurma, dönüş ve ayna dahil) kamera koordinatına çevirir.
  private func focus(in container: UIView, at point: CGPoint, lock: Bool) {
    let front = showsFront(container)
    let preview = front ? frontPreview : backPreview
    let devicePoint = preview.captureDevicePointConverted(fromLayerPoint: preview.convert(point, from: container.layer))
    showFocusSquare(at: container.convert(point, to: self), locked: lock)
    setFocusLocked(lock)
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let target = (front ? self.front : self.back)?.device
      // Aynı anda tek kamera odaklanmış/kilitli kalır; diğeri otomatiğe döner.
      for device in [self.back?.device, self.front?.device].compactMap({ $0 }) where device !== target {
        Self.applyFocus(device, at: nil, lock: false)
      }
      if let target { Self.applyFocus(target, at: devicePoint, lock: lock) }
    }
  }

  /// sessionQueue. `point` nil: ortada sürekli otomatik (varsayılan). Kilitte odak ve pozlama bir
  /// kez ayarlanıp öyle kalır; değilse sahne değişince (`subjectAreaChanged`) otomatiğe döner.
  private static func applyFocus(_ device: AVCaptureDevice, at point: CGPoint?, lock: Bool) {
    let target = point ?? CGPoint(x: 0.5, y: 0.5)
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      // Nokta, mod ayarlanınca geçerli olur; önce nokta.
      if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target }
      let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
      if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
      if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = target }
      let exposureMode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
      if device.isExposureModeSupported(exposureMode) { device.exposureMode = exposureMode }
      device.isSubjectAreaChangeMonitoringEnabled = point != nil && !lock
    } catch {
      // Kilitlenemezse dokunuş yok sayılır; kamera otomatikte kalır.
    }
  }

  /// Dokunulan yere odaklandıktan sonra sahne belirgin şekilde değişti: Kamera uygulaması gibi
  /// ortada sürekli otomatiğe dön (kilitliyse izleme kapalı, buraya gelmez).
  @objc private func subjectAreaChanged(_ note: Notification) {
    guard let device = note.object as? AVCaptureDevice else { return }
    sessionQueue.async { [weak self] in
      guard let self, device === self.back?.device || device === self.front?.device else { return }
      Self.applyFocus(device, at: nil, lock: false)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.focusLocked else { return }
      self.hideFocusSquare()
    }
  }

  /// Ana thread. Görüntüler yer değiştirince, kamera ya da çekim türü değişince odak sıfırlanır.
  private func releaseFocus() {
    hideFocusSquare()
    setFocusLocked(false)
    sessionQueue.async { [weak self] in
      guard let self else { return }
      for device in [self.back?.device, self.front?.device].compactMap({ $0 }) {
        Self.applyFocus(device, at: nil, lock: false)
      }
    }
  }

  private func setFocusLocked(_ locked: Bool) {
    guard locked != focusLocked else { return }
    focusLocked = locked
    onFocusLock(["locked": locked])
  }

  private func showFocusSquare(at center: CGPoint, locked: Bool) {
    focusGeneration += 1
    let generation = focusGeneration
    let side = min(bounds.width, bounds.height) * 0.2
    focusSquare.layer.removeAllAnimations()
    focusSquare.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    focusSquare.center = center
    focusSquare.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
    focusSquare.alpha = 1
    bringSubviewToFront(focusSquare)
    UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
      self.focusSquare.transform = .identity
    } completion: { _ in
      guard !locked, generation == self.focusGeneration else { return }
      UIView.animate(withDuration: 0.4, delay: 1.0, options: [.allowUserInteraction]) {
        self.focusSquare.alpha = 0
      }
    }
  }

  private func hideFocusSquare() {
    focusGeneration += 1
    UIView.animate(withDuration: 0.2) { self.focusSquare.alpha = 0 }
  }

  // MARK: - Ses tuşları

  /// Ses tuşları (iOS 17.2+): ses kısma birincil, ses açma ikincil olay. Ne yapılacağına JS karar
  /// verir (birincil: çek / durdur; ikincil: kayıtta foto). Kapalıyken tuşlar sesi değiştirir.
  private func addCaptureButtons() {
    guard #available(iOS 17.2, *) else { return }
    let interaction = AVCaptureEventInteraction(
      primary: { [weak self] event in
        if event.phase == .ended { self?.onHardwareButton(["button": "primary"]) }
      },
      secondary: { [weak self] event in
        if event.phase == .ended { self?.onHardwareButton(["button": "secondary"]) }
      })
    addInteraction(interaction)
    buttonInteraction = interaction
  }

  /// JS'ten: ayarlardan kapalıysa ya da ayarlar ekranı açıksa tuşlar normal ses tuşu olur.
  func setHardwareButtons(_ enabled: Bool) {
    guard #available(iOS 17.2, *), let interaction = buttonInteraction as? AVCaptureEventInteraction else { return }
    interaction.isEnabled = enabled
  }

  /// Pencereye (bölünmüşte iki yarıdan birine) dokununca kameralar yer değiştirir.
  @objc private func swapTapped() {
    releaseFocus()
    swapped.toggle()
    UIView.transition(with: self, duration: 0.25, options: .transitionCrossDissolve) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
    syncRecordingLayout()
    syncZoomTarget()
  }

  /// Kişi ayırma yalnızca "sahneye yerleştir" açıkken çalışır (pil). Önizleme pencere boyutunda çizilir.
  private func syncSegmentation(on: Bool, size: CGSize) {
    let scale = min(window?.screen.scale ?? 2, 720 / max(size.width, size.height, 1))
    let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    dataQueue.async { [weak self] in
      guard let self else { return }
      self.segmentationOn = on
      self.cutoutPreviewSize = pixels
      if !on { self.segmenter.latest = nil }
    }
    if !on { cutoutLayer.contents = nil }
  }

  /// dataQueue üzerinde: yeni maskeyle kesilmiş kişiyi çizip önizlemeye koyar.
  private func renderCutoutPreview() {
    guard let latest = segmenter.latest, cutoutPreviewSize.width > 0, cutoutPreviewSize.height > 0 else { return }
    let target = CGRect(origin: .zero, size: cutoutPreviewSize)
    let person = PipCompositor.cutout(CIImage(cvPixelBuffer: latest.face), mask: CIImage(cvPixelBuffer: latest.mask))
    guard let image = previewContext.createCGImage(PipCompositor.fill(person, into: target), from: target) else { return }
    DispatchQueue.main.async { [weak self] in
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self?.cutoutLayer.contents = image
      CATransaction.commit()
    }
  }

  private func syncRecordingLayout() {
    let current = CompositeLayout(layout: layout, swapped: swapped && layout != .cutout, pip: pipCenter)
    dataQueue.async { [weak self] in self?.recordingLayout = current }
  }

  /// Parmağı takip eder; bırakınca hızına göre o yöne kayar (fırlatma). Pencere karenin dışına
  /// taşmaz. Son yer JS'e bildirilir (kalıcı olsun diye).
  @objc private func pipPanned(_ pan: UIPanGestureRecognizer) {
    let vr = videoRect
    guard vr.width > 0, vr.height > 0 else { return }
    let current = pipContainer.center
    var target = current
    switch pan.state {
    case .changed:
      let t = pan.translation(in: self)
      pan.setTranslation(.zero, in: self)
      target = CGPoint(x: current.x + t.x, y: current.y + t.y)
    case .ended, .cancelled:
      let v = pan.velocity(in: self)
      target = CGPoint(x: current.x + v.x * 0.15, y: current.y + v.y * 0.15)
    default:
      return
    }

    let normalized = CGPoint(x: (target.x - vr.minX) / vr.width, y: (target.y - vr.minY) / vr.height)
    let rect = Pip.rect(in: vr.size, center: normalized, scale: layout == .cutout ? Pip.cutoutScale : 1)
    let frame = rect.offsetBy(dx: vr.minX, dy: vr.minY)
    let center = CGPoint(x: rect.midX / vr.width, y: rect.midY / vr.height)
    pipCenter = center
    syncRecordingLayout()

    if pan.state == .changed {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      pipContainer.frame = frame
      CATransaction.commit()
    } else {
      UIView.animate(
        withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) { self.pipContainer.frame = frame }
      onPipMove(["x": Double(center.x), "y": Double(center.y)])
    }
  }

  /// JS'ten gelen kamera seçimi: "both", "back" ya da "front". Kayıt sırasında yalnızca tek kameralar
  /// arasında (arka ↔ ön) değişir; kayıt aynı dosyada sürer.
  func setCameras(_ value: String) {
    guard let newMode = CameraMode(rawValue: value), newMode != mode else { return }
    if isRecording {
      guard newMode != .both, mode != .both else { return }
      dataQueue.async { [weak self] in self?.recorder?.pendingSource = newMode }
    }
    releaseFocus()
    mode = newMode
    setNeedsLayout()
    let zoomFront = zoomTargetIsFront
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.activeMode = newMode
      self.zoomOnFront = zoomFront
      self.applyCameraMode()
      self.applyTorch()
      self.applyZoom()
      self.emitZoomRange()
    }
  }

  /// JS'ten gelen çekim türü: "video" ya da "photo". Kayıt sırasında değişmez.
  func setCaptureMode(_ value: String) {
    guard !isRecording, let newKind = CaptureKind(rawValue: value), newKind != kind else { return }
    releaseFocus()
    kind = newKind
    UserDefaults.standard.set(newKind.rawValue, forKey: CameraRig.kindKey)
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.activeKind = newKind
      guard self.isConfigured else { return }
      self.session.beginConfiguration()
      do {
        try self.rig.applyFormats()
      } catch {
        self.emitError(error)
      }
      self.applyCameraMode()
      self.session.commitConfiguration()
      // Format değişince ışık sönebiliyor, yakınlaştırma da 1x'e döner (sınırı da değişebilir).
      self.applyTorch()
      self.applyZoom()
      self.emitZoomRange()
    }
  }

  /// JS'ten gelen yakınlaştırma (1 = normal), büyük görüntüdeki kameraya. Kayıt sırasında da
  /// değişebilir. İki parmak sürerken yok sayılır: JS'e giden değerler geride kalıp geri gelince
  /// görüntü titremesin.
  func setZoom(_ value: Double) {
    guard zoomPinch.state != .began, zoomPinch.state != .changed else { return }
    zoomShown = CGFloat(value)
    sessionQueue.async { [weak self] in self?.setTargetZoom(CGFloat(value)) }
  }

  /// Ana thread'de: büyük görüntüde ön kamera mı (bölünmüşte sol / üst yarı).
  private var zoomTargetIsFront: Bool {
    mode == .front || (mode == .both && swapped && layout != .cutout)
  }

  /// Yer değiştirince ya da düzen değişince yakınlaştırma büyük görüntüdeki kameraya geçer; JS o
  /// kameranın aralığını ve hatırlanan değerini alır.
  private func syncZoomTarget() {
    let front = zoomTargetIsFront
    sessionQueue.async { [weak self] in
      guard let self, self.zoomOnFront != front else { return }
      self.zoomOnFront = front
      self.emitZoomRange()
    }
  }

  /// sessionQueue üzerinde çağrılır.
  private func setTargetZoom(_ zoom: CGFloat) {
    if zoomOnFront { frontZoom = zoom } else { backZoom = zoom }
    applyZoom()
  }

  /// Ekrandaki yakınlaştırma (1x = geniş açı lens) ile cihazın `videoZoomFactor`'ü arasındaki çarpan.
  /// Ultra geniş lensli sanal kamerada 1.0 ultra geniştir (0,5x); geniş açı lense ilk geçiş
  /// noktasında (genelde 2.0) geçilir.
  private func zoomScale(_ device: AVCaptureDevice) -> CGFloat {
    guard device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
      let wide = device.virtualDeviceSwitchOverVideoZoomFactors.first
    else { return 1 }
    return CGFloat(truncating: wide)
  }

  private func zoomCap(_ device: AVCaptureDevice) -> CGFloat {
    device.position == .front ? maxFrontZoom : backZoomCap(device)
  }

  /// Arka kameranın üst sınırı, ekrandaki ölçekte (1 = geniş lens). Sanal kameranın son geçiş noktası
  /// tele lensin başladığı yerdir; telefon ne kadar destekliyorsa (`maxAvailableVideoZoomFactor`) onunla
  /// ayrıca sınırlanır.
  private func backZoomCap(_ device: AVCaptureDevice) -> CGFloat {
    guard device.constituentDevices.contains(where: { $0.deviceType == .builtInTelephotoCamera }),
      let tele = device.virtualDeviceSwitchOverVideoZoomFactors.last
    else { return maxZoom }
    return max(maxZoom, CGFloat(truncating: tele) / zoomScale(device) * teleZoomMultiplier)
  }

  /// sessionQueue üzerinde çağrılır. Büyük görüntüdeki kameranın aralığı ve hatırlanan değeri; JS
  /// yakınlaştırma düğmelerini buna göre gösterir (0,5x yalnızca ultra geniş lens varsa).
  private func emitZoomRange() {
    guard let device = (zoomOnFront ? front : back)?.device else { return }
    let scale = zoomScale(device)
    let limits = (
      min: device.minAvailableVideoZoomFactor / scale,
      max: min(device.maxAvailableVideoZoomFactor / scale, zoomCap(device))
    )
    let zoom = min(max(zoomOnFront ? frontZoom : backZoom, limits.min), limits.max)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.zoomLimits = limits
      self.zoomShown = zoom
      self.onZoomRange(["min": Double(limits.min), "max": Double(limits.max), "zoom": Double(zoom)])
    }
  }

  /// İki parmak: kamera doğrudan burada yakınlaşır (akıcı olsun), JS yalnızca değeri gösterir.
  /// `active` parmaklar ekrandayken true.
  @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
    switch pinch.state {
    case .began:
      pinchStartZoom = zoomShown
    case .changed, .ended:
      let zoom = min(max(pinchStartZoom * pinch.scale, zoomLimits.min), zoomLimits.max)
      zoomShown = zoom
      sessionQueue.async { [weak self] in self?.setTargetZoom(zoom) }
      onZoomChange(["zoom": Double(zoom), "active": pinch.state == .changed])
    case .cancelled, .failed:
      onZoomChange(["zoom": Double(zoomShown), "active": false])
    default:
      break
    }
  }

  /// sessionQueue üzerinde çağrılır. Her kamera kendi değerinde (küçük penceredeyken de). Arka sanal
  /// kamera tele lense geçtikten sonrası dijital; sınır `backZoomCap`, ön kamera 3x ile sınırlı.
  private func applyZoom() {
    for (links, zoom) in [(back, backZoom), (front, frontZoom)] {
      guard let device = links?.device else { continue }
      let scale = zoomScale(device)
      let upper = min(device.maxAvailableVideoZoomFactor, zoomCap(device) * scale)
      let clamped = min(max(zoom * scale, device.minAvailableVideoZoomFactor), upper)
      guard device.videoZoomFactor != clamped else { continue }
      do {
        try device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
      } catch {
        // Kilitlenemezse bir sonraki değişiklikte yeniden denenir.
      }
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

  /// sessionQueue üzerinde çağrılır. İki kamera da hep açık: bağlantıyı açıp kapatmak oturumu yeniden
  /// kurar ve iki görüntü de ~1 sn donar. Kamera değiştirmek (kayıtta çevirmek dahil) böylece anında
  /// olur; kullanılmayan kamera yalnızca gösterilmez ve yazılmaz. Video kareleri fotoda da açık (göz
  /// teması penceresi onlarla beslenir); fotoda yalnızca mikrofon kapanır. Foto çıkışı videoda da açık
  /// (kayıtta foto).
  private func applyCameraMode() {
    for links in [back, front].compactMap({ $0 }) {
      links.preview.isEnabled = true
      links.video.isEnabled = true
      links.photo.isEnabled = true
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
    applyZoom()
    emitZoomRange()
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

    // Kameralar çoğu zaman açılışta (CameraRig.prewarm) bağlanmış ve çalışıyor olur.
    if !rig.camerasReady {
      try rig.configureCameras()
    }
    for output in [backOutput, frontOutput] {
      output.setSampleBufferDelegate(self, queue: dataQueue)
    }
    let ratio = rig.frameRatio
    DispatchQueue.main.async { [weak self] in
      self?.frameRatio = ratio
      self?.setNeedsLayout()
    }

    applyOrientation()
    // Mikrofon izni yoksa kamera yine açılır, video sessiz kaydedilir.
    try? addMicrophone()
    applyCameraMode()
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

  func setNoiseReduction(_ enabled: Bool) {
    dataQueue.async { [weak self] in
      guard let self else { return }
      if enabled != (self.denoiser != nil) { self.denoiser = enabled ? NoiseReducer() : nil }
    }
  }

  /// JS'ten (ayarlardan): Ön+Arka tek dosya mı olsun (video ve foto). Sonraki çekimde geçerli olur.
  func setCombine(_ value: Bool) {
    combine = value
  }

  func startRecording() {
    isRecording = true
    let mode = self.mode
    // Sahneye yerleştir yalnızca tek videoyla anlamlı.
    let combine = self.combine || layout == .cutout
    dataQueue.async { [weak self] in
      guard let self, self.recorder == nil else { return }
      self.recorder = Recorder(mode: mode, combine: combine)
    }
  }

  /// Kaydı duraklatır / sürdürür. Dosya açık kalır; duraklatılan süre videoda yer almaz.
  func setPaused(_ paused: Bool) {
    dataQueue.async { [weak self] in self?.recorder?.paused = paused }
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
      // Dosyalar yalnızca galeriye aktarılınca silinir; olmazsa bir sonraki açılışta yeniden denenir.
      let recovered = tracks.contains { $0.salvaged }
      PendingRecordings.saveToPhotos(saved) { error in
        if let error {
          completion(.failure(error))
        } else {
          completion(.success(["duration": duration, "files": saved.count, "recovered": recovered]))
        }
      }
    }
  }

  // MARK: - Foto

  /// Seçili kameralarla birer foto çeker ve galeriye kaydeder (önce sahne, sonra yüz). Ön+Arka'da
  /// "tek dosya" açıksa (ya da sahneye yerleştirde) iki foto ekrandaki düzenle tek fotoğraf olur.
  /// Video kaydı sürerken de çalışır; o zaman deklanşör sesi (destekleniyorsa) çıkmaz.
  func takePhoto(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    let silent = isRecording
    let combined = combine || layout == .cutout
      ? CompositeLayout(layout: layout, swapped: swapped && layout != .cutout, pip: pipCenter)
      : nil
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let outputs = [
        self.activeMode.usesBack ? self.backPhotoOutput : nil,
        self.activeMode.usesFront ? self.frontPhotoOutput : nil,
      ].compactMap { $0 }
      guard self.session.isRunning, !outputs.isEmpty else {
        DispatchQueue.main.async { completion(.failure(DualCameraError.photoFailed)) }
        return
      }
      let combined = outputs.count == 2 ? combined : nil
      let shot = PhotoShot(outputs: outputs, queue: self.sessionQueue, location: LocationTracker.shared.current) { [weak self] shot, photos, error in
        self?.shots.remove(shot)
        guard !photos.isEmpty else {
          DispatchQueue.main.async { completion(.failure(error ?? DualCameraError.photoFailed)) }
          return
        }
        // Birleştirme kamerayı bekletmesin diye ayrı kuyrukta.
        DispatchQueue.global(qos: .userInitiated).async {
          var photos = photos
          if let combined, photos.count == 2,
            let single = PhotoCombiner.combine(scene: photos[0], face: photos[1], layout: combined)
          {
            photos = [single]
          }
          Self.save(photos, completion: completion)
        }
      }
      self.shots.insert(shot)
      for output in outputs {
        output.capturePhoto(with: Self.photoSettings(for: output, silent: silent), delegate: shot)
      }
    }
  }

  /// Önce diske: galeriye aktarma olmazsa foto kaybolmaz, bir sonraki açılışta kurtarılır.
  private static func save(_ photos: [Data], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    var files: [URL] = []
    for data in photos {
      let url = PendingRecordings.photoURL(for: data)
      if (try? data.write(to: url, options: .atomic)) != nil { files.append(url) }
    }
    guard files.count == photos.count else {
      PendingRecordings.remove(files)
      DispatchQueue.main.async { completion(.failure(DualCameraError.photoFailed)) }
      return
    }
    PendingRecordings.saveToPhotos(files) { error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(error))
        } else {
          completion(.success(["files": photos.count]))
        }
      }
    }
  }

  private static func photoSettings(for output: AVCapturePhotoOutput, silent: Bool) -> AVCapturePhotoSettings {
    let settings = output.availablePhotoCodecTypes.contains(.hevc)
      ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
      : AVCapturePhotoSettings()
    settings.maxPhotoDimensions = output.maxPhotoDimensions
    settings.photoQualityPrioritization = .quality
    // Kayıt sırasında deklanşör sesi videoya girmesin (sesin zorunlu olduğu ülkelerde desteklenmez).
    if silent, #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
      settings.isShutterSoundSuppressionEnabled = true
    }
    return settings
  }

  // MARK: - Kareler (dataQueue)

  /// Mikrofonun ses düzeyi (dB, 0 en yüksek). Kayıt yokken de gider; saniyede en fazla 10 kez.
  private func emitAudioLevel(_ connection: AVCaptureConnection) {
    let now = CACurrentMediaTime()
    guard now - lastLevelEmit >= 0.1,
      let db = connection.audioChannels.map(\.averagePowerLevel).max()
    else { return }
    lastLevelEmit = now
    let level: [String: Any] = ["db": Double(db)]
    DispatchQueue.main.async { [weak self] in self?.onAudioLevel(level) }
  }

  private var audioSettings: [String: Any]? {
    audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    var sampleBuffer = sampleBuffer
    if output === audioOutput {
      emitAudioLevel(connection)
      // Hışırtı azaltma kayıt yokken de çalışır: hışırtıyı önceden öğrenir, kayıt ilk saniyeden temiz.
      if let denoiser { sampleBuffer = denoiser.process(sampleBuffer) }
    }
    if output === frontOutput, miniVisible {
      showInMini(sampleBuffer)
    }
    if output === frontOutput, segmentationOn, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
      segmenter.submit(frame, on: dataQueue) { [weak self] in self?.renderCutoutPreview() }
    }
    guard let recorder else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    if output === frontOutput, recorder.style == .combined {
      recorder.latestFace = CMSampleBufferGetImageBuffer(sampleBuffer)
      return
    }

    // Duraklatılmışken görüntü ve ses atılır; devam edince aradaki süre düşülür.
    if recorder.startTime != nil {
      if recorder.paused {
        if recorder.pauseStart == nil { recorder.pauseStart = time }
        return
      }
      if let pauseStart = recorder.pauseStart {
        recorder.offset = CMTimeAdd(recorder.offset, CMTimeSubtract(time, pauseStart))
        recorder.pauseStart = nil
      }
    }
    let sample = recorder.retimed(sampleBuffer)

    if output === audioOutput {
      guard let start = recorder.startTime, CMTimeCompare(time, start) >= 0 else { return }
      recorder.tracks.forEach { $0.appendAudio(sample) }
      return
    }

    let target: Track?
    if recorder.style == .single {
      let camera: CameraMode? = output === backOutput ? .back : output === frontOutput ? .front : nil
      target = camera.map(recorder.accepts) == true ? recorder.back : nil
    } else {
      target = output === backOutput ? recorder.back : output === frontOutput ? recorder.front : nil
    }
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
    switch (recorder.style, recorder.compositor) {
    case (.combined, let compositor?):
      let cutout = recordingLayout.layout == .cutout
      track.appendVideo(
        sample, face: cutout ? segmenter.latest?.face : recorder.latestFace,
        mask: cutout ? segmenter.latest?.mask : nil, layout: recordingLayout, compositor: compositor)
    case (.single, let compositor?):
      track.appendVideo(sample, compositor: compositor)
    default:
      track.appendVideo(sample)
    }
  }
}

extension DualCameraView: UIGestureRecognizerDelegate {
  /// Odak dokunuşu, basılı tutma (kilit) olmadığı anlaşılınca çalışır; bölünmüş düzende ayrıca çift
  /// dokunuşun (yer değiştirme) olmadığı anlaşılınca.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
  ) -> Bool {
    if gestureRecognizer === mainFocusTap {
      return other === mainFocusHold || (other === mainTap && mainTap.isEnabled)
    }
    if gestureRecognizer === pipFocusTap {
      return other === pipFocusHold || (other === pipTap && pipTap.isEnabled && pipTap.numberOfTapsRequired == 2)
    }
    return false
  }
}
