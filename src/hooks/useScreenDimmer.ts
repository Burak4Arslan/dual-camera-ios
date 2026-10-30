import { useCallback, useEffect, useRef } from 'react';
import { AppState } from 'react-native';

import { setScreenBrightness } from '../../modules/dual-camera';

const DIM_AFTER_MS = 30_000;

/**
 * Uzun çekimde pil için: `enabled` iken 30 sn dokunulmazsa ekran parlaklığı düşer, görüntü görünür
 * kalır. Dönen `wake` her dokunuşta çağrılmalı: parlaklığı geri getirir ve sayacı baştan başlatır.
 */
export function useScreenDimmer(enabled: boolean) {
  const enabledRef = useRef(enabled);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const dimmed = useRef(false);

  const undim = useCallback(() => {
    clearTimeout(timer.current);
    if (dimmed.current) {
      dimmed.current = false;
      setScreenBrightness('normal');
    }
  }, []);

  const wake = useCallback(() => {
    undim();
    if (!enabledRef.current) return;
    timer.current = setTimeout(() => {
      dimmed.current = true;
      setScreenBrightness('dim');
    }, DIM_AFTER_MS);
  }, [undim]);

  useEffect(() => {
    enabledRef.current = enabled;
    if (enabled) wake();
    else undim();
  }, [enabled, wake, undim]);

  // Uygulamadan çıkınca iOS parlaklığı geri yükler; dönünce sayaç baştan başlasın.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') wake();
    });
    return () => {
      sub.remove();
      undim();
    };
  }, [wake, undim]);

  return wake;
}
