import AVFoundation
import ExpoModulesCore

public class DualCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("DualCamera")

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

    View(DualCameraView.self) {
      Events("onReady", "onMicChange", "onCameraError", "onAutoStopped")

      Prop("cameras") { (view: DualCameraView, value: String) in
        view.setCameras(value)
      }

      Prop("torch") { (view: DualCameraView, value: Bool) in
        view.setTorch(value)
      }

      Prop("captureMode") { (view: DualCameraView, value: String) in
        view.setCaptureMode(value)
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
