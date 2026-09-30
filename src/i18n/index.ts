import { useLocales } from 'expo-localization';

import { useSettings } from '../settings';
import { ErrorCode, Language, LANGUAGES, STRINGS, Strings } from './strings';

function isLanguage(code: string | null): code is Language {
  return LANGUAGES.includes(code as Language);
}

/** Ayarlardaki dil; "telefonun dili" seçiliyse telefonun tercih ettiği ilk desteklenen dil. */
export function useLanguage(): Language {
  const { language } = useSettings();
  const locales = useLocales();
  if (language !== 'system') return language;
  const device = locales.map((l) => l.languageCode).find(isLanguage);
  return device ?? 'en';
}

export function useStrings(): Strings {
  return STRINGS[useLanguage()];
}

/** `{n}`, `{time}` gibi yer tutucuları doldurur. */
export function fill(template: string, params: Record<string, string | number>) {
  return template.replace(/\{(\w+)\}/g, (_, key) => String(params[key] ?? ''));
}

/** Native taraftan gelen hata kodunu kullanıcının dilinde mesaja çevirir; sistem ayrıntısı parantezde. */
export function errorText(s: Strings, code?: string, detail?: string) {
  const text = code && code in s.errors ? s.errors[code as ErrorCode] : s.errors.unknown;
  return detail && detail !== code ? `${text} (${detail})` : text;
}
