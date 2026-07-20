import SwiftUI

/// Wallet (home) — Android `WalletFragment` + `fragment_wallet.xml` birebir portu.
/// Boş durum: NFC illüstrasyonu + "Kimlik Kartı Ekle" + (demo) + "Nasıl Çalışır?".
/// Kayıtlı durum: kart (item_wallet_card) + "QR ile Doğrula" + "Kimliği Sil".
struct WalletView: View {
    @EnvironmentObject var appState: AppState

    let onAddCard: () -> Void
    let onDemo: () -> Void
    let onVerifyQr: () -> Void
    let onSettings: () -> Void
    let onHistory: () -> Void
    var onDevMenu: (() -> Void)? = nil

    @State private var showDeleteConfirm = false
    @State private var removing = false
    @State private var removeError: String?
    @State private var showHowItWorks = false
    @State private var showNotifSoftAsk = false

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(onSettings: onSettings)
                // Dev menü: logoya uzun bas (yalnız development).
                .onLongPressGesture(minimumDuration: 0.8) { onDevMenu?() }

            if showNotifSoftAsk {
                NotificationSoftAskBanner(
                    onAllow: {
                        Task {
                            await NotificationPermission.requestAndRegister()
                            withAnimation { showNotifSoftAsk = false }
                        }
                    },
                    onLater: {
                        NotificationPermission.snooze()
                        withAnimation { showNotifSoftAsk = false }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if appState.hasCard {
                registeredState
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Radyal grimsi zemin (Android bg_wallet_body) — TÜM cüzdana uygulanır ki kesin görünsün.
        .background(Theme.walletBodyRadial.ignoresSafeArea())
        .task {
            // Soft-ask: yalnız sistem hiç sormamışken + snooze dolmuşken göster.
            let show = await NotificationPermission.shouldShowSoftAsk()
            withAnimation { showNotifSoftAsk = show }
        }
        // Android'de bu bir onay ekranı + "geçmişi de sil" checkbox'ı. iOS confirmationDialog
        // checkbox barındıramaz (yalnız buton) → aynı açık seçim iki ayrı destructive butonla
        // sunulur. Varsayılan davranış (yalnız kartı sil) geçmişi KORUR; bulut restore modeli
        // geçmişin kart yenilemesinden sağ çıkmasına dayanır.
        .confirmationDialog(L.t("delete_confirm_title"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L.t("btn_delete_confirm"), role: .destructive) {
                Task { await removeIdentity(deleteHistory: false) }
            }
            Button(L.t("delete_confirm_also_history"), role: .destructive) {
                Task { await removeIdentity(deleteHistory: true) }
            }
            Button(L.t("btn_cancel_upper"), role: .cancel) {}
        } message: {
            Text(L.t("delete_confirm_desc"))
        }
        .alert(L.t("operation_failed_title"), isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button(L.t("common_ok"), role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
        .sheet(isPresented: $showHowItWorks) {
            HelpView(onBack: { showHowItWorks = false })
        }
        .onAppear { appState.refresh() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 8)
            EmptyStateIllustration()
                .padding(.top, 12)

            Spacer().frame(height: 10)

            Text(L.t("empty_state_title"))
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 32)

            Text(L.t("empty_state_desc"))
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.horizontal, 40)
                .padding(.top, 12)

            Spacer()

            PrimaryGradientButton(title: L.t("btn_add_id"), systemImage: "creditcard.fill", action: onAddCard)
                .padding(.horizontal, 32)

            if appState.demoEnabled {
                Button(action: onDemo) {
                    Text(L.t("demo_mode_title"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.secondary, lineWidth: 1.5))
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }

            Button(action: howItWorks) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle").font(.system(size: 18)).foregroundColor(Theme.secondary)
                    Text(L.t("link_how_it_works"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.secondary)
                }
            }
            .padding(.vertical, 10)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    // "Nasıl Çalışır?" — tam Help ekranını (Aşama 6) sheet olarak aç.
    private func howItWorks() {
        showHowItWorks = true
    }

    // MARK: - Registered state

    private var registeredState: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 92 - 16) // Android marginTop 92 (top bar padding telafisi)

            Button(action: onHistory) {
                WalletCardView(
                    expiry: ExpiryFormatter.format(appState.expiryDate),
                    expired: ExpiryFormatter.isExpired(appState.expiryDate)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            Spacer()

            PrimaryGradientButton(title: L.t("btn_qr_login"), systemImage: "qrcode.viewfinder", fontSize: 16, action: onVerifyQr)
                .padding(.horizontal, 24)
                .disabled(removing)

            Button { showDeleteConfirm = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 16)).foregroundColor(Theme.error)
                    Text(L.t("btn_delete_identity")).font(.system(size: 14)).foregroundColor(Theme.error)
                }
            }
            .padding(8)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .disabled(removing)
        }
    }

    // MARK: - Kimliği kaldır (Android deleteTicket)

    /// Kartı kaldırır. [deleteHistory] true ise o karta ait TÜM işlem geçmişi de tombstone'lanır
    /// (senkronla buluttan ve diğer cihazlardan da silinir).
    ///
    /// Neden seçenek: geçmiş normalde kart silinince DURUR — liste cardId ile filtrelendiği için
    /// görünmez olur ve aynı kart tekrar eklenince geri gelir. Bilinçli tasarım (restore modeli
    /// buna dayanır) ama silmek isteyen için "gizlendi ≠ silindi" yanılgısı yaratıyordu.
    private func removeIdentity(deleteHistory: Bool) async {
        removing = true
        defer { removing = false }
        do {
            // Biyometrik onay (Android BiometricHelper.authenticate).
            try await BiometricGate.authenticate(reason: L.t("biometric_subtitle_decrypt"))
        } catch {
            // Biyometrik iptal/ret = beklenen kullanıcı davranışı → event değil, breadcrumb (ContentView deseni).
            Log.info("Kimlik kaldırma biyometrik iptal", category: .flow)
            return
        }
        let cardId = SecureStore.getCardId()
        TicketStore.clear()
        SecureStore.clear()
        KeychainKeyStore.deleteUserKey()
        // "Geçmişi de sil" seçildiyse DELETED_CARD kaydı EKLENMEZ: aynı cardId ile geride kalır
        // ve kart tekrar eklenince yeniden görünürdü — tam da kapatmak istediğimiz durum.
        if deleteHistory, let cid = cardId, !cid.isEmpty {
            HistoryRepository.shared.markDeletedByCardId(cid)
        } else {
            HistoryRepository.shared.insert(
                title: L.t("history_card_deleted_title"),
                description: L.t("history_card_deleted_desc"),
                status: 1,
                actionType: .deletedCard,
                cardId: cardId ?? ""
            )
        }
        Log.info("Kimlik kaldırıldı", category: .flow)
        appState.refresh()
    }
}

/// Bildirim izni soft-ask (priming) banner'ı — wallet üstünde, TopAppBar altında.
/// Sistem prompt'unu DOĞRUDAN açmaz; "İzin Ver"e basınca tetikler (kaza tap yok, bağlam var).
struct NotificationSoftAskBanner: View {
    let onAllow: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.themePrimary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("notif_softask_title"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.onSurface)
                    Text(L.t("notif_softask_desc"))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button(action: onLater) {
                    Text(L.t("notif_softask_later"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                Button(action: onAllow) {
                    Text(L.t("notif_softask_allow"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.themePrimary))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.outlineVariant, lineWidth: 1))
        )
    }
}

/// item_wallet_card.xml birebir kart görünümü (yeni tasarım: derinlik + dinamik durum).
struct WalletCardView: View {
    let expiry: String
    var expired: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.walletCardGradient)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.walletCardSheen))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.walletCardStroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    HStack(spacing: 5) {
                        Image(systemName: "shield.fill").font(.system(size: 12)).foregroundColor(.white)
                        Text("VerifyBlind").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                    Spacer()
                }

                Text("**** ****")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .tracking(4)
                    .padding(.top, 24)

                Text(L.t("wallet_verified_identity"))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.walletCardType)
                    .padding(.top, 4)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("wallet_expiry_label"))
                            .font(.system(size: 9))
                            .foregroundColor(Theme.walletExpiryLabel)
                        Text(expiry)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    StatusBadge(text: expired ? L.t("wallet_expired") : L.t("wallet_active"), expired: expired)
                }
            }
            .padding(20)

            // NFC dalga — sağ kenarda dikey ortada (Doğrulanmış kaldırıldı; Android ivNfcIcon)
            .overlay(alignment: .trailing) {
                Image(systemName: "wave.3.right")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.trailing, 20)
            }
        }
        .frame(height: 190)
        .shadow(color: Theme.walletCardShadow.opacity(0.35), radius: 16, x: 0, y: 10)
    }
}
