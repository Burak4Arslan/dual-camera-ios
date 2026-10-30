import { DarkTheme, Stack, ThemeProvider } from 'expo-router';
import { useEffect } from 'react';

import { useStrings } from '../i18n';
import { SettingsProvider } from '../settings';
import QuickLaunch from '../widgets/QuickLaunch';

function RootStack() {
  const s = useStrings();
  // Widget yazıları uygulamanın dilinde olsun (dil değişince de güncellenir).
  useEffect(() => {
    QuickLaunch.updateSnapshot({ title: s.appName, subtitle: s.widgetSubtitle });
  }, [s]);
  return (
    <Stack>
      <Stack.Screen name="index" options={{ headerShown: false }} />
      <Stack.Screen name="settings" options={{ presentation: 'modal', title: s.settings.title }} />
      <Stack.Screen name="privacy" options={{ presentation: 'modal', title: s.privacy.title }} />
    </Stack>
  );
}

export default function RootLayout() {
  return (
    <SettingsProvider>
      <ThemeProvider value={DarkTheme}>
        <RootStack />
      </ThemeProvider>
    </SettingsProvider>
  );
}
