# CocoaPods — YALNIZ Google ML Kit için. Diğer TÜM bağımlılıklar SPM'de kalır (project.yml `packages:`).
#
# NEDEN CocoaPods: ML Kit, Swift Package Manager DESTEKLEMİYOR (googlesamples/mlkit#180
# "closed as not planned"). Tek resmî dağıtım yolu bu. Vision'ın `smilingProbability` /
# `eyeOpenProbability` vermemesi yüzünden iOS'ta bu olasılıkları landmark geometrisinden
# TÜRETİYORDUK ve dört ayrı liveness hatası hep o türetimden çıktı; Android aynı sorunları
# MLKit ile hiç yaşamadı.
#
# AKIŞ (CI + lokal aynı): xcodegen generate → pod install → build `-workspace` ile.
# `.xcodeproj` ve `.xcworkspace` üretilir, gitignore'dadır; **Podfile.lock COMMIT EDİLİR**
# (Package.resolved ile aynı reproducibility deseni: CI üretir → artifact'tan indir → commit et).

platform :ios, '16.0'

target 'VerifyBlind' do
  use_frameworks!

  # 9.0.0 = 27 Haziran 2025 sürümü (MLKitFaceDetection 8.0.0'ı sarar).
  # Şartlar: iOS 15.5+ (biz 16.0), Xcode 16+ (runner macos-26).
  pod 'GoogleMLKit/FaceDetection', '9.0.0'

  # Test hedefi pod'ları LİNK ETMEZ, yalnız arama yollarını devralır.
  #
  # `@testable import VerifyBlind` modülün İÇ arayüzünü yükler; `FaceAnalyzer` ML Kit tiplerine
  # değindiği için o arayüz MLKitFaceDetection/MLKitVision modüllerini görmeyi gerektirir. Bu blok
  # olmadan uygulama sorunsuz derlenir ama test hedefi "Unable to resolve module dependency"
  # ile düşer — hata koda değil, pod'ların yalnız tek hedefe bağlanmış olmasına aittir.
  #
  # `:search_paths` (tam kalıtım DEĞİL) bilinçli: framework'ler zaten TEST_HOST uygulamanın içinde,
  # ikinci kez link etmek çift sembol demek olurdu.
  target 'VerifyBlindTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    # Pod'ların deployment target'ı uygulamanınkinin altında kalırsa Xcode uyarı yağdırır.
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end

    # ML Kit kaynak bundle'ları (GoogleMVFaceDetectorResources.bundle gibi) imzalanmaya
    # çalışılınca simülatör testi `CODE_SIGNING_ALLOWED=NO` ile çakışıp kırılır. Yalnız
    # bundle ürünlerini muaf tut — framework/kütüphane imzalaması ELLENMEZ.
    if target.respond_to?(:product_type) && target.product_type == 'com.apple.product-type.bundle'
      target.build_configurations.each do |config|
        config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      end
    end
  end
end
