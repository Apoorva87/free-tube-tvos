import SwiftUI

struct RoomPairingView: View {
    let helper: RoomAIHelper
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var pairingText = ""
    @State private var problem: String?
    @State private var pairingTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Laptop helper").font(.system(size: 58, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let name = helper.pairedName {
                    Label(name, systemImage: "laptopcomputer").font(.title2)
                    Text(helper.statusText).foregroundStyle(.secondary)
                } else {
                    Text("Start the Free Tube helper on your laptop and connect both devices to the same network.")
                        .foregroundStyle(.secondary)
                    if helper.helpers.isEmpty {
                        Label("Looking for laptops…", systemImage: "wifi")
                            .accessibilityIdentifier("ai-discovery")
                    } else {
                        ForEach(helper.helpers, id: \.self) { name in
                            Button {
                                selected = name
                                pairingText = ""
                                problem = nil
                            } label: {
                                Label(name, systemImage: selected == name ? "checkmark.circle.fill" : "laptopcomputer")
                            }
                            .disabled(helper.isPairing)
                        }
                    }
                    if let selected, helper.helpers.contains(selected) {
                        Text("Copy the pairing text from the helper. Paste it here with the Apple TV Remote keyboard on your iPhone, or enter it with the remote.")
                            .foregroundStyle(.secondary)
                        SecureField("Pairing text", text: $pairingText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("ai-pairing-code")
                        Button(helper.isPairing ? "Pairing…" : "Pair this Apple TV") {
                            let entry = pairingText
                            problem = nil
                            pairingTask = Task {
                                do {
                                    try await helper.pair(name: selected, text: entry)
                                    pairingText = ""
                                } catch is CancellationError {
                                } catch { problem = error.localizedDescription }
                            }
                        }
                        .disabled(pairingText.isEmpty || helper.isPairing)
                    }
                    if let notice = helper.pairingNotice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                }
                if let problem { Text(problem).foregroundStyle(.secondary) }
                HStack(spacing: 32) {
                    Button("Check again") {
                        problem = nil
                        helper.refresh()
                    }.disabled(helper.isPairing)
                    if helper.pairedName != nil {
                        Button("Forget laptop", role: .destructive) {
                            do {
                                try helper.forget()
                                problem = nil
                                selected = nil
                                pairingText = ""
                            } catch { problem = error.localizedDescription }
                        }
                    }
                    Button("Done") { dismiss() }
                }
            }
            .frame(maxWidth: 1160, alignment: .leading)
            .padding(64)
        }
        .onAppear { helper.start(); selectSingleHelper() }
        .onChange(of: helper.helpers) { _, _ in selectSingleHelper() }
        .onDisappear {
            pairingTask?.cancel()
            pairingText = ""
        }
    }

    private func selectSingleHelper() {
        if let selected, helper.helpers.contains(selected) { return }
        selected = helper.helpers.count == 1 ? helper.helpers.first : nil
        pairingText = ""
    }
}
