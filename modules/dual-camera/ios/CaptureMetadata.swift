import AVFoundation
import CoreLocation
import ImageIO

/// Çekime yazılan bilgiler (Kamera uygulamasının yazdıkları): çekim tarihi (saat dilimiyle), cihaz,
/// uygulama ve izin varsa konum. Fotoğraflar ve diğer uygulamalar (harita, tarih sırası, "hangi
/// telefonla çekildi") bunları dosyadan okur; dosya paylaşılınca da bilgiler onunla gider.
enum CaptureMetadata {
  /// "iPhone 15 Pro" gibi pazar adı (Kamera uygulaması videoya bunu yazar). Listede olmayan modelde
  /// nil: yanlış ad yazmaktansa hiç yazılmaz.
  static let deviceModel: String? = {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return modelNames[machine]
  }()

  /// "Dual Camera 1.2.0" (Info.plist'teki sürüm).
  static let software: String = {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    return version.isEmpty ? "Dual Camera" : "Dual Camera \(version)"
  }()

  // MARK: - Video

  /// AVAssetWriter'a `startWriting`ten önce verilir (dosyanın başına yazılır).
  static func videoItems(date: Date, location: CLLocation?) -> [AVMetadataItem] {
    var items = [
      item(.quickTimeMetadataCreationDate, quickTimeDate(date)),
      item(.quickTimeMetadataMake, "Apple"),
      item(.quickTimeMetadataSoftware, software),
    ]
    if let deviceModel { items.append(item(.quickTimeMetadataModel, deviceModel)) }
    if let location { items.append(item(.quickTimeMetadataLocationISO6709, iso6709(location))) }
    return items
  }

  private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }

  /// Kamera uygulamasının biçimi: "2026-11-14T13:04:35+0300" (yerel saat ve saat dilimi).
  static func quickTimeDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.string(from: date)
  }

  /// ISO 6709: "+41.0082+028.9784+045.000/" (enlem, boylam, varsa yükseklik).
  static func iso6709(_ location: CLLocation) -> String {
    let c = location.coordinate
    var text = String(format: "%+08.4f%+09.4f", c.latitude, c.longitude)
    if location.verticalAccuracy > 0 { text += String(format: "%+08.3f", location.altitude) }
    return text + "/"
  }

  // MARK: - Foto

  /// EXIF GPS sözlüğü (Kamera uygulamasının yazdığı alanlar).
  static func gps(_ location: CLLocation) -> [String: Any] {
    let c = location.coordinate
    let utc = DateFormatter()
    utc.locale = Locale(identifier: "en_US_POSIX")
    utc.timeZone = TimeZone(identifier: "UTC")
    utc.dateFormat = "yyyy:MM:dd"
    let date = utc.string(from: location.timestamp)
    utc.dateFormat = "HH:mm:ss.SS"
    let time = utc.string(from: location.timestamp)

    var gps: [String: Any] = [
      kCGImagePropertyGPSLatitude as String: abs(c.latitude),
      kCGImagePropertyGPSLatitudeRef as String: c.latitude >= 0 ? "N" : "S",
      kCGImagePropertyGPSLongitude as String: abs(c.longitude),
      kCGImagePropertyGPSLongitudeRef as String: c.longitude >= 0 ? "E" : "W",
      kCGImagePropertyGPSDateStamp as String: date,
      kCGImagePropertyGPSTimeStamp as String: time,
    ]
    if location.horizontalAccuracy > 0 {
      gps[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
    }
    if location.verticalAccuracy > 0 {
      gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
      gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude >= 0 ? 0 : 1
    }
    return gps
  }

  /// Ön+Arka tek foto: sahne fotosunun EXIF/TIFF/GPS bilgileri (tarih, cihaz, lens, konum). Görüntü
  /// zaten dik çevrildiği için yön 1; boyut yeni görüntününki. Kameraya özel ek bilgiler (Apple'ın
  /// HDR / derinlik notları) birleşik görüntü için geçerli olmadığından alınmaz.
  static func combinedProperties(from scene: [String: Any], size: CGSize) -> [String: Any] {
    var properties: [String: Any] = [kCGImagePropertyOrientation as String: 1]
    if var exif = scene[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      exif[kCGImagePropertyExifPixelXDimension as String] = Int(size.width)
      exif[kCGImagePropertyExifPixelYDimension as String] = Int(size.height)
      properties[kCGImagePropertyExifDictionary as String] = exif
    }
    if var tiff = scene[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
      tiff[kCGImagePropertyTIFFOrientation as String] = 1
      properties[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if let gps = scene[kCGImagePropertyGPSDictionary as String] {
      properties[kCGImagePropertyGPSDictionary as String] = gps
    }
    return properties
  }

  /// Ön ve arka kamerayı aynı anda çalıştırabilen (A12 ve sonrası) iPhone'lar; kimlikler Xcode'un
  /// cihaz listesinden. Yeni modeller çıkınca buraya eklenir.
  private static let modelNames: [String: String] = [
    "iPhone11,2": "iPhone XS",
    "iPhone11,4": "iPhone XS Max",
    "iPhone11,6": "iPhone XS Max",
    "iPhone11,8": "iPhone XR",
    "iPhone12,1": "iPhone 11",
    "iPhone12,3": "iPhone 11 Pro",
    "iPhone12,5": "iPhone 11 Pro Max",
    "iPhone12,8": "iPhone SE (2nd generation)",
    "iPhone13,1": "iPhone 12 mini",
    "iPhone13,2": "iPhone 12",
    "iPhone13,3": "iPhone 12 Pro",
    "iPhone13,4": "iPhone 12 Pro Max",
    "iPhone14,2": "iPhone 13 Pro",
    "iPhone14,3": "iPhone 13 Pro Max",
    "iPhone14,4": "iPhone 13 mini",
    "iPhone14,5": "iPhone 13",
    "iPhone14,6": "iPhone SE (3rd generation)",
    "iPhone14,7": "iPhone 14",
    "iPhone14,8": "iPhone 14 Plus",
    "iPhone15,2": "iPhone 14 Pro",
    "iPhone15,3": "iPhone 14 Pro Max",
    "iPhone15,4": "iPhone 15",
    "iPhone15,5": "iPhone 15 Plus",
    "iPhone16,1": "iPhone 15 Pro",
    "iPhone16,2": "iPhone 15 Pro Max",
    "iPhone17,1": "iPhone 16 Pro",
    "iPhone17,2": "iPhone 16 Pro Max",
    "iPhone17,3": "iPhone 16",
    "iPhone17,4": "iPhone 16 Plus",
    "iPhone17,5": "iPhone 16e",
    "iPhone18,1": "iPhone 17 Pro",
    "iPhone18,2": "iPhone 17 Pro Max",
    "iPhone18,3": "iPhone 17",
    "iPhone18,4": "iPhone Air",
    "iPhone18,5": "iPhone 17e",
    "iPhone19,2": "iPhone 18 Pro",
    "iPhone19,3": "iPhone 18 Pro Max",
    "iPhone19,4": "iPhone Duo",
  ]
}
