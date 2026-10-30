/** Uygulamada ve App Store'da görünen iletişim bilgileri (Ayarlar → Hakkında, gizlilik politikası). */
export const CONTACT = {
  developer: 'Burak Arslan',
  email: 'burak4arslan@gmail.com',
};

/** E-posta uygulamasını, konu satırında uygulama adı ve sürümüyle açan adres. */
export function contactMailUrl(appName: string, version: string) {
  const subject = encodeURIComponent(`${appName} ${version}`);
  return `mailto:${CONTACT.email}?subject=${subject}`;
}
