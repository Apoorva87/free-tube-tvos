import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ChannelAccountView: View {
    let account: ChannelAccount
    let profile: RoomChannel?
    let inventory: SubscriptionInventory?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var attempt: UUID?
    @State private var configuring = false

    init(account: ChannelAccount, profile: RoomChannel?, inventory: SubscriptionInventory?, startsSwitch: Bool) {
        self.account = account
        self.profile = profile
        self.inventory = inventory
        let start = account.state == .signedOut || (account.isSignedIn && startsSwitch)
        _attempt = State(initialValue: start ? UUID() : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("YouTube account")
                .font(.system(size: 58, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Group {
                switch account.state {
                case .unconfigured:
                    Text("Set up the Google TV client for this copy of Free Tube. Then approve your YouTube account on your phone.")
                case .signedOut:
                    Text("Connect your YouTube account to see the channels you subscribe to.")
                case .requesting:
                    ProgressView("Requesting a sign-in code…")
                case let .waiting(userCode, verificationURL):
                    authorization(userCode: userCode, url: verificationURL)
                case .signedIn:
                    if let profile {
                        Label(profile.title, systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.primary)
                        if let handle = profile.handle { Text(handle) }
                    } else { Label("Connected to YouTube", systemImage: "checkmark.circle") }
                    if let inventory {
                        Text("\(inventory.channels.count) subscriptions imported of \(inventory.reportedTotal ?? inventory.received) reported by YouTube")
                            .accessibilityIdentifier("sync-count")
                    }
                    if let error = account.signOutError { Text(error) }
                    if let error = account.switchError { Text(error) }
                case .failed(let message):
                    Text(message)
                }
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 30) {
                switch account.state {
                case .signedOut:
                    Button("Sign in with Google") { attempt = UUID() }
                case .failed:
                    Button("Try again") { attempt = UUID() }
                case .requesting, .waiting:
                    Button("Cancel sign-in") { attempt = nil }
                case .signedIn:
                    Button("Switch YouTube profile") { attempt = UUID() }
                    Button("Sign out of this TV") { account.signOut() }
                case .unconfigured:
                    EmptyView()
                }
                switch account.state {
                case .unconfigured, .signedOut, .failed:
                    Button("Set up Google client") { configuring = true }
                default:
                    EmptyView()
                }
                Button("Done") { dismiss() }
            }
        }
        .frame(maxWidth: 1160, alignment: .leading)
        .padding(64)
        .sheet(isPresented: $configuring) { ChannelClientSetup(account: account) }
        .task(id: attempt) {
            if attempt != nil { await account.signIn(replacingCurrent: account.isSignedIn) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { attempt = nil }
        }
    }

    private func authorization(userCode: String, url: URL) -> some View {
        HStack(alignment: .center, spacing: 48) {
            if let qr = Self.qrCode(for: ChannelDeviceCode.scanURL(for: url, userCode: userCode)) {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 280, height: 280)
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Scan with your phone").font(.title3).foregroundStyle(.primary)
                Text("Choose the Google account and YouTube channel you use on your TV, then approve the access request on your phone.")
                Text("Or open this address and enter the code below.")
                Text(verbatim: url.absoluteString)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                Text(verbatim: userCode)
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .speechSpellsOutCharacters()
            }
        }
    }

    private static func qrCode(for url: URL) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(url.absoluteString.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

private struct ChannelClientSetup: View {
    let account: ChannelAccount
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var secret = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Set up Google client").font(.title)
            Text("Use the TVs and Limited Input devices client from your Google Cloud project. You can paste each value using the Apple TV Remote keyboard on your iPhone.")
                .foregroundStyle(.secondary)
            TextField("OAuth client ID", text: $id).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("OAuth client secret", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error { Text(error).foregroundStyle(.secondary) }
            HStack {
                Button("Save on this Apple TV") {
                    do {
                        try account.configure(clientID: id, secret: secret)
                        secret = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(id.isEmpty || secret.isEmpty)
                Button("Cancel") { dismiss() }
            }
        }
        .frame(maxWidth: 1080, alignment: .leading).padding(64)
    }
}
