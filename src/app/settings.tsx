import { router, Stack } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { AppState, Linking, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { appVersion, locationPermission, requestLocationPermission } from '../../modules/dual-camera';
import { CONTACT, contactMailUrl } from '../contact';
import { useStrings } from '../i18n';
import { LANGUAGE_NAMES, LANGUAGES } from '../i18n/strings';
import { Settings, useSettings } from '../settings';

const LANGUAGE_OPTIONS: Settings['language'][] = ['system', ...LANGUAGES];
const LAYOUT_OPTIONS: Settings['layout'][] = ['pip', 'split', 'cutout'];

const LAYOUT_TEXT = {
  pip: ['layoutPip', 'layoutPipHint'],
  split: ['layoutSplit', 'layoutSplitHint'],
  cutout: ['layoutCutout', 'layoutCutoutHint'],
} as const;

export default function SettingsScreen() {
  const s = useStrings();
  const settings = useSettings();
  const insets = useSafeAreaInsets();
  const { version, build } = appVersion();
  const versionText = build ? `${version} (${build})` : version;
  // İzin iOS Ayarları'ndan değiştirilip dönülünce de güncellensin.
  const [location, setLocation] = useState(locationPermission);
  useEffect(() => {
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') setLocation(locationPermission());
    });
    return () => sub.remove();
  }, []);
  const locationDenied = settings.saveLocation && location === 'denied';
  // Yatayda çentik tarafında içerik kesilmesin.
  const side = { paddingLeft: Math.max(insets.left, 16), paddingRight: Math.max(insets.right, 16) };

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={[styles.content, side]}
      contentInsetAdjustmentBehavior="automatic"
    >
      <StatusBar style="light" />
      <Stack.Screen
        options={{
          headerRight: () => (
            <Pressable onPress={() => router.back()} hitSlop={8}>
              <Text style={styles.done}>{s.settings.done}</Text>
            </Pressable>
          ),
        }}
      />

      <Text style={styles.sectionTitle}>{s.settings.language}</Text>
      <View style={styles.section}>
        {LANGUAGE_OPTIONS.map((language, i) => (
          <Pressable
            key={language}
            style={[styles.row, i > 0 && styles.rowBorder]}
            onPress={() => settings.update({ language })}
          >
            <Text style={styles.rowText}>
              {language === 'system' ? s.settings.systemLanguage : LANGUAGE_NAMES[language]}
            </Text>
            {settings.language === language && <SymbolView name="checkmark" size={17} weight="semibold" tintColor="#0a84ff" />}
          </Pressable>
        ))}
      </View>

      <Text style={styles.sectionTitle}>{s.settings.camera}</Text>
      <View style={styles.section}>
        <View style={styles.row}>
          <Text style={styles.rowText}>{s.settings.grid}</Text>
          <Switch value={settings.grid} onValueChange={(grid) => settings.update({ grid })} />
        </View>
        <View style={[styles.row, styles.rowBorder]}>
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.shutterEffect}</Text>
            <Text style={styles.hint}>{s.settings.shutterEffectHint}</Text>
          </View>
          <Switch
            value={settings.shutterEffect}
            onValueChange={(shutterEffect) => settings.update({ shutterEffect })}
          />
        </View>
        <View style={[styles.row, styles.rowBorder]}>
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.volumeButtons}</Text>
            <Text style={styles.hint}>{s.settings.volumeButtonsHint}</Text>
          </View>
          <Switch
            value={settings.volumeButtons}
            onValueChange={(volumeButtons) => settings.update({ volumeButtons })}
          />
        </View>
        <View style={[styles.row, styles.rowBorder]}>
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.eyeContact}</Text>
            <Text style={styles.hint}>{s.settings.eyeContactHint}</Text>
          </View>
          <Switch value={settings.eyeContact} onValueChange={(eyeContact) => settings.update({ eyeContact })} />
        </View>
        <View style={[styles.row, styles.rowBorder]}>
          <Pressable
            style={styles.rowLabel}
            disabled={!locationDenied}
            accessibilityRole={locationDenied ? 'link' : undefined}
            onPress={() => Linking.openSettings()}
          >
            <Text style={styles.rowText}>{s.settings.saveLocation}</Text>
            <Text style={[styles.hint, locationDenied && styles.warning]}>
              {locationDenied ? s.settings.saveLocationDenied : s.settings.saveLocationHint}
            </Text>
          </Pressable>
          <Switch
            value={settings.saveLocation}
            onValueChange={(saveLocation) => {
              settings.update({ saveLocation });
              if (saveLocation && location === 'undetermined') requestLocationPermission();
            }}
          />
        </View>
      </View>

      <Text style={styles.sectionTitle}>{s.settings.dual}</Text>
      <View style={styles.section}>
        {LAYOUT_OPTIONS.map((layout, i) => (
          <Pressable
            key={layout}
            style={[styles.row, i > 0 && styles.rowBorder]}
            // Sahneye yerleştir yalnızca tek dosyayla anlamlı; seçilince tek dosya da açılır.
            onPress={() => settings.update(layout === 'cutout' ? { layout, combineVideo: true } : { layout })}
          >
            <View style={styles.rowLabel}>
              <Text style={styles.rowText}>{s.settings[LAYOUT_TEXT[layout][0]]}</Text>
              <Text style={styles.hint}>{s.settings[LAYOUT_TEXT[layout][1]]}</Text>
            </View>
            {settings.layout === layout && <SymbolView name="checkmark" size={17} weight="semibold" tintColor="#0a84ff" />}
          </Pressable>
        ))}
        <View style={[styles.row, styles.rowBorder]}>
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.combineVideo}</Text>
            <Text style={styles.hint}>
              {settings.layout === 'cutout' ? s.settings.combineVideoLocked : s.settings.combineVideoHint}
            </Text>
          </View>
          <Switch
            value={settings.combineVideo || settings.layout === 'cutout'}
            disabled={settings.layout === 'cutout'}
            onValueChange={(combineVideo) => settings.update({ combineVideo })}
          />
        </View>
      </View>

      <Text style={styles.sectionTitle}>{s.settings.video}</Text>
      <View style={styles.section}>
        <View style={styles.row}>
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.noiseReduction}</Text>
            <Text style={styles.hint}>{s.settings.noiseReductionHint}</Text>
          </View>
          <Switch
            value={settings.noiseReduction}
            onValueChange={(noiseReduction) => settings.update({ noiseReduction })}
          />
        </View>
        <View style={[styles.row, styles.rowBorder]}>
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.dimScreen}</Text>
            <Text style={styles.hint}>{s.settings.dimScreenHint}</Text>
          </View>
          <Switch value={settings.dimScreen} onValueChange={(dimScreen) => settings.update({ dimScreen })} />
        </View>
      </View>

      <Text style={styles.sectionTitle}>{s.settings.about}</Text>
      <View style={styles.section}>
        <View style={styles.row}>
          <Text style={styles.rowText}>{s.settings.version}</Text>
          <Text style={styles.value}>{versionText}</Text>
        </View>
        <Pressable
          style={[styles.row, styles.rowBorder]}
          accessibilityRole="link"
          onPress={() => Linking.openURL(contactMailUrl(s.appName, versionText))}
        >
          <View style={styles.rowLabel}>
            <Text style={styles.rowText}>{s.settings.contact}</Text>
            <Text style={styles.hint}>{CONTACT.email}</Text>
          </View>
          <SymbolView name="chevron.right" size={14} weight="semibold" tintColor="#636366" />
        </Pressable>
        <Pressable
          style={[styles.row, styles.rowBorder]}
          accessibilityRole="link"
          onPress={() => router.push('/privacy')}
        >
          <Text style={styles.rowText}>{s.settings.privacy}</Text>
          <SymbolView name="chevron.right" size={14} weight="semibold" tintColor="#636366" />
        </Pressable>
      </View>
      <Text style={styles.footer}>© 2026 {CONTACT.developer}</Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#000' },
  content: { paddingBottom: 32 },
  done: { color: '#0a84ff', fontSize: 17, fontWeight: '600' },
  sectionTitle: { color: '#8e8e93', fontSize: 13, marginTop: 24, marginBottom: 6, marginLeft: 16, textTransform: 'uppercase' },
  section: { backgroundColor: '#1c1c1e', borderRadius: 10, overflow: 'hidden' },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 48, paddingHorizontal: 16, paddingVertical: 10, gap: 12 },
  rowBorder: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: '#38383a' },
  rowLabel: { flexShrink: 1, gap: 2 },
  rowText: { color: '#fff', fontSize: 16 },
  hint: { color: '#8e8e93', fontSize: 13 },
  warning: { color: '#ff9f0a' },
  value: { color: '#8e8e93', fontSize: 16 },
  footer: { color: '#636366', fontSize: 12, textAlign: 'center', marginTop: 24 },
});
