import SwiftUI

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
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 28)).foregroundColor(Theme.secondary)
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
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock").font(.system(size: 44)).foregroundColor(Theme.onSurfaceVariant.opacity(0.5))
            Text(L.t("history_empty")).font(.system(size: 15)).foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// item_history.xml satırı.
private struct HistoryRowView: View {
    let record: HistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(iconColor.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: iconName).font(.system(size: 18)).foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(record.isRevoked ? Theme.onSurfaceVariant : Theme.onSurface)
                Text(record.description)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
            Spacer()
            Text(timeText)
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .padding(.vertical, 8)
        .opacity(record.isRevoked ? 0.6 : 1)
    }

    private var title: String {
        record.isRevoked ? "\(record.title) \(L.t("history_revoked_tag"))" : record.title
    }

    private var iconName: String {
        switch record.action {
        case .registration:    return "checkmark.seal.fill"
        case .sharedIdentity:  return "checkmark.shield.fill"
        case .deletedCard:     return "trash.fill"
        case .revokedIdentity: return "arrow.uturn.backward"
        case .restoredBackup:  return "icloud.and.arrow.down.fill"
        case .generic:         return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch record.action {
        case .deletedCard, .revokedIdentity: return Theme.error
        default: return Theme.themePrimary
        }
    }

    private var timeText: String {
        let date = Date(timeIntervalSince1970: Double(record.timestamp) / 1000)
        let df = DateFormatter()
        df.locale = Locale.current
        if Calendar.current.isDateInToday(date) {
            df.dateFormat = "HH:mm"
        } else {
            df.dateFormat = "dd/MM/yyyy"
        }
        return df.string(from: date)
    }
}
