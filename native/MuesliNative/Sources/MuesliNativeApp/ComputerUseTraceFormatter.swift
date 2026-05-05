import Foundation
import MuesliCore

enum ComputerUseTraceFormatter {
    static func debugText(for record: DictationRecord) -> String {
        guard let trace = record.computerUseTrace else {
            return record.rawText
        }

        var lines: [String] = [
            "CUA Command",
            record.rawText,
            "",
            "Final Status",
            trace.finalStatus,
            "",
            "Final Message",
            trace.finalMessage,
            "",
            "Step Trail",
        ]

        for event in trace.events {
            let step = event.step.map { "Step \($0)" } ?? "Run"
            let status = event.status.map { " [\($0)]" } ?? ""
            lines.append("\(step) - \(event.title)\(status)")
            lines.append(event.body)
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
