import Testing
@testable import MuesliNativeApp

@Suite("Meeting preview text")
struct MeetingPreviewTextTests {

    @Test("removes markdown structure from meeting previews")
    func removesMarkdownStructure() {
        let preview = MeetingPreviewText.snippet(from: """
        # Customer Sync

        ## Decisions
        - **Ship** pause controls
        - [ ] Follow up with [Rishab](https://example.com)
        - _Polish_ __meeting__ previews
        """, limit: 120)

        #expect(preview == "Customer Sync Decisions Ship pause controls Follow up with Rishab Polish meeting previews")
    }

    @Test("falls back when source is empty after cleanup")
    func emptyPreviewFallback() {
        let preview = MeetingPreviewText.snippet(from: """
        ```swift
        let hidden = true
        ```
        """)

        #expect(preview == "No notes yet")
    }
}
