import Storage from 'expo-sqlite/kv-store';
import { useState } from 'react';

/**
 * Ekrandaki son seçim (kamera, yatay/dikey, video/foto): uygulama yeniden açılınca aynısıyla başlar.
 * Ayarlarda ayrı bir seçenek yok, her değişiklik sessizce kaydedilir. Açılışta eşzamanlı okunur;
 * ilk karede doğru kamera açılır. Kayıtlı değer `allowed` içinde değilse (eski sürüm) varsayılan.
 */
export function useRemembered<T extends string>(key: string, fallback: T, allowed: readonly T[]) {
  const storageKey = `last.${key}`;
  const [value, setValue] = useState<T>(() => {
    try {
      const saved = Storage.getItemSync(storageKey);
      return saved && (allowed as readonly string[]).includes(saved) ? (saved as T) : fallback;
    } catch {
      return fallback;
    }
  });

  function set(next: T) {
    setValue(next);
    try {
      Storage.setItemSync(storageKey, next);
    } catch {
      // Kaydedilemezse yalnızca bu oturumda geçerli kalır.
    }
  }

  return [value, set] as const;
}
