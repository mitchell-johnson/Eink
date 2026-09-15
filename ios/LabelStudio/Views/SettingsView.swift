import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ConnectionSettings.savedEndpoint
    @State private var code = ""
    @State private var busy = false
    @State private var status: String?
    @State private var labelKey = ""
    @State private var hasLabelKey = (try? LabelKeyStore().load()) != nil
    @State private var labelKeyStatus: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your private server") {
                    Text("Your OpenAI key stays on Cloudflare. Connect this iPhone with the private connection code supplied during setup.").font(.subheadline)
                    TextField("https://your-server.workers.dev", text: $endpoint).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Server address")
                    SecureField("Private connection code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Private connection code")
                    Button { connect() } label: { HStack { Text("Save & test connection"); if busy { Spacer(); ProgressView() } } }.disabled(busy)
                    if let status { Text(status).font(.subheadline) }
                    if studio.connected { Button("Disconnect this iPhone", role: .destructive) { ConnectionSettings.remove(); studio.connected = false; status = "Disconnected."; code = "" }.disabled(busy || studio.isGenerating) }
                }
                Section("Label authentication") {
                    Text("Enter the Bluetooth authentication key supplied for your compatible label. It is separate from your server connection code.").font(.subheadline)
                    SecureField("32 hexadecimal characters", text: $labelKey)
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Label authentication key")
                    Button("Save label key") {
                        do {
                            try LabelKeyStore().save(hex: labelKey)
                            labelKey = ""; hasLabelKey = true; labelKeyStatus = "Label key saved securely on this iPhone."
                        } catch { labelKeyStatus = error.localizedDescription }
                    }
                    if let labelKeyStatus { Text(labelKeyStatus).font(.subheadline) }
                    if hasLabelKey {
                        Button("Remove label key", role: .destructive) {
                            do {
                                try LabelKeyStore().remove()
                                labelKey = ""; hasLabelKey = false; labelKeyStatus = "Label key removed."
                            } catch { labelKeyStatus = error.localizedDescription }
                        }
                    }
                }
                Section("Display profile") {
                    LabeledContent("Screen", value: "4.2-inch · 400 × 300")
                    LabeledContent("Inks", value: "Black, white, yellow, red")
                    LabeledContent("Image model", value: "GPT Image 2.5")
                    Text("The server asks for flat, bold artwork with readable text and safe margins. This app then enforces the exact pixel size and four-colour palette before every write.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Prompts go to your private Cloudflare server and OpenAI to generate images. Images on your server expire after 24 hours. A small request record remains to prevent accidental repeat charges. OpenAI applies its own API data policies. Saved designs and imported photos stay on this iPhone.").font(.subheadline)
                    Text("Your connection code and label key are stored in the iPhone Keychain and are never included in the app download. The label key is only used locally for Bluetooth authentication. The server records request outcomes to diagnose problems. There is no advertising or tracking.").font(.caption).foregroundStyle(.secondary)
                    Text("Bluetooth is used only to find and update nearby compatible labels. The app must stay open during a transfer.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func connect() {
        busy = true; status = nil
        Task {
            defer { busy = false }
            do {
                let token = try ConnectionSettings.tokenFor(endpoint: endpoint, enteredCode: code)
                let settings = try ConnectionSettings(endpoint: endpoint, token: token)
                let configuration = try await GenerationClient(settings: settings).configuration()
                try settings.save(); studio.connected = true; code = ""
                status = configuration.ready ? "Connected. You’re ready to create." : "Connected. The server still needs its OpenAI key."
            } catch { status = error.localizedDescription }
        }
    }
}
