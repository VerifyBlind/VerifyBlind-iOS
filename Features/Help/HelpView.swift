import SwiftUI

/// Nasıl Çalışır — Android `HelpFragment` + `fragment_help.xml` portu (Aşama 6).
/// Hızlı başlangıç (4 adım) + 9 ekran rehberi (akordeon) + 4 SSS kategorisi (akordeon) + sürüm.
/// "Destek Asistanı" butonu portlanmış Chatbot'u sheet olarak açar.
struct HelpView: View {
    let onBack: () -> Void
    @State private var showChatbot = false

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("help_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    chatbotButton
                    quickStartSection
                    screenGuidesSection
                    faqSection

                    Text(versionText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showChatbot) { ChatbotView() }
    }

    private var versionText: String {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0").uppercased()
        return "VERSION \(v)-STABLE"
    }

    // MARK: - Destek asistanı

    private var chatbotButton: some View {
        Button(action: { showChatbot = true }) {
            CardSurface {
                HStack(spacing: 16) {
                    IconCircle(systemName: "bubble.left.and.bubble.right", fill: Theme.blueSoft, tint: Theme.themePrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("chatbot_title")).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                        Text(L.t("chatbot_welcome")).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hızlı başlangıç

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L.t("help_quick_start"))
            quickStartRow("1", "help_step1_title", "help_step1_desc")
            quickStartRow("2", "help_step2_title", "help_step2_desc")
            quickStartRow("3", "help_step3_title", "help_step3_desc")
            quickStartRow("4", "help_step4_title", "help_step4_desc")
        }
    }

    private func quickStartRow(_ no: String, _ titleKey: String, _ descKey: String) -> some View {
        CardSurface {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Theme.stepperActive).frame(width: 26, height: 26)
                    Text(no).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(titleKey)).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                    Text(L.t(descKey)).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                }
                Spacer()
            }
        }
    }

    // MARK: - Ekran rehberleri

    private var screenGuidesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L.t("help_screen_guide"))
            ForEach(HelpData.guides) { guide in
                GuideAccordion(guide: guide)
            }
        }
    }

    // MARK: - SSS

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L.t("help_faq_label"))
            ForEach(HelpData.faqCategories) { cat in
                Text(L.help(cat.titleKey))
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(cat.color)
                    .padding(.top, 8)
                ForEach(1...cat.count, id: \.self) { i in
                    FaqAccordion(question: L.help("\(cat.questionsBase)_\(i)"),
                                 answer: L.help("\(cat.answersBase)_\(i)"))
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .foregroundColor(Theme.onSurfaceVariant)
            .padding(.top, 4)
    }
}

// MARK: - Akordeonlar

/// Ekran rehberi akordeonu: başlık (ikon+ad) → NE İÇİN VAR / ADIM ADIM / SORUN GİDERME / GÜVENLİK NOTU.
private struct GuideAccordion: View {
    let guide: HelpGuide
    @State private var expanded = false

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 12) {
                        IconCircle(systemName: guide.icon, fill: guide.tint.opacity(0.12), tint: guide.tint, size: 36)
                        Text(L.help(guide.titleKey)).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.onSurfaceVariant)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        labeled(L.t("guide_what_for"), L.help(guide.purposeKey))
                        labeled(L.t("guide_step_by_step"), L.help(guide.stepsKey))
                        labeled(L.t("guide_troubleshooting"), L.help(guide.troubleshootingKey))
                        labeled(L.t("guide_security_note"), L.help(guide.securityNoteKey))
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func labeled(_ label: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .heavy)).foregroundColor(Theme.themePrimary)
            Text(body).font(.system(size: 13)).foregroundColor(Theme.onSurfaceVariant).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SSS akordeonu: soru (tıkla) → cevap.
private struct FaqAccordion: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(question).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.onSurfaceVariant)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    Text(answer).font(.system(size: 13)).foregroundColor(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
            }
        }
    }
}
