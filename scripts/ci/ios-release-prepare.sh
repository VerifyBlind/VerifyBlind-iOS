#!/usr/bin/env bash
# Transparency release hazırlığı (Android dex-hashes.json paritesi, iOS provenance modeli).
# Apple'a yüklenen IPA'yı sabit isimle kopyalar, paket içindeki HER dosyanın SHA-256'sını ve
# sürüm bilgisini ipa-hashes.json'a yazar. Sonraki adımlar: attest-build-provenance (Sigstore
# imzalı SLSA provenance) + ios-release-publish.sh (GitHub Release build-N).
#
# Girdi : build/ios/ipa/*.ipa + env BUILD_NUMBER (ios-build-upload.sh GITHUB_ENV'e yazar),
#         GIT_COMMIT, GITHUB_REPOSITORY, GITHUB_ENV
# Çıktı : release-assets/{VerifyBlind.ipa, ipa-hashes.json} + GITHUB_ENV'e VERSION_NAME
set -euo pipefail

IPA_SRC=$(ls build/ios/ipa/*.ipa | head -1)
if [ ! -f "$IPA_SRC" ]; then
  echo "❌ build/ios/ipa altında IPA bulunamadı."
  exit 1
fi

mkdir -p release-assets
cp "$IPA_SRC" release-assets/VerifyBlind.ipa

WORK=$(mktemp -d)
unzip -q release-assets/VerifyBlind.ipa -d "$WORK"
APP_DIR=$(ls -d "$WORK"/Payload/*.app | head -1)

VERSION_NAME=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_DIR/Info.plist")
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_DIR/Info.plist")
echo "VERSION_NAME=$VERSION_NAME" >> "$GITHUB_ENV"

# Doğrulama zincirinin kilit taşı: kullanıcı telefonda "(Build N)" görür → release tag'i build-N.
# IPA'daki CFBundleVersion ile CI'ın TestFlight'tan hesapladığı BUILD_NUMBER aynı olmak zorunda.
if [ "$PLIST_BUILD" != "$BUILD_NUMBER" ]; then
  echo "❌ CFBundleVersion ($PLIST_BUILD) != BUILD_NUMBER ($BUILD_NUMBER) — tag eşleşmesi bozulur."
  exit 1
fi

IPA_SHA256=$(shasum -a 256 release-assets/VerifyBlind.ipa | awk '{print $1}')

JSON=release-assets/ipa-hashes.json
{
  echo "{"
  echo "  \"build_number\": $BUILD_NUMBER,"
  echo "  \"version_name\": \"$VERSION_NAME\","
  echo "  \"git_commit\": \"$GIT_COMMIT\","
  echo "  \"repository\": \"$GITHUB_REPOSITORY\","
  echo "  \"workflow\": \".github/workflows/ios-prod.yml\","
  echo "  \"ipa_sha256\": \"$IPA_SHA256\","
  echo "  \"files\": {"
} > "$JSON"

FIRST=1
while IFS= read -r f; do
  HASH=$(shasum -a 256 "$WORK/$f" | awk '{print $1}')
  if [ $FIRST -eq 1 ]; then FIRST=0; else printf ',\n' >> "$JSON"; fi
  printf '    "%s": "%s"' "$f" "$HASH" >> "$JSON"
done < <(cd "$WORK" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

printf '\n  }\n}\n' >> "$JSON"

echo ">>> ipa-hashes.json hazır: $(wc -l < "$JSON") satır"
echo ">>> IPA SHA-256: $IPA_SHA256"
rm -rf "$WORK"
