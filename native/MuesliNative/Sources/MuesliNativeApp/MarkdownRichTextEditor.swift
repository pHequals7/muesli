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
    var isEditable: Bool = true
    var placeholder: String = "Write notes here..."
    var onTextChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, command: $command, onTextChange: onTextChange)
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
        textView.isEditable = isEditable
        textView.isSelectable = true
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
        textView.isEditable = isEditable
        textView.isSelectable = true
        context.coordinator.onTextChange = onTextChange
        if context.coordinator.shouldApplyExternalMarkdown(text) {
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
        var onTextChange: ((String) -> Void)?
        weak var textView: NSTextView?
        var didFocus = false
        private(set) var currentMarkdown = ""
        private var isApplying = false
        private var isHandlingNewline = false
        private var usesMarkdownStyling = false
        private var lastBindingMarkdown = ""
        private var pendingLocalMarkdown: String?
        private var bindingPublishWorkItem: DispatchWorkItem?

        private let bodyFont = NSFont.systemFont(ofSize: 16)
        private let boldFont = NSFont.boldSystemFont(ofSize: 16)
        private let headingFont = NSFont.systemFont(ofSize: 26, weight: .bold)
        private let bodyColor = NSColor.labelColor
        private let secondaryColor = NSColor.secondaryLabelColor

        init(text: Binding<String>, command: Binding<MarkdownEditorCommand?>, onTextChange: ((String) -> Void)?) {
            _text = text
            _command = command
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            let markdown = markdownForLiveEdit(from: textView)
            currentMarkdown = markdown
            pendingLocalMarkdown = markdown
            onTextChange?(markdown)
            scheduleBindingPublish(markdown)
            textView.needsDisplay = true
        }

        func shouldApplyExternalMarkdown(_ markdown: String) -> Bool {
            if markdown == currentMarkdown {
                lastBindingMarkdown = markdown
                if pendingLocalMarkdown == markdown {
                    pendingLocalMarkdown = nil
                }
                return false
            }
            if pendingLocalMarkdown != nil, markdown == lastBindingMarkdown {
                return false
            }
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isHandlingNewline else { return true }
            guard replacementString == "\n" else { return true }
            continueListIfNeeded(in: textView, affectedCharRange: affectedCharRange)
            return false
        }

        func apply(markdown: String, to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            isApplying = true
            usesMarkdownStyling = Self.markdownNeedsRichRendering(markdown)
            textView.textStorage?.setAttributedString(attributedString(from: markdown))
            textView.typingAttributes = bodyAttributes()
            textView.selectedRanges = selectedRanges.clamped(to: textView.string.count)
            currentMarkdown = markdown
            lastBindingMarkdown = markdown
            pendingLocalMarkdown = nil
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
            usesMarkdownStyling = true
            let markdown = serializedMarkdown(from: textView)
            currentMarkdown = markdown
            pendingLocalMarkdown = markdown
            onTextChange?(markdown)
            publishBinding(markdown)
            textView.needsDisplay = true
            self.command = nil
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        private func scheduleBindingPublish(_ markdown: String) {
            bindingPublishWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.publishBinding(markdown)
            }
            bindingPublishWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        private func publishBinding(_ markdown: String) {
            bindingPublishWorkItem?.cancel()
            bindingPublishWorkItem = nil
            guard text != markdown else {
                lastBindingMarkdown = markdown
                if pendingLocalMarkdown == markdown {
                    pendingLocalMarkdown = nil
                }
                return
            }
            text = markdown
            lastBindingMarkdown = markdown
            if pendingLocalMarkdown == markdown {
                pendingLocalMarkdown = nil
            }
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
                result.append(attributedLine(from: parsed.displayText, attributes: parsed.attributes))
                if index < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
                }
            }
            return result
        }

        private func markdownForLiveEdit(from textView: NSTextView) -> String {
            // Plain note taking should stay on the NSTextView fast path. Full
            // markdown serialization walks every attribute run, which is only
            // needed after the user has used rich editor commands or opened
            // notes that already contain markdown structure.
            guard usesMarkdownStyling else {
                return textView.string
            }
            return serializedMarkdown(from: textView)
        }

        private static func markdownNeedsRichRendering(_ markdown: String) -> Bool {
            markdown
                .components(separatedBy: .newlines)
                .contains { line in
                    line.hasPrefix("# ")
                        || line.hasPrefix("- ")
                        || line.hasPrefix("- [ ] ")
                        || line.hasPrefix("- [x] ")
                        || line.hasPrefix("- [X] ")
                        || line.contains("**")
                }
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

        private func attributedLine(
            from line: String,
            attributes: [NSAttributedString.Key: Any]
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            var cursor = line.startIndex
            while cursor < line.endIndex {
                guard let opening = line.range(of: "**", range: cursor..<line.endIndex),
                      let closing = line.range(of: "**", range: opening.upperBound..<line.endIndex)
                else {
                    append(String(line[cursor..<line.endIndex]), to: result, attributes: attributes)
                    break
                }

                append(String(line[cursor..<opening.lowerBound]), to: result, attributes: attributes)
                var boldAttributes = attributes
                let baseFont = attributes[.font] as? NSFont ?? bodyFont
                boldAttributes[.font] = boldVersion(of: baseFont)
                append(String(line[opening.upperBound..<closing.lowerBound]), to: result, attributes: boldAttributes)
                cursor = closing.upperBound
            }
            return result
        }

        private func append(
            _ string: String,
            to result: NSMutableAttributedString,
            attributes: [NSAttributedString.Key: Any]
        ) {
            guard !string.isEmpty else { return }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }

        private func applyHeading(in textView: NSTextView) {
            let ranges = paragraphRanges(for: textView)
            guard let storage = textView.textStorage else { return }
            let removeHeading = ranges.allSatisfy { range in
                range.length > 0 && lineIsHeading(storage: storage, range: range)
            }
            isApplying = true
            for range in ranges {
                if removeHeading {
                    storage.addAttributes(bodyAttributes(), range: range)
                } else {
                    storage.addAttributes([
                        .font: headingFont,
                        .foregroundColor: bodyColor,
                        .paragraphStyle: paragraphStyle(spacing: 14, lineHeightMultiple: 1.02)
                    ], range: range)
                }
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
            let ranges = paragraphRanges(for: textView)
            let full = textView.string as NSString
            let replacements = ranges.map { range in
                let existingLine = full.substring(with: range).trimmingCharacters(in: .newlines)
                return prefix + removingListPrefix(from: existingLine)
            }

            isApplying = true
            var totalDelta = 0
            for (range, replacement) in zip(ranges, replacements).reversed() {
                textView.replaceCharacters(in: range, with: replacement)
                totalDelta += replacement.count - range.length
            }
            isApplying = false

            guard let firstRange = ranges.first, let lastRange = ranges.last else { return }
            if ranges.count == 1 {
                textView.setSelectedRange(NSRange(location: firstRange.location + replacements[0].count, length: 0))
            } else {
                let originalEnd = lastRange.location + lastRange.length
                textView.setSelectedRange(NSRange(location: firstRange.location, length: originalEnd + totalDelta - firstRange.location))
            }
        }

        private func removingListPrefix(from line: String) -> String {
            for existingPrefix in ["• ", "☐ ", "☑ "] where line.hasPrefix(existingPrefix) {
                return String(line.dropFirst(existingPrefix.count))
            }
            return line
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
            isHandlingNewline = true
            defer { isHandlingNewline = false }
            if prefix == nil {
                // Exiting empty list item — delete the marker line, leave a plain newline
                let exitText = paragraphRange.upperBound < full.length ? "\n" : ""
                textView.insertText(exitText, replacementRange: paragraphRange)
            } else {
                textView.insertText(prefix!, replacementRange: affectedCharRange)
            }
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
            return abs((font?.pointSize ?? 0) - headingFont.pointSize) < 0.1
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
