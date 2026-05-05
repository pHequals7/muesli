import Foundation

struct ComputerUseToolDefinition: Codable, Equatable {
    let name: ComputerUseToolName
    let description: String
    let schema: ComputerUseToolSchema
    let riskPolicy: String
    let mutating: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case schema
        case riskPolicy = "risk_policy"
        case mutating
    }
}

struct ComputerUseToolSchema: Codable, Equatable {
    let type: String
    let properties: [String: ComputerUseToolSchemaProperty]
    let required: [String]
    let additionalProperties: Bool

    init(
        properties: [String: ComputerUseToolSchemaProperty],
        required: [String]
    ) {
        type = "object"
        self.properties = properties
        self.required = required
        additionalProperties = false
    }
}

struct ComputerUseToolSchemaProperty: Codable, Equatable {
    let type: String
    let description: String
    let enumValues: [String]?
    let items: [String: String]?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
    }

    init(type: String, description: String, enumValues: [String]? = nil, items: [String: String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items
    }
}

enum ComputerUseToolRegistry {
    static let catalogVersion = "muesli-cua-tools-v1"

    static let definitions: [ComputerUseToolDefinition] = [
        definition(.listApps, "List running desktop apps with names, bundle IDs, process IDs, and active state.", required: [], properties: [:], risk: "safe read-only"),
        definition(.launchApp, "Launch or activate a macOS app by app_name or app_bundle_id.", required: [], properties: [
            "app_name": .string("Human app name, for example Google Chrome."),
            "app_bundle_id": .string("Bundle identifier, for example com.google.Chrome."),
        ], risk: "foreground activation allowed"),
        definition(.listWindows, "List visible windows, optionally scoped by app_bundle_id.", required: [], properties: [
            "app_bundle_id": .string("Optional bundle identifier to scope windows."),
        ], risk: "safe read-only"),
        definition(.getWindowState, "Capture the active window state: screenshot metadata, screenshot image for the planner, AX candidates, cursor, app, and window metadata.", required: [], properties: [
            "app_bundle_id": .string("Optional app bundle to activate before capture."),
            "window_id": .integer("Optional window id hint."),
        ], risk: "safe read-only"),
        definition(.click, "Click an AX element from the latest get_window_state by element_index/element_id, or click a screenshot coordinate when no AX target exists.", required: [], properties: [
            "element_index": .integer("Preferred temporary element index from the latest state."),
            "element_id": .string("Temporary element id from the latest state, for example e12."),
            "screenshot_id": .string("Current screenshot id when using x/y coordinates."),
            "x": .number("Screenshot pixel x coordinate."),
            "y": .number("Screenshot pixel y coordinate."),
            "clicks": .integer("1 for single click, 2 for double click."),
            "button": .string("left or right."),
            "label": .string("Human target label for trace and safety."),
        ], risk: "confirmation for risky labels or unknown coordinate targets"),
        definition(.setValue, "Set an AX element value by element_index/element_id from the latest state.", required: ["value"], properties: [
            "element_index": .integer("Temporary element index from the latest state."),
            "element_id": .string("Temporary element id from the latest state."),
            "value": .string("Value to set."),
            "label": .string("Human target label for trace."),
        ], risk: "local validation only; no send/submit bypass"),
        definition(.typeText, "Type text into the focused field.", required: ["text"], properties: [
            "text": .string("Text to type."),
        ], risk: "safe primitive"),
        definition(.pressKey, "Press one key with optional modifiers.", required: ["key"], properties: [
            "key": .string("Key name, for example enter, tab, l, escape."),
            "modifiers": .array("Optional modifiers.", item: .string("Modifier", enumValues: ComputerUseKeyModifier.allCases.map(\.rawValue))),
        ], risk: "confirmation for Cmd-Q and Cmd-W"),
        definition(.hotkey, "Alias for press_key used for keyboard shortcuts.", required: ["key"], properties: [
            "key": .string("Key name."),
            "modifiers": .array("Required or optional modifiers.", item: .string("Modifier", enumValues: ComputerUseKeyModifier.allCases.map(\.rawValue))),
        ], risk: "confirmation for Cmd-Q and Cmd-W"),
        definition(.scroll, "Scroll the current view.", required: ["direction"], properties: [
            "direction": .string("Scroll direction.", enumValues: ["up", "down", "left", "right"]),
            "pages": .number("Approximate page count, default 1."),
        ], risk: "safe primitive"),
        definition(.drag, "Drag from one screenshot coordinate to another.", required: ["screenshot_id", "x", "y", "to_x", "to_y"], properties: [
            "screenshot_id": .string("Current screenshot id."),
            "x": .number("Start screenshot pixel x."),
            "y": .number("Start screenshot pixel y."),
            "to_x": .number("End screenshot pixel x."),
            "to_y": .number("End screenshot pixel y."),
            "label": .string("Human target label for trace and safety."),
        ], risk: "confirmation for risky labels"),
        definition(.listBrowserTabs, "List tabs in Chrome-compatible browser windows.", required: ["app_bundle_id"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
        ], risk: "safe read-only"),
        definition(.activateBrowserTab, "Activate a browser tab by window_index and tab_index.", required: ["app_bundle_id", "window_index", "tab_index"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("1-based browser window index."),
            "tab_index": .integer("1-based tab index in the window."),
        ], risk: "foreground activation allowed"),
        definition(.navigateURL, "Navigate the selected browser tab to a safe http/https URL.", required: ["app_bundle_id", "url"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("Optional 1-based browser window index."),
            "tab_index": .integer("Optional 1-based tab index."),
            "url": .string("http or https URL only."),
        ], risk: "rejects javascript:, file:, data:, shell-like strings, and unsafe URLs"),
        definition(.pageGetText, "Read visible/body text from a Chrome tab using read-only Apple Events JavaScript.", required: ["app_bundle_id"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("Optional 1-based browser window index."),
            "tab_index": .integer("Optional 1-based tab index."),
        ], risk: "safe read-only"),
        definition(.pageQueryDOM, "Query DOM nodes in a Chrome tab and return text plus selected attributes. Read-only only.", required: ["app_bundle_id", "selector"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("Optional 1-based browser window index."),
            "tab_index": .integer("Optional 1-based tab index."),
            "selector": .string("CSS selector."),
            "attributes": .array("Attributes to return.", item: .string("Attribute name.")),
        ], risk: "safe read-only"),
        definition(.finish, "Finish when the user task is complete. Use reason for the final answer.", required: [], properties: [
            "reason": .string("Final user-facing result."),
        ], risk: "safe finalization"),
        definition(.fail, "Fail explicitly when blocked, unsupported, unsafe, or incomplete. Use reason to explain.", required: ["reason"], properties: [
            "reason": .string("Failure reason."),
        ], risk: "safe finalization"),
    ]

    static func definition(for tool: ComputerUseToolName) -> ComputerUseToolDefinition? {
        definitions.first { $0.name == tool }
    }

    static func promptDocumentation() -> String {
        definitions.map { definition in
            let required = definition.schema.required.isEmpty ? "none" : definition.schema.required.joined(separator: ", ")
            let properties = definition.schema.properties
                .sorted { $0.key < $1.key }
                .map { key, property in
                    var line = "  - \(key): \(property.type). \(property.description)"
                    if let values = property.enumValues {
                        line += " Allowed: \(values.joined(separator: ", "))."
                    }
                    return line
                }
                .joined(separator: "\n")
            let propertyText = properties.isEmpty ? "  - no arguments" : properties
            return """
            Tool: \(definition.name.rawValue)
            Description: \(definition.description)
            Required: \(required)
            Risk policy: \(definition.riskPolicy)
            Schema properties:
            \(propertyText)
            """
        }.joined(separator: "\n\n")
    }

    private static func definition(
        _ name: ComputerUseToolName,
        _ description: String,
        required: [String],
        properties: [String: ComputerUseToolSchemaProperty],
        risk: String
    ) -> ComputerUseToolDefinition {
        ComputerUseToolDefinition(
            name: name,
            description: description,
            schema: ComputerUseToolSchema(
                properties: ["tool": .string("Tool name.", enumValues: [name.rawValue])].merging(properties) { current, _ in current },
                required: ["tool"] + required
            ),
            riskPolicy: risk,
            mutating: ComputerUseToolInvocation(tool: name).isMutating
        )
    }
}

private extension ComputerUseToolSchemaProperty {
    static func string(_ description: String, enumValues: [String]? = nil) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "string", description: description, enumValues: enumValues)
    }

    static func integer(_ description: String) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "integer", description: description)
    }

    static func number(_ description: String) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "number", description: description)
    }

    static func array(_ description: String, item: ComputerUseToolSchemaProperty) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "array", description: description, items: ["type": item.type])
    }
}
