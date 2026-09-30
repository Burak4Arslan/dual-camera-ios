import { requireNativeModule, requireNativeView } from 'expo';
import type { ComponentType, Ref } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';

type MicInfo = { name: string; external: boolean };
/** `files`: galeriye kaydedilen video sayısı (arka + yüz = 2). */
export type RecordingResult = { duration: number; files: number };
type AutoStopped = { saved: boolean; duration?: number; files?: number; error?: string };

export type DualCameraRef = {
  startRecording(): Promise<void>;
  stopRecording(): Promise<RecordingResult>;
};

/** both: sahne + yüz (2 dosya), back: sadece sahne, front: sadece yüz. */
export type CameraMode = 'both' | 'back' | 'front';

export type DualCameraViewProps = ViewProps & {
  ref?: Ref<DualCameraRef>;
  cameras?: CameraMode;
  onReady?: () => void;
  onMicChange?: (e: NativeSyntheticEvent<MicInfo>) => void;
  onCameraError?: (e: NativeSyntheticEvent<{ message: string }>) => void;
  onAutoStopped?: (e: NativeSyntheticEvent<AutoStopped>) => void;
};

const DualCameraModule = requireNativeModule<{
  isSupported(): boolean;
  requestPermissions(): Promise<{ camera: boolean; microphone: boolean }>;
}>('DualCamera');

export const isSupported = () => DualCameraModule.isSupported();
export const requestPermissions = () => DualCameraModule.requestPermissions();

export const DualCameraView: ComponentType<DualCameraViewProps> = requireNativeView('DualCamera');
