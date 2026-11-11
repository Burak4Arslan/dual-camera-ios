# Çift Kamera / Dual Camera – App Store Connect bilgileri

App Store Connect'te yeni uygulama oluştururken ve sürüm sayfasında girilecek metinler. Karakter
sınırları içinde (ad 30, alt başlık 30, tanıtım metni 170, anahtar kelimeler 100).

## Uygulama bilgileri

| Alan | Değer |
|---|---|
| Bundle ID | `com.burakarslan.dualcam` |
| SKU | `dualcam-ios` |
| Birincil dil | English (U.S.) — Türkçe ikinci yerelleştirme. Yerelleştirmesi olmayan ülkelerde birincil dil görünür; İngilizce herkes için daha anlaşılır. |
| Ad (Türkçe) | Çift Kamera: Ön Arka Vlog |
| Ad (English U.S.) | Dual Camera: Vlog Front & Back |
| Ana ekrandaki ad | Çift Kamera / Dual Camera (`locales/*.json`, telefon diline göre) |
| Kategori | Fotoğraf ve Video (birincil) |
| Yaş derecesi | 4+ (tüm sorulara "Hayır") |
| Gizlilik politikası URL | https://burak4arslan.github.io/AppInfos/dualcam-privacy-policy.html |
| Destek URL | https://burak4arslan.github.io/AppInfos/dualcam-support.html |
| Telif hakkı | © 2026 Burak Arslan |

### Arama (ASO) notları
- App Store aramada **ad + alt başlık + anahtar kelimeler** birlikte sayılır; aynı kelimeyi iki alana yazmak
  boşa yer harcar. Aşağıdaki listelerde ad ve alt başlıktaki kelimeler tekrar edilmedi.
- Anahtar kelimeler virgülle, boşluksuz yazılır; tek kelimeler birbirleriyle birleşerek aranır
  ("bölünmüş" + "ekran" → "bölünmüş ekran").
- **TikTok, YouTube, Instagram, Reels, Shorts gibi marka adları ad, alt başlık ve anahtar kelimelere
  yazılmaz** (Kural 2.3.7, ret sebebi). Bu kitle "vlog", "reaksiyon", "video" diye arıyor; onları kapsıyoruz.
- Ad değiştirilirse `locales/*.json`, `src/i18n/strings.ts` (`appName`, `photosDenied`) ve `docs/` da güncellenmeli.

### Uygulama gizliliği (App Privacy)
"Veri toplamıyoruz" (**Data Not Collected**) seç. Uygulama hiçbir veriyi cihazdan dışarı göndermez;
analiz, reklam, izleme, hesap yok.

### Şifreleme (Export Compliance)
`ITSAppUsesNonExemptEncryption = NO` Info.plist'te tanımlı; yüklemede soru sorulmaz.

## Türkçe

**Ad:** Çift Kamera: Ön Arka Vlog

**Alt başlık:** Aynı anda iki açıdan video çek

**Tanıtım metni:** Sahneyi ve kendini aynı anda çek: pencere, bölünmüş ekran ya da arkandaki odayı silip seni sahneye yerleştiren yeni düzen. Hepsi cihazında, internetsiz.

**Anahtar kelimeler:** dual,camera,ikili,selfie,reaksiyon,tepki,pip,bölünmüş,ekran,multicam,röportaj,yaka,mikrofon,çekim

**Açıklama:**

Ön ve arka kamerayla aynı anda video ve fotoğraf çek. Gezi vlogları, ürün tanıtımları, tepki videoları ve röportajlar için sahneyi ve kendini tek seferde kaydet.

ÜÇ DÜZEN
• Pencere: Yüzün köşede küçük bir pencerede. Sürükleyip istediğin yere koy, dokununca kameralar yer değiştirsin.
• Bölünmüş ekran: Yatayda yan yana, dikeyde üst üste.
• Sahneye yerleştir: Arkandaki oda silinir, sadece sen sahnenin üstünde durursun — yeşil perde olmadan.

KAYIT
• İstersen sahne ve yüz ayrı dosyalar (kurguda esneklik), istersen ekrandaki düzenle tek video ve tek fotoğraf.
• Duraklat / devam et: Durdurduğun kısım videoya girmez.
• Kayıt sırasında fotoğraf çek, tek kamerada arka ↔ ön çevir; kayıt tek parça sürer.
• Ses tuşlarıyla çekim: Ses kısma başlat/durdur, ses açma kayıtta fotoğraf. Bluetooth kumandalarla da çalışır.
• Kayıt güvenliği: Uygulama kapansa bile kayıt kaybolmaz, bir sonraki açılışta galerine kurtarılır.

FOTOĞRAF
• Cihazın en yüksek fotoğraf kalitesi.
• Aralıklı çekim: 1–60 saniyede bir, sen durdurana kadar.

KAMERA
• 0,5×'ten telefonun desteklediği en yüksek değere (Pro modellerde 25×'e kadar) yakınlaştırma, iki parmakla ya da hızlı düğmelerle.
• Arka kamera ışığı ve yüzünü aydınlatan ön ışık.
• Göz teması penceresi: Görüntünün küçük bir kopyası lensin yanında durur, kameraya bakarak konuşursun.
• Izgara çizgileri, yatay/dikey kilit, tuşlar tuttuğun elin tarafında.

SES
• Yaka mikrofonu desteği ve canlı ses seviyesi göstergesi.
• Hışırtı azaltma.

GİZLİLİK
Hesap yok, reklam yok, veri toplama yok. Tüm işlemler cihazında yapılır.

Ön ve arka kamerayı aynı anda kullanmak iPhone XS / XR veya daha yenisini gerektirir.

**Bu sürümdeki yenilikler (1.0):** İlk sürüm.

## English

**Name:** Dual Camera: Vlog Front & Back

**Subtitle:** Reaction video & PiP recorder

**Promotional text:** Film the scene and yourself at once: picture-in-picture, split screen, or the new layout that removes your room and places you in the scene. All on device.

**Keywords:** cam,double,two,both,selfie,split,screen,multicam,rear,content,creator,interview,react,lavalier,mic

**Description:**

Record video and take photos with the front and back cameras at the same time. Capture the scene and yourself in one take — perfect for travel vlogs, product reviews, reactions and interviews.

THREE LAYOUTS
• Picture in picture: Your face in a small window. Drag it anywhere; tap it to swap cameras.
• Split screen: Side by side in landscape, stacked in portrait.
• Place me in the scene: Your room is removed and only you appear over the scene — no green screen needed.

RECORDING
• Save the scene and your face as separate files for flexible editing, or as a single video and photo with the on-screen layout.
• Pause / resume: paused parts are left out of the video.
• Take photos while recording, and flip between back and front in single-camera mode — the recording continues in one file.
• Shoot with the volume buttons: volume down starts/stops, volume up takes a photo while recording. Works with Bluetooth remotes too.
• Recording safety: even if the app closes, your recording isn't lost — it's recovered to your library the next time you open the app.

PHOTOS
• Your device's highest photo quality.
• Interval shooting: every 1–60 seconds until you stop.

CAMERA
• Zoom from 0.5× up to your iPhone's maximum (up to 25× on Pro models) with a pinch or quick buttons.
• Back camera light and a front light that brightens your face.
• Eye contact window: a small copy of the preview sits next to the lens, so you look at the camera while you talk.
• Grid lines, landscape/portrait lock, controls on the side of the hand holding the phone.

AUDIO
• Lavalier mic support with a live audio level meter.
• Hiss reduction.

PRIVACY
No accounts, no ads, no data collection. Everything happens on your device.

Using the front and back cameras at once requires iPhone XS / XR or later.

**What's new (1.0):** First release.

## App Review notları (Notes for App Review)

> The app records with the front and back cameras simultaneously using AVCaptureMultiCamSession, so it
> requires a device that supports multi-camera capture (iPhone XS / XR or later). On unsupported
> devices the app shows an explanatory message. No sign-in is required and no data leaves the device.
> The hardware volume buttons act as the shutter via AVCaptureEventInteraction (can be turned off in
> Settings → Camera). "Place me in the scene" uses Vision person segmentation on device.

## Ekran görüntüleri

- En az bir iPhone ekran boyutu için 3–10 ekran görüntüsü gerekir; App Store Connect yükleme ekranında
  hangi boyutun zorunlu olduğunu gösterir. Telefondan (yan tuş + ses açma) çekilen görüntüler kullanılabilir.
- Önerilen sıra: 1) Pencere düzeni (sahne + yüz), 2) Sahneye yerleştir, 3) Bölünmüş ekran,
  4) Kayıt sırasında (duraklat / foto), 5) Ayarlar.
- Uygulama yalnızca iPhone için (iPad desteği kapalı), iPad ekran görüntüsü gerekmez.

## Yayınlama adımları

1. Gizlilik ve destek sayfaları Burak4Arslan/AppInfos reposunda (GitHub Pages) yayında. `docs/` değişirse
   oradaki kopyaları da güncelle.
2. App Store Connect → Uygulamalar → **+** → Yeni uygulama (bundle ID yukarıda).
3. Derleme: `npx eas-cli@latest build -p ios --profile production` (ya da Xcode → Product → Archive).
4. Yükleme: `npx eas-cli@latest submit -p ios --latest` (ya da Xcode Organizer → Distribute App).
5. TestFlight'ta kendi telefonunda dene, sonra sürümü incelemeye gönder.
