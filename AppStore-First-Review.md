# App Store Review Runbook (Beta ✅ + Production)

> Güncellendi: **2026-06-27**. External TestFlight **Beta App Review = TAMAM** (2026-06-09).
> Bu doküman artık **Production App Store submission**'ı kapsar.
>
> ⚠️ **Önemli düzeltme:** Demo modu görünürlük mekanizması bu dokümanın eski sürümünde yanlış
> anlatılıyordu (`demoEnabled = dev || Config.isTestFlight`). O mekanizma artık YOK. Güncel ve doğru
> hali **Bölüm 0**'da. `Config.isTestFlight` ölü koddu, kaldırıldı.

---

## BÖLÜM 0 — Demo modu nasıl çalışıyor (GÜNCEL — production review'ın çekirdeği)

Demo modu artık **tamamen sunucu-kontrollü, sürüm-eşleşmeli**dir. Receipt (`sandboxReceipt`) ile ilgisi
yoktur.

**Mekanizma:**
1. **Admin** `PATCH /api/admin/demo-versions` ile `demoVersionIos` değerini `system_settings`'e yazar
   (`AdminController.SetDemoVersions`).
2. **iOS client** açılışta `loadConfig` ile app-config çeker ve:
   `demoEnabled = (demoVersionIos != "" && demoVersionIos == CFBundleShortVersionString)`
   (`App/AppState.swift` → `loadConfig`). Eşleşmezse demo butonu **gizli**.
3. **Sunucu demo-register guard** da **platform-aware**'dir ve aynı sürüme kilitlidir
   (`VerifyController` ~443-453): `platform=="ios" ? DemoVersionIosKey : DemoVersionAndroidKey`;
   `AppVersion != demoVersion` ise `404 DEMO_NOT_ACTIVE` döner. Yani sadece butonu gizlemekle kalmaz,
   backend de kapanır.

**Production review için bunun anlamı (kritik avantaj):**
Aynı binary'yi hem review ettirir hem yayınlarsın; demo görünürlüğünü **rebuild gerektirmeden,
sunucudan aç/kapat** edebilirsin:
- Review için: `demoVersionIos = <submit edilen build sürümü>` → reviewer kartsız tüm akışı dener.
- Yayından hemen önce: `demoVersionIos = ""` → demo butonu + demo-register herkese kapanır.

> Eski "demo-register Android Play sürümüyle çakışır" notu da artık geçersiz — guard platform-aware.

---

## BÖLÜM 1 — Kod tarafı durum (Claude)

| # | Konu | Durum | Dosya |
|---|------|-------|-------|
| 1 | **Privacy Manifest** (2024-05'ten beri zorunlu) | ✅ Var | `Resources/PrivacyInfo.xcprivacy` |
| 2 | **Demo görünürlüğü** — sunucu-kontrollü sürüm eşleşmesi | ✅ Bölüm 0 | `App/AppState.swift`, `Controllers/{Admin,Config,Verify}Controller.cs` |
| 3 | **Export compliance** — `ITSAppUsesNonExemptEncryption` | ✅ **`true`** (2026-06-27) | `App/Info.plist` |
| 4 | Ölü `Config.isTestFlight` kaldırıldı | ✅ | `Config/Config.swift` |

**Export compliance kararı (verildi):** VerifyBlind kimlik payload'ını uygulama katmanında özel
protokolle şifreliyor (RSA-OAEP-SHA256 + AES-GCM + RSA-PSS + cert pinning) → "yalnız HTTPS/auth"
muafiyeti DEĞİL. Doğru beyan `true`. ASC submit'inde export sorularına **standart-algoritma /
mass-market muafiyeti** (5D992) ile cevap verilir; bu, yılda bir basit self-classification gerektirebilir.
Detay → **Bölüm 2 / Adım 2**.

---

## BÖLÜM 2 — Production submission adımları (App Store Connect)

### Adım 0 — Ön koşullar
- [ ] App Store Connect'te uygulama kaydı (Bundle ID: `app.verifyblind.ios`).
- [ ] Prod GitHub Actions secret'ları dolu (`ios-prod.yml`): `APP_STORE_APP_ID`,
      `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`, `APP_STORE_CONNECT_PRIVATE_KEY`,
      `CERTIFICATE_PRIVATE_KEY`, `APPLE_TEAM_ID` (+ Sentry/Dropbox/Google). Cert pin'leri koda gömülü.
- [ ] **Backend canlı:** demo `api.verifyblind.com/api/verify/demo-register`'ı çağırır. Review penceresi
      boyunca prod API + Enclave ayakta olmalı, yoksa reviewer demo'da hata görür → red.

### Adım 1 — Privacy Policy URL
- [ ] ASC'ye **locale önekli** URL ver (çıplak `/privacy` redirect verme):
      `https://verifyblind.com/en/gizlilik` (reviewer için EN).
- [ ] **Submit öncesi tutarlılık düzeltmeleri** (App Privacy label ↔ politika uyumu; kaynak
      `src/landing-site/app/[locale]/gizlilik/page.tsx`):
  1. **Sentry/çökme teşhisi 3. taraf olarak** politikanın "Paylaştığımız Taraflar" tablosunda olmalı
     (label "Crash Data" diyecek). Bir satır ekle (PII redakte).
  2. Güvenlik bölümüne **iOS Keychain / Secure Enclave** ekle (yalnız "Android Keystore" demesin).
  3. (İyi olur) Kullanıcı-başlatımlı, uçtan-uca şifreli **bulut yedek (Dropbox/Google Drive)** cümlesi.

### Adım 2 — Export Compliance (plist artık `true`)
`App/Info.plist` → `ITSAppUsesNonExemptEncryption = true`. Submit sırasında ASC export sorularını sorar:
- "Does your app use encryption?" → **Yes**.
- "Qualifies for any of the exemptions?" → **Yes** — standart/yayınlanmış algoritmalar, mass-market
  (5D992). VerifyBlind özel kripto-sistem ÜRETMİYOR; standart RSA/AES/ECDSA kullanıyor.
- Sonuç: muaf. ASC bir **yıl-sonu self-classification** (Fransa için ek beyan) isteyebilir — basittir.
> Bunu hukuki danışmanla teyit etmen iyi olur; teknik sınıflandırma yukarıdaki gibi.

### Adım 3 — App Privacy (Privacy Nutrition Labels)
ASC → App Privacy. Zero-knowledge mimariye göre:
- **Do you collect data?** → **Yes** (yalnız çökme teşhisi — Sentry).
- **Diagnostics → Crash Data** ✅ → Purpose: *App Functionality*, Linked: **No**, Tracking: **No**.
- **Performance Data EKLEME** (`enableAutoPerformanceTracing = false`).
- **Tracking** → **None**. **Data Linked to You** → **None**.
- Başka kategori (Contact, Identifiers, Location, Health, Financial…) **işaretleme**.
- **Kimlik/biyometrik veri neden "collected" DEĞİL:** Enclave public key'iyle uçtan-uca şifrelenir,
  gerçek-zamanlı işlenir, **saklanmaz** → Apple'ın "collect" tanımına girmez. (Koşul: backend gerçekten
  saklamıyor — çekirdek mimari bu.) Bu yüzden label'a eklenmez; zero-knowledge iddiasıyla tutarlı.
- **Device ID:** push bildirimi UI'da aktifse ve cihaz token'ı toplanıyorsa
  Identifiers → Device ID (App Functionality, Not Linked, No tracking) ekle. Aksi halde ekleme.
- Chatbot UI'da aktif değilse User Content ekleme.

### Adım 4 — App Information / Age Rating / Category
- [ ] **Age Rating** → kısa anket; sakıncalı içerik yok → 4+.
- [ ] **Content Rights** → 3. taraf içerik? Hayır.
- [ ] **Category** → Utilities veya Business.

### Adım 5 — Store Listing (PRODUCTION'DA ZORUNLU — beta'da gerekmiyordu)
- [ ] **Screenshots** — iPhone **6.9"/6.7"** ve **6.5"** setleri (App Store'un istediği güncel boyutlar).
      Demo akışından alınmış ekranlar uygundur (kartsız çekilebilir).
- [ ] **App Name / Subtitle / Promotional Text / Description / Keywords**.
- [ ] **Support URL** (`https://verifyblind.com`), **Marketing URL**, **Privacy Policy URL** (Adım 1).
- [ ] Hedef ülke: **yalnız Türkiye** (ilk lansman).

### Adım 6 — Build üret/seç + App Store sürümüne iliştir
İki seçenek:
- **(En hızlı) Mevcut build'i kullan:** kod değişmediyse, hâlihazırda TestFlight'a yüklenmiş build'i
  App Store sürümüne iliştir. (Bu doküman + Info.plist değişikliği kod değişikliğidir → yeni build
  gerekir; bkz aşağı.)
- **Yeni build:** `main`'e push veya GitHub Actions → **"iOS Prod → TestFlight External"**
  (`ios-prod.yml`) `workflow_dispatch`. Build ASC'ye yüklenir (TestFlight'a düşer; App Store sürümüne
  de aynı build iliştirilir). Build numarası otomatik +1.
  > ⚠️ `ITSAppUsesNonExemptEncryption=true` ve `isTestFlight` kaldırma değişiklikleri yeni build
  > gerektirir — bu yüzden bu submit'te **yeni build** kullan.

### Adım 7 — Demo'yu reviewer için AÇ
- [ ] Admin panel → demo sürümleri → `demoVersionIos = <submit edilen build'in CFBundleShortVersionString'i>`
      (örn. `1.0.1`). Backend `PATCH /api/admin/demo-versions`.
- [ ] Doğrula: o build'de demo butonu görünüyor + demo-register çalışıyor.

### Adım 8 — Submit for App Store Review
- [ ] App Store sürümü oluştur → build'i iliştir → **App Review Information** → **Bölüm 3.1 (EN)**
      reviewer notes + iletişim (ad/telefon/email).
- [ ] **Version Release** → **"Manually release this version"** seç (kontrolü elde tut).
- [ ] (Opsiyonel ama önerilir) Gerçek NFC+canlılık akışını gösteren kısa video linki notes'a — reviewer
      demo ile geçse de "gerçek çekirdek işlev çalışıyor mu" sorusunu önceden kapatır.

### Adım 9 — Onay → yayın (demo'yu KAPAT, sonra release)
- [ ] Durum **"Pending Developer Release"** (onaylandı) olunca:
      admin → `demoVersionIos = ""` (boş). Demo butonu + demo-register **tüm public** için kapanır.
- [ ] Sonra ASC → **Release this version** → uygulama canlı.
> Sıra önemli: önce demo'yu kapat, sonra release. Manuel release bu kontrolü sağlar.

---

## BÖLÜM 3 — KOPYALA-YAPIŞTIR METİNLER

### 3.1 — Reviewer Notes (App Review Information → Notes) — **EN (birincil)**

```
VerifyBlind is a privacy-first "Proof of Personhood" / digital identity app. Users prove they are a
real, unique human using their Turkish NFC ID card + a face liveness check, WITHOUT exposing their
national ID number to third parties (zero-knowledge). It is NOT a KYC/data-collection app.

IMPORTANT FOR REVIEW — no physical ID card needed:
Normal use requires a physical Turkish NFC ID card, which you will not have. The app therefore
includes a built-in DEMO MODE that walks through the entire flow without any card or real biometric
data. Demo mode is enabled for this review build.

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

Encryption (export compliance): The app uses only standard, published algorithms (RSA-OAEP, AES-GCM,
RSA-PSS) for end-to-end protection of the identity payload; no proprietary cryptography. Qualifies
for the mass-market exemption.

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
tüm akışı kartsız ve gerçek biyometri olmadan gezdiren bir DEMO MODU vardır (bu review build'inde
açıktır).

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

Şifreleme (export compliance): Uygulama yalnızca standart, yayınlanmış algoritmalar (RSA-OAEP,
AES-GCM, RSA-PSS) kullanır; özel/tescilli kripto yoktur. Mass-market muafiyetine girer.

Ağ: Demo, api.verifyblind.com backend'ine istek atar; review penceresinde canlıdır.

İletişim: <ADIN SOYADIN> — <EMAIL> — <TELEFON>
```

### 3.3 — App Store Description — **EN / TR**

EN:
```
VerifyBlind lets you prove you are a real, unique person to websites and apps using your NFC ID card
and a quick face check — without ever sharing your ID number. Your identity stays encrypted on your
device.
```
TR:
```
VerifyBlind, NFC kimlik kartınız ve hızlı bir yüz kontrolü ile, kimlik numaranızı hiç paylaşmadan,
gerçek ve tekil bir kişi olduğunuzu web sitelerine ve uygulamalara kanıtlamanızı sağlar. Kimliğiniz
cihazınızda şifreli kalır.
```

---

## BÖLÜM 4 — Operasyonel watch-item'lar (red riskini azaltır)

1. **Backend canlı olsun** (Enclave dahil) — demo gerçek API'yi çağırır.
2. **Demo sürüm eşleşmesi:** `demoVersionIos` submit edilen build'in `CFBundleShortVersionString`'i ile
   **birebir** aynı olmalı (yoksa reviewer demo butonunu göremez). Guard platform-aware
   (`VerifyController`), Android demo sürümüyle çakışmaz.
3. **Yayından önce demo'yu KAPAT** (`demoVersionIos = ""`) — public kullanıcılar demo görmesin.
4. **PrivacyInfo.xcprivacy bundle'a girdi mi:** CI `xcodegen generate` sonrası "Copy Bundle
   Resources"ta olmalı; ASC'den privacy uyarısı gelmezse tamam.
5. **Screenshots:** Production'da ZORUNLU (6.9"/6.7" + 6.5"). Beta'da gerekmiyordu.
6. **Video (opsiyonel):** Gerçek cihazda NFC kart okuma + yüz canlılık + başarı — 45-90 sn, TCKN
   bulanık, unlisted link. "Gerçek çekirdek işlev çalışıyor mu" sorusunu önceden kapatır.
