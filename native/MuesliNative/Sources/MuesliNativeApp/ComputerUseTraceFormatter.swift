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
            let status = displayStatus(for: event).map { " [\($0)]" } ?? ""
            lines.append("\(step) - \(event.title)\(status)")
            lines.append(event.body)
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayStatus(for event: ComputerUseTraceEvent) -> String? {
        guard let status = event.status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else { return nil }
        let normalizedStatus = status.lowercased()
        let normalizedTitle = event.title.lowercased()
        if normalizedStatus == normalizedTitle {
            return nil
        }
        switch (event.kind, normalizedStatus) {
        case ("observation", "observed"),
             ("planning", "planning"),
             ("tool_call", "executing"),
             ("model_output", "planned"):
            return nil
        default:
            return status
        }
    }
}
