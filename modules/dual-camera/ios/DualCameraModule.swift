import AVFoundation
import ExpoModulesCore

public class DualCameraModule: Module {
  /// Karartmadan önceki parlaklık; ana thread'de kullanılır.
  private var savedBrightness: CGFloat?

  public func definition() -> ModuleDefinition {
    Name("DualCamera")

    // Ekran parlaklığı: "dim" uzun çekimde pil için loş (görüntü görünür kalır), "max" ön ışık için
    // tam, "normal" kullanıcının parlaklığı. Uygulama öndeyken geçerlidir; uygulamadan çıkınca iOS
    // kullanıcının parlaklığını kendisi geri yükler.
    AsyncFunction("setScreenBrightness") { (level: String) in
      let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
      guard let screen else { return }
      switch level {
      case "dim", "max":
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = level == "max" ? 1 : 0.1
      default:
        if let saved = savedBrightness {
          screen.brightness = saved
          savedBrightness = nil
        }
      }
    }.runOnQueue(.main)

    Function("isSupported") { () -> Bool in
      AVCaptureMultiCamSession.isMultiCamSupported
    }

    AsyncFunction("requestPermissions") { (promise: Promise) in
      AVCaptureDevice.requestAccess(for: .video) { camera in
        AVCaptureDevice.requestAccess(for: .audio) { microphone in
          promise.resolve(["camera": camera, "microphone": microphone])
        }
      }
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
        "onReady", "onMicChange", "onCameraError", "onAutoStopped", "onZoomRange", "onAudioLevel", "onPipMove",
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
