import SwiftUI

/// Android empty-state illüstrasyonu (NFC halkaları + ID kart mockup + telefon mockup + NFC dalga)
/// SwiftUI yeniden üretimi. Wallet/home boş durumunda gösterilir.
struct EmptyStateIllustration: View {
    var body: some View {
        ZStack {
            // Soft glow + NFC halkaları (bg_nfc_ring_blue stroke #54A3FD)
            Circle().fill(Theme.nfcRing.opacity(0.06)).frame(width: 220, height: 220)
            Circle().stroke(Theme.nfcRing.opacity(0.28), lineWidth: 2).frame(width: 260, height: 260)
            Circle().stroke(Theme.nfcRing.opacity(0.18), lineWidth: 2).frame(width: 192, height: 192)

            // ID kart mockup (192×124, -6° eğik, sağ-yukarı kaydırılmış)
            idCardMockup
                .rotationEffect(.degrees(-6))
                .offset(x: 18, y: -30)

            // Telefon mockup (90×182, NFC dalga ikon)
            phoneMockup
        }
        .frame(width: 280, height: 280)
    }

    private var idCardMockup: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .frame(width: 192, height: 124)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle().fill(Theme.themePrimary).frame(width: 34, height: 34)
                    Image(systemName: "touchid")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.secondaryContainer)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceHighest).frame(width: 120, height: 6)
                    .padding(.bottom, 6)
                RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceHighest).frame(width: 80, height: 6)
            }
            .padding(14)
            .frame(width: 192, height: 124, alignment: .topLeading)
        }
    }

    private var phoneMockup: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(Theme.phoneBody)
                .frame(width: 90, height: 182)
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.phoneEdge, lineWidth: 3))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

            VStack {
                Capsule().fill(Color.white.opacity(0.5)).frame(width: 36, height: 5).padding(.top, 10)
                Spacer()
                Image(systemName: "wave.3.right")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.secondaryContainer)
                Spacer()
            }
            .frame(width: 90, height: 182)
        }
    }
}
