import CoreLocation
import UIKit

/// Çekimlere konum (Kamera uygulaması gibi): ayar açık, izin verilmiş ve uygulama öndeyken son konum
/// tutulur; çekim anında dosyaya yazılır. Konum hiçbir yere gönderilmez. Uygulama arka plana geçince
/// takip durur ve eski konum silinir (dönüşte yanlış yer yazılmasın).
final class LocationTracker: NSObject, CLLocationManagerDelegate {
  static let shared = LocationTracker()

  // Yalnızca ana thread'de.
  private var manager: CLLocationManager?
  private var enabled = false
  private var observers: [NSObjectProtocol] = []

  private let lock = NSLock()
  private var latest: CLLocation?

  /// Çekim anındaki konum; ayar kapalı, izin yok ya da konum henüz bulunamadıysa nil. Her thread'den.
  var current: CLLocation? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  /// "Ayarlar → Konumu kaydet". Açıkken izin zaten verildiyse takip başlar.
  func setEnabled(_ on: Bool) {
    DispatchQueue.main.async { [self] in
      enabled = on
      update()
    }
  }

  /// İzin daha önce sorulmadıysa sorar (kamera ve mikrofon izinlerinden sonra çağrılır).
  func requestPermission() {
    DispatchQueue.main.async { [self] in
      let manager = ensureManager()
      if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }
  }

  /// "granted" | "denied" | "undetermined" (Ayarlar ekranındaki uyarı için).
  static func permission() -> String {
    switch CLLocationManager().authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: return "granted"
    case .notDetermined: return "undetermined"
    default: return "denied"
    }
  }

  private func ensureManager() -> CLLocationManager {
    if let manager { return manager }
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    self.manager = manager
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.update()
      })
    }
    return manager
  }

  private func update() {
    let manager = ensureManager()
    let status = manager.authorizationStatus
    let allowed = status == .authorizedWhenInUse || status == .authorizedAlways
    if enabled && allowed && UIApplication.shared.applicationState != .background {
      manager.startUpdatingLocation()
    } else {
      manager.stopUpdatingLocation()
      store(nil)
    }
  }

  private func store(_ location: CLLocation?) {
    lock.lock()
    latest = location
    lock.unlock()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
    store(location)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    update()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Konum geçici olarak bulunamadı (kapalı alan vb.); takip sürer, son konum kalır.
  }
}
