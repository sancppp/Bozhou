import AppKit
import SwiftUI
import BozhouCore

struct FindCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button(L10n.tr("Find…")) { SearchField.focusCurrentField() }
                .keyboardShortcut("f")
        }
    }
}

struct SearchField: View {
    let title: String
    @Binding var text: String
    var focusNotification: String?
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            SearchInput(title: title, text: $draft, clear: { draft = ""; text = "" })
            if !draft.isEmpty {
                Button { draft = ""; text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help(L10n.tr("Clear Search"))
            }
        }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { draft = text }
            .onChange(of: text) { _, value in if value != draft { draft = value } }
            .task(id: draft) {
                guard draft != text else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                    try Task.checkCancellation()
                    text = draft
                } catch {}
            }
            .onReceive(NotificationCenter.default.publisher(for: .init(focusNotification ?? "BozhouUnusedSearchFocus"))) { _ in
                SearchInput.focusCurrentField()
            }
    }
    static func focusCurrentField() { SearchInput.focusCurrentField() }
}

/// Resolve focus from the current window, so a menu action cannot retain a removed page's field.
private struct SearchInput: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let clear: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.identifier = .init("page-search")
        field.setAccessibilityIdentifier("page-search")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = title
        if field.stringValue != text { field.stringValue = text }
    }
    static func focusCurrentField() {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "page-search",
               !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        // Menus restore their previous responder as they close; focus after that restoration.
        DispatchQueue.main.async {
            if let content = NSApp.keyWindow?.contentView?.superview, let field = find(content) {
                field.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInput
        init(_ parent: SearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.clear(); control.window?.makeFirstResponder(nil); return true
        }
    }
}

struct HighlightedText: View {
    let text: String
    let query: String
    init(_ text: String, query: String) { self.text = text; self.query = query }
    var body: some View { Text(Self.attributed(text, query: query)) }
    static func attributed(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for nsRange in TextSearch.ranges(in: text, query: query) {
            if let stringRange = Range(nsRange, in: text), let range = Range(stringRange, in: result) {
                result[range].backgroundColor = .yellow.opacity(0.65)
                result[range].foregroundColor = .black
            }
        }
        return result
    }
}

/// Native selectable text keeps large log/output searches fast and scrolls to each hit.
struct SearchableText: View {
    let text: String
    let query: String
    var fontSize: CGFloat = 12
    @State private var match = 0
    @State private var hits: [NSRange] = []
    var body: some View {
        VStack(spacing: 5) {
            if !query.isEmpty {
                HStack {
                    Text(hits.isEmpty ? L10n.tr("No matches") : L10n.tr("Match \(min(match + 1, hits.count)) of \(hits.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { match = (match - 1 + hits.count) % hits.count } label: { Image(systemName: "chevron.up") }
                        .help(L10n.tr("Previous Match")).disabled(hits.isEmpty)
                    Button { match = (match + 1) % hits.count } label: { Image(systemName: "chevron.down") }
                        .help(L10n.tr("Next Match")).disabled(hits.isEmpty)
                }
            }
            SearchTextView(text: text, query: query, ranges: hits, match: match, fontSize: fontSize)
        }
        .task(id: TextSearch.Request(text: text, query: query)) {
            let text = text, query = query
            hits = []; match = 0
            let result = await TextSearch.background { TextSearch.ranges(in: text, query: query) }
            if !Task.isCancelled { hits = result }
        }
    }
}

struct SearchTextView: NSViewRepresentable {
    let text: String
    let query: String
    let ranges: [NSRange]
    var match = 0
    var fontSize: CGFloat = 12
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.setAccessibilityIdentifier("searchable-output")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        let contentChanged = coordinator.text != text || coordinator.fontSize != fontSize
        let highlightsChanged = contentChanged || coordinator.ranges != ranges
        let navigated = highlightsChanged || coordinator.match != match
        if contentChanged {
            let value = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ])
            view.textStorage?.setAttributedString(value)
            view.sizeToFit()
            view.setFrameSize(NSSize(width: max(view.frame.width, scroll.contentSize.width),
                                     height: max(view.frame.height, scroll.contentSize.height)))
        }
        if highlightsChanged, let storage = view.textStorage {
            storage.beginEditing()
            if !contentChanged {
                for range in coordinator.ranges where NSMaxRange(range) <= storage.length {
                    storage.removeAttribute(.backgroundColor, range: range)
                    storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                }
            }
            for range in ranges where NSMaxRange(range) <= storage.length {
                storage.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.65),
                                       .foregroundColor: NSColor.black], range: range)
            }
            storage.endEditing()
        }
        if (navigated || contentChanged), !ranges.isEmpty {
            let range = ranges[min(match, ranges.count - 1)]
            // Do not steal the first responder from the search field.
            if NSMaxRange(range) <= (view.string as NSString).length { view.scrollRangeToVisible(range) }
        }
        coordinator.text = text; coordinator.query = query; coordinator.match = match; coordinator.fontSize = fontSize
        coordinator.ranges = ranges
    }
    final class Coordinator {
        var text: String?
        var query = ""
        var match = 0
        var fontSize: CGFloat = 0
        var ranges: [NSRange] = []
    }
}
