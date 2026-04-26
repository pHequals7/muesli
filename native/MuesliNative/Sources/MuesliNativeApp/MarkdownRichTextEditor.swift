import AppKit
import SwiftUI

struct MarkdownRichTextEditor: NSViewRepresentable {
    @Binding var text: String
    var shouldFocus: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.apply(text: text, to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.apply(text: text, to: textView)
        } else {
            context.coordinator.restyle(textView)
        }
        if shouldFocus, !context.coordinator.didFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                context.coordinator.didFocus = true
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        var didFocus = false
        private var isApplying = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            text = textView.string
            restyle(textView)
        }

        func apply(text: String, to textView: NSTextView) {
            isApplying = true
            textView.textStorage?.setAttributedString(styledMarkdown(text))
            isApplying = false
        }

        func restyle(_ textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            isApplying = true
            textView.textStorage?.setAttributedString(styledMarkdown(textView.string))
            textView.selectedRanges = selectedRanges
            isApplying = false
        }

        private func styledMarkdown(_ markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let bodyFont = NSFont.systemFont(ofSize: 14)
            let bodyColor = NSColor.labelColor
            let secondaryColor = NSColor.secondaryLabelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 7

            let lines = markdown.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let attrs: [NSAttributedString.Key: Any]
                if line.hasPrefix("# ") {
                    attrs = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: bodyColor, .paragraphStyle: paragraph]
                } else if line.hasPrefix("## ") {
                    attrs = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: bodyColor, .paragraphStyle: paragraph]
                } else if line.hasPrefix("### ") {
                    attrs = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: bodyColor, .paragraphStyle: paragraph]
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line.hasPrefix("- ") {
                    attrs = [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraph]
                } else {
                    attrs = [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraph]
                }
                result.append(NSAttributedString(string: line, attributes: attrs))
                if index < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont, .foregroundColor: secondaryColor]))
                }
            }
            return result
        }
    }
}
