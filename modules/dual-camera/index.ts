import { requireNativeModule, requireNativeView } from 'expo';
import type { ComponentType, Ref } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';

type MicInfo = { name: string; external: boolean };
/** `files`: galeriye kaydedilen video sayısı (arka + yüz = 2). */
export type RecordingResult = { duration: number; files: number };
/** `files`: galeriye kaydedilen foto sayısı (ön+arka modunda sahne + yüz = 2). */
export type PhotoResult = { files: number };
/** Hata: `code` çeviri anahtarıdır (src/i18n), `detail` sistemden gelen ayrıntı. Söz (promise)
 * hatalarında da aynısı: `error.code` ve `error.message`. */
export type CameraError = { code: string; detail?: string };
type AutoStopped = { saved: boolean; duration?: number; files?: number } & Partial<CameraError>;

export type DualCameraRef = {
  startRecording(): Promise<void>;
  stopRecording(): Promise<RecordingResult>;
  /** Yalnızca `captureMode="photo"` iken. */
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
  /** Arka kameranın ışığı (video için sürekli yanar). `front` modunda yanmaz. */
  torch?: boolean;
  onReady?: () => void;
  onMicChange?: (e: NativeSyntheticEvent<MicInfo>) => void;
  onCameraError?: (e: NativeSyntheticEvent<CameraError>) => void;
  onAutoStopped?: (e: NativeSyntheticEvent<AutoStopped>) => void;
};

const DualCameraModule = requireNativeModule<{
  isSupported(): boolean;
  requestPermissions(): Promise<{ camera: boolean; microphone: boolean }>;
}>('DualCamera');

export const isSupported = () => DualCameraModule.isSupported();
export const requestPermissions = () => DualCameraModule.requestPermissions();

export const DualCameraView: ComponentType<DualCameraViewProps> = requireNativeView('DualCamera');
