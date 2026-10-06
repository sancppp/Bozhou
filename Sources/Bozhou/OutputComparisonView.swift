import SwiftUI
import BozhouCore

struct OutputComparisonView: View {
    @EnvironmentObject var model: AppModel
    let before: Interaction
    let after: Interaction
    @State private var diff: OutputDiff?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("Output Diff")).font(.headline)
                Spacer()
                if let diff {
                    Text("− \(diff.removed)").foregroundStyle(.red)
                    Text("+ \(diff.added)").foregroundStyle(.green)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                summary(before, label: L10n.tr("Original")); summary(after, label: L10n.tr("Comparison"))
            }
            if let diff {
                DiffColumns(diff: diff).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView(L10n.tr("Comparing…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(L10n.tr("Red − Removed · Green + Added · Blank rows align output · Scrolling is synchronized"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .task(id: before.id.uuidString + after.id.uuidString) {
                diff = nil
                let old = before.output, new = after.output
                let result = await Task.detached(priority: .userInitiated) { OutputDiff(old, new) }.value
                if !Task.isCancelled { diff = result }
            }
    }
    private func summary(_ item: Interaction, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(label); HostNameLabel(model.displayName(for: item)) }.font(.subheadline.weight(.medium))
            Text(item.command).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled)
            Text(L10n.tr("\(L10n.date(item.date)) · Exit \(item.exitCode.map(String.init) ?? L10n.tr("Unknown"))"))
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// AppKit text views provide native selection, copy, accessibility and horizontal scrolling.
private struct DiffColumns: NSViewRepresentable {
    let diff: OutputDiff
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSStackView {
        let split = NSStackView()
        split.orientation = .horizontal; split.distribution = .fillEqually
        split.alignment = .top; split.spacing = 1
        for _ in 0..<2 {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            let text = NSTextView(frame: .zero)
            text.isEditable = false; text.isRichText = false; text.isSelectable = true
            text.isVerticallyResizable = true; text.isHorizontallyResizable = true
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainerInset = NSSize(width: 8, height: 8)
            scroll.documentView = text
            scroll.contentView.postsBoundsChangedNotifications = true
            split.addArrangedSubview(scroll)
            scroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        }
        let scrolls = split.arrangedSubviews.compactMap { $0 as? NSScrollView }
        context.coordinator.observe(scrolls)
        return split
    }
    func updateNSView(_ split: NSStackView, context: Context) {
        let scrolls = split.arrangedSubviews.compactMap { $0 as? NSScrollView }
        for (scroll, lines) in zip(scrolls, [diff.left, diff.right]) {
            guard let text = scroll.documentView as? NSTextView else { continue }
            let result = NSMutableAttributedString()
            for line in lines {
                let prefix = line.kind == .removed ? "−" : line.kind == .added ? "+" : " "
                let number = line.number.map { String(format: "%5d", $0) } ?? "     "
                let background: NSColor = line.kind == .removed ? .systemRed.withAlphaComponent(0.13) :
                    line.kind == .added ? .systemGreen.withAlphaComponent(0.13) : .textBackgroundColor
                result.append(NSAttributedString(string: "\(number) \(prefix) \(line.text)\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.textColor, .backgroundColor: background
                ]))
            }
            text.textStorage?.setAttributedString(result)
            text.sizeToFit()
            text.setFrameSize(NSSize(width: max(text.frame.width, scroll.contentSize.width),
                                     height: max(text.frame.height, scroll.contentSize.height)))
        }
    }
    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        private var updating = false
        func observe(_ scrolls: [NSScrollView]) {
            for (index, scroll) in scrolls.enumerated() {
                let other = scrolls[1 - index]
                observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll, weak other] _ in
                    guard let self, !updating, let scroll, let other else { return }
                    updating = true
                    other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: scroll.contentView.bounds.origin.y))
                    other.reflectScrolledClipView(other.contentView)
                    updating = false
                })
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
