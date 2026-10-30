// iOS 27, "sahne" (UIScene) yaşam döngüsüne geçmemiş uygulamaları açılışta durduruyor. Expo SDK 57
// şablonu henüz bunu yapmıyor; bu eklenti SDK 58 şablonundaki çözümün aynısını uygular:
// - AppDelegate pencereyi kendisi açmaz; pencereyi açıp React Native'i SceneDelegate başlatır
//   (Expo'nun ExpoAppSceneDelegate'i),
// - Info.plist sahne tanımını içerir.
// SDK 58'e geçince bu eklenti kaldırılabilir.
const { withAppDelegate, withInfoPlist } = require('expo/config-plugins');

const START_REACT_NATIVE = /#if os\(iOS\) \|\| os\(tvOS\)\n\s*window = UIWindow\(frame: UIScreen\.main\.bounds\)\n\s*factory\.startReactNative\([\s\S]*?\)\n#endif\n/;

const SCENE_DELEGATE = `
@objc(SceneDelegate)
class SceneDelegate: ExpoAppSceneDelegate {
  // Pencereyi açıp React Native'i başlatır (iOS 27 sahne yaşam döngüsü).
}
`;

function withSceneManifest(config) {
  return withInfoPlist(config, (c) => {
    c.modResults.UIApplicationSceneManifest = {
      UIApplicationSupportsMultipleScenes: false,
      UISceneConfigurations: {
        UIWindowSceneSessionRoleApplication: [
          {
            UISceneConfigurationName: 'Default Configuration',
            UISceneDelegateClassName: '$(PRODUCT_MODULE_NAME).SceneDelegate',
          },
        ],
      },
    };
    return c;
  });
}

function withSceneAppDelegate(config) {
  return withAppDelegate(config, (c) => {
    let source = c.modResults.contents;
    if (source.includes('class SceneDelegate')) return c;
    // Şablon değişirse sessizce bozuk uygulama üretmesin: beklenen kod yoksa prebuild dursun.
    if (!source.includes('class AppDelegate: ExpoAppDelegate {') || !START_REACT_NATIVE.test(source)) {
      throw new Error('withSceneDelegate: AppDelegate.swift beklenen Expo şablonunda değil; eklentiyi güncelle.');
    }
    source = source
      .replace('class AppDelegate: ExpoAppDelegate {', 'class AppDelegate: ExpoAppDelegate, ExpoReactNativeFactoryProvider {')
      .replace(START_REACT_NATIVE, "    // Pencereyi ve React Native'i SceneDelegate başlatır (iOS 27 sahne yaşam döngüsü).\n");
    c.modResults.contents = source + SCENE_DELEGATE;
    return c;
  });
}

module.exports = function withSceneDelegate(config) {
  return withSceneAppDelegate(withSceneManifest(config));
};
