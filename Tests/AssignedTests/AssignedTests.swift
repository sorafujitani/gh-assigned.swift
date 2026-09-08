import Foundation
import Testing
@testable import AssignedCore
@testable import AssignedTerminal
@testable import AssignedCLI

struct AssignedTests {
    @Test func jsonUsesCompatibleSchemaAndEnumStrings() async throws {
        let executor = FixtureExecutor()
        let directory = try temporaryDirectory()
        let cache = CacheStore(fileURL: directory.appendingPathComponent("snapshot.json"))
        let output = try await AssignedCLI.jsonOutput(client: GitHubClient(executor: executor), cache: cache)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: Data(output.utf8))
        #expect(decoded.lists.count == 3)
        #expect(decoded.lists[0][0].checks == .failure)
        #expect(decoded.lists[0][0].review == .approved)
        #expect(output.contains("\"is_draft\""))
        #expect(output.contains("\"base_ref\""))
        #expect(output.contains("\"head_ref\""))
        #expect(output.contains("\"checks\" : \"Failure\""))
        #expect(output.contains("\"review\" : \"Approved\""))
        #expect(cache.load() != nil)
        #expect(executor.log.count == 6)
        #expect(executor.log.queries.allSatisfy { $0.contains("first: 100") })
    }

    @Test func githubPreservesPartialDataAndMapsUnknownEnums() async throws {
        let executor = FixtureExecutor(partial: true)
        let list = try await GitHubClient(executor: executor).fetchList(.mine)
        #expect(list.count == 1)
        #expect(list[0].author == "")
        #expect(list[0].review == .none)
        let checks = try await GitHubClient(executor: executor).fetchChecks(.mine)
        #expect(checks[PRKey(repo: "owner/repo", number: 7)] == .failure)
    }

    @Test func githubFetchesTheThreeListsAndChecksInParallelContract() async throws {
        let executor = FixtureExecutor()
        _ = try await GitHubClient(executor: executor).fetchAll()
        let queries = executor.log.queries
        #expect(queries.count == 6)
        #expect(queries.contains(where: { $0.contains("author:@me") }))
        #expect(queries.contains(where: { $0.contains("review-requested:@me") }))
        #expect(queries.contains(where: { $0.contains("assignee:@me") }))
        #expect(queries.filter { $0.contains("statusCheckRollup") }.count == 3)
    }

    @Test func stackNestsOnlyWithinTheSameRepositoryAndKeepsCycles() {
        let prs = [
            makePR(number: 3, repo: "o/r", base: "b", head: "c"),
            makePR(number: 1, repo: "o/r", base: "main", head: "a"),
            makePR(number: 2, repo: "o/r", base: "a", head: "b"),
            makePR(number: 4, repo: "o/other", base: "b", head: "c"),
        ]
        let shape = Stack.arrange(prs).map { ($0.pr.number, $0.depth) }
        #expect(shape.map(\.0) == [1, 2, 3, 4])
        #expect(shape.map(\.1) == [0, 1, 2, 0])
        let cycle = Stack.arrange([
            makePR(number: 1, repo: "o/r", base: "b", head: "a"),
            makePR(number: 2, repo: "o/r", base: "a", head: "b"),
        ])
        #expect(cycle.map(\.depth) == [0, 0])
    }

    @Test func searchMatchesFieldsEndOfFieldAndHighlightsUnicode() {
        let rows = Stack.arrange([
            makePR(number: 1, repo: "o/gh-assigned", title: "toridori docs", author: "octocat"),
            makePR(number: 2, repo: "o/r", title: "❤️ fix login", author: "ali"),
        ])
        let docs = SearchEngine.search(rows: rows, query: "docs", scope: .title, mode: .substring, showAuthor: true)
        #expect(docs.map(\.rowIndex) == [0])
        #expect(SearchEngine.highlight(match: docs[0], row: rows[0], scope: .title, showAuthor: true).title.count == 4)
        let login = SearchEngine.search(rows: rows, query: "LOGIN", scope: .all, mode: .fuzzy, showAuthor: true)
        #expect(login.map(\.rowIndex) == [1])
        let highlight = SearchEngine.highlight(match: login[0], row: rows[1], scope: .all, showAuthor: true)
        #expect(highlight.title.count == 5)
    }

    @Test func appStateRejectsOldGenerationAndKeepsFirstChecks() {
        var app = AppState()
        let old = app.startFetch(steps: 2)
        app.setChecks(.mine, [makePR(number: 1).key: .success])
        app.setList(.mine, [makePR(number: 1)])
        #expect(app.selected?.checks == .success)
        let current = app.startFetch(steps: 2)
        #expect(current != old)
        #expect(!app.accepts(generation: old))
        app.setList(.mine, [makePR(number: 1)])
        app.setChecks(.mine, [makePR(number: 1).key: .failure])
        #expect(app.selected?.checks == .failure)
        #expect(app.status == .fresh)
    }

    @Test func cacheIgnoresCorruptDataAndReadsRustCompatibleSnapshot() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("snapshot.json")
        let cache = CacheStore(fileURL: file)
        try Data("not json".utf8).write(to: file)
        #expect(cache.load() == nil)
        let snapshot = Snapshot(lists: [[makePR(number: 1)], [], []])
        try cache.store(snapshot)
        #expect(cache.load() == snapshot)
        try Data(#"{"lists":[[],[]]}"#.utf8).write(to: file)
        #expect(cache.load() == nil)
    }

    @Test func keyDecoderHandlesUtf8AnsiAndControlKeys() {
        var decoder = KeyDecoder()
        let bytes = Array("\u{1b}[A\u{1b}[6~\u{1b}[Z\u{1b}OPあ".utf8)
        let keys = decoder.feed(bytes)
        #expect(keys == [.up, .pageDown, .backTab, .function(1), .character("あ")])
        #expect(decoder.feed([3, 8, 13]) == [.control("c"), .backspace, .enter])
        var split = KeyDecoder()
        #expect(split.feed([0xe3, 0x81]).isEmpty)
        #expect(split.feed([0x82]) == [.character("あ")])
    }

    @Test func unicodeWidthAndInlineRendererStayTerminalSafe() {
        #expect(UnicodeWidth.of("日本") == 4)
        #expect(UnicodeWidth.of("❤️") == 2)
        #expect(UnicodeWidth.truncate("日本語abc", to: 5) == "日本…")
        var renderer = InlineRenderer()
        let start = renderer.start()
        let frame = renderer.render(RenderFrame(lines: ["one", "two"], cursorColumn: 2))
        let finish = renderer.finish()
        #expect(!start.contains("1049"))
        #expect(!frame.contains("2J"))
        #expect(!finish.contains("2J"))
        #expect(frame.contains("[K"))
        #expect(finish.contains("[2A"))
    }

    @Test func subprocessDrainsLargeStdoutAndStderrTogether() async throws {
        let script = "i=0; while [ $i -lt 20000 ]; do printf o; printf e >&2; i=$((i+1)); done"
        let result = try await Subprocess.run(executable: "/bin/sh", arguments: ["-c", script])
        #expect(result.succeeded)
        #expect(result.stdout.count == 20_000)
        #expect(result.stderr.count == 20_000)
    }

    private func makePR(
        number: UInt64,
        repo: String = "o/r",
        base: String = "main",
        head: String? = nil,
        title: String? = nil,
        author: String = "me"
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: title ?? "pr \(number)",
            url: "https://github.com/\(repo)/pull/\(number)",
            author: author,
            isDraft: false,
            baseRef: base,
            headRef: head ?? "branch-\(number)",
            checks: .none,
            review: .none
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class FixtureLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private struct FixtureExecutor: CommandExecuting {
    let log: FixtureLog
    let partial: Bool

    init(partial: Bool = false) {
        log = FixtureLog()
        self.partial = partial
    }

    func run(executable: String, arguments: [String], stdin: Data?) async throws -> CommandResult {
        let query = arguments.last ?? ""
        log.append(query)
        let checks = query.contains("statusCheckRollup")
        let body: String
        if checks {
            body = #"{"data":{"search":{"nodes":[{"number":7,"repository":{"nameWithOwner":"owner/repo"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"ERROR"}}}]}}]}}}"#
        } else if partial {
            body = #"""
            {"data":{"search":{"nodes":[null,
            {"number":7,"title":"fixture","url":"https://github.com/owner/repo/pull/7",
            "isDraft":false,"baseRefName":"main","headRefName":"fixture",
            "repository":{"nameWithOwner":"owner/repo"},"author":null,
            "reviewDecision":"NEW_VALUE"}]}},"errors":[{"message":"one node failed"}]}
            """#
        } else {
            body = #"""
            {"data":{"search":{"nodes":[{"number":7,"title":"fixture",
            "url":"https://github.com/owner/repo/pull/7","isDraft":false,
            "baseRefName":"main","headRefName":"fixture",
            "repository":{"nameWithOwner":"owner/repo"},
            "author":{"login":"octocat"},"reviewDecision":"APPROVED"}]}}}
            """#
        }
        return CommandResult(status: partial && !checks ? 1 : 0, stdout: Data(body.utf8), stderr: Data("gh: fixture warning\n".utf8))
    }
}

private extension FixtureLog {
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var queries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
