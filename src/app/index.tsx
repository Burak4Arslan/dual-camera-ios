import * as ScreenOrientation from 'expo-screen-orientation';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { ReactNode, useEffect, useRef, useState } from 'react';
import { Animated, Linking, Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  CameraMode,
  CaptureMode,
  DualCameraRef,
  DualCameraView,
  isSupported,
  requestPermissions,
} from '../../modules/dual-camera';
import { errorText, fill, useStrings } from '../i18n';
import type { Strings } from '../i18n/strings';
import { useSettings } from '../settings';

const { Orientation, OrientationLock } = ScreenOrientation;

type Mic = { name: string; external: boolean };
type Mode = 'landscape' | 'portrait';

const NEXT_CAMERA: Record<CameraMode, CameraMode> = { both: 'back', back: 'front', front: 'both' };
const CAPTURE_MODES: CaptureMode[] = ['video', 'photo'];
/** Aralıklı çekim seçenekleri (saniye). 0 = kapalı: deklanşör tek foto çeker. */
const INTERVALS = [0, 1, 2, 3, 5, 10, 30, 60];

function formatTime(sec: number) {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

/** Sahne (arka kamera) ve yüz ayrı video olarak kaydedilir. */
function savedText(s: Strings, files: number, duration: number) {
  return fill(files >= 2 ? s.saved.videos : s.saved.video, { time: formatTime(duration) });
}

function intervalText(s: Strings, sec: number) {
  return sec ? fill(s.interval.seconds, { n: sec }) : s.interval.off;
}

/** Çekilen karenin ekrandaki yeri; önizleme kareyi ekrana sığdırır (video 16:9, foto 4:3). */
function frameRect(width: number, height: number, capture: CaptureMode) {
  const ratio = capture === 'photo' ? 4 / 3 : 16 / 9;
  const aspect = width > height ? ratio : 1 / ratio;
  const w = Math.min(width, height * aspect);
  const h = w / aspect;
  return { left: (width - w) / 2, top: (height - h) / 2, width: w, height: h };
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

export default function CameraScreen() {
  const s = useStrings();
  const settings = useSettings();
  const insets = useSafeAreaInsets();
  const camera = useRef<DualCameraRef>(null);
  const shutterBlink = useRef(new Animated.Value(0)).current;
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const [mode, setMode] = useState<Mode>('landscape');
  const [capture, setCapture] = useState<CaptureMode>('video');
  const [cameras, setCameras] = useState<CameraMode>('both');
  const [torch, setTorch] = useState(false);
  const [intervalSec, setIntervalSec] = useState(0);
  const [intervalPicker, setIntervalPicker] = useState(false);
  const [permission, setPermission] = useState<'pending' | 'ok' | 'denied'>('pending');
  const [micAllowed, setMicAllowed] = useState(true);
  const [recording, setRecording] = useState(false);
  const [shooting, setShooting] = useState(false);
  const [photos, setPhotos] = useState(0);
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [mic, setMic] = useState<Mic | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  /** Video kaydı ya da aralıklı çekim sürüyor; ayarlar kilitli. */
  const active = recording || shooting;

  // Kenar boşlukları telefona göre (çentik, Dynamic Island, ana ekran çubuğu).
  const edge = {
    top: Math.max(insets.top, 12),
    bottom: Math.max(insets.bottom, 16),
    left: Math.max(insets.left, 12),
    right: Math.max(insets.right, 12),
  };
  const controlsBottom = edge.bottom + 6;
  const captureBottom = landscape ? edge.bottom : controlsBottom + 96;

  // Mikrofon isteğe bağlı: izin yoksa video sessiz kaydedilir.
  useEffect(() => {
    requestPermissions().then(({ camera, microphone }) => {
      setPermission(camera ? 'ok' : 'denied');
      setMicAllowed(microphone);
    });
  }, []);

  // Çekim yokken ekran seçilen moda göre döner (yatayda sol/sağ ikisi de olur).
  useEffect(() => {
    if (active) return;
    ScreenOrientation.lockAsync(
      mode === 'landscape' ? OrientationLock.LANDSCAPE : OrientationLock.PORTRAIT_UP,
    );
  }, [mode, active]);

  useEffect(() => {
    if (!active) return;
    const started = Date.now();
    setElapsed(0);
    const id = setInterval(() => setElapsed((Date.now() - started) / 1000), 250);
    return () => clearInterval(id);
  }, [active]);

  /** Foto çekildiğini belli et: iPhone kamerası gibi görüntü bir an kararıp açılır. */
  function blink() {
    if (!settings.shutterEffect) return;
    shutterBlink.setValue(1);
    Animated.timing(shutterBlink, { toValue: 0, duration: 250, useNativeDriver: true }).start();
  }

  /** Native söz (promise) hatası: `code` çeviri anahtarı, `message` sistem ayrıntısı. */
  function failText(e: any) {
    return errorText(s, e?.code, e?.message);
  }

  // Aralıklı çekim: ilk foto hemen, sonra durdurana kadar her `intervalSec` saniyede bir.
  // Tek bir foto hata verirse çekim sürer (telefon başında kimse olmayabilir).
  useEffect(() => {
    if (!shooting) return;
    const shoot = () => {
      blink();
      camera.current
        ?.takePhoto()
        .then(({ files }) => setPhotos((n) => n + files))
        .catch((e) => setToast(failText(e)));
    };
    shoot();
    const id = setInterval(shoot, intervalSec * 1000);
    return () => clearInterval(id);
  }, [shooting, intervalSec]);

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
        setToast(savedText(s, files, duration));
      } else {
        await lockCurrentOrientation();
        await camera.current.startRecording();
        setRecording(true);
      }
    } catch (e) {
      setRecording(false);
      setToast(failText(e));
    } finally {
      setBusy(false);
    }
  }

  async function takePhoto() {
    if (!camera.current || busy) return;
    setBusy(true);
    blink();
    try {
      const { files } = await camera.current.takePhoto();
      setToast(files >= 2 ? s.saved.photos : s.saved.photo);
    } catch (e) {
      setToast(failText(e));
    } finally {
      setBusy(false);
    }
  }

  async function toggleShooting() {
    if (shooting) {
      setShooting(false);
      setToast(fill(s.saved.shootingStopped, { n: photos }));
      return;
    }
    await lockCurrentOrientation();
    setPhotos(0);
    setShooting(true);
  }

  function onShutter() {
    setIntervalPicker(false);
    if (capture === 'video') toggleRecording();
    else if (intervalSec > 0) toggleShooting();
    else takePhoto();
  }

  if (!isSupported()) {
    return <Message text={s.start.notSupported} />;
  }
  if (permission === 'pending') {
    return <Message text={s.start.waiting} />;
  }
  if (permission === 'denied') {
    return (
      <Message text={s.start.cameraDenied}>
        <Pressable style={styles.settingsButton} onPress={() => Linking.openSettings()}>
          <Text style={styles.settingsText}>{s.start.openSettings}</Text>
        </Pressable>
      </Message>
    );
  }

  // Boyut pencereden: RN'in kök view'i ekran dönünce bir önceki yönün boyutunda kalabiliyor,
  // `flex: 1` ile her şey o eski kutuya yerleşip köşeye kayıyordu.
  return (
    <View style={[styles.screen, { width, height }]}>
      <StatusBar hidden />
      <DualCameraView
        ref={camera}
        cameras={cameras}
        captureMode={capture}
        torch={torch}
        style={StyleSheet.absoluteFill}
        onMicChange={(e) => setMic(e.nativeEvent)}
        onCameraError={(e) => setToast(errorText(s, e.nativeEvent.code, e.nativeEvent.detail))}
        onAutoStopped={(e) => {
          setRecording(false);
          const { saved, duration, files, code, detail } = e.nativeEvent;
          setToast(
            saved
              ? `${s.saved.recordingStopped} ${savedText(s, files ?? 0, duration ?? 0)}`
              : errorText(s, code, detail),
          );
        }}
      />
      {settings.grid && <Grid rect={frameRect(width, height, capture)} />}
      <Animated.View style={[StyleSheet.absoluteFill, styles.blink, { opacity: shutterBlink }]} pointerEvents="none" />

      <View
        style={[
          styles.top,
          landscape
            ? { top: edge.top + 4, left: edge.left + 12, right: edge.right + 12 }
            : { top: edge.top + 6, left: edge.left, right: edge.right },
        ]}
        pointerEvents="box-none"
      >
        {!active && (
          <Pressable style={styles.roundButton} onPress={() => router.push('/settings')}>
            <Text style={styles.roundText}>⚙️</Text>
          </Pressable>
        )}
        {/* Işık yalnızca arka kamerada var; kayıt sırasında da açılıp kapanabilir. */}
        {cameras !== 'front' && (
          <Pressable style={[styles.roundButton, torch && styles.torchOn]} onPress={() => setTorch(!torch)}>
            <Text style={styles.roundText}>🔦</Text>
          </Pressable>
        )}
        <View style={styles.pills} pointerEvents="box-none">
          {/* Foto seçenekleri; yenileri de buraya eklenir. */}
          {capture === 'photo' && !active && (
            <Pressable style={[styles.pill, styles.option]} onPress={() => setIntervalPicker(!intervalPicker)}>
              <Text style={styles.pillText}>
                ⏱ {s.interval.label}: {intervalText(s, intervalSec)}
              </Text>
            </Pressable>
          )}
          {capture === 'photo' && !active && intervalPicker && (
            <View style={styles.chips}>
              {INTERVALS.map((sec) => (
                <Pressable
                  key={sec}
                  style={[styles.pill, styles.option, sec === intervalSec && styles.chipOn]}
                  onPress={() => {
                    setIntervalSec(sec);
                    setIntervalPicker(false);
                  }}
                >
                  <Text style={[styles.pillText, sec === intervalSec && styles.chipTextOn]}>
                    {intervalText(s, sec)}
                  </Text>
                </Pressable>
              ))}
            </View>
          )}
          {capture === 'video' && !micAllowed && (
            <View style={[styles.pill, styles.micWarning]}>
              <Text style={styles.pillText}>🎤 {s.mic.denied}</Text>
            </View>
          )}
          {capture === 'video' && micAllowed && mic && (
            <View style={[styles.pill, mic.external ? styles.micExternal : styles.option]}>
              <Text style={styles.pillText}>🎤 {mic.external ? mic.name : s.mic.builtIn}</Text>
            </View>
          )}
          {active && (
            <View style={[styles.pill, styles.option]}>
              <View style={styles.dot} />
              <Text style={styles.pillText}>
                {formatTime(elapsed)}
                {shooting ? ` · ${fill(s.saved.photoCount, { n: photos })}` : ''}
              </Text>
            </View>
          )}
        </View>
      </View>

      {toast && (
        <View style={[styles.toastWrap, { bottom: captureBottom + 50 }]} pointerEvents="none">
          <Text style={styles.toast}>{toast}</Text>
        </View>
      )}

      {!active && (
        <View style={[styles.captureWrap, { bottom: captureBottom }]} pointerEvents="box-none">
          <View style={styles.captureSwitch}>
            {CAPTURE_MODES.map((c) => (
              <Pressable
                key={c}
                style={[styles.captureTab, capture === c && styles.captureTabOn]}
                onPress={() => {
                  setCapture(c);
                  setIntervalPicker(false);
                }}
              >
                <Text style={[styles.captureText, capture === c && styles.captureTextOn]}>
                  {s.capture[c]}
                </Text>
              </Pressable>
            ))}
          </View>
        </View>
      )}

      <View
        style={
          landscape
            ? [styles.controlsLandscape, { right: edge.right }]
            : [styles.controlsPortrait, { bottom: controlsBottom }]
        }
      >
        <View style={styles.side}>
          {!active && (
            <Pressable style={styles.modeButton} onPress={() => setCameras(NEXT_CAMERA[cameras])}>
              <Text style={styles.modeText}>{s.camera[cameras]}</Text>
            </Pressable>
          )}
        </View>
        <Pressable
          onPress={onShutter}
          disabled={busy}
          style={[styles.recordOuter, busy && { opacity: 0.5 }]}
        >
          {active ? (
            <View style={styles.recordStop} />
          ) : capture === 'video' ? (
            <View style={styles.recordInner} />
          ) : (
            <View style={styles.photoInner}>
              {intervalSec > 0 && <Text style={styles.photoInnerText}>{intervalText(s, intervalSec)}</Text>}
            </View>
          )}
        </Pressable>
        <View style={styles.side}>
          {!active && (
            <Pressable
              style={styles.modeButton}
              onPress={() => setMode(mode === 'landscape' ? 'portrait' : 'landscape')}
            >
              <Text style={styles.modeText}>{s.orientation[mode]}</Text>
            </Pressable>
          )}
        </View>
      </View>
    </View>
  );
}

/** Üçte bir kuralı çizgileri; kaydedilen karenin üstüne. */
function Grid({ rect }: { rect: ReturnType<typeof frameRect> }) {
  return (
    <View style={[styles.grid, rect]} pointerEvents="none">
      <View style={[styles.gridLine, styles.gridV, { left: '33.33%' }]} />
      <View style={[styles.gridLine, styles.gridV, { left: '66.67%' }]} />
      <View style={[styles.gridLine, styles.gridH, { top: '33.33%' }]} />
      <View style={[styles.gridLine, styles.gridH, { top: '66.67%' }]} />
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
  screen: { backgroundColor: '#000' },
  blink: { backgroundColor: '#000' },
  center: { alignItems: 'center', justifyContent: 'center', padding: 24 },
  message: { color: '#fff', fontSize: 17, textAlign: 'center' },
  settingsButton: { marginTop: 16, paddingHorizontal: 20, paddingVertical: 10, backgroundColor: '#fff', borderRadius: 20 },
  settingsText: { color: '#000', fontWeight: '600' },
  grid: { position: 'absolute' },
  gridLine: { position: 'absolute', backgroundColor: '#ffffff66' },
  gridV: { top: 0, bottom: 0, width: StyleSheet.hairlineWidth },
  gridH: { left: 0, right: 0, height: StyleSheet.hairlineWidth },
  top: { position: 'absolute', flexDirection: 'row', gap: 8, alignItems: 'flex-start' },
  pills: { flexShrink: 1, gap: 8, alignItems: 'flex-start' },
  roundButton: { width: 40, height: 40, borderRadius: 20, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  roundText: { fontSize: 18 },
  torchOn: { backgroundColor: '#facc15' },
  pill: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, paddingVertical: 6, borderRadius: 16 },
  pillText: { color: '#fff', fontSize: 14, fontWeight: '600' },
  option: { backgroundColor: '#000a' },
  micExternal: { backgroundColor: '#1f9d55cc' },
  micWarning: { backgroundColor: '#d97706cc' },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  chipOn: { backgroundColor: '#facc15' },
  chipTextOn: { color: '#000' },
  dot: { width: 10, height: 10, borderRadius: 5, backgroundColor: '#ef4444', marginRight: 8 },
  toastWrap: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  toast: { color: '#fff', backgroundColor: '#000b', paddingHorizontal: 14, paddingVertical: 8, borderRadius: 12, overflow: 'hidden' },
  captureWrap: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  captureSwitch: { flexDirection: 'row', backgroundColor: '#000a', borderRadius: 18, padding: 3 },
  captureTab: { paddingHorizontal: 16, paddingVertical: 6, borderRadius: 15 },
  captureTabOn: { backgroundColor: '#fff' },
  captureText: { color: '#fff', fontSize: 13, fontWeight: '700' },
  captureTextOn: { color: '#000' },
  controlsPortrait: {
    position: 'absolute', left: 0, right: 0,
    flexDirection: 'row', justifyContent: 'center', alignItems: 'center', gap: 28,
  },
  controlsLandscape: {
    position: 'absolute', top: 0, bottom: 0,
    flexDirection: 'column-reverse', justifyContent: 'center', alignItems: 'center', gap: 28,
  },
  side: { width: 64, height: 64, alignItems: 'center', justifyContent: 'center' },
  modeButton: { width: 64, height: 64, borderRadius: 32, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  modeText: { color: '#fff', fontSize: 12, fontWeight: '700', textAlign: 'center' },
  recordOuter: { width: 78, height: 78, borderRadius: 39, borderWidth: 5, borderColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  recordInner: { width: 60, height: 60, borderRadius: 30, backgroundColor: '#ef4444' },
  recordStop: { width: 30, height: 30, borderRadius: 6, backgroundColor: '#ef4444' },
  photoInner: { width: 60, height: 60, borderRadius: 30, backgroundColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  photoInnerText: { color: '#000', fontSize: 13, fontWeight: '700' },
});
