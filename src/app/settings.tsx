import Constants from 'expo-constants';
import { router, Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useStrings } from '../i18n';
import { LANGUAGE_NAMES, LANGUAGES } from '../i18n/strings';
import { Settings, useSettings } from '../settings';

const LANGUAGE_OPTIONS: Settings['language'][] = ['system', ...LANGUAGES];

export default function SettingsScreen() {
  const s = useStrings();
  const settings = useSettings();
  const insets = useSafeAreaInsets();
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
            {settings.language === language && <Text style={styles.check}>✓</Text>}
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
      </View>

      <Text style={styles.sectionTitle}>{s.settings.about}</Text>
      <View style={styles.section}>
        <View style={styles.row}>
          <Text style={styles.rowText}>{s.settings.version}</Text>
          <Text style={styles.value}>{Constants.expoConfig?.version}</Text>
        </View>
      </View>
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
  value: { color: '#8e8e93', fontSize: 16 },
  check: { color: '#0a84ff', fontSize: 17, fontWeight: '600' },
});
