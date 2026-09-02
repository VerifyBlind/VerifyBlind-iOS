# Tools

## convert_mobilefacenet_to_coreml.ipynb

Android'in `mobilefacenet.tflite` modelini iOS CoreML `.mlpackage`'a çeviren **tek seferlik**
Google Colab notebook'u. Cihaz-içi canlı yüz-eşleşme %'si (Aşama 3) için gereklidir.

**Neden Colab:** coremltools Windows'ta çalışmaz; Colab ücretsiz + tarayıcı tabanlı (Mac gerekmez).

**Önemli:** Dönüşüm **yalnızca 1 kez** yapılır. Üretilen `MobileFaceNet.mlpackage` repoya
(`Resources/`) commit edilir; Xcode onu her build'de yalnızca *derler* — coremltools'u
TEKRAR çalıştırmaz. Per-build maliyet **sıfır**.

### Kullanım
1. [colab.research.google.com](https://colab.research.google.com) → **File → Upload notebook** →
   bu `.ipynb`'yi yükle.
2. **Runtime → Run all**. İstendiğinde `mobilefacenet.tflite`'ı yükle
   (`src/VerifyBlind.Android/app/src/main/assets/mobilefacenet.tflite`).
3. Parite hücresinde **cosine ≥ 0.99** gör (dönüşüm sadık).
4. İnen `MobileFaceNet.mlpackage.zip`'i aç → `MobileFaceNet.mlpackage`'ı
   `src/VerifyBlind.iOS/Resources/`'a koy → commit + push (`dev`).

Model commit'lenene kadar uygulama canlı %'yi nazikçe gizler (liveness yine çalışır —
`FaceEmbedder` graceful-degrade). Model gelince bir sonraki build'de % aktifleşir.
