import KeyboardShortcuts
import SwiftUI

// Settings window content. Sections: Behavior, Shortcuts, About. All UI in
// code; the recorder is KeyboardShortcuts' standard capture control.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Show HUD popup", isOn: $viewModel.hudEnabled)
                Toggle("Play sound on change", isOn: $viewModel.soundEnabled)
                Toggle("Debug console", isOn: $viewModel.debugEnabled)
                Toggle("Launch at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.launchAtLogin = $0 }
                ))
            }

            Section("Shortcuts") {
                shortcutRow("Toggle Mic", name: .toggleMic)
                shortcutRow("Mute", name: .muteMic)
                shortcutRow("Unmute", name: .unmuteMic)
                shortcutRow("Push to Talk", name: .pushToTalk)
            }

            Section("Remote Control") {
                Toggle("Allow remote control over LAN", isOn: $viewModel.remoteEnabled)
                if viewModel.remoteEnabled {
                    remoteDetails
                } else {
                    Text("Let a phone mute/unmute your mic from the same network. Off by default: this opens a local network port.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("About") {
                aboutBlock
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    // Token + QR, shown only while the listener is enabled.
    @ViewBuilder
    private var remoteDetails: some View {
        let url = viewModel.pairingURL
        VStack(alignment: .leading, spacing: 6) {
            Text("Pairing URL")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(url ?? "Generating…")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let qr = QRCodeImage(url: url) {
                qr
            }
            HStack {
                Button("Regenerate Token") { viewModel.regenerateToken() }
                Text("Invalidates the old pairing URL.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func shortcutRow(_ label: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    // Pairing QR via CoreImage's CIQRCodeGenerator — no dependencies.
    private struct QRCodeImage: View {
        let url: String

        init?(url: String?) {
            guard let url, !url.isEmpty else { return nil }
            self.url = url
        }

        var body: some View {
            if let image = Self.generate(url) {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 132, height: 132)
            } else {
                Text("QR unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        private static func generate(_ text: String) -> CGImage? {
            let filter = CIFilter(name: "CIQRCodeGenerator")
            filter?.setValue(Data(text.utf8), forKey: "inputMessage")
            filter?.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter?.outputImage else { return nil }
            let scaled = output.transformed(
                by: CGAffineTransform(scaleX: 8, y: 8)
            )
            let context = CIContext()
            return context.createCGImage(scaled, from: scaled.extent)
        }
    }

    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("MicSync").font(.headline)
                Text(versionString).foregroundColor(.secondary)
            }
            Text("Syncs mute state across Google Meet (Chrome) and Slack huddles.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(short) (\(build))"
    }
}
