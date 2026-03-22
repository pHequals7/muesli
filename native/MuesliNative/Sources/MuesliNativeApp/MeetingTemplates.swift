import Foundation
import MuesliCore

struct CustomMeetingTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var prompt: String
}

struct MeetingTemplateSnapshot: Equatable, Sendable {
    let id: String
    let name: String
    let kind: MeetingTemplateKind
    let prompt: String
}

struct MeetingTemplateDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let category: String?
    let icon: String
    let kind: MeetingTemplateKind
    let promptBody: String

    var snapshot: MeetingTemplateSnapshot {
        MeetingTemplateSnapshot(
            id: id,
            name: title,
            kind: kind,
            prompt: promptBody
        )
    }
}

enum MeetingTemplates {
    static let autoID = "auto"

    static let auto = MeetingTemplateDefinition(
        id: autoID,
        title: "Auto",
        category: nil,
        icon: "sparkles",
        kind: .auto,
        promptBody: """
        Use this structure exactly:

        ## Meeting Summary
        A 2-3 sentence overview of what was discussed.

        ## Key Discussion Points
        - Bullet points of the main topics discussed

        ## Decisions Made
        - Bullet points of any decisions reached

        ## Action Items
        - [ ] Bullet points of tasks assigned or agreed upon, with owners if mentioned

        ## Notable Quotes
        - Any important or notable statements, if applicable
        """
    )

    static let builtIns: [MeetingTemplateDefinition] = [
        MeetingTemplateDefinition(
            id: "one-to-one",
            title: "1 to 1",
            category: "Team",
            icon: "person.2.fill",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Check-In
            A brief summary of how the conversation opened and the overall tone.

            ## Topics Discussed
            - Main themes raised by either person

            ## Support Needed
            - Blockers, concerns, or asks for help

            ## Commitments
            - [ ] Follow-ups or commitments made by either person

            ## Manager Notes
            - Coaching, feedback, or context that should be remembered
            """
        ),
        MeetingTemplateDefinition(
            id: "customer-discovery",
            title: "Customer: Discovery",
            category: "Commercial",
            icon: "person.crop.circle.badge.questionmark",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Customer Context
            - Company, role, or situation if mentioned

            ## Problems and Pain Points
            - Explicit frustrations, blockers, or unmet needs

            ## Current Workflow
            - How they currently solve the problem today

            ## Buying Signals
            - Indicators of urgency, budget, timing, or decision process

            ## Next Steps
            - [ ] Follow-up actions, owners, and dates if mentioned
            """
        ),
        MeetingTemplateDefinition(
            id: "hiring",
            title: "Hiring",
            category: "Recruiting",
            icon: "briefcase.fill",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Candidate Snapshot
            A concise overview of the candidate and relevant background.

            ## Strengths
            - Positive signals from the conversation

            ## Concerns
            - Risks, gaps, or open questions

            ## Role Fit
            - Why they do or do not fit the role as discussed

            ## Decision and Next Steps
            - [ ] Hiring decision, interview progression, or follow-up items
            """
        ),
        MeetingTemplateDefinition(
            id: "stand-up",
            title: "Stand-Up",
            category: "Team",
            icon: "figure.stand",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Yesterday
            - Work completed or progress since the last update

            ## Today
            - Planned work or priorities for today

            ## Blockers
            - Risks, delays, or dependencies

            ## Coordination Notes
            - Decisions, asks, or cross-team alignment points
            """
        ),
        MeetingTemplateDefinition(
            id: "weekly-team-meeting",
            title: "Weekly Team Meeting",
            category: "Team",
            icon: "calendar",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Weekly Overview
            A concise summary of the most important updates from the meeting.

            ## Progress Updates
            - Key workstreams and status changes

            ## Decisions
            - Decisions made or confirmed

            ## Risks and Open Questions
            - Issues that need attention or follow-up

            ## Action Items
            - [ ] Tasks, owners, and timing if mentioned
            """
        ),
    ]

    static func customDefinition(from customTemplate: CustomMeetingTemplate) -> MeetingTemplateDefinition {
        MeetingTemplateDefinition(
            id: customTemplate.id,
            title: customTemplate.name,
            category: "Custom",
            icon: "square.and.pencil",
            kind: .custom,
            promptBody: customTemplate.prompt
        )
    }

    static func customDefinitions(from customTemplates: [CustomMeetingTemplate]) -> [MeetingTemplateDefinition] {
        customTemplates.map(customDefinition)
    }

    static func allDefinitions(customTemplates: [CustomMeetingTemplate]) -> [MeetingTemplateDefinition] {
        [auto] + builtIns + customDefinitions(from: customTemplates)
    }

    static func resolveDefinition(id: String?, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateDefinition {
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? autoID
        if normalizedID == autoID {
            return auto
        }
        if let builtIn = builtIns.first(where: { $0.id == normalizedID }) {
            return builtIn
        }
        if let custom = customTemplates.first(where: { $0.id == normalizedID }) {
            return customDefinition(from: custom)
        }
        return auto
    }

    static func resolveSnapshot(id: String?, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateSnapshot {
        resolveDefinition(id: id, customTemplates: customTemplates).snapshot
    }

    static func snapshot(for meeting: MeetingRecord, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateSnapshot {
        let storedID = meeting.selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedName = meeting.selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedPrompt = meeting.selectedTemplatePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedID.isEmpty, !storedName.isEmpty, !storedPrompt.isEmpty {
            return MeetingTemplateSnapshot(
                id: storedID,
                name: storedName,
                kind: meeting.selectedTemplateKind ?? .auto,
                prompt: storedPrompt
            )
        }
        return resolveSnapshot(id: storedID.isEmpty ? nil : storedID, customTemplates: customTemplates)
    }
}
