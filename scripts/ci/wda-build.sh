#!/usr/bin/env bash
#
# WebDriverAgent'i imzalayıp .ipa üretir — Windows'taki test pilotunun iPhone'u
# sürebilmesi için.
#
# NEDEN GEREKLİ: iOS'u Windows'tan sürmenin yolu WDA'dan (Apple'ın XCUITest
# çerçevesi üzerine kurulu ajan) geçiyor. WDA cihaza kurulduktan sonra HTTP API
# açıyor ve pilot onunla konuşuyor; ama kurulabilmesi için ÖNCE imzalanması
# gerekiyor ve imzalama macOS ister. Mac'imiz yok — bu yüzden zaten uygulamayı
# derlediğimiz CI runner'ında imzalıyoruz.
#
# NEDEN AYRI BİR BUNDLE ID: WDA uygulamanın kendisi değil, ayrı bir test
# koşucusu. Uygulamanın kimliğiyle imzalanamaz; kendi App ID'si olmalı.
#
# NEDEN DEVELOPMENT PROFİLİ (App Store DEĞİL): WDA mağazaya gitmiyor, belirli
# bir cihaza kuruluyor. Development profili yalnızca hesaba KAYITLI cihazlarda
# çalışır, o yüzden telefonun UDID'si önce kaydedilir.
#
# ⚠️ PROFİL SÜRESİ: development profilleri bir yıl geçerli. Süresi dolunca WDA
# cihazda AÇILMAZ ve pilot "bağlanamıyorum" der — sebebi görünmez. Böyle bir
# durumda ilk bakılacak yer budur; iş akışını yeniden koşmak yeter.
set -euo pipefail

: "${APP_STORE_CONNECT_ISSUER_ID:?eksik}"
: "${APP_STORE_CONNECT_KEY_IDENTIFIER:?eksik}"
: "${APP_STORE_CONNECT_PRIVATE_KEY:?eksik}"
: "${APPLE_TEAM_ID:?eksik}"
: "${DEVICE_UDID:?eksik — pilotun süreceği iPhone'un UDID'si}"

WDA_REPO="https://github.com/appium/WebDriverAgent.git"
WDA_DIR="${WDA_DIR:-$PWD/wda-src}"
# Uygulamanın bundle id'sinin ALTINDA: aynı takıma ait olduğu açık olsun ve
# App ID listesinde uygulamanın yanında dursun.
WDA_BUNDLE_ID="${WDA_BUNDLE_ID:-app.verifyblind.ios.wda}"
CIKTI="${CIKTI:-$PWD/build/wda}"

echo "=== 1. WebDriverAgent kaynağı ==="
if [ ! -d "$WDA_DIR" ]; then
  # Appium'un çatalı: yukarı akış Facebook deposu arşivlendi, bakım burada.
  git clone --depth 1 "$WDA_REPO" "$WDA_DIR"
fi
cd "$WDA_DIR"
git log -1 --format='WDA commit: %h %s'

echo "=== 2. Cihazı hesaba kaydet ==="
# Zaten kayıtlıysa hata verir; bu bir arıza DEĞİL, o yüzden yutuluyor. Kaydın
# GERÇEKTEN olup olmadığı 3. adımda profil üretilirken belli olur.
app-store-connect devices register \
  --udid "$DEVICE_UDID" \
  --name "pilot-iphone" \
  --platform IOS \
  --issuer-id "$APP_STORE_CONNECT_ISSUER_ID" \
  --key-id "$APP_STORE_CONNECT_KEY_IDENTIFIER" \
  --private-key "@env:APP_STORE_CONNECT_PRIVATE_KEY" || \
  echo "  (cihaz zaten kayıtlı olabilir — devam ediliyor)"

echo "=== 3. İmzalama: OTOMATİK, App Store Connect anahtarıyla ==="
# ⚠️ `fetch-signing-files` + `use-profiles` YOLU BURADA ÇALIŞMIYOR.
# `use-profiles` profilleri hedeflere BUNDLE ID'ye bakarak eşliyor. WDA'nın
# projedeki kimlikleri `com.facebook.*` olarak geliyor; bizim ürettiğimiz
# profiller `app.verifyblind.ios.wda` için olduğu için hiçbir hedefe eşleşmedi,
# projeye hiçbir şey yazılmadı ve derleme "requires a development team" ile
# düştü (CI koşusu 33421225916). Bundle id'yi komut satırında değiştirmek de
# kurtarmıyor: `use-profiles` ondan ÖNCE koşuyor.
#
# Onun yerine Xcode'un kendi otomatik imzalaması kullanılıyor: App Store Connect
# anahtarıyla `-allowProvisioningUpdates`, gerekli App ID'yi ve development
# profilini Xcode kendisi üretip indiriyor. Cihaz 2. adımda kaydedildiği için
# profil onu içeriyor.
ANAHTAR_DIZIN="$HOME/private_keys"
mkdir -p "$ANAHTAR_DIZIN"
ANAHTAR="$ANAHTAR_DIZIN/AuthKey_${APP_STORE_CONNECT_KEY_IDENTIFIER}.p8"
printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" > "$ANAHTAR"
chmod 600 "$ANAHTAR"

echo "=== 4. Derleme (build-for-testing) ==="
# 'build-for-testing': XCTest koşucusu üretir, testi ÇALIŞTIRMAZ. Çalıştırmayı
# cihazda pilot yapacak.
# 'generic/platform=iOS': belirli bir cihaz/simülatör seçmez — çıktı gerçek
# cihaza kurulabilir bir .app olur.
ARGS=(build-for-testing
  -project WebDriverAgent.xcodeproj
  -scheme WebDriverAgentRunner
  -destination 'generic/platform=iOS'
  -derivedDataPath "$CIKTI/DerivedData"
  -allowProvisioningUpdates
  -authenticationKeyPath "$ANAHTAR"
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_IDENTIFIER"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
  CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
  PRODUCT_BUNDLE_IDENTIFIER="$WDA_BUNDLE_ID"
)
xcodebuild "${ARGS[@]}"

echo "=== 5. .ipa paketle ==="
UYGULAMA=$(find "$CIKTI/DerivedData/Build/Products" -name 'WebDriverAgentRunner-Runner.app' -maxdepth 3 | head -1)
if [ -z "$UYGULAMA" ]; then
  echo "::error::WebDriverAgentRunner-Runner.app bulunamadı — derleme çıktısı beklenen yerde değil."
  exit 1
fi
echo "  bulundu: $UYGULAMA"

rm -rf "$CIKTI/Payload"
mkdir -p "$CIKTI/Payload"
cp -R "$UYGULAMA" "$CIKTI/Payload/"
( cd "$CIKTI" && zip -qry WebDriverAgentRunner.ipa Payload )

echo "=== Tamam ==="
ls -la "$CIKTI/WebDriverAgentRunner.ipa"
echo "bundle id: $WDA_BUNDLE_ID"
