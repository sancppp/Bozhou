import AppKit
import SwiftUI
import BozhouCore

struct HostNameLabel: View {
    let name: HostDisplayName
    var query: String
    init(_ name: HostDisplayName, query: String = "") { self.name = name; self.query = query }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HighlightedText(name.full, query: query).fixedSize()
            HighlightedText(name.compact, query: query).fixedSize()
            HStack(spacing: 0) {
                HighlightedText(name.name, query: query).lineLimit(1).truncationMode(.middle)
                HighlightedText(name.suffix(compact: true), query: query).fixedSize()
            }
        }.help(name.full).accessibilityLabel(name.full)
    }
}

/// Native menu controls flatten custom labels. Draw the adaptive label above the
/// native hit target so both the selected hostname and the full menu titles survive.
struct HostPicker: View {
    let title: String
    let hosts: [Host]
    @Binding var selection: UUID?
    var body: some View {
        LabeledContent(title) {
            Menu {
                Button(L10n.tr("Select a saved host")) { selection = nil }
                ForEach(hosts) { host in
                    Button(host.displayName.full) { selection = host.id }
                }
            } label: { Text(" ") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 6) {
                        if let host = hosts.first(where: { $0.id == selection }) {
                            HostNameLabel(host.displayName)
                        } else { Text(L10n.tr("Select a saved host")) }
                        Image(systemName: "chevron.down").font(.system(size: 10))
                    }.allowsHitTesting(false)
                }
                .accessibilityLabel(title)
                .accessibilityValue(hosts.first(where: { $0.id == selection })?.displayName.full ?? L10n.tr("Select a saved host"))
        }
    }
}

/// NSTableView cells are resized by AppKit without reloading their row.
final class HostNameTextField: NSTextField {
    var query = "" { didSet { fitName() } }
    var hostName = HostDisplayName(name: "", hostname: nil) {
        didSet { toolTip = hostName.full; fitName() }
    }
    override func layout() {
        super.layout()
        fitName()
    }
    private func fitName() {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12)]
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: attributes).width <= max(0, bounds.width - 4) }
        var value = hostName.full
        if !fits(value) { value = hostName.compact }
        if !fits(value) {
            let suffix = hostName.suffix(compact: true)
            var count = hostName.name.count
            repeat {
                count -= 1
                value = String(hostName.name.prefix(max(0, (count + 1) / 2))) + "…"
                    + String(hostName.name.suffix(max(0, count / 2))) + suffix
            } while count > 0 && !fits(value)
        }
        let rendered = NSMutableAttributedString(string: value, attributes: attributes)
        for range in TextSearch.ranges(in: value, query: query) {
            rendered.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.65),
                                    .foregroundColor: NSColor.black], range: range)
        }
        if attributedStringValue != rendered { attributedStringValue = rendered }
        setAccessibilityLabel(hostName.full)
    }
}
