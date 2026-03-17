import Foundation
import MuesliCore

enum MeetingSummaryClient {
    private static let openAIURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham")!
    private static let defaultOpenAIModel = "gpt-5-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultChatGPTModel = "gpt-5-mini"

    private static let titleInstructions = """
    Generate a short, descriptive meeting title (3-7 words) from this transcript. \
    Return ONLY the title text, nothing else. No quotes, no prefix, no explanation. \
    Examples: "Q3 Sprint Planning", "Customer Onboarding Review", "Security Audit Discussion"
    """

    private static let summaryInstructions = """
    You are a meeting notes assistant. Given a raw meeting transcript, produce structured meeting notes with the following sections:

    ## Meeting Summary
    A 2-3 sentence overview of what was discussed.

    ## Key Discussion Points
    - Bullet points of main topics discussed

    ## Decisions Made
    - Bullet points of any decisions reached

    ## Action Items
    - [ ] Bullet points of tasks assigned or agreed upon, with owners if mentioned

    ## Notable Quotes
    - Any important or notable statements (if applicable)

    Keep it concise and professional. If a section has no content, write "None noted."
    """

    static func summarize(transcript: String, meetingTitle: String, config: AppConfig) async -> String {
        let backend = (config.meetingSummaryBackend.isEmpty ? MeetingSummaryBackendOption.openAI.backend : config.meetingSummaryBackend).lowercased()
        if backend == MeetingSummaryBackendOption.chatGPT.backend {
            return await summarizeWithChatGPT(transcript: transcript, meetingTitle: meetingTitle, config: config)
        }
        if backend == MeetingSummaryBackendOption.openRouter.backend {
            return await summarizeWithOpenRouter(transcript: transcript, meetingTitle: meetingTitle, config: config)
        }
        return await summarizeWithOpenAI(transcript: transcript, meetingTitle: meetingTitle, config: config)
    }

    private static func summarizeWithOpenAI(transcript: String, meetingTitle: String, config: AppConfig) async -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
        guard !apiKey.isEmpty else {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }

        let body: [String: Any] = [
            "model": config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel,
            "input": [
                ["role": "system", "content": summaryInstructions],
                ["role": "user", "content": "Meeting title: \(meetingTitle)\n\nRaw transcript:\n\(transcript)"],
            ],
            "reasoning": ["effort": "low"],
            "text": ["verbosity": "low"],
            "max_output_tokens": 1200,
        ]

        var request = URLRequest(url: openAIURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenAIText(from: json),
                !text.isEmpty
            else {
                return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
            }
            return "# \(meetingTitle)\n\n\(text)"
        } catch {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }
    }

    private static func summarizeWithOpenRouter(transcript: String, meetingTitle: String, config: AppConfig) async -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
        guard !apiKey.isEmpty else {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }

        let model = config.openRouterModel.isEmpty ? defaultOpenRouterModel : config.openRouterModel
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": summaryInstructions],
                ["role": "user", "content": "Meeting title: \(meetingTitle)\n\nRaw transcript:\n\(transcript)"],
            ],
            "max_tokens": 1200,
        ]

        var request = URLRequest(url: openRouterURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppIdentity.displayName, forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenRouterText(from: json),
                !text.isEmpty
            else {
                return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
            }
            return "# \(meetingTitle)\n\n\(text)"
        } catch {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }
    }

    private static func summarizeWithChatGPT(transcript: String, meetingTitle: String, config: AppConfig) async -> String {
        do {
            let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
            let model = config.chatGPTModel.isEmpty ? defaultChatGPTModel : config.chatGPTModel
            let userMessage = "Meeting title: \(meetingTitle)\n\nRaw transcript:\n\(transcript)"

            let body: [String: Any] = [
                "model": model,
                "store": false,
                "instructions": summaryInstructions,
                "input": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "input_text", "text": userMessage],
                        ],
                    ] as [String: Any],
                ],
            ]

            var request = URLRequest(url: whamURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if !accountId.isEmpty {
                request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenAIText(from: json),
                !text.isEmpty
            else {
                fputs("[summary] ChatGPT WHAM: unexpected response format\n", stderr)
                return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
            }
            return "# \(meetingTitle)\n\n\(text)"
        } catch {
            fputs("[summary] ChatGPT summarization failed: \(error)\n", stderr)
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }
    }

    private static func extractOpenAIText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let output = payload["output"] as? [[String: Any]] ?? []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for entry in content {
                if let text = entry["text"] as? String, !text.isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func extractOpenRouterText(from payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { entry -> String? in
                guard (entry["type"] as? String) == "text", let text = entry["text"] as? String, !text.isEmpty else {
                    return nil
                }
                return text
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func generateTitle(transcript: String, config: AppConfig) async -> String? {
        let backend = (config.meetingSummaryBackend.isEmpty ? MeetingSummaryBackendOption.openAI.backend : config.meetingSummaryBackend).lowercased()

        // Use a short prefix of the transcript for title generation (save tokens)
        let truncated = String(transcript.prefix(1500))

        if backend == MeetingSummaryBackendOption.chatGPT.backend {
            return await generateTitleWithChatGPT(transcript: truncated, config: config)
        }

        if backend == MeetingSummaryBackendOption.openRouter.backend {
            let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
            guard !apiKey.isEmpty else { return nil }
            let model = config.openRouterModel.isEmpty ? defaultOpenRouterModel : config.openRouterModel
            return await callChatCompletions(
                url: openRouterURL,
                apiKey: apiKey,
                model: model,
                systemPrompt: titleInstructions,
                userPrompt: truncated,
                maxTokens: 30,
                extraHeaders: ["X-OpenRouter-Title": AppIdentity.displayName]
            )
        } else {
            let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
            guard !apiKey.isEmpty else { return nil }
            let model = config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel
            return await callChatCompletions(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: apiKey,
                model: model,
                systemPrompt: titleInstructions,
                userPrompt: truncated,
                maxTokens: 30,
                extraHeaders: [:]
            )
        }
    }

    private static func callChatCompletions(
        url: URL, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        maxTokens: Int, extraHeaders: [String: String]
    ) async -> String? {
        let isOpenAI = url.host?.contains("openai.com") == true
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        // OpenAI newer models require max_completion_tokens; OpenRouter uses max_tokens
        body[isOpenAI ? "max_completion_tokens" : "max_tokens"] = maxTokens

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("[summary] title generation: invalid JSON response\n", stderr)
                return nil
            }
            if let error = json["error"] as? [String: Any] {
                fputs("[summary] title generation error: \(error["message"] ?? error)\n", stderr)
                return nil
            }
            let result = extractOpenRouterText(from: json)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            fputs("[summary] generated title: \(result ?? "(nil)")\n", stderr)
            return result
        } catch {
            fputs("[summary] title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func generateTitleWithChatGPT(transcript: String, config: AppConfig) async -> String? {
        do {
            let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
            let model = config.chatGPTModel.isEmpty ? defaultChatGPTModel : config.chatGPTModel

            let body: [String: Any] = [
                "model": model,
                "store": false,
                "instructions": titleInstructions,
                "input": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "input_text", "text": transcript],
                        ],
                    ] as [String: Any],
                ],
                "max_output_tokens": 30,
            ]

            var request = URLRequest(url: whamURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if !accountId.isEmpty {
                request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = extractOpenAIText(from: json) else {
                fputs("[summary] ChatGPT title generation: unexpected response\n", stderr)
                return nil
            }
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            fputs("[summary] ChatGPT generated title: \(result)\n", stderr)
            return result
        } catch {
            fputs("[summary] ChatGPT title generation failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func rawTranscriptFallback(transcript: String, meetingTitle: String) -> String {
        "# \(meetingTitle)\n\n## Raw Transcript\n\n\(transcript)"
    }
}
