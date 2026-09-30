export const LANGUAGES = ['tr', 'en'] as const;
export type Language = (typeof LANGUAGES)[number];

/** Dil seçiminde her dil kendi adıyla görünür. */
export const LANGUAGE_NAMES: Record<Language, string> = { tr: 'Türkçe', en: 'English' };

// `{n}`, `{time}` gibi yerler `fill` ile doldurulur.
const tr = {
  camera: { both: 'Ön+Arka', back: 'Arka', front: 'Ön' },
  capture: { video: 'VİDEO', photo: 'FOTO' },
  orientation: { landscape: 'Yatay', portrait: 'Dikey' },
  interval: { label: 'Aralıklı', off: 'Kapalı', seconds: '{n} sn' },
  mic: {
    builtIn: 'Dahili mikrofon',
    denied: 'Mikrofon izni yok, video sessiz kaydedilir',
  },
  saved: {
    videos: '2 video (sahne + yüz) galeriye kaydedildi ({time})',
    video: 'Video galeriye kaydedildi ({time})',
    photos: '2 foto (sahne + yüz) galeriye kaydedildi',
    photo: 'Foto galeriye kaydedildi',
    recordingStopped: 'Kayıt durdu.',
    shootingStopped: 'Çekim durdu, {n} foto galeriye kaydedildi',
    photoCount: '{n} foto',
  },
  start: {
    notSupported: 'Bu cihaz ön ve arka kamerayı aynı anda desteklemiyor.',
    waiting: 'İzinler bekleniyor…',
    cameraDenied: 'Kamera izni gerekli.',
    openSettings: 'Ayarları aç',
  },
  errors: {
    notSupported: 'Bu cihaz aynı anda iki kamerayı desteklemiyor.',
    noCamera: 'Kameralar açılamadı.',
    notRecording: 'Kayıt yapılmıyor.',
    tooShort: 'Kayıt çok kısa, hiç kare yakalanmadı.',
    writerFailed: 'Video yazılamadı.',
    photosDenied: 'Galeriye kaydetme izni yok. Ayarlar > DualCam > Fotoğraflar.',
    saveFailed: 'Galeriye kaydedilemedi.',
    photoFailed: 'Foto çekilemedi.',
    torchUnavailable: 'Işık şu an kullanılamıyor (telefon ısınmış olabilir).',
    torchFailed: 'Işık açılamadı.',
    audioSession: 'Ses açılamadı.',
    runtime: 'Kamera hatası.',
    recordFailed: 'Kamera kaydedilemiyor.',
    unknown: 'Bir hata oluştu.',
  },
  settings: {
    title: 'Ayarlar',
    done: 'Bitti',
    language: 'Dil',
    systemLanguage: 'Telefonun dili',
    camera: 'Kamera',
    grid: 'Izgara çizgileri',
    shutterEffect: 'Çekim efekti',
    shutterEffectHint: 'Foto çekilince görüntü bir an kararır.',
    about: 'Hakkında',
    version: 'Sürüm',
  },
};

export type Strings = typeof tr;
export type ErrorCode = keyof Strings['errors'];

const en: Strings = {
  camera: { both: 'Front+Back', back: 'Back', front: 'Front' },
  capture: { video: 'VIDEO', photo: 'PHOTO' },
  orientation: { landscape: 'Landscape', portrait: 'Portrait' },
  interval: { label: 'Interval', off: 'Off', seconds: '{n}s' },
  mic: {
    builtIn: 'Built-in mic',
    denied: 'No microphone access, video will be silent',
  },
  saved: {
    videos: '2 videos (scene + face) saved to Photos ({time})',
    video: 'Video saved to Photos ({time})',
    photos: '2 photos (scene + face) saved to Photos',
    photo: 'Photo saved to Photos',
    recordingStopped: 'Recording stopped.',
    shootingStopped: 'Stopped, {n} photos saved to Photos',
    photoCount: '{n} photos',
  },
  start: {
    notSupported: "This device can't use the front and back cameras at the same time.",
    waiting: 'Waiting for permissions…',
    cameraDenied: 'Camera access is required.',
    openSettings: 'Open Settings',
  },
  errors: {
    notSupported: "This device can't use two cameras at the same time.",
    noCamera: "Couldn't open the cameras.",
    notRecording: 'Not recording.',
    tooShort: 'Recording too short, no frames captured.',
    writerFailed: "Couldn't write the video.",
    photosDenied: 'No permission to save to Photos. Settings > DualCam > Photos.',
    saveFailed: "Couldn't save to Photos.",
    photoFailed: "Couldn't take the photo.",
    torchUnavailable: 'Light is unavailable right now (the phone may be too warm).',
    torchFailed: "Couldn't turn on the light.",
    audioSession: "Couldn't start audio.",
    runtime: 'Camera error.',
    recordFailed: "Couldn't record from the camera.",
    unknown: 'Something went wrong.',
  },
  settings: {
    title: 'Settings',
    done: 'Done',
    language: 'Language',
    systemLanguage: 'Device language',
    camera: 'Camera',
    grid: 'Grid lines',
    shutterEffect: 'Shutter effect',
    shutterEffectHint: 'The preview blinks when a photo is taken.',
    about: 'About',
    version: 'Version',
  },
};

export const STRINGS: Record<Language, Strings> = { tr, en };
