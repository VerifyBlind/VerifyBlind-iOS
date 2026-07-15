import Foundation
import UIKit

/// Cihaz donanım kimliği ↔ pazarlama model adı — tek kaynak (history display + feedback triyajı ortak
/// kullanır). Kimlik `utsname.machine` (ör. "iPhone15,2"); pazarlama adı map'ten ("iPhone 14 Pro").
/// NOT: identifier pazarlama numarasından bir nesil ÖNDEDİR (iPhone 14 Pro = iPhone15,2).
/// Android `util/DeviceInfo` paritesi.
/// Bkz. docs/superpowers/specs/2026-07-05-history-device-name-design.md
enum DeviceInfo {

    /// İşlem geçmişinde saklanan temiz pazarlama adı ("iPhone 14 Pro"). Bilinmeyen/yeni model veya
    /// simülatör → `UIDevice.current.model` ("iPhone"/"iPad"); hiç boş dönmez.
    static func marketingName() -> String {
        marketingName(for: hardwareIdentifier()) ?? UIDevice.current.model
    }

    /// Belirli bir donanım kimliği için pazarlama adı, bilinmiyorsa nil (feedback triyajı ham id ekler).
    static func marketingName(for id: String) -> String? {
        modelMap[id]
    }

    /// Ham donanım kimliği (`utsname.machine`, ör. "iPhone13,2"). Simülatörde `machine` "arm64"/"x86_64"
    /// döner → gerçek model kimliği env'de (`SIMULATOR_MODEL_IDENTIFIER`).
    static func hardwareIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// iPhone kimliği → pazarlama adı. iPad'ler bilinçli olarak yok (jenerik "iPad" fallback yeterli —
    /// hedef kitle iPhone ağırlıklı). Yeni model eklenmezse çağıran taraf ham id / UIDevice.model'e düşer.
    static let modelMap: [String: String] = [
        "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7",
        "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2. nesil)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3. nesil)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e"
    ]
}
