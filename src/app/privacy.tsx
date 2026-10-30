import { StatusBar } from 'expo-status-bar';
import { ScrollView, StyleSheet, Text } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { CONTACT } from '../contact';
import { fill, useStrings } from '../i18n';

/** Uygulama içi gizlilik politikası (web sürümüyle aynı içerik: docs/dualcam-privacy-policy.html). */
export default function PrivacyScreen() {
  const s = useStrings();
  const insets = useSafeAreaInsets();

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={[
        styles.content,
        { paddingLeft: Math.max(insets.left, 20), paddingRight: Math.max(insets.right, 20) },
      ]}
      contentInsetAdjustmentBehavior="automatic"
    >
      <StatusBar style="light" />
      <Text style={styles.updated}>{s.privacy.updated}</Text>
      {s.privacy.sections.map(([title, body]) => (
        <Text key={title} style={styles.paragraph}>
          <Text style={styles.heading}>{title}{'\n'}</Text>
          {fill(body, { developer: CONTACT.developer, email: CONTACT.email })}
        </Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#000' },
  content: { paddingTop: 16, paddingBottom: 40, gap: 18 },
  updated: { color: '#8e8e93', fontSize: 13 },
  paragraph: { color: '#d1d1d6', fontSize: 15, lineHeight: 22 },
  heading: { color: '#fff', fontSize: 17, fontWeight: '600' },
});
