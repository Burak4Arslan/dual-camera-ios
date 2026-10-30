const { withEntitlementsPlist, withXcodeProject } = require('expo/config-plugins');

/**
 * expo-widgets (57.0.22) için düzeltmeler. app.json'da expo-widgets'tan ÖNCE gelmeli: sonra eklenen
 * eklentinin değişikliği önce çalışır, bu yüzden bunlar expo-widgets'tan sonra uygulanır.
 *
 * - Push yetkisi (aps-environment) `enablePushNotifications` kapalıyken de ekleniyor; belgesine göre
 *   yalnızca açıkken eklemeli. Uygulama bildirim göndermiyor, kaldırılır.
 * - Widget hedefinin Release ayarı optimizasyonsuz (-Onone) geliyor; Xcode bu yüzden pakete
 *   önizleme dosyaları (debug.dylib, __preview.dylib) koyuyor. Release normal derlenir.
 * - Widget hedefi iPad'i de hedefliyor; uygulama yalnızca iPhone (supportsTablet: false), eşitlenir.
 */
module.exports = function withExpoWidgetsFixes(config) {
  config = withEntitlementsPlist(config, (mod) => {
    delete mod.modResults['aps-environment'];
    return mod;
  });
  return withXcodeProject(config, (mod) => {
    const configs = mod.modResults.pbxXCBuildConfigurationSection();
    for (const entry of Object.values(configs)) {
      const settings = entry?.buildSettings;
      // Değerler proje dosyasında tırnaklı tutuluyor ("com.….ExpoWidgetsTarget").
      const bundleId = String(settings?.PRODUCT_BUNDLE_IDENTIFIER ?? '').replace(/"/g, '');
      if (!settings || !bundleId.endsWith('.ExpoWidgetsTarget')) continue;
      settings.TARGETED_DEVICE_FAMILY = '1';
      if (entry.name === 'Release') {
        settings.SWIFT_OPTIMIZATION_LEVEL = '"-O"';
        settings.ENABLE_DEBUG_DYLIB = 'NO';
      }
    }
    return mod;
  });
};
