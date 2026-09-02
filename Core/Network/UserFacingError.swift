import Foundation

/// Yakalanan bir hatayı kullanıcıya GÖSTERİLEBİLİR başlık+metne çeviren tek nokta
/// (Android `ServerErrorMessages.friendlyTitle`/`friendlyMessage` paritesi).
///
/// Neden: hata ekranları uzun süre `error.localizedDescription`'ı doğrudan basıyordu. Sistem
/// metinleri hem cihaz diline göre değişiyor hem de teknik (`Code(rawValue: -1009)`,
/// `Unable to resolve host "api.verifyblind.com"`). Sunucu adını içeren bir satır, sorun
/// kullanıcının kendi bağlantısındayken bile "servis çökmüş" izlenimi veriyor.
enum UserFacingError {

    /// Ekran başlığı. Bağlantı sorunu ile uygulama içi arıza AYRI başlık alır.
    ///
    /// - Parameter internalFallbackKey: yalnızca taşıma hatası OLMAYAN durumda kullanılacak
    ///   akışa özgü başlık (ör. "Kayıt Başarısız"). Bu parametre var ki çağıran, kendi
    ///   bağlamını korumak için bu fonksiyonu ATLAMAK zorunda kalmasın — atlayan çağrılar
    ///   tam da bu dosyanın engellemek için var olduğu hatayı geri getiriyordu.
    static func title(for error: Error, internalFallbackKey: String? = nil) -> String {
        if let api = error as? APIClientError, let key = api.suggestedTitleKey {
            return L.t(key)
        }
        if NetworkStatus.isTransportFailure(error) { return L.t("connection_error_title") }
        return L.t(internalFallbackKey ?? "error_system_title")
    }

    /// Gövde metni. `APIClientError` zaten yerelleştirilmiş bir metin taşır (5xx/4xx/429 ayrımı
    /// dahil) → onu kullan; geri kalanda ham sistem metni yerine kanonik iki mesajdan biri.
    ///
    /// - Parameter internalFallbackKey: yalnızca taşıma hatası OLMAYAN durumda kullanılacak
    ///   akışa özgü metin. Taşıma hatasında ASLA kullanılmaz: kullanıcının kendi bağlantısı
    ///   yokken "sunucu hatası oluştu" demek arızayı yanlış tarafa yazar.
    static func message(for error: Error, internalFallbackKey: String? = nil) -> String {
        if let api = error as? APIClientError, let text = api.errorDescription {
            return text
        }
        if NetworkStatus.isTransportFailure(error) { return L.t("error_connection_generic") }
        return L.t(internalFallbackKey ?? "error_internal_generic")
    }
}
