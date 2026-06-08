import SwiftUI
import UIKit

/// İşlem Geçmişi — Android `HistoryFragment` + `fragment_history.xml` / `item_history.xml` portu.
/// Sola kaydır = sil, sağa kaydır = doğrulama iptali / rıza geri çekme.
struct HistoryView: View {
    let onBack: () -> Void

    @EnvironmentObject var appState: AppState
    @StateObject private var vm = HistoryViewModel()

    @State private var pendingRevoke: HistoryRecord?

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("history_title"), titleColor: Theme.primary, onBack: onBack)

            backupBanner
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Text(L.t("history_swipe_hint"))
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            if vm.records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { vm.load() }
        .confirmationDialog(revokeTitle, isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }), titleVisibility: .visible) {
            if let rec = pendingRevoke {
                Button(L.t(rec.action == .registration ? "btn_withdraw" : "btn_revoke"), role: .destructive) {
                    Task {
                        if rec.action == .registration { await vm.withdrawRegistration(rec, appState: appState) }
                        else { await vm.revokeVerification(rec) }
                        pendingRevoke = nil
                    }
                }
                Button(L.t("btn_cancel"), role: .cancel) { pendingRevoke = nil }
            }
        } message: {
            Text(revokeMessage)
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toast {
                Text(toast)
                    .font(.system(size: 13)).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.onSurface.opacity(0.9), in: Capsule())
                    .padding(.bottom, 32)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { vm.toast = nil } }
            }
        }
    }

    private var revokeTitle: String {
        L.t(pendingRevoke?.action == .registration ? "revoke_registration_title" : "revoke_verification_title")
    }
    private var revokeMessage: String {
        L.t(pendingRevoke?.action == .registration ? "revoke_registration_message" : "revoke_verification_message")
    }

    // MARK: - Backup banner (Aşama 5 işlevsiz)

    private var backupBanner: some View {
        CardSurface(padding: 12) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 28)).foregroundColor(Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("history_local_only")).font(.system(size: 13)).foregroundColor(Theme.onSurface)
                    Text(L.t("history_backup_suggest")).font(.system(size: 11)).foregroundColor(Theme.onSurfaceVariant)
                }
                Spacer()
                Text(L.t("history_backup_btn")).font(.system(size: 12, weight: .bold)).foregroundColor(Theme.secondary)
            }
        }
    }

    // MARK: - Liste

    private var list: some View {
        List {
            ForEach(vm.records, id: \.id) { rec in
                HistoryRowView(record: rec)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { vm.delete(rec) } label: {
                            Label(L.t("btn_delete"), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if canRevoke(rec) {
                            Button { pendingRevoke = rec } label: {
                                Label(L.t("btn_revoke"), systemImage: "arrow.uturn.backward")
                            }
                            .tint(Theme.error)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func canRevoke(_ rec: HistoryRecord) -> Bool {
        guard !rec.isRevoked else { return false }
        return rec.action == .sharedIdentity || rec.action == .registration
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 56)).foregroundColor(Theme.outlineVariant)
            Text(L.t("history_empty")).font(.system(size: 16)).foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// item_history.xml satırı — Android `HistoryAdapter` birebir: başlık/açıklama actionType'tan
/// türetilir (saklı şifreli metin değil), ikon status/revoked'a göre renkli daire + beyaz glyph,
/// shared+partner logosu varsa logo, tarih "dd MMM HH:mm".
private struct HistoryRowView: View {
    let record: HistoryRecord

    private var partner: PartnerItem? { record.partnerId.flatMap { PartnerManager.get($0) } }
    private var isRevoked: Bool { record.isRevoked || record.action == .revokedIdentity }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            iconCircle
            VStack(alignment: .leading, spacing: 4) {
                Text(resolvedTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.onSurface)
                Text(resolvedDesc)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
            Spacer()
            Text(timeText)
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var iconCircle: some View {
        if record.action == .sharedIdentity, !isRevoked, let logo = partnerLogo {
            Image(uiImage: logo).resizable().scaledToFill()
                .frame(width: 40, height: 40).clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(circleColor).frame(width: 40, height: 40)
                Image(systemName: glyph).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            }
        }
    }

    private var circleColor: Color {
        if isRevoked { return Theme.circleGray }
        switch record.status {
        case 1: return Theme.circleGreen
        case 2: return Theme.circleRed
        default: return Theme.circleGray
        }
    }

    private var glyph: String {
        if isRevoked { return "xmark" }
        switch record.status {
        case 1: return "checkmark"
        case 2: return "exclamationmark"
        default: return "clock"
        }
    }

    private var partnerLogo: UIImage? {
        guard let b64 = partner?.logoBase64, !b64.isEmpty else { return nil }
        let clean = b64
            .replacingOccurrences(of: "data:image/png;base64,", with: "")
            .replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: clean) else { return nil }
        return UIImage(data: data)
    }

    private var resolvedTitle: String {
        switch record.action {
        case .registration:
            let t = L.t("history_action_registration")
            return isRevoked ? "\(t) \(L.t("history_consent_withdrawn"))" : t
        case .sharedIdentity:
            if let name = partner?.name, !name.isEmpty { return name }
            let prefix = L.t("history_partner_prefix")
            if record.description.hasPrefix(prefix) {
                let n = String(record.description.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { return n }
            }
            return L.t("history_action_shared")
        case .deletedCard:     return L.t("history_action_deleted")
        case .restoredBackup:  return L.t("history_action_restored")
        case .revokedIdentity: return L.t("history_action_revoked")
        case .generic:         return record.title
        }
    }

    private var resolvedDesc: String {
        switch record.action {
        case .registration:    return L.t("history_desc_registration")
        case .sharedIdentity:
            let base = L.t("history_action_shared")
            return isRevoked ? "\(base) \(L.t("history_revoked_tag"))" : base
        case .deletedCard:     return L.t("history_desc_deleted")
        case .restoredBackup:  return L.t("history_desc_restored")
        case .revokedIdentity: return L.t("history_desc_revoked")
        case .generic:         return record.description
        }
    }

    private var timeText: String {
        let date = Date(timeIntervalSince1970: Double(record.timestamp) / 1000)
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "dd MMM HH:mm"
        return df.string(from: date)
    }
}
