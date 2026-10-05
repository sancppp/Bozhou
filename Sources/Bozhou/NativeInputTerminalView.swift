import AppKit
import SwiftTerm

/// Keep IME composition local until macOS commits it. SwiftTerm handles the resulting UTF-8.
class NativeInputTerminalView: LocalProcessTerminalView {
    private var composition = NSAttributedString()
    private var compositionSelection = NSRange(location: 0, length: 0)
    private lazy var compositionLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.textColor = .textColor
        label.isHidden = true
        addSubview(label)
        return label
    }()

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        super.insertText(text as NSString, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composition = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        compositionSelection = boundedRange(selectedRange)
        compositionLabel.stringValue = composition.string
        compositionLabel.font = font
        compositionLabel.isHidden = composition.length == 0
        positionComposition()
    }

    override func unmarkText() {
        super.unmarkText()
        composition = NSAttributedString()
        compositionSelection = NSRange(location: 0, length: 0)
        compositionLabel.isHidden = true
    }

    override func hasMarkedText() -> Bool { composition.length > 0 }
    override func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: composition.length) : NSRange(location: NSNotFound, length: 0)
    }
    override func selectedRange() -> NSRange {
        hasMarkedText() ? compositionSelection : super.selectedRange()
    }
    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText(), range.location != NSNotFound else { return nil }
        let bounded = boundedRange(range)
        actualRange?.pointee = bounded
        return composition.attributedSubstring(from: bounded)
    }
    override func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor] }
    override func layout() {
        super.layout()
        if hasMarkedText() { positionComposition() }
    }
    private func boundedRange(_ range: NSRange) -> NSRange {
        let start = min(range.location, composition.length)
        return NSRange(location: start, length: min(range.length, composition.length - start))
    }
    private func positionComposition() {
        compositionLabel.sizeToFit()
        let cursor = caretFrame
        compositionLabel.setFrameOrigin(NSPoint(x: max(0, min(cursor.minX, bounds.width - compositionLabel.frame.width)),
                                                y: cursor.minY))
    }
}
