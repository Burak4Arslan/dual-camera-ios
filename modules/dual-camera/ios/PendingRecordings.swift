import AVFoundation
import Photos

/// Kayıtlar kaybolmasın: video ve fotolar önce iOS'un kendiliğinden temizlemediği bir klasöre yazılır
/// (Application Support; yedeğe girmez, Dosyalar'da görünmez) ve yalnızca galeriye başarıyla
/// kaydedildikten sonra silinir. Uygulama çökse, telefon kapansa ya da galeriye aktarma başarısız
/// olsa bile dosya burada kalır; bir sonraki açılışta `recover` onu galeriye kaydeder.
enum PendingRecordings {
  static let directory: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var url = base.appendingPathComponent("PendingRecordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
    return url
  }()

  static func newURL(name: String, ext: String = "mov") -> URL {
    directory.appendingPathComponent("dualcam-\(name)-\(UUID().uuidString).\(ext)")
  }

  /// Fotonun verisi; uzantı JPEG ise "jpg", değilse (HEIC) "heic".
  static func photoURL(for data: Data) -> URL {
    newURL(name: "foto", ext: data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic")
  }

  static func remove(_ urls: [URL]) {
    urls.forEach { try? FileManager.default.removeItem(at: $0) }
  }

  /// Galeriye kaydeder; yalnızca başarılı olursa dosyaları siler. Hata olursa dosyalar kalır
  /// (bir sonraki açılışta `recover` yeniden dener).
  static func saveToPhotos(_ urls: [URL], completion: @escaping (Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(DualCameraError.photosDenied)
        return
      }
      PHPhotoLibrary.shared().performChanges({
        for url in urls {
          let request = PHAssetCreationRequest.forAsset()
          request.addResource(with: url.pathExtension == "mov" ? .video : .photo, fileURL: url, options: nil)
        }
      }) { ok, error in
        if ok { remove(urls) }
        completion(ok ? nil : DualCameraError.savePending(error?.localizedDescription ?? ""))
      }
    }
  }

  /// Önceki açılışlardan kalan (yarım kalmış ya da galeriye gidememiş) kayıtları galeriye kaydeder;
  /// kaç dosya kurtarıldığını döner. Son bir dakikada değişen dosyalara dokunmaz (yazılıyor olabilir).
  /// İçinde görüntü olmayan (hiç kare yazılamamış) videolar silinir.
  static func recover(completion: @escaping (Int) -> Void) {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
    let stale = files.filter { url in
      let values = try? url.resourceValues(forKeys: Set(keys))
      return (values?.contentModificationDate ?? .distantPast) < Date().addingTimeInterval(-60)
    }
    guard !stale.isEmpty else {
      completion(0)
      return
    }
    Task {
      var playable: [URL] = []
      for url in stale {
        if url.pathExtension != "mov" {
          playable.append(url)
          continue
        }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let duration = (try? await asset.load(.duration)) ?? .zero
        if !tracks.isEmpty, duration.seconds > 0 {
          playable.append(url)
        } else {
          remove([url])
        }
      }
      guard !playable.isEmpty else {
        completion(0)
        return
      }
      saveToPhotos(playable) { error in completion(error == nil ? playable.count : 0) }
    }
  }
}
