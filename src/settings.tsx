import Storage from 'expo-sqlite/kv-store';
import { createContext, ReactNode, useContext, useState } from 'react';

import type { DualLayout, PipPosition } from '../modules/dual-camera';
import type { Language } from './i18n/strings';

export type Settings = {
  /** `system`: telefonun dili (desteklenmiyorsa İngilizce). */
  language: 'system' | Language;
  grid: boolean;
  shutterEffect: boolean;
  /** Ön+Arka videoyu tek dosya yap (yüz sahnenin köşesinde); kapalıyken iki ayrı video. */
  combineVideo: boolean;
  /** Kayıt ya da aralıklı çekimde 30 sn dokunulmazsa parlaklığı düşür. */
  dimScreen: boolean;
  /** Yüz penceresinin son yeri; null = sağ üst köşe. */
  pipPosition: PipPosition | null;
  /** Ön+Arka düzeni: küçük pencere ya da bölünmüş ekran (önizleme ve tek video). */
  layout: DualLayout;
  /** Ses tuşlarıyla çekim: ses kısma çek / durdur, ses açma kayıtta foto. */
  volumeButtons: boolean;
  /** Ön kamera açıkken lensin yanında görüntünün küçük kopyası (kaydedilmez). */
  eyeContact: boolean;
  /** Kaydedilen sesteki sürekli hışırtıyı temizle. Varsayılan kapalı: ham ses, sonradan
   * CapCut gibi bir programla (ör. Isolate voice) çok daha iyi temizleniyor. */
  noiseReduction: boolean;
};

const DEFAULTS: Settings = {
  language: 'system',
  grid: false,
  shutterEffect: true,
  combineVideo: false,
  dimScreen: true,
  pipPosition: null,
  layout: 'pip',
  volumeButtons: true,
  eyeContact: true,
  noiseReduction: false,
};
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
