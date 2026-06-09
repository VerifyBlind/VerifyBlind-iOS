# App Store — İlk Review (External TestFlight) Hazırlık Rehberi

> Hazırlandı: 2026-06-09 · Hedef: TestFlight **External Testing** için Beta App Review.
> Beta App Review tipik süre: **~24-48 saat** (çoğu zaman <24s). Bu, production App Store review'undan
> daha hafif ve hızlıdır; ama aynı guideline'lar (2.1, 5.1.1) uygulanır.

---

## BÖLÜM 1 — Kod tarafında YAPILDI (Claude)

| # | Eksik | Durum | Dosya |
|---|-------|-------|-------|
| 1 | **Privacy Manifest yoktu** (2024-05'ten beri zorunlu; yoksa upload uyarı/red) | ✅ Eklendi | `Resources/PrivacyInfo.xcprivacy` |
| 2 | **Demo modu yalnız dev build'de görünüyordu** → reviewer production build'de demo butonunu göremez → **garantili Guideline 2.1 reddi** | ✅ Düzeltildi: TestFlight build'lerinde de demo açık (gerçek App Store prod'da gizli) | `Config/Config.swift` (`isTestFlight`), `App/AppState.swift` (`demoEnabled`) |

**#2 nasıl çalışıyor:** `demoEnabled = (dev) || Config.isTestFlight`. TestFlight makbuzu `sandboxReceipt`,
App Store prod makbuzu `receipt` olur. Yani:
- TestFlight (reviewer + harici testçiler) → **demo görünür** ✅
- Gerçek App Store yayını (production) → demo **gizli** ✅

> ⚠️ İstersen bu davranışı değiştirebiliriz (örn. demo'yu production'da da göster, ya da yalnız
> gizli bir jest/koddan aç). Şu anki seçim "TestFlight'ta aç, production'da gizle" — review için ideal.

---

## BÖLÜM 2 — SENİN YAPACAKLARIN (App Store Connect + web)

### Adım 0 — Ön koşullar (muhtemelen hazır)
- [ ] App Store Connect'te uygulama kaydı var (Bundle ID: `app.verifyblind.ios`).
- [ ] Prod GitHub Actions secret'ları dolu: `APP_STORE_APP_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
      `APP_STORE_CONNECT_KEY_IDENTIFIER`, `APP_STORE_CONNECT_PRIVATE_KEY`, `CERTIFICATE_PRIVATE_KEY`,
      `APPLE_TEAM_ID` (+ CERT_PIN, ENCLAVE_DEVELOPER_PUBLIC_KEY, opsiyonel Sentry/Dropbox/Google).
- [ ] **Backend canlı:** Demo, `api.verifyblind.com/api/verify/demo-register`'a istek atar. Review
      penceresi boyunca prod API + Enclave ayakta olmalı, yoksa reviewer demo'da hata görür → red.

### Adım 1 — Privacy Policy URL (zorunlu)
Apple, review için **herkese açık bir gizlilik politikası URL'i** ister. Politika zaten yayında ve
KVKK açısından kapsamlı (7 bölüm). Apple'ın 6 şartını (ne toplanıyor, 3. taraflar, saklama, silme,
haklar, iletişim) karşılıyor.
- [ ] App Store Connect'e **locale önekli** URL ver — çıplak `/privacy` için redirect YOK:
      **`https://verifyblind.com/en/gizlilik`** (reviewer için İngilizce) veya `/en/privacy` (→ 301 gizlilik'e).
- [ ] **Submit öncesi 3 tutarlılık düzeltmesi** (label ↔ politika uyumu; kaynak:
      `src/landing-site/app/[locale]/gizlilik/page.tsx` TR+EN):
  1. **Sentry/çökme teşhisi 3. taraf olarak EKSİK** — App Privacy label'ın "Crash Data" diyecek ama
     politikanın "Paylaştığımız Taraflar" tablosunda Sentry yok. Bir satır ekle (PII redakte, kimlik gitmez).
  2. **Güvenlik bölümü yalnız "Android Keystore" diyor** — iOS Keychain/Secure Enclave de ekle.
  3. (İyi olur) **Bulut yedek (Dropbox/Google Drive)** politikada yok — kullanıcı-başlatımlı, uçtan
     uca şifreli, kullanıcının kendi hesabına olduğunu belirten bir cümle ekle.

### Adım 2 — Export Compliance kararı (ŞİFRELEME) — **senin/hukuk kararın**
Şu an `App/Info.plist` → `ITSAppUsesNonExemptEncryption = false`.
- VerifyBlind çekirdeği RSA-OAEP / AES-GCM / RSA-PSS + cert pinning kullanıyor → "yalnız HTTPS"
  değil; **standart algoritmalarla özel bir kripto protokolü** uyguluyorsun.
- `false` (kullanmıyorum) pek çok standart-kripto kimlik uygulamasının yaptığı şey ama senin
  durumun için **sınırda**. Doğru/güvenli yol genelde:
  `ITSAppUsesNonExemptEncryption = true` → App Store Connect export sorularında **muafiyet** beyan
  et (standart algoritmalar / mass-market). Bu, yılda bir basit self-classification raporu
  gerektirebilir.
- **Karar senin (hukuki).** İlk TestFlight beta'sını **mevcut `false` ile geçirebilirsin** (ASC soru
  sormaz, build geçer). Ama **production'a çıkmadan önce** bu beyanı bir uzmanla netleştir.
- Eğer `true` yapmak istersen `Info.plist`'i ben güncelleyebilirim — söyle.

### Adım 3 — App Privacy (Privacy Nutrition Labels)
App Store Connect → uygulaman → **App Privacy** → "Get Started / Edit".

**Akış (ASC ekranları sırası):** önce "Veri topluyor musun?" → **Yes**. Sonra bir **veri tipi
ızgarası** çıkar (Contact, Identifiers, Diagnostics, Usage Data, …) — burada SADECE topladığını seç.
**"Data Linked / Not Linked / Tracking" ayrı seçenek DEĞİL** — onları, seçtiğin her tip için sonradan
sorulan "ne amaçla / kimliğe bağlı mı / takip için mi" sorularından ASC kendi üretir.

Seç:
- **Diagnostics → Crash Data** ✅ → sonraki sorular: Purpose = **App Functionality**, Linked = **No**,
  Tracking = **No**. (Sonuç: "Data Not Linked to You → Diagnostics → Crash Data".)
- **Identifiers → Device ID → ŞİMDİLİK SEÇME.** Label mevcut build'i yansıtır; push bildirimi henüz
  yok → cihaz token'ı toplanmıyor. Sentry'nin kurulum UUID'si "Crash Data" altında sayılır, takip
  Device ID'si değil. **Push'u eklediğinde** Device ID'yi (App Functionality, Not Linked, No tracking)
  ekle — label'ı yeni build olmadan da güncelleyebilirsin.
- Başka tip seçme.

Cevaplar (zero-knowledge mimariye göre):
- **Do you collect data from this app?** → **Yes** (yalnız çökme teşhisi — Sentry).
- **Tracking (Used to Track You):** → **None.** ("Ask App Not to Track" gerektiren takip yok.)
- **Data Linked to You:** → **None.** (Kimlik verisi sunucuda saklanmaz; kullanıcıya bağlı veri yok.)
- **Data Not Linked to You → Diagnostics:**
  - ✅ **Crash Data** — Purpose: *App Functionality*
  - ❌ Performance Data EKLEME — `enableAutoPerformanceTracing = false`, Sentry yalnız çökme/hata topluyor.
- Başka hiçbir kategori işaretleme (Contact, Identifiers, Location, Health, Financial, vb. → hayır).

> **Kimlik/biyometrik veri neden "collected" DEĞİL?** Apple'ın "collect" tanımı = veriyi cihaz dışına
> gönderip *gerçek-zamanlı isteği işlemek için gerekenden uzun süre* erişilebilir tutmak. VerifyBlind'de
> kimlik verisi Enclave'in public key'iyle uçtan uca şifrelenir (Relay okuyamaz bile), Enclave gerçek
> zamanlı işler ve **saklamaz** → tanım gereği "collected" değildir. Sentry'de de `beforeSend` PII'ı
> redact ediyor. Bu yüzden kimlik/biyometriği label'a EKLEMİYORUZ — zero-knowledge iddianla tutarlı.
> (Koşul: backend gerçekten saklamıyor olmalı — ki çekirdek mimarin bu.)

> Not: Uygulama içi **chatbot şu an UI'da açık DEĞİL** (kod var ama hiçbir ekrandan çağrılmıyor).
> İleride chatbot'u bağlarsan label'a **User Content → Customer Support (Not Linked)** ekle.

### Adım 4 — External Testers grubu
App Store Connect → TestFlight → Groups → **+** :
- [ ] Grup adı **tam olarak**: `External Testers`  *(workflow'daki `BETA_GROUP` ile birebir aynı olmalı)*.
- [ ] En az 1 harici testçi e-postası ekle (kendi 2. mailin olabilir) ya da Public Link aç.

### Adım 4.5 — App Information (uygulama-seviyesi minimum)
App Store Connect → uygulaman → **App Information** / **Age Rating**. Beta için gereken minimum:

| Alan | Beta için | Not |
|------|-----------|-----|
| **Age Rating** | ✅ Doldur | Kısa anket; sakıncalı içerik yok → 4+ |
| **Content Rights** | ✅ Doldur | "Üçüncü taraf içeriği içeriyor mu?" → Hayır |
| **Category** | ⚠️ Önerilir | Utilities veya Business |
| Subtitle | ⏭️ Atla | Store listing alanı |
| App Encryption Documentation | ⏭️ Boş bırak | plist `false` zaten kapsıyor |
| Screenshots (App Store) | ⏭️ Atla | **Sadece production yayınında** gerekli (6.7"+6.5") |

> "Atla" denenler production'a submit ederken gerekli olacak — beta için değil.

### Adım 5 — Test Information (External için zorunlu)
App Store Connect → TestFlight → **Test Information** (tüm diller için):
- [ ] **Beta App Description** → aşağıdaki metin
- [ ] **Feedback Email** → senin destek/iletişim mailin (örn. `ercumente@gmail.com` veya destek adresi)
- [ ] **Marketing URL** → `https://verifyblind.com`
- [ ] **Privacy Policy URL** → Adım 1'deki URL (`https://verifyblind.com/en/gizlilik`)
- [ ] **App Review Information** (beta review notu + iletişim) → aşağıdaki **Reviewer Notes** metni,
      ve First/Last name + telefon + email doldur. (Demo butonlu olduğu için ayrı "demo account"
      kullanıcı adı/şifresi GEREKMEZ — notta bunu belirttim.)

> **"What to Test" burada DEĞİL** — build'e özeldir. Build yüklendikten sonra (Adım 6) ilgili build'in
> üzerinde "Test Details / What to Test" alanına aşağıdaki metni gir.
>
> **"Invitation Experience → Show approved screenshots and category"** → işaretleme/boş bırak;
> onaylı store screenshot'ın yok, beta review'a etkisi yok (sadece davet görselleri).

### Adım 6 — Build üret + yükle
- [ ] GitHub → Actions → **"iOS Prod → TestFlight External"** workflow'unu `workflow_dispatch` ile
      çalıştır (veya `main`'e push). Build numarası TestFlight'tan otomatik +1 alınır.
- [ ] Build işlenince (ASC'de "Processing" biter, ~5-30 dk) → build'in üzerinde **What to Test**
      metnini gir → build'i **External Testers** grubuna ata → **Submit for Beta App Review**.
- [ ] Export compliance sorusu çıkarsa Adım 2 kararına göre cevapla (`false` ise sormaz).

### Adım 7 — Bekle
- Beta App Review ~1 gün. Onaylanınca harici testçiler (ve sen) build'i kurabilir.
- Red gelirse Resolution Center'daki sebebi bana getir — birlikte düzeltiriz.

---

## BÖLÜM 3 — KOPYALA-YAPIŞTIR METİNLER

### 3.1 — Reviewer Notes (App Review Information → Notes) — **EN (birincil)**

```
VerifyBlind is a privacy-first "Proof of Personhood" / digital identity app. Users prove they are a
real, unique human using their Turkish NFC ID card + a face liveness check, WITHOUT exposing their
national ID number to third parties (zero-knowledge). It is NOT a KYC/data-collection app.

IMPORTANT FOR REVIEW — no physical ID card needed:
Normal use requires a physical Turkish NFC ID card, which you will not have. The app therefore
includes a built-in DEMO MODE (automatically enabled on TestFlight builds) that walks through the
entire flow without any card or real biometric data.

How to run the demo:
1. Launch the app and continue past the intro to the home (Wallet) screen.
2. Tap the "Demo" button (shown beneath the "Add ID Card" button).
3. Tick the consent (privacy/KVKK) checkbox, then tap Start.
4. The app SIMULATES the ID document scan (~2s) and the NFC chip read (~2s) — no real card needed.
5. Approve the biometric-data consent screen.
6. Allow Camera access when prompted. In demo mode the liveness gestures auto-complete after ~1s
   each; no real face match is performed.
7. The app completes a demo verification and shows a success screen with a credential stored
   on-device.

After the demo you can explore: History, Settings, Backup, Help, and "Delete Identity".

Account & data deletion (Guideline 5.1.1): All identity data is stored ONLY on the device. Our
servers do NOT store personal data tied to the user (zero-knowledge). To delete everything, tap
"Delete Identity" on the home screen and confirm — all on-device identity data and keys are
permanently erased.

Third-party login note (Guideline 4.8): Google Sign-In and Dropbox are used ONLY as optional cloud
destinations for the user's ENCRYPTED backup file. They are NOT used to create or authenticate the
account/identity, so Sign in with Apple does not apply.

Network: The demo calls our backend at api.verifyblind.com; it is live during the review window.

Contact: <ADIN SOYADIN> — <EMAIL> — <TELEFON>
```

### 3.2 — Reviewer Notes — **TR (yedek/çeviri)**

```
VerifyBlind, gizlilik öncelikli bir "Kişi Doğrulama (Proof of Personhood)" / dijital kimlik
uygulamasıdır. Kullanıcı, Türk NFC kimlik kartı + yüz canlılık kontrolü ile gerçek ve tekil bir
insan olduğunu, TC kimlik numarasını üçüncü taraflara açmadan kanıtlar (zero-knowledge). KYC / veri
toplama uygulaması DEĞİLDİR.

REVIEW İÇİN ÖNEMLİ — fiziksel kart gerekmez:
Normal kullanım fiziksel Türk NFC kimlik kartı gerektirir; sizde olmayacaktır. Bu yüzden uygulamada,
tüm akışı kartsız ve gerçek biyometri olmadan gezdiren bir DEMO MODU vardır (TestFlight
build'lerinde otomatik açıktır).

Demo adımları:
1. Uygulamayı açın, giriş ekranlarını geçip ana (Cüzdan) ekrana gelin.
2. "Demo" düğmesine dokunun ("Kimlik Kartı Ekle" düğmesinin altında).
3. Onay (gizlilik/KVKK) kutusunu işaretleyin, Başla'ya dokunun.
4. Uygulama kimlik taramasını (~2s) ve NFC çip okumasını (~2s) SİMÜLE eder — kart gerekmez.
5. Biyometrik veri onay ekranını onaylayın.
6. Sorulduğunda Kamera iznini verin. Demo modunda canlılık jestleri her biri ~1s sonra otomatik
   tamamlanır; gerçek yüz eşleştirmesi yapılmaz.
7. Uygulama demo doğrulamayı tamamlar ve cihazda saklanan bir kimlik bilgisiyle başarı ekranını
   gösterir.

Demo sonrası: Geçmiş, Ayarlar, Yedekleme, Yardım ve "Kimliği Sil" gezilebilir.

Hesap ve veri silme (Madde 5.1.1): Tüm kimlik verisi YALNIZCA cihazda saklanır. Sunucularımız
kullanıcıya bağlı kişisel veri TUTMAZ (zero-knowledge). Silmek için ana ekranda "Kimliği Sil"e
dokunup onaylayın — cihazdaki tüm kimlik verisi ve anahtarlar kalıcı olarak silinir.

Üçüncü taraf giriş notu (Madde 4.8): Google Sign-In ve Dropbox YALNIZCA kullanıcının ŞİFRELİ yedek
dosyası için opsiyonel bulut hedefidir. Hesap/kimlik oluşturma veya doğrulama için KULLANILMAZ; bu
nedenle Sign in with Apple kapsam dışıdır.

Ağ: Demo, api.verifyblind.com backend'ine istek atar; review penceresinde canlıdır.

İletişim: <ADIN SOYADIN> — <EMAIL> — <TELEFON>
```

### 3.3 — Beta App Description — **EN / TR**

EN:
```
VerifyBlind lets you prove you are a real, unique person to websites and apps using your NFC ID card
and a quick face check — without ever sharing your ID number. Your identity stays encrypted on your
device. This beta lets you try the full verification flow via the built-in Demo mode (no physical
card required).
```
TR:
```
VerifyBlind, NFC kimlik kartınız ve hızlı bir yüz kontrolü ile, kimlik numaranızı hiç paylaşmadan,
gerçek ve tekil bir kişi olduğunuzu web sitelerine ve uygulamalara kanıtlamanızı sağlar. Kimliğiniz
cihazınızda şifreli kalır. Bu beta'da, dahili Demo modu ile tüm doğrulama akışını fiziksel kart
gerekmeden deneyebilirsiniz.
```

### 3.4 — What to Test — **EN / TR**

EN:
```
Please test using the "Demo" button on the home screen (no ID card needed):
- Complete a demo verification (consent → simulated scan/NFC → camera liveness → success).
- Try "Delete Identity" to confirm data is removed.
- Browse History, Settings, Backup and Help.
Report any crash, confusing wording, or step that fails to advance.
```
TR:
```
Lütfen ana ekrandaki "Demo" düğmesiyle test edin (kimlik kartı gerekmez):
- Bir demo doğrulamayı tamamlayın (onay → simüle tarama/NFC → kamera canlılık → başarı).
- "Kimliği Sil" ile verinin silindiğini doğrulayın.
- Geçmiş, Ayarlar, Yedekleme ve Yardım'ı gezin.
Çökme, kafa karıştıran ifade veya ilerlemeyen bir adım olursa bildirin.
```

---

## BÖLÜM 4 — Operasyonel watch-item'lar (red riskini azaltır)

1. **Backend canlı olsun** (Enclave dahil) — demo gerçek API'yi çağırır.
2. **demo-register sürüm çakışması:** Sunucu, `app_version`'ı **Android Play Store** sürümüyle
   karşılaştırıp eşitse 403/`DEMO_PUBLISHED_APP` döner. iOS build sürümü `1.0.1`; Android Play Store
   yayını yoksa fallback `1.0.0` → demo geçer. İleride Android `1.0.1` yayınlanırsa iOS demo'su
   kırılabilir — sürümleri ayrı tut.
3. **PrivacyInfo.xcprivacy bundle'a girdi mi:** CI `xcodegen generate` sonrası dosya "Copy Bundle
   Resources"ta olmalı (Resources/ zaten target source'u, otomatik girer). Build sonrası ASC'den
   privacy uyarısı gelmezse tamamdır.
4. **Store screenshot'ları:** External TestFlight için **gerekmez**. Production App Store yayınında
   gerekecek (6.7" + 6.5" iPhone setleri).
```
