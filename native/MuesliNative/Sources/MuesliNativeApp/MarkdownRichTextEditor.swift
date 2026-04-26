import AppKit
import SwiftUI

struct MarkdownEditorCommand: Equatable {
    enum Kind: Equatable {
        case heading
        case bold
        case bullet
        case checkbox
    }

    let id = UUID()
    let kind: Kind
}

struct MarkdownRichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var command: MarkdownEditorCommand?
    var shouldFocus: Bool = false
    var placeholder: String = "Write notes here..."

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, command: $command)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 34, height: 30)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = context.coordinator.bodyAttributes()
        context.coordinator.apply(markdown: text, to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        textView.placeholder = placeholder
        if context.coordinator.serializedMarkdown(from: textView) != text {
            context.coordinator.apply(markdown: text, to: textView)
        }
        if let command {
            context.coordinator.perform(command.kind, in: textView)
            DispatchQueue.main.async {
                if self.command?.id == command.id {
                    self.command = nil
                }
            }
        }
        if shouldFocus, !context.coordinator.didFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                context.coordinator.didFocus = true
            }
        }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var command: MarkdownEditorCommand?
        weak var textView: NSTextView?
        var didFocus = false
        private var isApplying = false

        private let bodyFont = NSFont.systemFont(ofSize: 16)
        private let boldFont = NSFont.boldSystemFont(ofSize: 16)
        private let headingFont = NSFont.systemFont(ofSize: 26, weight: .bold)
        private let bodyColor = NSColor.labelColor
        private let secondaryColor = NSColor.secondaryLabelColor

        init(text: Binding<String>, command: Binding<MarkdownEditorCommand?>) {
            _text = text
            _command = command
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            text = serializedMarkdown(from: textView)
            textView.needsDisplay = true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard replacementString == "\n" else { return true }
            continueListIfNeeded(in: textView, affectedCharRange: affectedCharRange)
            return false
        }

        func apply(markdown: String, to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            isApplying = true
            textView.textStorage?.setAttributedString(attributedString(from: markdown))
            textView.typingAttributes = bodyAttributes()
            textView.selectedRanges = selectedRanges.clamped(to: textView.string.count)
            isApplying = false
            textView.needsDisplay = true
        }

        func perform(_ command: MarkdownEditorCommand.Kind, in textView: NSTextView) {
            switch command {
            case .heading:
                applyHeading(in: textView)
            case .bold:
                toggleBold(in: textView)
            case .bullet:
                insertLinePrefix("• ", in: textView)
            case .checkbox:
                insertLinePrefix("☐ ", in: textView)
            }
            text = serializedMarkdown(from: textView)
            textView.needsDisplay = true
            self.command = nil
        }

        func bodyAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraphStyle(spacing: 8, lineHeightMultiple: 1.08)
            ]
        }

        private func attributedString(from markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let lines = markdown.components(separatedBy: .newlines)
            for (index, rawLine) in lines.enumerated() {
                let parsed = parseLine(rawLine)
                let line = NSMutableAttributedString(string: parsed.displayText, attributes: parsed.attributes)
                applyInlineBold(in: line, baseAttributes: parsed.attributes)
                result.append(line)
                if index < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
                }
            }
            return result
        }

        private func parseLine(_ line: String) -> (displayText: String, attributes: [NSAttributedString.Key: Any]) {
            if line.hasPrefix("# ") {
                return (
                    String(line.dropFirst(2)),
                    [
                        .font: headingFont,
                        .foregroundColor: bodyColor,
                        .paragraphStyle: paragraphStyle(spacing: 14, lineHeightMultiple: 1.02)
                    ]
                )
            }
            if line.hasPrefix("- [ ] ") {
                return ("☐ " + line.dropFirst(6), bodyAttributes())
            }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                return ("☑ " + line.dropFirst(6), bodyAttributes())
            }
            if line.hasPrefix("- ") {
                return ("• " + line.dropFirst(2), bodyAttributes())
            }
            return (line, bodyAttributes())
        }

        private func applyInlineBold(
            in line: NSMutableAttributedString,
            baseAttributes: [NSAttributedString.Key: Any]
        ) {
            let raw = line.string as NSString
            var searchRange = NSRange(location: 0, length: raw.length)
            while true {
                let opening = raw.range(of: "**", options: [], range: searchRange)
                guard opening.location != NSNotFound else { break }
                let afterOpening = NSRange(
                    location: opening.location + opening.length,
                    length: raw.length - opening.location - opening.length
                )
                let closing = raw.range(of: "**", options: [], range: afterOpening)
                guard closing.location != NSNotFound else { break }

                line.deleteCharacters(in: closing)
                line.deleteCharacters(in: opening)
                let boldRange = NSRange(location: opening.location, length: closing.location - opening.location - 2)
                if boldRange.length > 0 {
                    let baseFont = baseAttributes[.font] as? NSFont ?? bodyFont
                    line.addAttribute(.font, value: boldVersion(of: baseFont), range: boldRange)
                }
                let nextLocation = opening.location + max(boldRange.length, 0)
                searchRange = NSRange(location: nextLocation, length: max(line.length - nextLocation, 0))
                if searchRange.length == 0 { break }
            }
        }

        private func applyHeading(in textView: NSTextView) {
            let ranges = paragraphRanges(for: textView)
            guard let storage = textView.textStorage else { return }
            isApplying = true
            for range in ranges {
                storage.addAttributes([
                    .font: headingFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: paragraphStyle(spacing: 14, lineHeightMultiple: 1.02)
                ], range: range)
            }
            isApplying = false
        }

        private func toggleBold(in textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            if selectedRange.length == 0 {
                var attributes = textView.typingAttributes
                let currentFont = attributes[.font] as? NSFont ?? bodyFont
                attributes[.font] = isBold(currentFont) ? bodyFont : boldVersion(of: currentFont)
                textView.typingAttributes = attributes
                return
            }
            guard let storage = textView.textStorage else { return }
            let shouldUnbold = selectionIsBold(in: storage, range: selectedRange)
            isApplying = true
            storage.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let currentFont = value as? NSFont ?? bodyFont
                let replacement = shouldUnbold ? regularVersion(of: currentFont) : boldVersion(of: currentFont)
                storage.addAttribute(.font, value: replacement, range: range)
            }
            isApplying = false
        }

        private func insertLinePrefix(_ prefix: String, in textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            let full = textView.string as NSString
            let paragraphRange = full.paragraphRange(for: selectedRange)
            let existingLine = full.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
            let cleaned = existingLine
                .replacingOccurrences(of: "• ", with: "")
                .replacingOccurrences(of: "☐ ", with: "")
                .replacingOccurrences(of: "☑ ", with: "")
            let replacement = prefix + cleaned
            textView.replaceCharacters(in: paragraphRange, with: replacement + (paragraphRange.upperBound < full.length ? "\n" : ""))
            textView.setSelectedRange(NSRange(location: paragraphRange.location + replacement.count, length: 0))
        }

        private func continueListIfNeeded(in textView: NSTextView, affectedCharRange: NSRange) {
            let full = textView.string as NSString
            let paragraphRange = full.paragraphRange(for: affectedCharRange)
            let line = full.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
            let prefix: String?
            if line.hasPrefix("• ") {
                prefix = line == "• " ? nil : "\n• "
            } else if line.hasPrefix("☐ ") {
                prefix = line == "☐ " ? nil : "\n☐ "
            } else if line.hasPrefix("☑ ") {
                prefix = line == "☑ " ? nil : "\n☐ "
            } else {
                prefix = "\n"
            }
            textView.insertText(prefix ?? "\n", replacementRange: affectedCharRange)
        }

        private func paragraphRanges(for textView: NSTextView) -> [NSRange] {
            let selectedRange = textView.selectedRange()
            let full = textView.string as NSString
            guard full.length > 0 else { return [NSRange(location: 0, length: 0)] }
            return full.paragraphRanges(for: selectedRange).map { range in
                NSRange(location: range.location, length: max(range.length - 1, 0))
            }
        }

        func serializedMarkdown(from textView: NSTextView) -> String {
            guard let storage = textView.textStorage else { return textView.string }
            var lines: [String] = []
            let full = storage.string as NSString
            let fullRange = NSRange(location: 0, length: full.length)
            full.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                lines.append(self.markdownLine(from: storage, range: range))
            }
            if storage.string.hasSuffix("\n") {
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }

        private func markdownLine(from storage: NSTextStorage, range: NSRange) -> String {
            let raw = (storage.string as NSString).substring(with: range)
            let prefix: String
            let content: String
            if raw.hasPrefix("☐ ") {
                prefix = "- [ ] "
                content = String(raw.dropFirst(2))
            } else if raw.hasPrefix("☑ ") {
                prefix = "- [x] "
                content = String(raw.dropFirst(2))
            } else if raw.hasPrefix("• ") {
                prefix = "- "
                content = String(raw.dropFirst(2))
            } else if lineIsHeading(storage: storage, range: range) {
                prefix = "# "
                content = raw
            } else {
                prefix = ""
                content = raw
            }
            let contentRange = NSRange(location: range.location + raw.count - content.count, length: content.count)
            return prefix + markdownInline(from: storage, contentRange: contentRange)
        }

        private func markdownInline(from storage: NSTextStorage, contentRange: NSRange) -> String {
            guard contentRange.length > 0 else { return "" }
            var output = ""
            storage.enumerateAttributes(in: contentRange) { attrs, range, _ in
                let substring = (storage.string as NSString).substring(with: range)
                let font = attrs[.font] as? NSFont ?? bodyFont
                if isBold(font), !lineIsHeading(storage: storage, range: contentRange) {
                    output += "**\(substring)**"
                } else {
                    output += substring
                }
            }
            return output
        }

        private func lineIsHeading(storage: NSTextStorage, range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            return (font?.pointSize ?? 0) >= 22
        }

        private func selectionIsBold(in storage: NSTextStorage, range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            var allBold = true
            storage.enumerateAttribute(.font, in: range) { value, _, stop in
                let font = value as? NSFont ?? bodyFont
                if !isBold(font) {
                    allBold = false
                    stop.pointee = true
                }
            }
            return allBold
        }

        private func isBold(_ font: NSFont) -> Bool {
            NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }

        private func boldVersion(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }

        private func regularVersion(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        }

        private func paragraphStyle(spacing: CGFloat, lineHeightMultiple: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacing = spacing
            style.lineHeightMultiple = lineHeightMultiple
            return style
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(
            x: textContainerInset.width + 5,
            y: textContainerInset.height
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}

private extension Array where Element == NSValue {
    func clamped(to stringLength: Int) -> [NSValue] {
        map { value in
            let range = value.rangeValue
            let location = Swift.min(range.location, stringLength)
            let length = Swift.min(range.length, Swift.max(stringLength - location, 0))
            return NSValue(range: NSRange(location: location, length: length))
        }
    }
}

private extension NSString {
    func paragraphRanges(for range: NSRange) -> [NSRange] {
        let safeRange = NSRange(location: min(range.location, length), length: min(range.length, max(length - range.location, 0)))
        let paragraphRange = self.paragraphRange(for: safeRange)
        var ranges: [NSRange] = []
        var location = paragraphRange.location
        while location < paragraphRange.upperBound {
            let current = self.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(current)
            location = current.upperBound
        }
        return ranges.isEmpty ? [paragraphRange] : ranges
    }
}
