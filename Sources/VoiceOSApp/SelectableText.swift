import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    let text: String
    let onSelectionChange: (String, NSRange) -> Void
    @Environment(\.vosTextScale) private var textScale

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 16 * textScale)
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.ignoresSelectionChange = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.ignoresSelectionChange = false
        }
        let font = NSFont.systemFont(ofSize: 16 * textScale)
        if textView.font?.pointSize != font.pointSize { textView.font = font }
        if textView.textColor?.isEqual(NSColor.labelColor) != true { textView.textColor = .labelColor }
    }

    static func scalarOffset(ofUTF16Offset offset: Int, in text: String) -> Int? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        guard let scalarIndex = index.samePosition(in: text.unicodeScalars) else { return nil }
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: scalarIndex)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableText
        var ignoresSelectionChange = false

        init(_ parent: SelectableText) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !ignoresSelectionChange, let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let string = textView.string as NSString
            guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= string.length else {
                parent.onSelectionChange("", NSRange(location: 0, length: 0))
                return
            }
            parent.onSelectionChange(string.substring(with: range), range)
        }
    }
}
