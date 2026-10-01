import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';

import { getFreeSpace } from '../../modules/dual-camera';

/** Video dosyası başına: 16 Mbit/s HEVC + ses. */
const VIDEO_BYTES_PER_SECOND = 2_050_000;
/** En yüksek kalitede bir HEIC foto (12 MP) için pay bırakılmış boyut. */
const PHOTO_BYTES = 4_000_000;

/** Ekran açıkken 10 sn'de bir kullanılabilir alanı okur (bayt); okunamazsa null. */
export function useFreeSpace() {
  const [free, setFree] = useState<number | null>(null);

  useFocusEffect(
    useCallback(() => {
      const read = () => getFreeSpace().then(setFree, () => setFree(null));
      read();
      const id = setInterval(read, 10_000);
      return () => clearInterval(id);
    }, []),
  );

  return free;
}

/**
 * Kalan video süresi (sn). Video önce geçici dosyaya yazılıp sonra galeriye kopyalandığı için
 * kayıt sonunda iki katı yer gerekir. `files`: aynı anda yazılan dosya sayısı (Ön+Arka ayrı = 2).
 */
export function videoSecondsLeft(free: number, files: number) {
  return free / (2 * files * VIDEO_BYTES_PER_SECOND);
}

/** Kalan foto sayısı; `files`: bir çekimdeki foto sayısı (Ön+Arka = 2). */
export function photosLeft(free: number, files: number) {
  return Math.floor(free / (files * PHOTO_BYTES));
}
