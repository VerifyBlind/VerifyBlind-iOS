#!/usr/bin/env bash
# Transparency release yayınlama: build-N tag'ine IPA + ipa-hashes.json + Sigstore attestation
# bundle'ını ekler; Türkçe doğrulama talimatlı release body + GITHUB_STEP_SUMMARY üretir.
# (Android build-android.yml "Create GitHub Release" + transparency report adımlarının paritesi.)
#
# Girdi env: BUILD_NUMBER, VERSION_NAME, GIT_COMMIT, ATTESTATION_BUNDLE (attest-build-provenance
#            outputs.bundle-path), GH_TOKEN, GITHUB_REPOSITORY, GITHUB_STEP_SUMMARY
set -euo pipefail

cp "$ATTESTATION_BUNDLE" release-assets/attestation.sigstore.json

# DEV_BUILD=true → "dev-build-N" (ios-dev.yml); boş/false → "build-N" (ios-prod.yml)
if [ "${DEV_BUILD:-false}" = "true" ]; then
  TAG="dev-build-$BUILD_NUMBER"
  TITLE="VerifyBlind iOS v$VERSION_NAME (Dev Build $BUILD_NUMBER)"
  WF_FILE="ios-dev.yml"
else
  TAG="build-$BUILD_NUMBER"
  TITLE="VerifyBlind iOS v$VERSION_NAME (Build $BUILD_NUMBER)"
  WF_FILE="ios-prod.yml"
fi
IPA_SHA256=$(shasum -a 256 release-assets/VerifyBlind.ipa | awk '{print $1}')
SHORT_SHA="${GIT_COMMIT:0:7}"

# ── Release body (markdown backtick'leri unquoted heredoc'ta \` ile escape edilir) ──────────────
cat > release-body.md << EOF
**Commit:** [\`$SHORT_SHA\`](https://github.com/$GITHUB_REPOSITORY/commit/$GIT_COMMIT)
**Version:** $VERSION_NAME (Build $BUILD_NUMBER)
**IPA SHA-256:** \`$IPA_SHA256\`

---

Bu release, App Store Connect'e yüklenen IPA'nın **bu commit'ten, herkese açık GitHub Actions üzerinde derlendiğinin** kriptografik kanıtını içerir (Sigstore imzalı SLSA build provenance):

| Dosya | Açıklama |
|-------|----------|
| \`VerifyBlind.ipa\` | Apple'a yüklenen imzalı paket (FairPlay şifrelemesi ÖNCESİ hali) |
| \`ipa-hashes.json\` | IPA'nın ve paket içindeki her dosyanın SHA-256 özeti |
| \`attestation.sigstore.json\` | Sigstore attestation — hangi repo/commit/workflow'un ürettiğinin imzalı kanıtı |

## Doğrulama

**Otomatik:** [verify-ios.ps1 (Windows)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.ps1) · [verify-ios.sh (macOS / Linux)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.sh)

**Manuel ([cosign](https://github.com/sigstore/cosign) ≥ 2.4 ile):**
\`\`\`bash
cosign verify-blob-attestation \\
  --bundle attestation.sigstore.json --new-bundle-format \\
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \\
  --certificate-identity-regexp="^https://github.com/$GITHUB_REPOSITORY/.github/workflows/$WF_FILE@" \\
  VerifyBlind.ipa
\`\`\`

## iOS'ta doğrulama Android'den neden farklı?

Android'de telefonunuzdaki APK'yı USB ile çekip hash'lerini GitHub'dakiyle bit-bit karşılaştırabilirsiniz. iOS'ta bu mümkün değil: Apple'ın FairPlay DRM'i App Store'dan inen her uygulamanın binary'sini şifreler ve stok bir iPhone'dan karşılaştırılabilir kopya çıkarılamaz. Bu, VerifyBlind'e özgü değil, platform kısıtıdır (Telegram dahil tüm iOS uygulamaları için geçerlidir). iOS'ta güven zinciri şöyle kapanır:

1. **Bu attestation** — Apple'a Build $BUILD_NUMBER olarak yüklenen IPA'nın yukarıdaki commit'ten derlendiğini matematiksel olarak kanıtlar. İmza, GitHub Actions'ın OIDC kimliğine (\`$GITHUB_REPOSITORY/.github/workflows/$WF_FILE\`) bağlıdır; bu repo dışında kimse üretemez.
2. **Apple kod imzalama zorunluluğu** — stok iOS yalnızca Apple'ın imzaladığı App Store kopyasını çalıştırır; değiştirilmiş bir uygulama cihazda hiç açılmaz. Aynı build numarası App Store Connect'te yalnızca bir kez var olabilir.
3. **App Attest** — VerifyBlind sunucusu her kayıtta, cihazdaki uygulamanın gerçek App Store build'i olduğunu Apple üzerinden doğrular.

Telefonunuzda hangi build'in kurulu olduğunu **Ayarlar ekranının en altındaki sürüm satırında** görebilirsiniz: \`$VERSION_NAME ($BUILD_NUMBER) · $SHORT_SHA\` — satıra dokunmak bu sayfayı açar.

---

## English

This release contains cryptographic proof that the IPA uploaded to App Store Connect was **built from this commit on public GitHub Actions** (Sigstore-signed SLSA build provenance):

| File | Description |
|------|-------------|
| \`VerifyBlind.ipa\` | The signed package uploaded to Apple (BEFORE FairPlay encryption) |
| \`ipa-hashes.json\` | SHA-256 of the IPA and of every file inside the bundle |
| \`attestation.sigstore.json\` | Sigstore attestation — signed proof of which repo/commit/workflow produced it |

### Verify

**Automatic:** [verify-ios.ps1 (Windows)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.ps1) · [verify-ios.sh (macOS / Linux)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.sh)

**Manual (with [cosign](https://github.com/sigstore/cosign) ≥ 2.4):**
\`\`\`bash
cosign verify-blob-attestation \\
  --bundle attestation.sigstore.json --new-bundle-format \\
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \\
  --certificate-identity-regexp="^https://github.com/$GITHUB_REPOSITORY/.github/workflows/$WF_FILE@" \\
  VerifyBlind.ipa
\`\`\`

### Why is iOS verification different from Android?

On Android you can pull the APK off your phone over USB and compare its hashes bit-for-bit with GitHub. On iOS this is impossible: Apple's FairPlay DRM encrypts the binary of every App Store download, so no comparable copy can be extracted from a stock iPhone. This is not specific to VerifyBlind — it is a platform constraint (it applies to every iOS app, Telegram included). On iOS the chain of trust closes as follows:

1. **This attestation** mathematically proves that the IPA uploaded to Apple as Build $BUILD_NUMBER was built from the commit above. The signature is bound to the GitHub Actions OIDC identity (\`$GITHUB_REPOSITORY/.github/workflows/$WF_FILE\`); no one outside this repo can produce it.
2. **Apple code-signing enforcement** — stock iOS only runs the App Store copy signed by Apple; a modified app will not even launch on the device. The same build number can exist only once in App Store Connect.
3. **App Attest** — on every registration the VerifyBlind server verifies, via Apple, that the app on the device is the genuine App Store build.

You can see which build is installed on the **version line at the bottom of the Settings screen**: \`$VERSION_NAME ($BUILD_NUMBER) · $SHORT_SHA\` — tapping it opens this page.
EOF

# ── Step summary (workflow sayfasındaki şeffaflık raporu) ───────────────────────────────────────
{
  echo "### VerifyBlind iOS Build Transparency Report"
  echo ""
  echo "| Alan | Değer |"
  echo "|------|-------|"
  echo "| **Versiyon** | $VERSION_NAME (Build $BUILD_NUMBER) |"
  echo "| **Commit** | [\`$SHORT_SHA\`](https://github.com/$GITHUB_REPOSITORY/tree/$GIT_COMMIT) |"
  echo "| **IPA SHA-256** | \`$IPA_SHA256\` |"
  echo "| **Release** | [\`$TAG\`](https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG) |"
  echo ""
  echo "Doğrulama talimatları release sayfasında."
} >> "$GITHUB_STEP_SUMMARY"

# ── Release oluştur (re-run toleransı: eski tag/release silinir, Android paritesi) ──────────────
gh release delete "$TAG" --yes 2>/dev/null || true
git push origin ":refs/tags/$TAG" 2>/dev/null || true
gh release create "$TAG" \
  --title "$TITLE" \
  --notes-file release-body.md \
  --repo "$GITHUB_REPOSITORY" \
  release-assets/VerifyBlind.ipa \
  release-assets/ipa-hashes.json \
  release-assets/attestation.sigstore.json

echo ">>> Release yayınlandı: https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG"
