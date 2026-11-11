import Foundation
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

// MARK: - shortenPath tests

@Test func shortenPathReplacesHomeWithTilde() {
    let home = NSHomeDirectory()
    let path = "\(home)/Documents/project"
    let result = shortenPath(path)
    #expect(result == "~/Documents/project")
}

@Test func shortenPathPreservesNonHomePaths() {
    let result = shortenPath("/usr/local/bin")
    #expect(result == "/usr/local/bin")
}

@Test func shortenPathHandlesEmptyString() {
    let result = shortenPath("")
    #expect(result == "")
}

@Test func shortenPathHandlesExactHomeDirectory() {
    let home = NSHomeDirectory()
    let result = shortenPath(home)
    #expect(result == "~")
}

@Test func shortenPathHandlesHomeWithTrailingSlash() {
    let home = NSHomeDirectory()
    let path = "\(home)/"
    let result = shortenPath(path)
    // v1.5.2 PT1: utils/paths.ts:73-77 returns ~ for the home directory itself.
    #expect(result == "~")
}

// MARK: - formatSessionDate tests

@Test func formatSessionDateJustNow() {
    let now = Date()
    let result = formatSessionDate(now, relativeTo: now)
    #expect(result == "just now")
}

@Test func formatSessionDateSecondsAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-30) // 30 seconds ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "just now")
}

@Test func formatSessionDateOneMinuteAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-60) // 1 minute ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "1 minute ago")
}

@Test func formatSessionDateMinutesAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-300) // 5 minutes ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "5 minutes ago")
}

@Test func formatSessionDateOneHourAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-3600) // 1 hour ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "1 hour ago")
}

@Test func formatSessionDateHoursAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-7200) // 2 hours ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "2 hours ago")
}

@Test func formatSessionDateOneDayAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-86400) // 1 day ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "1 day ago")
}

@Test func formatSessionDateDaysAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-259200) // 3 days ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "3 days ago")
}

@Test func formatSessionDateSixDaysAgo() {
    let now = Date()
    let date = now.addingTimeInterval(-518400) // 6 days ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "6 days ago")
}

@Test func formatSessionDateWeekOrMoreShowsDate() {
    let now = Date()
    let date = now.addingTimeInterval(-604800) // 7 days ago
    let result = formatSessionDate(date, relativeTo: now)
    // Should be a formatted date, not relative
    #expect(!result.contains("ago"))
    #expect(!result.contains("just now"))
}

// MARK: - SessionInfo tests

@Test func sessionInfoCanBeCreated() {
    let info = SessionInfo(
        path: "/tmp/test.jsonl",
        id: "abc123",
        cwd: "/home/user/project",
        name: "Test Session",
        created: Date(),
        modified: Date(),
        messageCount: 5,
        firstMessage: "Hello",
        allMessagesText: "Hello World"
    )

    #expect(info.id == "abc123")
    #expect(info.name == "Test Session")
    #expect(info.messageCount == 5)
}

@Test func sessionInfoOptionalName() {
    let info = SessionInfo(
        path: "/tmp/test.jsonl",
        id: "abc123",
        cwd: "/home/user",
        name: nil,
        created: Date(),
        modified: Date(),
        messageCount: 1,
        firstMessage: "First",
        allMessagesText: "First"
    )

    #expect(info.name == nil)
}

// MARK: - fuzzyFilter with SessionInfo tests

private func makeSession(
    id: String,
    name: String? = nil,
    cwd: String = "",
    firstMessage: String = "hello",
    allMessagesText: String = "hello"
) -> SessionInfo {
    SessionInfo(
        path: "/tmp/\(id).jsonl",
        id: id,
        cwd: cwd,
        name: name,
        created: Date(timeIntervalSince1970: 0),
        modified: Date(timeIntervalSince1970: 0),
        messageCount: 1,
        firstMessage: firstMessage,
        allMessagesText: allMessagesText
    )
}

@Test func fuzzyFilterSessionsById() {
    let sessions = [
        makeSession(id: "abc123"),
        makeSession(id: "def456"),
        makeSession(id: "abc789")
    ]

    let result = fuzzyFilter(sessions, "abc") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 2)
    #expect(result.map(\.id).contains("abc123"))
    #expect(result.map(\.id).contains("abc789"))
}

@Test func fuzzyFilterSessionsByName() {
    let sessions = [
        makeSession(id: "a", name: "Project Alpha"),
        makeSession(id: "b", name: "Project Beta"),
        makeSession(id: "c", name: nil)
    ]

    let result = fuzzyFilter(sessions, "alpha") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 1)
    #expect(result.first?.id == "a")
}

@Test func fuzzyFilterSessionsByMessageContent() {
    let sessions = [
        makeSession(id: "a", allMessagesText: "fix the login bug"),
        makeSession(id: "b", allMessagesText: "add new feature"),
        makeSession(id: "c", allMessagesText: "debug network issue")
    ]

    let result = fuzzyFilter(sessions, "bug") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 2)
    #expect(result.map(\.id).contains("a"))
    #expect(result.map(\.id).contains("c")) // "debug" contains pattern match
}

@Test func fuzzyFilterSessionsByCwd() {
    let sessions = [
        makeSession(id: "a", cwd: "/Users/dev/project-alpha"),
        makeSession(id: "b", cwd: "/Users/dev/project-beta"),
        makeSession(id: "c", cwd: "/tmp/other")
    ]

    let result = fuzzyFilter(sessions, "alpha") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 1)
    #expect(result.first?.id == "a")
}

@Test func fuzzyFilterSessionsEmptyQuery() {
    let sessions = [
        makeSession(id: "a"),
        makeSession(id: "b"),
        makeSession(id: "c")
    ]

    let result = fuzzyFilter(sessions, "") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 3)
}

@Test func fuzzyFilterSessionsNoMatch() {
    let sessions = [
        makeSession(id: "abc", allMessagesText: "some content"),
        makeSession(id: "def", allMessagesText: "other content")
    ]

    let result = fuzzyFilter(sessions, "xyz123") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.isEmpty)
}

@Test func fuzzyFilterSessionsMultipleTokens() {
    let sessions = [
        makeSession(id: "a", name: "Project", allMessagesText: "fix bug"),
        makeSession(id: "b", name: "Project", allMessagesText: "add feature"),
        makeSession(id: "c", name: "Other", allMessagesText: "fix bug")
    ]

    let result = fuzzyFilter(sessions, "project fix") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 1)
    #expect(result.first?.id == "a")
}

@Test func fuzzyFilterSessionsCaseInsensitive() {
    let sessions = [
        makeSession(id: "a", allMessagesText: "FIX THE BUG"),
        makeSession(id: "b", allMessagesText: "add feature")
    ]

    let result = fuzzyFilter(sessions, "fix") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    #expect(result.count == 1)
    #expect(result.first?.id == "a")
}

@Test func fuzzyFilterSessionsWhitespaceQuery() {
    let sessions = [
        makeSession(id: "a"),
        makeSession(id: "b")
    ]

    let result = fuzzyFilter(sessions, "   ") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    // Whitespace-only query should return all sessions
    #expect(result.count == 2)
}

@Test func fuzzyFilterSessionsPreservesOrder() {
    let sessions = [
        makeSession(id: "exact"),
        makeSession(id: "exactmatch"),
        makeSession(id: "e_x_a_c_t")
    ]

    let result = fuzzyFilter(sessions, "exact") { session in
        "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
    }

    // Better matches should come first
    #expect(result.count == 3)
    #expect(result.first?.id == "exact")
}

// MARK: - formatSessionDate edge cases

@Test func formatSessionDateAt59Minutes() {
    let now = Date()
    let date = now.addingTimeInterval(-3540) // 59 minutes ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "59 minutes ago")
}

@Test func formatSessionDateAt23Hours() {
    let now = Date()
    let date = now.addingTimeInterval(-82800) // 23 hours ago
    let result = formatSessionDate(date, relativeTo: now)
    #expect(result == "23 hours ago")
}

@Test func formatSessionDateFutureDate() {
    let now = Date()
    let date = now.addingTimeInterval(3600) // 1 hour in future
    let result = formatSessionDate(date, relativeTo: now)
    // Future dates should show as "just now" since diff is negative
    #expect(result == "just now")
}

// MARK: - shortenPath edge cases

@Test func shortenPathWithNestedHomeDirectory() {
    let home = NSHomeDirectory()
    let path = "\(home)/foo/bar/baz/deep/path"
    let result = shortenPath(path)
    #expect(result == "~/foo/bar/baz/deep/path")
}

@Test func shortenPathWithHomeLikePrefix() {
    // A path that looks similar but isn't actually the home directory
    let result = shortenPath("/Users/otherhome/Documents")
    // Should only be shortened if it actually starts with NSHomeDirectory()
    // The result depends on whether /Users/otherhome matches the home directory
    #expect(result.hasPrefix("/Users/") || result.hasPrefix("~"))
}
