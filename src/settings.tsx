import Storage from 'expo-sqlite/kv-store';
import { createContext, ReactNode, useContext, useState } from 'react';

import type { Language } from './i18n/strings';

export type Settings = {
  /** `system`: telefonun dili (desteklenmiyorsa İngilizce). */
  language: 'system' | Language;
  grid: boolean;
  shutterEffect: boolean;
};

const DEFAULTS: Settings = { language: 'system', grid: false, shutterEffect: true };
const KEY = 'settings';

/** Açılışta eşzamanlı okunur; ilk karede ayarlar hazır olur (dil titremez). */
function load(): Settings {
  try {
    const saved = Storage.getItemSync(KEY);
    return saved ? { ...DEFAULTS, ...JSON.parse(saved) } : DEFAULTS;
  } catch {
    return DEFAULTS;
  }
}

type SettingsContextValue = Settings & { update(patch: Partial<Settings>): void };

const SettingsContext = createContext<SettingsContextValue | null>(null);

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState(load);

  function update(patch: Partial<Settings>) {
    const next = { ...settings, ...patch };
    setSettings(next);
    Storage.setItemSync(KEY, JSON.stringify(next));
  }

  return <SettingsContext.Provider value={{ ...settings, update }}>{children}</SettingsContext.Provider>;
}

export function useSettings() {
  const value = useContext(SettingsContext);
  if (!value) throw new Error('useSettings, SettingsProvider içinde kullanılmalı');
  return value;
}
