import Foundation

/// Liveness challenge türleri — Android `api/ApiModels.kt` `LivenessAction` eşdeğeri.
///
/// Handshake yanıtı `challenges: [Int]` verir (`APIModels.swift`); bu int'ler `fromInt` ile
/// buraya map edilir. Değerler sunucu sözleşmesiyle birebir aynı olmalı.
enum LivenessAction: Int, CaseIterable {
    case none = 0
    case faceLeft = 1
    case faceRight = 2
    case blink = 3
    case smile = 4

    static func fromInt(_ value: Int) -> LivenessAction {
        LivenessAction(rawValue: value) ?? .none
    }

    /// Rastgele jest (None hariç) — eksik challenge'ları doldurmak için (Android ≥5 garantisi).
    static func randomGesture() -> LivenessAction {
        allCases.filter { $0 != .none }.randomElement() ?? .blink
    }
}
