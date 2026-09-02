# VerifyBlind — iOS

**Bu, VerifyBlind iOS uygulamasının herkese açık kaynak kodudur.** App Store'a yüklenen sürümün
**tam olarak burada gördüğünüz koddan** derlendiğini kriptografik olarak doğrulayabilirsiniz.

**This is the public source code of the VerifyBlind iOS app.** You can cryptographically verify that
the version published to the App Store was built from **exactly the code you see here**.

🌐 [verifyblind.com](https://verifyblind.com) · 📦 [Releases](https://github.com/VerifyBlind/VerifyBlind-iOS/releases) · 🤖 [Android](https://github.com/VerifyBlind/VerifyBlind-Android) · 🔐 [Enclave](https://github.com/VerifyBlind/VerifyBlind-Enclave)

**[🇹🇷 Türkçe](#türkçe) · [🇬🇧 English](#english)**

--- 

## Türkçe

### Bu repo nedir?

VerifyBlind, Türk dijital kimliğiyle çalışan **sıfır-bilgi (zero-knowledge)** bir kimlik doğrulama
sistemidir: kimlik numaranız (TCKN) cihazınızdan ve güvenli enclave'den asla dışarı çıkmaz. Bu
güvenlik vaadinin anlamlı olması için **çalıştırdığınız kodu doğrulayabilmeniz** gerekir.

> Bu repo, özel geliştirme monorepo'sunun **salt-okunur kaynak aynasıdır**. Her sürüm, herkese açık
> GitHub Actions üzerinde derlenir ve Sigstore imzalı build provenance ile yayınlanır.

### iOS'ta doğrulama Android'den neden farklı?

Android'de telefonunuzdaki APK'yı USB ile çekip GitHub'daki kodla bit-bit karşılaştırabilirsiniz.
iOS'ta bu **mümkün değildir**: Apple'ın FairPlay DRM'i App Store'dan inen her uygulamanın binary'sini
şifreler; stok bir iPhone'dan karşılaştırılabilir kopya çıkarılamaz. Bu VerifyBlind'e özgü değil, bir
platform kısıtıdır (Telegram dahil tüm iOS uygulamaları için geçerli). Bu yüzden iOS'ta güven zinciri
**üç bağımsız halkayla** kapanır:

1. **Build provenance (bu repo)** — Her release'e eklenen `attestation.sigstore.json`, App Store'a
   yüklenen IPA'nın yukarıdaki commit'ten, bu repo'nun GitHub Actions iş akışında derlendiğini
   matematiksel olarak kanıtlar. İmza, iş akışının OIDC kimliğine bağlıdır; bu repo dışında kimse üretemez.
2. **Apple kod imzalama zorunluluğu** — Stok iOS yalnızca Apple'ın imzaladığı App Store kopyasını
   çalıştırır; değiştirilmiş bir uygulama cihazda hiç açılmaz. Aynı build numarası App Store Connect'te
   yalnızca bir kez var olabilir.
3. **App Attest** — VerifyBlind sunucusu her kayıtta, cihazdaki uygulamanın gerçek App Store build'i
   olduğunu Apple üzerinden doğrular.

### Nasıl doğrularsınız?

Her [Release](https://github.com/VerifyBlind/VerifyBlind-iOS/releases) sayfasında `VerifyBlind.ipa`,
`ipa-hashes.json` ve `attestation.sigstore.json` bulunur.

**Otomatik:** [verify-ios.ps1 (Windows)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.ps1) ·
[verify-ios.sh (macOS / Linux)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.sh) — IPA
hash'ini manifest'le karşılaştırır ve attestation'ı cosign ile **çevrimdışı** doğrular.

**Manuel ([cosign](https://github.com/sigstore/cosign) ≥ 2.4):**
```bash
cosign verify-blob-attestation \
  --bundle attestation.sigstore.json --new-bundle-format \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp="^https://github.com/VerifyBlind/VerifyBlind-iOS/.github/workflows/ios-prod.yml@" \
  VerifyBlind.ipa
```

Telefonunuzdaki sürüm ve commit'i uygulama içinde **Ayarlar ekranının en altındaki sürüm satırında**
görebilirsiniz (`sürüm (build) · commit`); satıra dokunmak ilgili release sayfasını açar.

### Build nasıl çalışır?
GitHub Actions ([`.github/workflows/ios-prod.yml`](.github/workflows/ios-prod.yml) ve
[`ios-dev.yml`](.github/workflows/ios-dev.yml)) IPA'yı derler, `actions/attest-build-provenance` ile
Sigstore attestation üretir ve [`scripts/ci/ios-release-publish.sh`](scripts/ci/ios-release-publish.sh)
ile `build-N` (prod) / `dev-build-N` (dev) etiketli release yayınlar.

---

## English

### What is this repo?

VerifyBlind is a **zero-knowledge** identity verification system built on the Turkish digital ID: your
national ID number never leaves your device or the secure enclave. For that security promise to mean
anything, **you must be able to verify the code you are running**.

> This repo is a **read-only source mirror** of the private development monorepo. Every release is
> built on public GitHub Actions and published with Sigstore-signed build provenance.

### Why is iOS verification different from Android?

On Android you can pull the APK off your phone over USB and compare it bit-for-bit with the code on
GitHub. On iOS this is **impossible**: Apple's FairPlay DRM encrypts the binary of every App Store
download, so no comparable copy can be extracted from a stock iPhone. This is not specific to
VerifyBlind — it's a platform constraint (it applies to every iOS app, Telegram included). So on iOS
the chain of trust closes through **three independent links**:

1. **Build provenance (this repo)** — The `attestation.sigstore.json` attached to each release is
   mathematical proof that the IPA uploaded to the App Store was built from the commit above, in this
   repo's GitHub Actions workflow. The signature is bound to the workflow's OIDC identity; no one
   outside this repo can produce it.
2. **Apple code-signing enforcement** — Stock iOS only runs the App Store copy signed by Apple; a
   modified app will not even launch. The same build number can exist only once in App Store Connect.
3. **App Attest** — On every registration the VerifyBlind server verifies, via Apple, that the app on
   the device is the genuine App Store build.

### How to verify

Every [Release](https://github.com/VerifyBlind/VerifyBlind-iOS/releases) ships `VerifyBlind.ipa`,
`ipa-hashes.json` and `attestation.sigstore.json`.

**Automatic:** [verify-ios.ps1 (Windows)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.ps1) ·
[verify-ios.sh (macOS / Linux)](https://cdn.verifyblind.com/autoverifyscripts/verify-ios.sh) — compares
the IPA hash against the manifest and verifies the attestation **offline** with cosign.

**Manual (with [cosign](https://github.com/sigstore/cosign) ≥ 2.4):**
```bash
cosign verify-blob-attestation \
  --bundle attestation.sigstore.json --new-bundle-format \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp="^https://github.com/VerifyBlind/VerifyBlind-iOS/.github/workflows/ios-prod.yml@" \
  VerifyBlind.ipa
```

You can see your installed version and commit in the app, on the **version line at the bottom of the
Settings screen** (`version (build) · commit`); tapping it opens the matching release page.

### How the build works
GitHub Actions ([`.github/workflows/ios-prod.yml`](.github/workflows/ios-prod.yml) and
[`ios-dev.yml`](.github/workflows/ios-dev.yml)) builds the IPA, produces a Sigstore attestation via
`actions/attest-build-provenance`, and [`scripts/ci/ios-release-publish.sh`](scripts/ci/ios-release-publish.sh)
publishes a release tagged `build-N` (prod) / `dev-build-N` (dev).
