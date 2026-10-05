import AppKit
import SwiftTerm

final class InputProbe: NativeInputTerminalView {
    var sent: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
}

@main
struct NativeInputTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = InputProbe(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.setMarkedText(NSAttributedString(string: "zhongwen"), selectedRange: NSRange(location: 8, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(view.hasMarkedText())
        precondition(view.markedRange() == NSRange(location: 0, length: 8))
        precondition(view.selectedRange() == NSRange(location: 8, length: 0))
        precondition(view.sent.isEmpty, "IME preedit must not reach the remote shell")
        view.insertText(NSAttributedString(string: "中文 English"), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(String(decoding: view.sent, as: UTF8.self) == "中文 English")
        precondition(!view.hasMarkedText())
        view.setMarkedText("cancel", selectedRange: NSRange(location: 6, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        precondition(!view.hasMarkedText())
        precondition(String(decoding: view.sent, as: UTF8.self) == "中文 English")
        print("PASS native IME marked text, selection, attributed UTF-8 commit and cancellation")
    }
}
