const { IOSConfig, withDangerousMod, withXcodeProject } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

/**
 * Kilit ekranının alt köşeleri, Denetim Merkezi ve Eylem düğmesi için "Çift Kamera" kontrolü
 * (iOS 18+): dokununca uygulamayı açar. expo-widgets kontrolleri desteklemediği için onun widget
 * eklentisine (ExpoWidgetsTarget) eklenir. app.json'da expo-widgets'tan ÖNCE gelmeli (sonra
 * uygulansın: hedef ve index.swift o zaman var olur).
 */
const TARGET = 'ExpoWidgetsTarget';

// Hem uygulamada hem eklentide olmalı: sistem uygulamayı ancak eylem uygulamada da tanımlıysa açar.
const INTENT = `import AppIntents

/// Uygulamayı açar. Kilit ekranı / Denetim Merkezi kontrolü (DualCameraControl) bunu çalıştırır.
struct OpenDualCameraIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Dual Camera"
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    .result()
  }
}
`;

const CONTROL = `import AppIntents
import SwiftUI
import WidgetKit

/// Kilit ekranı köşesi, Denetim Merkezi ve Eylem düğmesi: dokununca uygulamayı açar (telefon
/// kilitliyse önce Face ID ister).
@available(iOS 18.0, *)
struct DualCameraControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.burakarslan.dualcam.open") {
      ControlWidgetButton(action: OpenDualCameraIntent()) {
        Label("Dual Camera", systemImage: "video.fill")
      }
    }
    .displayName("Dual Camera")
    .description("Opens the camera.")
  }
}
`;

module.exports = function withLaunchControl(config) {
  config = withDangerousMod(config, [
    'ios',
    async (mod) => {
      const ios = mod.modRequest.platformProjectRoot;
      const widgetDir = path.join(ios, TARGET);
      fs.writeFileSync(path.join(ios, mod.modRequest.projectName, 'OpenDualCameraIntent.swift'), INTENT);
      fs.writeFileSync(path.join(widgetDir, 'OpenDualCameraIntent.swift'), INTENT);
      fs.writeFileSync(path.join(widgetDir, 'DualCameraControl.swift'), CONTROL);

      // expo-widgets'ın ürettiği widget paketine kontrolü ekle.
      const indexPath = path.join(widgetDir, 'index.swift');
      const index = fs.readFileSync(indexPath, 'utf8');
      if (!index.includes('DualCameraControl()')) {
        const patched = index.replace(
          /(var body: some Widget \{\n)/,
          '$1    if #available(iOS 18.0, *) {\n      DualCameraControl()\n    }\n',
        );
        if (patched === index) throw new Error('withLaunchControl: index.swift beklenen biçimde değil');
        fs.writeFileSync(indexPath, patched);
      }
      return mod;
    },
  ]);

  return withXcodeProject(config, (mod) => {
    const project = mod.modResults;
    const projectName = mod.modRequest.projectName;
    const widgetUuid = project.findTargetKey(TARGET);
    if (!widgetUuid) throw new Error(`withLaunchControl: ${TARGET} hedefi bulunamadı`);
    const app = IOSConfig.XcodeUtils.getApplicationNativeTarget({ project, projectName });
    IOSConfig.XcodeUtils.addBuildSourceFileToGroup({
      filepath: `${projectName}/OpenDualCameraIntent.swift`, groupName: projectName, project, targetUuid: app.uuid,
    });
    for (const file of ['OpenDualCameraIntent.swift', 'DualCameraControl.swift']) {
      IOSConfig.XcodeUtils.addBuildSourceFileToGroup({ filepath: file, groupName: TARGET, project, targetUuid: widgetUuid });
    }
    return mod;
  });
};
