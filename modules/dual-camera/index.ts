import { requireNativeModule, requireNativeView } from 'expo';
import type { ComponentType, Ref } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';

type MicInfo = { name: string; external: boolean };
/** `files`: galeriye kaydedilen video sayısı (arka + yüz = 2). */
/** `recovered`: kayıt sırasında yazıcı hata verdi ama o ana kadarki kısım kurtarıldı. */
export type RecordingResult = { duration: number; files: number; recovered?: boolean };
/** `files`: galeriye kaydedilen foto sayısı (ön+arka modunda sahne + yüz = 2). */
export type PhotoResult = { files: number };
/** Hata: `code` çeviri anahtarıdır (src/i18n), `detail` sistemden gelen ayrıntı. Söz (promise)
 * hatalarında da aynısı: `error.code` ve `error.message`. */
export type CameraError = { code: string; detail?: string };
type AutoStopped = { saved: boolean; duration?: number; files?: number } & Partial<CameraError>;

export type DualCameraRef = {
  startRecording(): Promise<void>;
  stopRecording(): Promise<RecordingResult>;
  /** Dosya açık kalır; duraklatılan süre videoda yer almaz. */
  pauseRecording(): Promise<void>;
  resumeRecording(): Promise<void>;
  /** Foto modunda ya da video kaydı sürerken (o zaman deklanşör sesi, destekleniyorsa, çıkmaz). */
  takePhoto(): Promise<PhotoResult>;
};

/** both: sahne + yüz (2 dosya), back: sadece sahne, front: sadece yüz. */
export type CameraMode = 'both' | 'back' | 'front';

/** video: 16:9 kayıt. photo: 4:3, kameranın en yüksek foto çözünürlüğü. */
export type CaptureMode = 'video' | 'photo';

export type DualCameraViewProps = ViewProps & {
  ref?: Ref<DualCameraRef>;
  cameras?: CameraMode;
  captureMode?: CaptureMode;
  /** Büyük görüntüdeki kameranın yakınlaştırması (1 = geniş açı lens, 0,5 = ultra geniş, en fazla 10;
   * ön kamerada 3). Her kamera kendi değerini hatırlar. */
  zoom?: number;
  /** `both`ta tek dosya, video ve foto (yüz sahnenin köşesinde); yoksa iki ayrı dosya. Sonraki çekimde geçerli. */
  combine?: boolean;
  /** Yüz penceresinin yeri (merkezinin kareye oranı, 0–1); verilmezse sağ üst köşe. */
  pipPosition?: PipPosition;
  /** Kullanıcı yüz penceresini sürükleyip bıraktığında yeni yeri. */
  onPipMove?: (e: NativeSyntheticEvent<PipPosition>) => void;
  /** Ön+Arka düzeni (önizleme ve tek dosya): küçük pencere, bölünmüş ekran ya da sahneye yerleştir
   * (kişi arka planı silinmiş olarak sahnenin üstünde; yalnızca tek dosyayla). */
  layout?: DualLayout;
  /** Ses tuşlarıyla çekim (iOS 17.2+). Kapalıyken tuşlar sesi değiştirir. */
  hardwareButtons?: boolean;
  /** Ses kısma `primary`, ses açma `secondary`. */
  onHardwareButton?: (e: NativeSyntheticEvent<{ button: 'primary' | 'secondary' }>) => void;
  /** Kaydedilen sesteki sürekli hışırtıyı temizle (spektral gürültü azaltma). Sonraki kayıtta geçerli. */
  noiseReduction?: boolean;
  /** Çekimlere konum yaz (izin verildiyse). Uygulama öndeyken konum takip edilir. */
  saveLocation?: boolean;
  /** Önizlemenin boyutu (1 = tam). Ön ışıkta küçülür, etrafı beyaz kalır; kayda etkisi yok. */
  previewScale?: number;
  /** Göz teması penceresinin ekrandaki yeri (pt); verilmezse gizli. Yalnızca ekranda, kaydedilmez. */
  miniPreviewFrame?: { x: number; y: number; width: number; height: number };
  /** Ekranın gerçek yönü değişince (yatay sol ↔ sağ dahil; o dönüşte boyut değişmez). */
  onOrientationChange?: (e: NativeSyntheticEvent<{ orientation: InterfaceOrientation }>) => void;
  /** Arka kameranın ışığı (video için sürekli yanar). `front` modunda yanmaz. */
  torch?: boolean;
  onReady?: () => void;
  onMicChange?: (e: NativeSyntheticEvent<MicInfo>) => void;
  onCameraError?: (e: NativeSyntheticEvent<CameraError>) => void;
  onAutoStopped?: (e: NativeSyntheticEvent<AutoStopped>) => void;
  /** Büyük görüntüdeki kamera değişince (kamera seçimi, yer değiştirme) onun aralığı ve hatırlanan
   * değeri; `min` 0,5 ise ultra geniş lens var. */
  onZoomRange?: (e: NativeSyntheticEvent<ZoomRange>) => void;
  /** İki parmakla yakınlaştırınca yeni değer (kamera native tarafta zaten yakınlaştı). `active`:
   * parmaklar hâlâ ekranda. */
  onZoomChange?: (e: NativeSyntheticEvent<{ zoom: number; active: boolean }>) => void;
  /** Mikrofonun ses düzeyi (dB; 0 en yüksek, -50 altı sessiz), saniyede ~10 kez. Yalnızca video modunda. */
  onAudioLevel?: (e: NativeSyntheticEvent<{ db: number }>) => void;
};

export type ZoomRange = { min: number; max: number; zoom: number };
export type PipPosition = { x: number; y: number };
export type DualLayout = 'pip' | 'split' | 'cutout';
export type ScreenBrightness = 'normal' | 'dim' | 'max';

/** Arayüzün (ekranın) gerçek yönü; yatayda sol/sağ, UIKit'teki adlarıyla. */
export type InterfaceOrientation =
  | 'portrait'
  | 'portraitUpsideDown'
  | 'landscapeLeft'
  | 'landscapeRight'
  | 'unknown';

const DualCameraModule = requireNativeModule<{
  isSupported(): boolean;
  requestPermissions(): Promise<{ camera: boolean; microphone: boolean }>;
  permissionsGranted(): { camera: boolean; microphone: boolean };
  getInterfaceOrientation(): Promise<InterfaceOrientation>;
  setScreenBrightness(level: ScreenBrightness): Promise<void>;
  getFreeSpace(): Promise<number>;
  recoverRecordings(): Promise<number>;
  appVersion(): { version: string; build: string };
  requestLocationPermission(): void;
  locationPermission(): LocationPermission;
}>('DualCamera');

export type LocationPermission = 'granted' | 'denied' | 'undetermined';

export const isSupported = () => DualCameraModule.isSupported();
export const requestPermissions = () => DualCameraModule.requestPermissions();
/** Eşzamanlı: izinler daha önce verildiyse açılışta bekleme ekranı hiç görünmez. */
export const permissionsGranted = () => DualCameraModule.permissionsGranted();
export const getInterfaceOrientation = () => DualCameraModule.getInterfaceOrientation();
/** Ekran parlaklığı: loş (uzun çekimde pil), tam (ön ışık) ya da kullanıcının ayarı. */
export const setScreenBrightness = (level: ScreenBrightness) => DualCameraModule.setScreenBrightness(level);

/** Kullanılabilir alan (bayt); kalan kayıt süresi tahmini için. */
export const getFreeSpace = () => DualCameraModule.getFreeSpace();
/**
 * Önceki açılışlardan kalan (uygulama çöktüğü ya da galeriye aktarılamadığı için) kayıtları galeriye
 * kaydeder; kaç dosya kurtarıldığını döner.
 */
export const recoverRecordings = () => DualCameraModule.recoverRecordings();
/** Konum izni daha önce sorulmadıysa sorar (kamera ve mikrofondan sonra). */
export const requestLocationPermission = () => DualCameraModule.requestLocationPermission();
export const locationPermission = () => DualCameraModule.locationPermission();
/** App Store'daki sürüm (ör. 1.0.0) ve build numarası. */
export const appVersion = () => DualCameraModule.appVersion();

export const DualCameraView: ComponentType<DualCameraViewProps> = requireNativeView('DualCamera');
