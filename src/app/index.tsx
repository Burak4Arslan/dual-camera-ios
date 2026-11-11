import * as ScreenOrientation from 'expo-screen-orientation';
import { router, useFocusEffect } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { ReactNode, useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Linking,
  PanResponder,
  Pressable,
  StyleProp,
  StyleSheet,
  Text,
  TextStyle,
  useWindowDimensions,
  View,
} from 'react-native';
import { EdgeInsets, useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  CameraMode,
  CaptureMode,
  DualCameraRef,
  InterfaceOrientation,
  DualCameraView,
  getInterfaceOrientation,
  isSupported,
  recoverRecordings,
  requestPermissions,
  setScreenBrightness,
} from '../../modules/dual-camera';
import { errorText, fill, useLanguage, useStrings } from '../i18n';
import type { Language, Strings } from '../i18n/strings';
import { photosLeft, useFreeSpace, videoSecondsLeft } from '../hooks/useFreeSpace';
import { useRemembered } from '../hooks/useRemembered';
import { useScreenDimmer } from '../hooks/useScreenDimmer';
import { useSettings } from '../settings';

const { OrientationLock } = ScreenOrientation;

type Mic = { name: string; external: boolean };
type Mode = 'landscape' | 'portrait';

const NEXT_CAMERA: Record<CameraMode, CameraMode> = { both: 'back', back: 'front', front: 'both' };
const CAPTURE_MODES: CaptureMode[] = ['video', 'photo'];
/** Aralıklı çekim seçenekleri (saniye). 0 = kapalı: deklanşör tek foto çeker. */
const INTERVALS = [0, 1, 2, 3, 5, 10, 30, 60];
/** Kamera açılana kadarki varsayılan sınır; gerçeğini cihaza göre native taraf bildirir (onZoomRange). */
const MAX_ZOOM = 10;
/** Hızlı yakınlaştırma düğmeleri; cihazın aralığında olanlar gösterilir, sonuna "Maks" eklenir. */
const ZOOM_PRESETS = [0.5, 1, 2, 5, 10];
/** Yakınlaştırma düğmelerinin üstünde parmak bu kadar (pt) sağa kayınca yakınlaştırma iki katına çıkar. */
const ZOOM_SCRUB_DOUBLING = 70;

/** "1.7×", Türkçede "1,7×". */
function zoomLabel(zoom: number, language: Language) {
  const text = String(Math.round(zoom * 10) / 10);
  return `${language === 'tr' ? text.replace('.', ',') : text}×`;
}

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
function frameRect(width: number, height: number, capture: CaptureMode, scale = 1) {
  const ratio = capture === 'photo' ? 4 / 3 : 16 / 9;
  const aspect = width > height ? ratio : 1 / ratio;
  const w = Math.min(width, height * aspect) * scale;
  const h = w / aspect;
  return { left: (width - w) / 2, top: (height - h) / 2, width: w, height: h };
}

/** Ön ışıkta önizlemenin boyutu; geri kalan ekran beyaz kalıp yüzü aydınlatır. */
const LIGHT_PREVIEW_SCALE = 0.6;

/** Göz teması penceresinin uzun kenarı (pt). */
const MINI_LONG = 112;

/**
 * Göz teması penceresinin yeri: ön kamera lensinin hemen yanı. Dikeyde ekranın üstü (lens çentiğin /
 * Dynamic Island'ın sağ tarafında, ortanın biraz sağında); yatayda lensin olduğu kenarın ortası
 * (arayüz landscapeRight'ta lens solda, landscapeLeft'te sağda).
 */
function miniRect(
  width: number,
  height: number,
  insets: EdgeInsets,
  capture: CaptureMode,
  orientation: InterfaceOrientation,
) {
  const short = Math.round(MINI_LONG / (capture === 'photo' ? 4 / 3 : 16 / 9));
  if (width <= height) {
    const x = Math.min(width - short - 8, Math.max(8, width * 0.58 - short / 2));
    return { x, y: insets.top + 4, width: short, height: MINI_LONG };
  }
  const x = orientation === 'landscapeRight' ? insets.left + 4 : width - insets.right - 4 - MINI_LONG;
  return { x, y: (height - short) / 2, width: MINI_LONG, height: short };
}

/**
 * Kayıt boyunca ekranı o anki yönde sabitle; video ortasında dönmesin. Yön pencereden okunur:
 * ScreenOrientation.getOrientationAsync tahmin yürütüyor, yatayda sol/sağı karıştırıp kayıt
 * başlarken ekranı ters tarafa çeviriyordu.
 */
async function lockCurrentOrientation() {
  const current = await getInterfaceOrientation();
  const lock =
    current === 'landscapeLeft'
      ? OrientationLock.LANDSCAPE_LEFT
      : current === 'landscapeRight'
        ? OrientationLock.LANDSCAPE_RIGHT
        : OrientationLock.PORTRAIT_UP;
  await ScreenOrientation.lockAsync(lock);
}

export default function CameraScreen() {
  const s = useStrings();
  const language = useLanguage();
  const settings = useSettings();
  const insets = useSafeAreaInsets();
  const camera = useRef<DualCameraRef>(null);
  const shutterBlink = useRef(new Animated.Value(0)).current;
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  // Yatayda tuşlar telefonun tutulduğu elin tarafında: sağa yatırınca (arayüz landscapeRight) sağ el,
  // sola yatırınca (arayüz landscapeLeft) sol el. Ayarlar ve göstergeler karşı köşeye geçer.
  const [uiOrientation, setUiOrientation] = useState<InterfaceOrientation>('unknown');
  const controlsLeft = landscape && uiOrientation === 'landscapeLeft';
  // Son seçilen yön, çekim türü ve kamera hatırlanır; uygulama aynısıyla açılır.
  const [mode, setMode] = useRemembered<Mode>('mode', 'landscape', ['landscape', 'portrait']);
  const [capture, setCapture] = useRemembered<CaptureMode>('capture', 'video', CAPTURE_MODES);
  const [cameras, setCameraSelection] = useRemembered<CameraMode>('cameras', 'both', ['both', 'back', 'front']);
  const [torch, setTorch] = useState(false);
  /** Ön ışık: ekran tam parlak ve beyaz, önizleme ortada küçük; yüzü aydınlatır. Kayda etkisi yok. */
  const [frontLight, setFrontLight] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [zoomRange, setZoomRange] = useState({ min: 1, max: MAX_ZOOM });
  const zoomPresets = [
    ...ZOOM_PRESETS.filter((p) => p >= zoomRange.min - 0.01 && p < zoomRange.max),
    zoomRange.max,
  ];
  /** İki parmak ya da kaydırma sürüyor: büyük yakınlaştırma etiketi görünür. */
  const [zoomAdjusting, setZoomAdjusting] = useState(false);
  const zoomNow = useRef({ zoom, range: zoomRange });
  useEffect(() => {
    zoomNow.current = { zoom, range: zoomRange };
  });
  // Düğmelerin üstünde yana kaydırınca ara değerler (sağa yakınlaşır). Kısa dokunuş düğmeye gider.
  const [zoomScrub] = useState(() => {
    let start = 1;
    const end = () => setZoomAdjusting(false);
    return PanResponder.create({
      onMoveShouldSetPanResponder: (_, g) => Math.abs(g.dx) > 8 && Math.abs(g.dx) > Math.abs(g.dy),
      onPanResponderGrant: () => {
        start = zoomNow.current.zoom;
        setZoomAdjusting(true);
      },
      onPanResponderMove: (_, g) => {
        const { min, max } = zoomNow.current.range;
        setZoom(Math.min(max, Math.max(min, start * 2 ** (g.dx / ZOOM_SCRUB_DOUBLING))));
      },
      onPanResponderRelease: end,
      onPanResponderTerminate: end,
    });
  });
  const [intervalSec, setIntervalSec] = useState(0);
  const [intervalPicker, setIntervalPicker] = useState(false);
  const [permission, setPermission] = useState<'pending' | 'ok' | 'denied'>('pending');
  const [micAllowed, setMicAllowed] = useState(true);
  const [recording, setRecording] = useState(false);
  const [paused, setPaused] = useState(false);
  /** Geçen süre: duraklatmalara kadar biriken `total` ms, çalışıyorsa `since` başlangıcı (0 = duraklatıldı). */
  const clock = useRef({ total: 0, since: 0 });
  const [shooting, setShooting] = useState(false);
  const [photos, setPhotos] = useState(0);
  const [busy, setBusy] = useState(false);
  /** Deklanşöre üst üste basılınca (ya da ses tuşu + ekran) iki işlem birden başlamasın. */
  const captureInFlight = useRef(false);
  const [elapsed, setElapsed] = useState(0);
  const [mic, setMic] = useState<Mic | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  /** Video kaydı ya da aralıklı çekim sürüyor; ayarlar kilitli. */
  const active = recording || shooting;
  const wake = useScreenDimmer(active && settings.dimScreen && !frontLight);
  /** Ön+Arka tek dosya (video ve foto); sahneye yerleştir yalnızca tek dosyayla anlamlı. */
  const combineVideo = settings.combineVideo || settings.layout === 'cutout';

  /** Kamera seçimi; ön ışık yalnızca ön kamera kullanılırken açık kalabilir. */
  function setCameras(value: CameraMode) {
    setCameraSelection(value);
    if (value === 'back') setFrontLight(false);
  }

  // Ön ışık açıkken parlaklık tam. Kilitten ya da başka uygulamadan dönünce yerel modül yeniden uygular.
  useEffect(() => {
    if (!frontLight) return;
    setScreenBrightness('max');
    return () => {
      setScreenBrightness('normal');
    };
  }, [frontLight]);
  const freeSpace = useFreeSpace();
  // Ayarlar ekranı açıkken ses tuşları çekim yapmasın, normal ses tuşu olsun.
  const [focused, setFocused] = useState(true);
  useFocusEffect(
    useCallback(() => {
      setFocused(true);
      return () => setFocused(false);
    }, []),
  );
  const audioLevel = useRef(new Animated.Value(0)).current;

  // Kenar boşlukları telefona göre (çentik, Dynamic Island, ana ekran çubuğu).
  const edge = {
    top: Math.max(insets.top, 12),
    bottom: Math.max(insets.bottom, 16),
    left: Math.max(insets.left, 12),
    right: Math.max(insets.right, 12),
  };
  const controlsBottom = edge.bottom + 6;
  const captureBottom = landscape ? edge.bottom : controlsBottom + 96;
  const zoomBottom = captureBottom + 44;

  // Mikrofon isteğe bağlı: izin yoksa video sessiz kaydedilir.
  useEffect(() => {
    requestPermissions().then(({ camera, microphone }) => {
      setPermission(camera ? 'ok' : 'denied');
      setMicAllowed(microphone);
    });
  }, []);

  // Uygulama kayıt sırasında çöktüyse ya da galeriye aktarma olmadıysa kayıt kaybolmaz: dosyası
  // durur ve burada galeriye kaydedilir.
  useEffect(() => {
    if (permission !== 'ok') return;
    recoverRecordings()
      .then((n) => n > 0 && setToast(fill(s.saved.recoveredCount, { n })))
      .catch(() => {});
    // Yalnızca açılışta bir kez (izin verilince).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [permission]);

  // Çekim yokken ekran seçilen moda göre döner (yatayda sol/sağ ikisi de olur).
  useEffect(() => {
    if (active) return;
    ScreenOrientation.lockAsync(
      mode === 'landscape' ? OrientationLock.LANDSCAPE : OrientationLock.PORTRAIT_UP,
    );
  }, [mode, active]);

  useEffect(() => {
    if (!active) return;
    const id = setInterval(() => {
      const { total, since } = clock.current;
      setElapsed((total + (since ? Date.now() - since : 0)) / 1000);
    }, 250);
    return () => clearInterval(id);
  }, [active]);

  /** Foto çekildiğini belli et: iPhone kamerası gibi görüntü bir an kararıp açılır. */
  const blink = useCallback(() => {
    if (!settings.shutterEffect) return;
    shutterBlink.setValue(1);
    Animated.timing(shutterBlink, { toValue: 0, duration: 250, useNativeDriver: true }).start();
  }, [settings.shutterEffect, shutterBlink]);

  /** Native söz (promise) hatası: `code` çeviri anahtarı, `message` sistem ayrıntısı. */
  const failText = useCallback((e: any) => errorText(s, e?.code, e?.message), [s]);

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
  }, [shooting, intervalSec, blink, failText]);

  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(null), 3000);
    return () => clearTimeout(id);
  }, [toast]);

  async function toggleRecording() {
    if (!camera.current || busy || captureInFlight.current) return;
    captureInFlight.current = true;
    setBusy(true);
    try {
      if (recording) {
        // Dosya kapanıp galeriye aktarılana kadar kayıt durumu (ve yön kilidi) korunur.
        const { duration, files, recovered } = await camera.current.stopRecording();
        setRecording(false);
        setPaused(false);
        setToast((recovered ? s.saved.salvaged + ' ' : '') + savedText(s, files, duration));
      } else {
        await lockCurrentOrientation();
        await camera.current.startRecording();
        clock.current = { total: 0, since: Date.now() };
        setElapsed(0);
        setRecording(true);
      }
    } catch (e) {
      setRecording(false);
      setPaused(false);
      setToast(failText(e));
    } finally {
      captureInFlight.current = false;
      setBusy(false);
    }
  }

  /** Kayıt dosyası açık kalır; duraklatılan süre videoda yer almaz, sayaç da durur. */
  async function togglePause() {
    if (!camera.current || !recording) return;
    try {
      if (paused) {
        await camera.current.resumeRecording();
        clock.current.since = Date.now();
        setPaused(false);
      } else {
        await camera.current.pauseRecording();
        clock.current.total += Date.now() - clock.current.since;
        clock.current.since = 0;
        setPaused(true);
      }
    } catch (e) {
      setToast(failText(e));
    }
  }

  /** Ses kısma (birincil): deklanşör. Ses açma (ikincil): kayıtta foto, yoksa o da deklanşör. */
  function onHardwareButton(button: 'primary' | 'secondary') {
    wake();
    if (button === 'secondary' && recording) snapWhileRecording();
    else onShutter();
  }

  /** Kalan kayıt süresi / foto sayısı (depolamaya göre); az kaldıysa uyarı rengi. */
  function storageInfo() {
    if (freeSpace === null) return null;
    const locale = language === 'tr' ? 'tr-TR' : 'en-US';
    if (capture === 'photo') {
      const n = photosLeft(freeSpace, cameras === 'both' ? 2 : 1);
      return { text: fill(s.storage.photos, { n: n.toLocaleString(locale) }), low: n < 50 };
    }
    const files = cameras === 'both' && !combineVideo ? 2 : 1;
    const minutes = Math.floor(videoSecondsLeft(freeSpace, files) / 60);
    const text =
      minutes >= 60
        ? fill(s.storage.hours, { h: Math.floor(minutes / 60), m: minutes % 60 })
        : fill(s.storage.minutes, { n: minutes });
    return { text, low: minutes < 5 };
  }
  const storage = storageInfo();

  // Göz teması: ön kamera açıkken görüntünün küçük kopyası lensin hemen yanında (dikeyde üstte,
  // yatayda lensin olduğu kenarda; tuşlar karşı tarafta). Kaydedilmez.
  const mini = settings.eyeContact && cameras !== 'back' ? miniRect(width, height, insets, capture, uiOrientation) : null;

  /** Video kaydı sürerken foto; kayıt durmaz, deklanşör düğmesi de meşgul olmaz. */
  function snapWhileRecording() {
    blink();
    camera.current
      ?.takePhoto()
      .then(({ files }) => setToast(files >= 2 ? s.saved.photos : s.saved.photo))
      .catch((e) => setToast(failText(e)));
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
    clock.current = { total: 0, since: Date.now() };
    setElapsed(0);
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
    <View style={[styles.screen, frontLight && styles.lightScreen, { width, height }]} onTouchStart={wake}>
      <StatusBar hidden />
      <DualCameraView
        ref={camera}
        cameras={cameras}
        captureMode={capture}
        torch={torch}
        zoom={zoom}
        combine={combineVideo}
        noiseReduction={settings.noiseReduction}
        previewScale={frontLight ? LIGHT_PREVIEW_SCALE : 1}
        pipPosition={settings.pipPosition ?? undefined}
        layout={settings.layout}
        miniPreviewFrame={mini ?? undefined}
        hardwareButtons={settings.volumeButtons && focused}
        onHardwareButton={(e) => onHardwareButton(e.nativeEvent.button)}
        onOrientationChange={(e) => setUiOrientation(e.nativeEvent.orientation)}
        onPipMove={(e) => settings.update({ pipPosition: { x: e.nativeEvent.x, y: e.nativeEvent.y } })}
        style={StyleSheet.absoluteFill}
        onMicChange={(e) => setMic(e.nativeEvent)}
        onAudioLevel={(e) => audioLevel.setValue(levelFromDb(e.nativeEvent.db))}
        onZoomRange={(e) => {
          const { min, max, zoom } = e.nativeEvent;
          setZoomRange({ min, max });
          setZoom(zoom);
        }}
        onZoomChange={(e) => {
          setZoom(e.nativeEvent.zoom);
          setZoomAdjusting(e.nativeEvent.active);
        }}
        onCameraError={(e) => setToast(errorText(s, e.nativeEvent.code, e.nativeEvent.detail))}
        onAutoStopped={(e) => {
          setRecording(false);
          setPaused(false);
          const { saved, duration, files, code, detail } = e.nativeEvent;
          setToast(
            saved
              ? `${s.saved.recordingStopped} ${savedText(s, files ?? 0, duration ?? 0)}`
              : errorText(s, code, detail),
          );
        }}
      />
      {settings.grid && <Grid rect={frameRect(width, height, capture, frontLight ? LIGHT_PREVIEW_SCALE : 1)} />}
      <Animated.View style={[StyleSheet.absoluteFill, styles.blink, { opacity: shutterBlink }]} pointerEvents="none" />

      <View
        style={[
          styles.top,
          landscape
            ? { top: edge.top + 4, left: edge.left + 12, right: edge.right + 12 }
            : { top: edge.top + 6 + (mini ? mini.height + 10 : 0), left: edge.left, right: edge.right },
          controlsLeft && styles.topRight,
        ]}
        pointerEvents="box-none"
      >
        {!active && (
          <Pressable
            style={styles.roundButton}
            accessibilityRole="button"
            accessibilityLabel={s.a11y.settings}
            onPress={() => router.push('/settings')}
          >
            <Text style={styles.roundText}>⚙️</Text>
          </Pressable>
        )}
        {/* Işık yalnızca arka kamerada var; kayıt sırasında da açılıp kapanabilir. */}
        {/* Ön ışık: yalnızca ön kamera kullanılırken; kayıt sırasında da açılıp kapanabilir. */}
        {cameras !== 'back' && (
          <Pressable
            style={[styles.roundButton, frontLight && styles.torchOn]}
            accessibilityRole="switch"
            accessibilityLabel={s.a11y.frontLight}
            accessibilityState={{ checked: frontLight }}
            onPress={() => setFrontLight(!frontLight)}
          >
            <Text style={styles.roundText}>💡</Text>
          </Pressable>
        )}
        {cameras !== 'front' && (
          <Pressable
            style={[styles.roundButton, torch && styles.torchOn]}
            accessibilityRole="switch"
            accessibilityLabel={s.a11y.torch}
            accessibilityState={{ checked: torch }}
            onPress={() => setTorch(!torch)}
          >
            <Text style={styles.roundText}>🔦</Text>
          </Pressable>
        )}
        <View style={[styles.pills, controlsLeft && styles.pillsRight]} pointerEvents="box-none">
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
              <AudioMeter level={audioLevel} />
            </View>
          )}
          {active && (
            <View style={[styles.pill, styles.option]}>
              <View style={[styles.dot, paused && styles.dotPaused]} />
              <Text style={styles.pillText}>
                {paused ? '⏸ ' : ''}
                {formatTime(elapsed)}
                {shooting ? ` · ${fill(s.saved.photoCount, { n: photos })}` : ''}
              </Text>
            </View>
          )}
          {storage && (
            <View style={[styles.pill, storage.low ? styles.micWarning : styles.option]}>
              <Text style={styles.pillText}>💾 {storage.text}</Text>
            </View>
          )}
        </View>
      </View>

      {mini && active && <LookHere mini={mini} landscape={landscape} lensLeft={uiOrientation === 'landscapeRight'} />}

      {zoomAdjusting ? (
        <View style={[styles.toastWrap, { bottom: zoomBottom + 50 }]} pointerEvents="none">
          <Text style={styles.zoomHint}>{zoomLabel(zoom, language)}</Text>
        </View>
      ) : (
        toast && (
          <View style={[styles.toastWrap, { bottom: zoomBottom + 50 }]} pointerEvents="none">
            <Text style={styles.toast}>{toast}</Text>
          </View>
        )
      )}

      {/* Kayıt sırasında da yakınlaştırılabilir: düğmeler, üstlerinde yana kaydırma ya da iki parmak.
          Etkin düğme ara değeri gösterir. */}
      <View style={[styles.captureWrap, { bottom: zoomBottom }]} pointerEvents="box-none">
        <View style={styles.zoomRow} {...zoomScrub.panHandlers}>
          {zoomPresets.map((preset, i) => {
            const next = zoomPresets[i + 1];
            const isMax = next === undefined;
            const on = isMax ? zoom >= preset - 0.01 : zoom >= preset - 0.01 && zoom < next - 0.01;
            return (
              <Pressable key={preset} style={styles.zoomChip} onPress={() => setZoom(preset)}>
                <Text style={[styles.zoomText, on && styles.zoomTextOn]}>
                  {isMax ? s.zoom.max : zoomLabel(on ? zoom : preset, language)}
                </Text>
              </Pressable>
            );
          })}
        </View>
      </View>

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
            ? [styles.controlsLandscape, controlsLeft ? { left: edge.left } : { right: edge.right }]
            : [styles.controlsPortrait, { bottom: controlsBottom }]
        }
      >
        <View style={styles.side}>
          {!active && (
            <Pressable
              style={styles.modeButton}
              onPress={() => setCameras(NEXT_CAMERA[cameras])}
            >
              <FitText text={s.camera[cameras]} style={styles.modeText} />
            </Pressable>
          )}
          {recording && (
            <Pressable
              style={styles.modeButton}
              accessibilityRole="button"
              accessibilityLabel={paused ? s.a11y.resume : s.a11y.pause}
              onPress={togglePause}
            >
              <Text style={styles.roundText}>{paused ? '▶️' : '⏸️'}</Text>
            </Pressable>
          )}
        </View>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={
            active ? s.a11y.stop : capture === 'video' ? s.a11y.record : intervalSec > 0 ? s.a11y.interval : s.a11y.photo
          }
          onPress={onShutter}
          disabled={busy}
          style={[styles.recordOuter, frontLight && styles.recordOuterLit, busy && { opacity: 0.5 }]}
        >
          {active ? (
            <View style={styles.recordStop} />
          ) : capture === 'video' ? (
            <View style={styles.recordInner} />
          ) : (
            <View style={[styles.photoInner, frontLight && styles.photoInnerLit]}>
              {intervalSec > 0 && (
                <FitText
                  text={intervalText(s, intervalSec)}
                  style={[styles.photoInnerText, frontLight && styles.photoInnerTextLit]}
                />
              )}
            </View>
          )}
        </Pressable>
        <View style={styles.side}>
          {!active && (
            <Pressable
              style={styles.modeButton}
              onPress={() => setMode(mode === 'landscape' ? 'portrait' : 'landscape')}
            >
              <FitText text={s.orientation[mode]} style={styles.modeText} />
            </Pressable>
          )}
          {recording && (
            <Pressable
              style={styles.modeButton}
              accessibilityRole="button"
              accessibilityLabel={s.a11y.snap}
              onPress={snapWhileRecording}
            >
              <View style={styles.snapInner} />
            </Pressable>
          )}
          {/* Tek kamerada arka ↔ ön, sağdaki düğmenin hemen üstünde (dikeyde yukarıda, yatayda
              sütunun üstünde). Video kaydı sürerken de: kayıt aynı dosyada devam eder. */}
          {cameras !== 'both' && (
            <Pressable
              style={[styles.roundButton, styles.flipButton]}
              accessibilityRole="button"
              accessibilityLabel={s.a11y.flip}
              onPress={() => setCameras(cameras === 'back' ? 'front' : 'back')}
            >
              <Text style={styles.roundText}>🔄</Text>
            </Pressable>
          )}
        </View>
      </View>
    </View>
  );
}

/** Ses düzeyi (dB) → 0–1: -65 dB ve altı boş, 0 dB dolu. Mikrofonun duyduğu her ses (sessiz bir
 * odanın hışırtısı dahil) küçük de olsa görünsün. */
function levelFromDb(db: number) {
  return Math.min(1, Math.max(0, (db + 65) / 65));
}

/**
 * Mikrofonun canlı ses düzeyi. Saniyede ~10 güncellenir; React'i yeniden çizdirmemek için doğrudan
 * Animated değeriyle. Yeşil normal, sarı yüksek, kırmızı patlamaya yakın.
 */
function AudioMeter({ level }: { level: Animated.Value }) {
  const color = level.interpolate({
    inputRange: [0, 0.8, 0.9, 1],
    outputRange: ['#22c55e', '#22c55e', '#facc15', '#ef4444'],
  });
  return (
    <View style={styles.meter}>
      <Animated.View style={[styles.meterFill, { backgroundColor: color, transform: [{ scaleX: level }] }]} />
    </View>
  );
}

/** Kayıt sırasında "kameraya bak" hatırlatıcısı: göz teması penceresinin lens tarafında yanıp sönen ok. */
function LookHere({
  mini,
  landscape,
  lensLeft,
}: {
  mini: ReturnType<typeof miniRect>;
  landscape: boolean;
  lensLeft: boolean;
}) {
  const [pulse] = useState(() => new Animated.Value(1));
  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: 0.25, duration: 600, useNativeDriver: true }),
        Animated.timing(pulse, { toValue: 1, duration: 600, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [pulse]);

  const half = 11;
  const [arrow, left, top] = !landscape
    ? ['▲', mini.x + mini.width / 2 - half, mini.y - half]
    : lensLeft
      ? ['◀', mini.x - half, mini.y + mini.height / 2 - half]
      : ['▶', mini.x + mini.width - half, mini.y + mini.height / 2 - half];
  return (
    <Animated.View style={[styles.lookHere, { left, top, opacity: pulse }]} pointerEvents="none">
      <Text style={styles.lookHereText}>{arrow}</Text>
    </Animated.View>
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

/**
 * Sabit boyutlu yuvarlak tuşların yazısı. Sığmazsa kelimenin ortasından bölünmez, küçülür (uzun
 * çeviriler ve büyük yazı boyutu ayarı için). Satır sayısı metindeki `\n`'lerden gelir.
 */
function FitText({ text, style }: { text: string; style: StyleProp<TextStyle> }) {
  return (
    <Text style={style} numberOfLines={text.split('\n').length} adjustsFontSizeToFit minimumFontScale={0.6}>
      {text}
    </Text>
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
  lightScreen: { backgroundColor: '#fff' },
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
  topRight: { flexDirection: 'row-reverse' },
  pillsRight: { alignItems: 'flex-end' },
  roundButton: { width: 40, height: 40, borderRadius: 20, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  roundText: { fontSize: 18 },
  torchOn: { backgroundColor: '#facc15' },
  flipButton: { position: 'absolute', bottom: 76, left: 12 },
  lookHere: { position: 'absolute', width: 22, height: 22, borderRadius: 11, backgroundColor: '#facc15', alignItems: 'center', justifyContent: 'center' },
  lookHereText: { color: '#000', fontSize: 11, fontWeight: '800' },
  pill: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, paddingVertical: 6, borderRadius: 16 },
  pillText: { color: '#fff', fontSize: 14, fontWeight: '600' },
  option: { backgroundColor: '#000a' },
  micExternal: { backgroundColor: '#1f9d55cc' },
  micWarning: { backgroundColor: '#d97706cc' },
  meter: { width: 44, height: 6, borderRadius: 3, marginLeft: 8, backgroundColor: '#ffffff33', overflow: 'hidden' },
  meterFill: { width: '100%', height: '100%', transformOrigin: 'left' },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  chipOn: { backgroundColor: '#facc15' },
  chipTextOn: { color: '#000' },
  dot: { width: 10, height: 10, borderRadius: 5, backgroundColor: '#ef4444', marginRight: 8 },
  dotPaused: { backgroundColor: '#9ca3af' },
  toastWrap: { position: 'absolute', left: 0, right: 0, paddingHorizontal: 24, alignItems: 'center' },
  toast: { color: '#fff', backgroundColor: '#000b', paddingHorizontal: 14, paddingVertical: 8, borderRadius: 12, overflow: 'hidden', textAlign: 'center' },
  captureWrap: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  captureSwitch: { flexDirection: 'row', backgroundColor: '#000a', borderRadius: 18, padding: 3 },
  captureTab: { paddingHorizontal: 16, paddingVertical: 6, borderRadius: 15 },
  captureTabOn: { backgroundColor: '#fff' },
  captureText: { color: '#fff', fontSize: 13, fontWeight: '700' },
  captureTextOn: { color: '#000' },
  zoomRow: { flexDirection: 'row', gap: 6, backgroundColor: '#0006', borderRadius: 22, padding: 4 },
  zoomChip: { minWidth: 36, height: 36, borderRadius: 18, paddingHorizontal: 6, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  zoomText: { color: '#fff', fontSize: 12, fontWeight: '700' },
  zoomTextOn: { color: '#facc15' },
  zoomHint: { color: '#facc15', fontSize: 16, fontWeight: '800', backgroundColor: '#000b', paddingHorizontal: 14, paddingVertical: 6, borderRadius: 14, overflow: 'hidden' },
  controlsPortrait: {
    position: 'absolute', left: 0, right: 0,
    flexDirection: 'row', justifyContent: 'center', alignItems: 'center', gap: 28,
  },
  controlsLandscape: {
    position: 'absolute', top: 0, bottom: 0,
    flexDirection: 'column-reverse', justifyContent: 'center', alignItems: 'center', gap: 28,
  },
  side: { width: 64, height: 64, alignItems: 'center', justifyContent: 'center' },
  modeButton: { width: 64, height: 64, borderRadius: 32, paddingHorizontal: 4, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  modeText: { color: '#fff', fontSize: 12, fontWeight: '700', textAlign: 'center' },
  recordOuter: { width: 78, height: 78, borderRadius: 39, borderWidth: 5, borderColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  recordInner: { width: 60, height: 60, borderRadius: 30, backgroundColor: '#ef4444' },
  recordStop: { width: 30, height: 30, borderRadius: 6, backgroundColor: '#ef4444' },
  photoInner: { width: 60, height: 60, borderRadius: 30, paddingHorizontal: 6, backgroundColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  photoInnerText: { color: '#000', fontSize: 13, fontWeight: '700' },
  // Ön ışıkta zemin beyaz: deklanşör koyu olsun, kaybolmasın.
  recordOuterLit: { borderColor: '#1c1c1e' },
  photoInnerLit: { backgroundColor: '#1c1c1e' },
  photoInnerTextLit: { color: '#fff' },
  snapInner: { width: 36, height: 36, borderRadius: 18, backgroundColor: '#fff' },
});
