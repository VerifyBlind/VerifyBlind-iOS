#!/usr/bin/env bash
# Transparency release yayınlama: build-N tag'ine IPA + ipa-hashes.json + Sigstore attestation
# bundle'ını ekler; Türkçe doğrulama talimatlı release body + GITHUB_STEP_SUMMARY üretir.
# (Android build-android.yml "Create GitHub Release" + transparency report adımlarının paritesi.)
#
# Girdi env: BUILD_NUMBER, VERSION_NAME, GIT_COMMIT, ATTESTATION_BUNDLE (attest-build-provenance
#            outputs.bundle-path), GH_TOKEN, GITHUB_REPOSITORY, GITHUB_STEP_SUMMARY
set -euo pipefail

cp "$ATTESTATION_BUNDLE" release-assets/attestation.sigstore.json

TAG="build-$BUILD_NUMBER"
TITLE="VerifyBlind iOS v$VERSION_NAME (Build $BUILD_NUMBER)"
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
  --certificate-identity-regexp="^https://github.com/$GITHUB_REPOSITORY/.github/workflows/ios-prod.yml@" \\
  VerifyBlind.ipa
\`\`\`

## iOS'ta doğrulama Android'den neden farklı?

Android'de telefonunuzdaki APK'yı USB ile çekip hash'lerini GitHub'dakiyle bit-bit karşılaştırabilirsiniz. iOS'ta bu mümkün değil: Apple'ın FairPlay DRM'i App Store'dan inen her uygulamanın binary'sini şifreler ve stok bir iPhone'dan karşılaştırılabilir kopya çıkarılamaz. Bu, VerifyBlind'e özgü değil, platform kısıtıdır (Telegram dahil tüm iOS uygulamaları için geçerlidir). iOS'ta güven zinciri şöyle kapanır:

1. **Bu attestation** — Apple'a Build $BUILD_NUMBER olarak yüklenen IPA'nın yukarıdaki commit'ten derlendiğini matematiksel olarak kanıtlar. İmza, GitHub Actions'ın OIDC kimliğine (\`$GITHUB_REPOSITORY/.github/workflows/ios-prod.yml\`) bağlıdır; bu repo dışında kimse üretemez.
2. **Apple kod imzalama zorunluluğu** — stok iOS yalnızca Apple'ın imzaladığı App Store kopyasını çalıştırır; değiştirilmiş bir uygulama cihazda hiç açılmaz. Aynı build numarası App Store Connect'te yalnızca bir kez var olabilir.
3. **App Attest** — VerifyBlind sunucusu her kayıtta, cihazdaki uygulamanın gerçek App Store build'i olduğunu Apple üzerinden doğrular.

Telefonunuzda hangi build'in kurulu olduğunu **Ayarlar ekranının en altındaki sürüm satırında** görebilirsiniz: \`$VERSION_NAME ($BUILD_NUMBER) · $SHORT_SHA\` — satıra dokunmak bu sayfayı açar.
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
