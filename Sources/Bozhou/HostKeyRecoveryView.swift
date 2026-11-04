import SwiftUI
import BozhouCore

struct HostKeyRecoveryView: View {
    let failure: SSHHostKeyFailure
    let reconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.tr("Server Identity Changed"), systemImage: "exclamationmark.shield").font(.title2)
            Text(failure.endpoint.name).font(.headline)
            Text("\(failure.endpoint.address):\(failure.endpoint.port)").font(.system(.body, design: .monospaced))
            Text(L10n.tr("Reinstalling a server can change its SSH host key. Verify the new fingerprint through a trusted channel before resetting the saved key."))
            Text(failure.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(L10n.tr("Only this server on this connection route will be reset. Reconnecting will ask you to confirm the new key; other saved keys will be kept."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("Reset Saved Key and Reconnect")) {
                    do { try failure.resetTrust(); dismiss(); reconnect() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 540)
    }
}
