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

      AsyncFunction("startRecording") { (view: DualCameraView) in
        view.startRecording()
      }

      AsyncFunction("stopRecording") { (view: DualCameraView, promise: Promise) in
        view.stopRecording { result in
          switch result {
          case .success(let info):
            promise.resolve(info)
          case .failure(let error):
            promise.reject("E_RECORDING", error.localizedDescription)
          }
        }
      }
    }
  }
}
