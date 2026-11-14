import { router, Stack } from 'expo-router';
import { SFSymbol, SymbolView } from 'expo-symbols';
import { StatusBar } from 'expo-status-bar';
import { ReactNode, useEffect, useState } from 'react';
import { AppState, Image, Linking, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
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

/** iOS koyu tema renkleri (Ayarlar uygulamasıyla aynı). */
const C = {
  background: '#000',
  card: '#1c1c1e',
  separator: '#38383a',
  label: '#fff',
  secondary: '#8e8e93',
  tertiary: '#636366',
  fill: '#76768033',
  selectedFill: '#636366',
  blue: '#0a84ff',
  orange: '#ff9f0a',
};

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
  const cutout = settings.layout === 'cutout';

  // Yatayda çentik tarafında içerik kesilmesin; geniş ekranda satırlar okunur genişlikte kalsın.
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
            <Pressable
              onPress={() => router.back()}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel={s.settings.done}
            >
              <SymbolView name="xmark" size={17} weight="semibold" tintColor={C.label} />
            </Pressable>
          ),
        }}
      />
      <View style={styles.column}>
        <Section title={s.settings.language}>
          <View style={styles.segmentRow}>
            <Segmented
              options={LANGUAGE_OPTIONS.map((language) => ({
                value: language,
                label: language === 'system' ? s.settings.systemLanguageShort : LANGUAGE_NAMES[language],
                accessibilityLabel: language === 'system' ? s.settings.systemLanguage : undefined,
              }))}
              value={settings.language}
              onChange={(language) => settings.update({ language })}
            />
          </View>
        </Section>

        <Section title={s.settings.dual}>
          <View style={styles.layouts}>
            {LAYOUT_OPTIONS.map((layout) => (
              <LayoutCard
                key={layout}
                layout={layout}
                label={s.settings[LAYOUT_TEXT[layout][0]]}
                selected={settings.layout === layout}
                // Sahneye yerleştir yalnızca tek dosyayla anlamlı; seçilince tek dosya da açılır.
                onPress={() => settings.update(layout === 'cutout' ? { layout, combineVideo: true } : { layout })}
              />
            ))}
          </View>
          <Text style={styles.layoutHint}>{s.settings[LAYOUT_TEXT[settings.layout][1]]}</Text>
          <Row
            icon="rectangle.on.rectangle"
            color="#30b0c7"
            title={s.settings.combineVideo}
            hint={cutout ? s.settings.combineVideoLocked : s.settings.combineVideoHint}
            border
          >
            <Switch
              value={settings.combineVideo || cutout}
              disabled={cutout}
              onValueChange={(combineVideo) => settings.update({ combineVideo })}
            />
          </Row>
        </Section>

        <Section title={s.settings.camera}>
          <Row icon="grid" color="#8e8e93" title={s.settings.grid}>
            <Switch value={settings.grid} onValueChange={(grid) => settings.update({ grid })} />
          </Row>
          <Row
            icon="speaker.wave.2.fill"
            color="#ff375f"
            title={s.settings.volumeButtons}
            hint={s.settings.volumeButtonsHint}
            border
          >
            <Switch
              value={settings.volumeButtons}
              onValueChange={(volumeButtons) => settings.update({ volumeButtons })}
            />
          </Row>
          <Row icon="eye.fill" color="#0a84ff" title={s.settings.eyeContact} hint={s.settings.eyeContactHint} border>
            <Switch value={settings.eyeContact} onValueChange={(eyeContact) => settings.update({ eyeContact })} />
          </Row>
          <Row
            icon="location.fill"
            color="#30d158"
            title={s.settings.saveLocation}
            hint={locationDenied ? s.settings.saveLocationDenied : s.settings.saveLocationHint}
            warning={locationDenied}
            onPress={locationDenied ? () => Linking.openSettings() : undefined}
            border
          >
            <Switch
              value={settings.saveLocation}
              onValueChange={(saveLocation) => {
                settings.update({ saveLocation });
                if (saveLocation && location === 'undetermined') requestLocationPermission();
              }}
            />
          </Row>
        </Section>

        <Section title={s.settings.video}>
          <Row icon="waveform" color="#bf5af2" title={s.settings.noiseReduction} hint={s.settings.noiseReductionHint}>
            <Switch
              value={settings.noiseReduction}
              onValueChange={(noiseReduction) => settings.update({ noiseReduction })}
            />
          </Row>
          <Row icon="moon.fill" color="#5e5ce6" title={s.settings.dimScreen} hint={s.settings.dimScreenHint} border>
            <Switch value={settings.dimScreen} onValueChange={(dimScreen) => settings.update({ dimScreen })} />
          </Row>
        </Section>

        <Section title={s.settings.about}>
          <Row
            icon="envelope.fill"
            color="#0a84ff"
            title={s.settings.contact}
            hint={CONTACT.email}
            onPress={() => Linking.openURL(contactMailUrl(s.appName, versionText))}
            accessibilityRole="link"
          >
            <Chevron />
          </Row>
          <Row
            icon="hand.raised.fill"
            color="#0a84ff"
            title={s.settings.privacy}
            onPress={() => router.push('/privacy')}
            accessibilityRole="link"
            border
          >
            <Chevron />
          </Row>
        </Section>

        <View style={styles.identity}>
          <Image source={require('../../assets/icon.png')} style={styles.appIcon} />
          <Text style={styles.appName}>{s.appName}</Text>
          <Text style={styles.appMeta}>
            {s.settings.version} {versionText}
          </Text>
          <Text style={styles.appMeta}>© 2026 {CONTACT.developer}</Text>
        </View>
      </View>
    </ScrollView>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <>
      <Text style={styles.sectionTitle}>{title}</Text>
      <View style={styles.section}>{children}</View>
    </>
  );
}

/** Ayarlar uygulamasındaki gibi satır: renkli simge kutusu, başlık, açıklama, sağda kontrol. */
function Row({
  icon,
  color,
  title,
  hint,
  warning = false,
  border = false,
  onPress,
  accessibilityRole,
  children,
}: {
  icon: SFSymbol;
  color: string;
  title: string;
  hint?: string;
  warning?: boolean;
  border?: boolean;
  onPress?: () => void;
  accessibilityRole?: 'link' | 'button';
  children?: ReactNode;
}) {
  return (
    <Pressable
      style={({ pressed }) => [styles.row, pressed && onPress && styles.rowPressed]}
      disabled={!onPress}
      onPress={onPress}
      accessibilityRole={onPress ? accessibilityRole ?? 'button' : undefined}
    >
      <View style={[styles.tile, { backgroundColor: color }]}>
        <SymbolView name={icon} size={17} weight="semibold" tintColor="#fff" />
      </View>
      <View style={[styles.rowBody, border && styles.rowBorder]}>
        <View style={styles.rowLabel}>
          <Text style={styles.rowText}>{title}</Text>
          {hint ? <Text style={[styles.hint, warning && styles.warning]}>{hint}</Text> : null}
        </View>
        {children}
      </View>
    </Pressable>
  );
}

function Chevron() {
  return <SymbolView name="chevron.right" size={14} weight="semibold" tintColor={C.tertiary} style={styles.chevron} />;
}

/** iOS segmentli seçici görünümü. */
function Segmented<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string; accessibilityLabel?: string }[];
  value: T;
  onChange: (value: T) => void;
}) {
  return (
    <View style={styles.segmented} accessibilityRole="tablist">
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <Pressable
            key={option.value}
            style={[styles.segment, selected && styles.segmentSelected]}
            onPress={() => onChange(option.value)}
            accessibilityRole="tab"
            accessibilityState={{ selected }}
            accessibilityLabel={option.accessibilityLabel}
          >
            <Text style={[styles.segmentText, selected && styles.segmentTextSelected]} numberOfLines={1}>
              {option.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

/** Ön+Arka düzeni: küçük bir çizimle (sahne dağ, yüz kişi simgesi). */
function LayoutCard({
  layout,
  label,
  selected,
  onPress,
}: {
  layout: Settings['layout'];
  label: string;
  selected: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      style={styles.layoutCard}
      onPress={onPress}
      accessibilityRole="radio"
      accessibilityState={{ selected }}
      accessibilityLabel={label}
    >
      <View style={[styles.diagram, selected && styles.diagramSelected]}>
        {layout === 'split' ? (
          <View style={styles.splitRow}>
            <View style={[styles.scene, styles.splitHalf]}>
              <SymbolView name="mountain.2.fill" size={20} tintColor="#8e8e93" />
            </View>
            <View style={[styles.face, styles.splitHalf]}>
              <SymbolView name="person.fill" size={18} tintColor="#d1d1d6" />
            </View>
          </View>
        ) : (
          <View style={styles.scene}>
            <SymbolView name="mountain.2.fill" size={22} tintColor="#8e8e93" />
            {layout === 'pip' ? (
              <View style={[styles.face, styles.pipWindow]}>
                <SymbolView name="person.fill" size={11} tintColor="#d1d1d6" />
              </View>
            ) : (
              <View style={styles.cutoutPerson}>
                <SymbolView name="person.fill" size={26} tintColor="#fff" />
              </View>
            )}
          </View>
        )}
        {selected && (
          <View style={styles.badge}>
            <SymbolView name="checkmark.circle.fill" size={18} tintColor={C.blue} />
          </View>
        )}
      </View>
      <Text style={[styles.layoutLabel, selected && styles.layoutLabelSelected]} numberOfLines={2}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: C.background },
  content: { paddingBottom: 40, alignItems: 'center' },
  column: { width: '100%', maxWidth: 680 },
  sectionTitle: { color: C.secondary, fontSize: 13, marginTop: 28, marginBottom: 7, marginLeft: 16, textTransform: 'uppercase' },
  section: { backgroundColor: C.card, borderRadius: 12, overflow: 'hidden' },

  // Simge, başlık ve anahtar ilk satırda hizalı (açıklama uzasa da simge ortada kalmaz).
  row: { flexDirection: 'row', alignItems: 'flex-start', paddingLeft: 16, minHeight: 52 },
  rowPressed: { backgroundColor: '#2c2c2e' },
  tile: { width: 30, height: 30, borderRadius: 7, alignItems: 'center', justifyContent: 'center', marginRight: 14, marginTop: 11 },
  // Ayırıcı çizgi simgeden sonra başlar (iOS Ayarlar gibi).
  rowBody: { flex: 1, flexDirection: 'row', alignItems: 'flex-start', gap: 12, paddingVertical: 10, paddingRight: 16, minHeight: 52 },
  rowBorder: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: C.separator },
  rowLabel: { flex: 1, gap: 2, paddingTop: 6, paddingBottom: 2 },
  rowText: { color: C.label, fontSize: 17, lineHeight: 22 },
  hint: { color: C.secondary, fontSize: 13, lineHeight: 17 },
  warning: { color: C.orange },
  chevron: { width: 14, height: 14, marginTop: 10 },

  segmentRow: { padding: 12 },
  segmented: { flexDirection: 'row', backgroundColor: C.fill, borderRadius: 9, padding: 2 },
  segment: { flex: 1, height: 30, borderRadius: 7, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 6 },
  segmentSelected: { backgroundColor: C.selectedFill },
  segmentText: { color: C.label, fontSize: 14, fontWeight: '500' },
  segmentTextSelected: { fontWeight: '600' },

  layouts: { flexDirection: 'row', justifyContent: 'center', gap: 10, paddingHorizontal: 12, paddingTop: 14 },
  // Yatayda kartlar çok büyümesin.
  layoutCard: { flex: 1, maxWidth: 170, alignItems: 'center', gap: 8 },
  diagram: { width: '100%', aspectRatio: 16 / 10, borderRadius: 10, padding: 3, borderWidth: 2, borderColor: 'transparent' },
  diagramSelected: { borderColor: C.blue },
  scene: { flex: 1, borderRadius: 7, backgroundColor: '#3a3a3c', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' },
  face: { backgroundColor: '#636366', alignItems: 'center', justifyContent: 'center' },
  pipWindow: { position: 'absolute', top: 6, right: 6, width: '32%', aspectRatio: 16 / 10, borderRadius: 4, borderWidth: 1, borderColor: '#fff' },
  cutoutPerson: { position: 'absolute', right: 8, bottom: -3 },
  splitRow: { flex: 1, flexDirection: 'row', gap: 2, borderRadius: 7, overflow: 'hidden' },
  splitHalf: { flex: 1, borderRadius: 0 },
  badge: { position: 'absolute', top: -7, right: -7, backgroundColor: C.card, borderRadius: 10 },
  layoutLabel: { color: C.secondary, fontSize: 13, fontWeight: '500', textAlign: 'center' },
  layoutLabelSelected: { color: C.label, fontWeight: '600' },
  layoutHint: { color: C.secondary, fontSize: 13, lineHeight: 17, paddingHorizontal: 16, paddingTop: 12, paddingBottom: 14 },

  identity: { alignItems: 'center', marginTop: 36, gap: 4 },
  appIcon: { width: 60, height: 60, borderRadius: 14, marginBottom: 8 },
  appName: { color: C.label, fontSize: 15, fontWeight: '600' },
  appMeta: { color: C.tertiary, fontSize: 12 },
});
