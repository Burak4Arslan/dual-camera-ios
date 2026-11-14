import AVFoundation
import ExpoModulesCore

public class DualCameraModule: Module {
  /// Karartmadan önceki parlaklık; ana thread'de kullanılır.
  private var savedBrightness: CGFloat?
  /// İstenen parlaklık ("dim" / "max"); uygulamaya dönünce yeniden uygulanır. `nil`: kullanıcınınki.
  private var targetLevel: String?
  /// En son bizim verdiğimiz değer. iOS aynı değer tekrar istenince komutu yok sayıyor (kilitten
  /// dönünce ekran loş kalırken 1.0 istemek işe yaramıyordu); yeniden uygularken değer biraz değişir.
  private var lastSetBrightness: CGFloat?
  private var observers: [NSObjectProtocol] = []

  public func definition() -> ModuleDefinition {
    Name("DualCamera")

    // Kilitten ya da başka uygulamadan dönünce iOS kullanıcının parlaklığını geri yükler; bunu
    // uygulama etkinleştikten sonra da yapabiliyor (ön ışık beyaz ama loş kalıyordu). İstenen düzey
    // dönüşte ve parlaklık her değiştiğinde (uygulama öndeyken) yeniden uygulanır.
    OnCreate {
      // Kameraları hemen hazırlamaya başla; arayüz kodu yüklenirken kamera da açılsın.
      CameraRig.shared.prewarm()
      let center = NotificationCenter.default
      for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          for delay in [0.0, 0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.applyTargetBrightness() }
          }
        })
      }
      observers.append(center.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.applyTargetBrightness()
      })
    }

    OnDestroy {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
    }

    // Ekran parlaklığı: "dim" uzun çekimde pil için loş (görüntü görünür kalır), "max" ön ışık için
    // tam, "normal" kullanıcının parlaklığı. Uygulama öndeyken geçerlidir; uygulamadan çıkınca iOS
    // kullanıcının parlaklığını kendisi geri yükler, dönünce istenen düzey yeniden uygulanır.
    AsyncFunction("setScreenBrightness") { (level: String) in
      guard let screen = currentScreen() else { return }
      switch level {
      case "dim", "max":
        if savedBrightness == nil { savedBrightness = screen.brightness }
        targetLevel = level
        applyTargetBrightness()
      default:
        targetLevel = nil
        if let saved = savedBrightness {
          screen.brightness = saved
          lastSetBrightness = saved
          savedBrightness = nil
        }
      }
    }.runOnQueue(.main)

    // Önceki açılışlardan kalan (yarım kalmış ya da galeriye gidememiş) kayıtları galeriye kaydeder;
    // kaç dosya kurtarıldığını döner.
    AsyncFunction("recoverRecordings") { (promise: Promise) in
      PendingRecordings.recover { count in promise.resolve(count) }
    }

    // Ayarlar → Hakkında: App Store'daki sürüm ve build numarası (Info.plist'ten).
    Function("appVersion") { () -> [String: String] in
      let info = Bundle.main.infoDictionary ?? [:]
      return [
        "version": info["CFBundleShortVersionString"] as? String ?? "",
        "build": info["CFBundleVersion"] as? String ?? "",
      ]
    }

    Function("isSupported") { () -> Bool in
      AVCaptureMultiCamSession.isMultiCamSupported
    }

    // Açılışta eşzamanlı: izin zaten verildiyse kamera ilk karede kurulur, bekleme ekranı çıkmaz.
    Function("permissionsGranted") { () -> [String: Bool] in
      [
        "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
        "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      ]
    }

    AsyncFunction("requestPermissions") { (promise: Promise) in
      AVCaptureDevice.requestAccess(for: .video) { camera in
        AVCaptureDevice.requestAccess(for: .audio) { microphone in
          promise.resolve(["camera": camera, "microphone": microphone])
        }
      }
    }

    // Konum izni kamera ve mikrofondan sonra sorulur (daha önce sorulduysa bir şey olmaz).
    Function("requestLocationPermission") {
      LocationTracker.shared.requestPermission()
    }

    Function("locationPermission") { () -> String in
      LocationTracker.permission()
    }

    // Arayüzün gerçek yönü (pencere sahnesinden). expo-screen-orientation'ın getOrientationAsync'i
    // yönü cihazın fiziksel duruşundan tahmin ediyor; yatayda sol/sağı karıştırabiliyor.
    AsyncFunction("getInterfaceOrientation") { () -> String in
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
      return scene?.interfaceOrientation.jsName ?? "unknown"
    }.runOnQueue(.main)

    // Kalan kayıt süresi tahmini için: önemli kullanım (kullanıcı başlattı) için kullanılabilir alan.
    AsyncFunction("getFreeSpace") { () -> Double in
      let values = try URL(fileURLWithPath: NSHomeDirectory())
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    View(DualCameraView.self) {
      Events(
        "onReady", "onMicChange", "onCameraError", "onAutoStopped", "onZoomRange", "onZoomChange", "onAudioLevel", "onPipMove",
        "onHardwareButton", "onOrientationChange")

      Prop("cameras") { (view: DualCameraView, value: String) in
        view.setCameras(value)
      }

      Prop("torch") { (view: DualCameraView, value: Bool) in
        view.setTorch(value)
      }

      Prop("captureMode") { (view: DualCameraView, value: String) in
        view.setCaptureMode(value)
      }

      Prop("zoom") { (view: DualCameraView, value: Double) in
        view.setZoom(value)
      }

      Prop("combine") { (view: DualCameraView, value: Bool) in
        view.setCombine(value)
      }

      Prop("layout") { (view: DualCameraView, value: String) in
        view.setLayout(value)
      }

      Prop("hardwareButtons") { (view: DualCameraView, value: Bool) in
        view.setHardwareButtons(value)
      }

      Prop("miniPreviewFrame") { (view: DualCameraView, value: MiniFrame?) in
        view.setMiniPreviewFrame(value.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
      }

      Prop("previewScale") { (view: DualCameraView, value: Double) in
        view.setPreviewScale(value)
      }

      Prop("noiseReduction") { (view: DualCameraView, value: Bool) in
        view.setNoiseReduction(value)
      }

      Prop("saveLocation") { (_: DualCameraView, value: Bool) in
        LocationTracker.shared.setEnabled(value)
      }

      Prop("pipPosition") { (view: DualCameraView, value: PipPosition?) in
        view.setPipPosition(value.map { CGPoint(x: $0.x, y: $0.y) })
      }

      AsyncFunction("takePhoto") { (view: DualCameraView, promise: Promise) in
        view.takePhoto { result in
          switch result {
          case .success(let info):
            promise.resolve(info)
          case .failure(let error):
            reject(promise, error)
          }
        }
      }

      AsyncFunction("startRecording") { (view: DualCameraView) in
        view.startRecording()
      }

      AsyncFunction("pauseRecording") { (view: DualCameraView) in
        view.setPaused(true)
      }

      AsyncFunction("resumeRecording") { (view: DualCameraView) in
        view.setPaused(false)
      }

      AsyncFunction("stopRecording") { (view: DualCameraView, promise: Promise) in
        view.stopRecording { result in
          switch result {
          case .success(let info):
            promise.resolve(info)
          case .failure(let error):
            reject(promise, error)
          }
        }
      }
    }
  }
}

private func currentScreen() -> UIScreen? {
  UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
}

extension DualCameraModule {
  /// Ana thread'de çağrılır. Uygulama arka plandayken dokunulmaz.
  fileprivate func applyTargetBrightness() {
    guard let level = targetLevel, UIApplication.shared.applicationState == .active,
          let screen = currentScreen() else { return }
    let target: CGFloat = level == "max" ? 1 : 0.1
    // Kendi ayarımız da değişiklik bildirimi doğurur; zaten hedefteyse dokunma (döngü olmasın).
    guard abs(screen.brightness - target) > 0.01 else { return }
    let value = lastSetBrightness == target ? target - 0.002 : target
    screen.brightness = value
    lastSetBrightness = value
  }
}

/// JS'te `error.code` çeviri anahtarıdır, `error.message` sistemden gelen ayrıntı (boş olabilir).
private func reject(_ promise: Promise, _ error: Error) {
  let payload = error.jsPayload
  promise.reject(payload["code"] as? String ?? "unknown", payload["detail"] as? String ?? "")
}

/// Yüz penceresinin yeri: merkezinin kareye oranı (0–1).
struct PipPosition: Record {
  @Field var x: Double = 0
  @Field var y: Double = 0
}

/// Göz teması penceresinin ekrandaki yeri (pt).
struct MiniFrame: Record {
  @Field var x: Double = 0
  @Field var y: Double = 0
  @Field var width: Double = 0
  @Field var height: Double = 0
}
