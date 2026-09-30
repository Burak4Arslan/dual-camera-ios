import { DarkTheme, Stack, ThemeProvider } from 'expo-router';

import { useStrings } from '../i18n';
import { SettingsProvider } from '../settings';

function RootStack() {
  const s = useStrings();
  return (
    <Stack>
      <Stack.Screen name="index" options={{ headerShown: false }} />
      <Stack.Screen name="settings" options={{ presentation: 'modal', title: s.settings.title }} />
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
