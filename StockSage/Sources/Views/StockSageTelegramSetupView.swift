#if os(macOS)
import SwiftUI

/// All Telegram setup requests are explicit button actions. Opening the sheet sends nothing.
struct StockSageTelegramSetupView: View {
    @ObservedObject var telegram: StockSageTelegram
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var token = ""
    @State private var confirmRemoval = false

    init(telegram: StockSageTelegram = .shared) { self.telegram = telegram }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Telegram alerts", systemImage: "paperplane").font(.title2.bold())
                Spacer()
                Button("Done") { token = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Connect a bot to your own Telegram account for Micro cap research alerts. This setup does not enable monitoring or place orders.")
                        .fixedSize(horizontal: false, vertical: true)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("In Telegram, open the official BotFather, send /newbot, and follow its instructions. Create a dedicated bot for StockSage; do not share its token.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open BotFather", systemImage: "arrow.up.right.square") {
                                openURL(URL(string: "https://t.me/BotFather")!)
                            }.accessibilityIdentifier("telegram.botFather")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    } label: { Text("1. Create your bot").font(.headline) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            SecureField("Bot token from BotFather", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("telegram.token")
                            Text("The token is saved only in this Mac’s Keychain. It is sent to Telegram to verify your bot and deliver alerts; it is never sent to the analyst model.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Save token and verify bot") {
                                let entered = token
                                token = ""
                                Task { await telegram.saveAndVerify(token: entered) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(telegram.isBusy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("telegram.verifyBot")
                            if let username = telegram.botUsername {
                                Label("Verified bot: @\(username)", systemImage: "checkmark.shield")
                                    .font(.callout).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    } label: { Text("2. Save and verify the token").font(.headline) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open the pairing link in your own Telegram account and press Start. Then return here and verify. Keep this one-time link private; it expires after ten minutes.")
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = telegram.pairingURL {
                                Button("Open private pairing link", systemImage: "arrow.up.right.square") { openURL(url) }
                                    .disabled(telegram.isBusy)
                                    .accessibilityIdentifier("telegram.openPairing")
                                Button("Verify my private chat") { Task { await telegram.verifyPairing() } }
                                    .disabled(telegram.isBusy)
                                    .accessibilityIdentifier("telegram.verifyPairing")
                            } else if telegram.isReady {
                                Label("Private chat paired", systemImage: "checkmark.circle")
                            } else {
                                Text("Verify the bot above to create a pairing link.").foregroundStyle(.secondary)
                            }
                            Text("Verification reads recent bot updates without deleting them or changing webhooks. An existing webhook or busy shared bot may prevent pairing.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    } label: { Text("3. Pair your own phone").font(.headline) }
                    Label {
                        Text(telegram.status).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: telegram.isReady ? "checkmark.circle" : "info.circle")
                    }.accessibilityIdentifier("telegram.status")
                    if telegram.isBusy { ProgressView("Contacting Telegram…") }
                    Text("Public research alerts leave this Mac for Telegram. Local delivery records prevent automatic retries when receipt is uncertain. Telegram acceptance does not prove a notification appeared on your phone or that you read it. Research alerts are not orders or guaranteed outcomes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Remove token and disable alerts", role: .destructive) { confirmRemoval = true }
                        .accessibilityIdentifier("telegram.remove")
                }.padding(.trailing, 4)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: 680, minHeight: 500, idealHeight: 700)
        .background(DS.Palette.bgTop)
        .confirmationDialog("Remove the saved Telegram token?", isPresented: $confirmRemoval) {
            Button("Remove token", role: .destructive) { token = ""; telegram.removeToken() }
        } message: {
            Text("Alerts will stop. The delivery history remains saved to prevent duplicate alerts. This does not delete your Telegram bot or messages.")
        }
    }
}
#endif
