import * as ScreenOrientation from 'expo-screen-orientation';
import { StatusBar } from 'expo-status-bar';
import { ReactNode, useEffect, useRef, useState } from 'react';
import { Linking, Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';

import {
  CameraMode,
  DualCameraRef,
  DualCameraView,
  isSupported,
  requestPermissions,
} from './modules/dual-camera';

const { Orientation, OrientationLock } = ScreenOrientation;

type Mic = { name: string; external: boolean };
type Mode = 'landscape' | 'portrait';

const CAMERA_LABELS: Record<CameraMode, string> = { both: 'Ön+Arka', back: 'Arka', front: 'Ön' };
const NEXT_CAMERA: Record<CameraMode, CameraMode> = { both: 'back', back: 'front', front: 'both' };

function formatTime(sec: number) {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

/** Sahne (arka kamera) ve yüz ayrı video olarak kaydedilir. */
function savedText(files: number, duration: number) {
  const what = files >= 2 ? '2 video (sahne + yüz)' : 'Video';
  return `${what} galeriye kaydedildi (${formatTime(duration)})`;
}

/** Kayıt boyunca ekranı o anki yönde sabitle; video ortasında dönmesin. */
async function lockCurrentOrientation() {
  const current = await ScreenOrientation.getOrientationAsync();
  const lock =
    current === Orientation.LANDSCAPE_LEFT
      ? OrientationLock.LANDSCAPE_LEFT
      : current === Orientation.LANDSCAPE_RIGHT
        ? OrientationLock.LANDSCAPE_RIGHT
        : OrientationLock.PORTRAIT_UP;
  await ScreenOrientation.lockAsync(lock);
}

export default function App() {
  const camera = useRef<DualCameraRef>(null);
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const [mode, setMode] = useState<Mode>('landscape');
  const [cameras, setCameras] = useState<CameraMode>('both');
  const [permission, setPermission] = useState<'pending' | 'ok' | 'denied'>('pending');
  const [recording, setRecording] = useState(false);
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [mic, setMic] = useState<Mic | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  useEffect(() => {
    requestPermissions().then(({ camera, microphone }) =>
      setPermission(camera && microphone ? 'ok' : 'denied'),
    );
  }, []);

  // Kayıt yokken ekran seçilen moda göre döner (yatayda sol/sağ ikisi de olur).
  useEffect(() => {
    if (recording) return;
    ScreenOrientation.lockAsync(
      mode === 'landscape' ? OrientationLock.LANDSCAPE : OrientationLock.PORTRAIT_UP,
    );
  }, [mode, recording]);

  useEffect(() => {
    if (!recording) return;
    const started = Date.now();
    setElapsed(0);
    const id = setInterval(() => setElapsed((Date.now() - started) / 1000), 250);
    return () => clearInterval(id);
  }, [recording]);

  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(null), 3000);
    return () => clearTimeout(id);
  }, [toast]);

  async function toggleRecording() {
    if (!camera.current || busy) return;
    setBusy(true);
    try {
      if (recording) {
        setRecording(false);
        const { duration, files } = await camera.current.stopRecording();
        setToast(savedText(files, duration));
      } else {
        await lockCurrentOrientation();
        await camera.current.startRecording();
        setRecording(true);
      }
    } catch (e: any) {
      setRecording(false);
      setToast(e?.message ?? 'Bir hata oluştu');
    } finally {
      setBusy(false);
    }
  }

  if (!isSupported()) {
    return <Message text="Bu cihaz ön ve arka kamerayı aynı anda desteklemiyor." />;
  }
  if (permission === 'pending') {
    return <Message text="İzinler bekleniyor…" />;
  }
  if (permission === 'denied') {
    return (
      <Message text="Kamera ve mikrofon izni gerekli.">
        <Pressable style={styles.settingsButton} onPress={() => Linking.openSettings()}>
          <Text style={styles.settingsText}>Ayarları aç</Text>
        </Pressable>
      </Message>
    );
  }

  return (
    <View style={styles.container}>
      <StatusBar hidden />
      <DualCameraView
        ref={camera}
        cameras={cameras}
        style={StyleSheet.absoluteFill}
        onMicChange={(e) => setMic(e.nativeEvent)}
        onCameraError={(e) => setToast(e.nativeEvent.message)}
        onAutoStopped={(e) => {
          setRecording(false);
          const { saved, duration, files, error } = e.nativeEvent;
          setToast(saved ? `Kayıt durdu. ${savedText(files ?? 0, duration ?? 0)}` : error ?? 'Kayıt durdu');
        }}
      />

      <View style={[styles.top, landscape ? styles.topLandscape : styles.topPortrait]} pointerEvents="none">
        {mic && (
          <View style={[styles.pill, { backgroundColor: mic.external ? '#1f9d55cc' : '#d97706cc' }]}>
            <Text style={styles.pillText}>
              🎤 {mic.external ? mic.name : 'iPhone mikrofonu (yaka mikrofonu takılı değil)'}
            </Text>
          </View>
        )}
        {recording && (
          <View style={[styles.pill, styles.timer]}>
            <View style={styles.dot} />
            <Text style={styles.pillText}>{formatTime(elapsed)}</Text>
          </View>
        )}
      </View>

      {toast && (
        <View style={[styles.toastWrap, { bottom: landscape ? 24 : 150 }]} pointerEvents="none">
          <Text style={styles.toast}>{toast}</Text>
        </View>
      )}

      <View style={landscape ? styles.controlsLandscape : styles.controlsPortrait}>
        <View style={styles.side}>
          {!recording && (
            <Pressable style={styles.modeButton} onPress={() => setCameras(NEXT_CAMERA[cameras])}>
              <Text style={styles.modeText}>{CAMERA_LABELS[cameras]}</Text>
            </Pressable>
          )}
        </View>
        <Pressable
          onPress={toggleRecording}
          disabled={busy}
          style={[styles.recordOuter, busy && { opacity: 0.5 }]}
        >
          <View style={recording ? styles.recordStop : styles.recordInner} />
        </Pressable>
        <View style={styles.side}>
          {!recording && (
            <Pressable
              style={styles.modeButton}
              onPress={() => setMode(mode === 'landscape' ? 'portrait' : 'landscape')}
            >
              <Text style={styles.modeText}>{mode === 'landscape' ? 'Yatay' : 'Dikey'}</Text>
            </Pressable>
          )}
        </View>
      </View>
    </View>
  );
}

function Message({ text, children }: { text: string; children?: ReactNode }) {
  return (
    <View style={[styles.container, styles.center]}>
      <StatusBar style="light" />
      <Text style={styles.message}>{text}</Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  center: { alignItems: 'center', justifyContent: 'center', padding: 24 },
  message: { color: '#fff', fontSize: 17, textAlign: 'center' },
  settingsButton: { marginTop: 16, paddingHorizontal: 20, paddingVertical: 10, backgroundColor: '#fff', borderRadius: 20 },
  settingsText: { color: '#000', fontWeight: '600' },
  top: { position: 'absolute', gap: 8, alignItems: 'flex-start' },
  topPortrait: { top: 54, left: 12, right: 12 },
  topLandscape: { top: 16, left: 96, right: 96 },
  pill: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, paddingVertical: 6, borderRadius: 16 },
  pillText: { color: '#fff', fontSize: 14, fontWeight: '600' },
  timer: { backgroundColor: '#000a' },
  dot: { width: 10, height: 10, borderRadius: 5, backgroundColor: '#ef4444', marginRight: 8 },
  toastWrap: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  toast: { color: '#fff', backgroundColor: '#000b', paddingHorizontal: 14, paddingVertical: 8, borderRadius: 12, overflow: 'hidden' },
  controlsPortrait: {
    position: 'absolute', bottom: 40, left: 0, right: 0,
    flexDirection: 'row', justifyContent: 'center', alignItems: 'center', gap: 28,
  },
  controlsLandscape: {
    position: 'absolute', right: 24, top: 0, bottom: 0,
    flexDirection: 'column-reverse', justifyContent: 'center', alignItems: 'center', gap: 28,
  },
  side: { width: 64, height: 64, alignItems: 'center', justifyContent: 'center' },
  modeButton: { width: 64, height: 64, borderRadius: 32, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  modeText: { color: '#fff', fontSize: 13, fontWeight: '700' },
  recordOuter: { width: 78, height: 78, borderRadius: 39, borderWidth: 5, borderColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  recordInner: { width: 60, height: 60, borderRadius: 30, backgroundColor: '#ef4444' },
  recordStop: { width: 30, height: 30, borderRadius: 6, backgroundColor: '#ef4444' },
});
