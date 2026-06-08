#!/usr/bin/env bash
# Shared iOS signed build + dSYM + TestFlight upload (GitHub Actions).
# Env: APP_ATTEST_ENVIRONMENT (development|production), optional BETA_GROUP.
# All secrets injected by workflow job via env:.
set -euo pipefail

XCODE_SCHEME="VerifyBlind"
XCODE_PROJECT="VerifyBlind.xcodeproj"
BUNDLE_ID="${BUNDLE_ID:-app.verifyblind.ios}"

# ── 1. Resolve next build number from TestFlight ──────────────────────────────
echo "=== Build number: TestFlight latest +1 ==="
LATEST=$(app-store-connect get-latest-testflight-build-number "$APP_STORE_APP_ID" \
  --issuer-id "$APP_STORE_CONNECT_ISSUER_ID" \
  --key-id "$APP_STORE_CONNECT_KEY_IDENTIFIER" \
  --private-key "@env:APP_STORE_CONNECT_PRIVATE_KEY" 2>/dev/null || echo 0)
BUILD_NUMBER=$(( ${LATEST:-0} + 1 ))
echo "BUILD_NUMBER=$BUILD_NUMBER" >> "$GITHUB_ENV"
echo "TestFlight latest=${LATEST:-0} → new build number=$BUILD_NUMBER"

# ── 2. Generate xcconfig ──────────────────────────────────────────────────────
echo "=== Generate xcconfig ==="
# xcconfig treats '//' as comment start → URL/DSN values get truncated.
# Escape '//' → '/$()/' ($() expands to empty string at Xcode build time). gotcha #10.
DSN_ESC=$(printf '%s' "${SENTRY_DSN:-}" | sed 's|//|/$()/|g')

xcconfig_body() {
  echo "API_BASE_URL = https:/\$()/api.verifyblind.com/api/verify/"
  echo "CERT_PIN_1 = ${CERT_PIN_1:-}"
  echo "CERT_PIN_2 = ${CERT_PIN_2:-}"
  echo "ENCLAVE_DEVELOPER_PUBLIC_KEY = ${ENCLAVE_DEVELOPER_PUBLIC_KEY:-}"
  echo "APPLE_TEAM_ID = ${APPLE_TEAM_ID}"
  echo "IOS_BUNDLE_ID = ${BUNDLE_ID}"
  echo "APP_ATTEST_ENVIRONMENT = ${APP_ATTEST_ENVIRONMENT}"
  echo "ICLOUD_CONTAINER_ID = iCloud.${BUNDLE_ID}"
  echo "SENTRY_DSN = $DSN_ESC"
  echo "DROPBOX_IOS_APP_KEY = ${DROPBOX_IOS_APP_KEY:-}"
  echo "BUILD_NUMBER = $BUILD_NUMBER"
}

if [ "$APP_ATTEST_ENVIRONMENT" = "development" ]; then
  # build uses --config Release → Release.xcconfig is read; but also write Debug.xcconfig
  # so dev values don't accidentally load prod config from a stale file. gotcha #9.
  xcconfig_body | tee Config/Debug.xcconfig > Config/Release.xcconfig
else
  xcconfig_body > Config/Release.xcconfig
fi

# ── 3. Generate Xcode project ─────────────────────────────────────────────────
echo "=== XcodeGen ==="
xcodegen generate

# ── 4. Place locked Package.resolved ─────────────────────────────────────────
echo "=== Place locked Package.resolved ==="
DEST="$XCODE_PROJECT/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$DEST"
cp Package.resolved "$DEST/Package.resolved"

# ── 5. Resolve SPM dependencies ───────────────────────────────────────────────
echo "=== Resolve SPM dependencies ==="
xcodebuild -resolvePackageDependencies \
  -project "$XCODE_PROJECT" \
  -scheme "$XCODE_SCHEME"

# ── 6. Keychain + distribution cert + provisioning profile ───────────────────
echo "=== Signing ==="
keychain initialize

app-store-connect fetch-signing-files "$BUNDLE_ID" \
  --type IOS_APP_STORE \
  --issuer-id "$APP_STORE_CONNECT_ISSUER_ID" \
  --key-id "$APP_STORE_CONNECT_KEY_IDENTIFIER" \
  --private-key "@env:APP_STORE_CONNECT_PRIVATE_KEY" \
  --certificate-key "@env:CERTIFICATE_PRIVATE_KEY" \
  --create

keychain add-certificates

xcode-project use-profiles

# ── 7. Build IPA ──────────────────────────────────────────────────────────────
echo "=== Build IPA ==="
xcode-project build-ipa \
  --project "$XCODE_PROJECT" \
  --scheme "$XCODE_SCHEME" \
  --config Release

# ── 8. Upload dSYMs to Sentry ─────────────────────────────────────────────────
echo "=== dSYM upload to Sentry ==="
# Silent skip if credentials missing — build must not fail on missing Sentry vars. gotcha #12.
# --include-sources: embeds source at build time → inline code in Sentry stack traces (repo public).
if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
  echo "⚠️  SENTRY_AUTH_TOKEN/SENTRY_ORG/SENTRY_PROJECT eksik — dSYM upload atlandı."
else
  command -v sentry-cli >/dev/null 2>&1 || curl -sL https://sentry.io/get-cli/ | bash
  sentry-cli debug-files upload \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    --include-sources \
    build/ios \
    "$HOME/Library/Developer/Xcode/DerivedData"
fi

# ── 9. Upload IPA to TestFlight ───────────────────────────────────────────────
echo "=== TestFlight upload ==="
# Internal testers receive every processed build automatically — no group assignment needed or
# allowed via API ("Cannot add internal group to a build"). gotcha #11.
# --beta-group only for external groups (prod only).
PUBLISH_ARGS=(
  "app-store-connect" "publish"
  "--path" "build/ios/ipa/*.ipa"
  "--testflight"
  "--key-id" "$APP_STORE_CONNECT_KEY_IDENTIFIER"
  "--issuer-id" "$APP_STORE_CONNECT_ISSUER_ID"
  "--private-key" "@env:APP_STORE_CONNECT_PRIVATE_KEY"
  "--expire-build-submitted-for-review"
)
# --expire-build-submitted-for-review her zaman eklenir (dev + prod): publish --testflight her
# build'de BetaAppReviewSubmission oluşturur; önceki beklemedeyse "Another build in review" 422
# hatası verir. expire ile eskiyi sil, yenisini gir. Internal testçiler review bitmeden build'i
# alır (VALID olur olmaz otomatik dağıtım), bu sadece Apple'ın arka plan sürecidir. gotcha #13.
# --beta-group yalnız prod: external testçilere yönlendirme + review zorunlu. gotcha #11.
if [ -n "${BETA_GROUP:-}" ]; then
  PUBLISH_ARGS+=("--beta-group" "$BETA_GROUP")
fi

# Apple altyapısı upload SONRASI adımlarda (RETRIEVE UPLOAD OPERATIONS / beta-review) zaman zaman
# geçici 500 verip altool'u exit≠0 yapıyor — IPA aslında YÜKLENMİŞ oluyor ("UPLOAD SUCCEEDED").
# Internal testçiler binary VALID olunca otomatik alır; post-adımlar best-effort. Bu yüzden:
# yalnızca çıktıda "UPLOAD SUCCEEDED" VARSA publish hatasını yut; YOKSA gerçekten başarısızdır → fail.
PUBLISH_LOG="$(mktemp)"
set +e
"${PUBLISH_ARGS[@]}" 2>&1 | tee "$PUBLISH_LOG"
PUBLISH_RC=${PIPESTATUS[0]}
set -e
if [ "$PUBLISH_RC" -ne 0 ]; then
  if grep -q "UPLOAD SUCCEEDED" "$PUBLISH_LOG"; then
    echo "⚠️  publish exit=$PUBLISH_RC ama IPA yüklendi (UPLOAD SUCCEEDED) — Apple geçici post-adım hatası, build YEŞİL sayılıyor."
  else
    echo "❌ publish başarısız (UPLOAD SUCCEEDED yok) — gerçek yükleme hatası."
    exit "$PUBLISH_RC"
  fi
fi
