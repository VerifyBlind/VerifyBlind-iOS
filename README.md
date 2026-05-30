# VerifyBlind.iOS

iOS portu (VerifyBlind.Android uygulamasının işlevsel eşdeğeri). Mac'siz geliştirme akışı için tasarlandı: kod VSCode'da yazılır, GitHub'a push'lanır, **CodeMagic** Mac runner'da build alır, **TestFlight**'a yükler, telefondan TestFlight uygulaması ile cihaza kurulur.

## Tek seferlik kurulum (Apple Dev hesabı onaylandıktan sonra)

### 1) Apple Developer Console
- App ID kayıt: bundle ID `app.verifyblind.ios` (geçici; final isim netleşince değiştirilebilir)
- Capabilities: NFC Tag Reading, App Attest, iCloud (CloudDocuments), Associated Domains
- App Store Connect'te yeni app oluştur (TestFlight Internal grubu hazırla)

### 2) App Store Connect API Key
- App Store Connect → Users and Access → Keys → "+" → Admin role
- `.p8` dosyasını indir, Key ID + Issuer ID'yi not al

### 3) CodeMagic ayarları
- App Store Connect Integration: yukarıdaki API Key'i CodeMagic > Teams > Integrations > App Store Connect'e ekle, name `VerifyBlind_ASC_API_Key`
- Code signing: CodeMagic Distribution → iOS code signing → otomatik provisioning (App Store distribution + manual signing)
- Environment groups oluştur:
  - **`verifyblind_ios_dev`** (dev branch için):
    - `APP_BASE_URL_DEV=https://dev.api.verifyblind.com/api/Verify/`
    - `IOS_BUNDLE_ID=app.verifyblind.ios`
    - `APPLE_TEAM_ID=<senin Team ID>`
    - `IOS_CERT_PIN_1=<SHA256 SPKI hash>`, `IOS_CERT_PIN_2=<root hash>`
    - `VERIFYBLIND_DEVELOPER_PUBLIC_KEY=<SPKI base64; sunucuyla aynı>`
    - `ICLOUD_CONTAINER_ID=iCloud.app.verifyblind.ios`
    - `SENTRY_DSN=<sentry projesinden alınır>`
    - `DROPBOX_IOS_APP_KEY=<dropbox dev console>`
    - `APP_STORE_APP_ID=<App Store Connect numerik ID>`
  - **`verifyblind_ios_prod`** (main branch için): Aynı değişkenler + `APP_BASE_URL_PROD=https://api.verifyblind.com/api/Verify/`

### 4) Sentry projesi
- sentry.io'da yeni iOS projesi → DSN'i kopyala → CodeMagic env'e gir

## Geliştirme akışı

```
[VSCode'da .swift düzenle]
        ↓
[git commit + git push origin dev]
        ↓
[CodeMagic auto-build (5-15 dk)]
        ↓
[TestFlight Internal'a yüklenir (5-30 dk processing)]
        ↓
[Telefonda TestFlight uygulamasından "Install"]
        ↓
[Cihazda aç → Sentry'de log'ları izle (browser)]
```

Branch stratejisi:
- `dev` → CodeMagic `ios-dev` workflow → TestFlight Internal grubu (App Attest dev environment)
- `main` → CodeMagic `ios-prod` workflow → TestFlight External grubu (App Attest prod environment)

## Kod organizasyonu

- `App/` — uygulama giriş noktası (`@main`, root view)
- `Config/` — xcconfig (build-time env injection) + Config.swift + entitlements
- `Core/` — paylaşılan altyapı: Logging, Crypto, Network, Storage, Security
- `Features/` — ekran/akış bazlı modüller: Register, Liveness, Login, Wallet, History, Settings, …
- `NFC/` — CoreNFC + NFCPassportReader bridge
- `Camera/`, `OCR/` — AVFoundation + Vision sarmalayıcılar
- `Backup/` — iCloud Drive + Dropbox provider'ları
- `Resources/` — Assets, Localizable
- `Tests/` — Unit + UI testleri
- `project.yml` — XcodeGen şeması (`.xcodeproj` Mac'te `xcodegen generate` ile üretilir; CodeMagic build'inde otomatik)
- `codemagic.yaml` — CI/CD pipeline (test + build + TestFlight upload)

## Lokal "soft check" (Mac yoksa)

Push etmeden önce yazım hatalarını yakalamak için VSCode + Swift extension:
- VSCode marketplace: **`Swift for Visual Studio Code`** (sourcekit-lsp tabanlı) yüklü olmalı
- VSCode marketplace: **`sweetpad`** Xcode-benzeri kolaylıklar
- `.vscode/settings.json` repoda hazır

Compile değil ama yazım/import hataları, signature uyumsuzlukları, missing types görünür.

## Konfigürasyon değişkenleri

Tüm build-time değerler **Info.plist üzerinden** akar:

```
CodeMagic env vars
        ↓
codemagic.yaml içinde xcconfig dosyasına yazılır
        ↓
Info.plist'teki $(VAR) referansları build sırasında doldurulur
        ↓
Config.swift Bundle.main.object(forInfoDictionaryKey:) ile okur
```

Lokal placeholder değerler `Config/Debug.xcconfig` ve `Config/Release.xcconfig` içinde; production'da CodeMagic her build'de bunların üzerine yazar. Hardcoded gizli değer YOK.

## Aşama 0 doğrulaması (ilk dummy build)

Beklenen sonuç:
1. CodeMagic build yeşil
2. TestFlight Internal'a yüklendi
3. Telefonda "Hello VerifyBlind" ekranı görünüyor
4. Build info satırları (bundle ID, version, API, Sentry) doluy
5. "Sentry'e test event gönder" butonuna basınca Sentry dashboard'da event görünüyor
6. Uygulama açıldığında log'lar Sentry'e akıyor

Doğrulanırsa Aşama 1 (Network + Crypto) başlar.
