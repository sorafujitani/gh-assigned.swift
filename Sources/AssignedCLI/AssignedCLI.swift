import ArgumentParser
import AssignedCore
import AssignedTerminal
@preconcurrency import Foundation

public enum AssignedCLI {
    public static let exitCancelled: Int32 = 130
    public static let helpDiscussion = """
    Tabs: Mine, Review requested, Assigned.
    Interactive mode uses an inline picker and keeps shell scrollback visible.
    Use --json to fetch all three lists for scripts.
    """

    public static func run(
        json: Bool,
        client: GitHubClient = GitHubClient(),
        cache: CacheStore = CacheStore()
    ) async throws {
        if json {
            let output = try await jsonOutput(client: client, cache: cache)
            print(output)
            return
        }
        guard TerminalSession.isTerminal else {
            throw ValidationError("gh assigned needs an interactive terminal; use --json for scripts")
        }
        let outcome = try await InteractiveSession(client: client, cache: cache).run()
        if case .cancel = outcome {
            throw ExitCode(exitCancelled)
        }
        if case let .open(url) = outcome {
            try await Browser.open(url: url)
        }
    }

    public static func jsonOutput(client: GitHubClient, cache: CacheStore) async throws -> String {
        let snapshot = try await client.fetchAll()
        // Cache is a warm start. A read-only or unavailable cache must not make
        // a successful API response unusable.
        try? cache.store(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }
}

private enum InteractiveOutcome: Sendable {
    case cancel
    case open(String)
}

private enum ExternalResult: Sendable {
    case success(String)
    case failure(String)
}

private enum InteractiveEvent: Sendable {
    case key(TerminalKey)
    case tick
    case list(UInt64, ListKind, [PullRequest])
    case checks(UInt64, ListKind, [PRKey: Checks])
    case listError(UInt64, ListKind, String)
    case checksError(UInt64, ListKind, String)
    case external(ExternalResult)
    case terminate
}

private actor SnapshotSaver {
    private let cache: CacheStore
    private var lastSave: Task<Void, Never>?

    init(cache: CacheStore) {
        self.cache = cache
    }

    func enqueue(_ snapshot: Snapshot) {
        let previous = lastSave
        let cache = self.cache
        lastSave = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            try? cache.store(snapshot)
        }
    }

    func finish() async {
        if let lastSave { await lastSave.value }
    }
}

private struct InteractiveSession: Sendable {
    let client: GitHubClient
    let cache: CacheStore

    func run() async throws -> InteractiveOutcome {
        let session = try TerminalSession()
        var renderer = InlineRenderer()
        var state = AppState(cached: cache.load())
        let saver = SnapshotSaver(cache: cache)
        let (events, continuation) = AsyncStream.makeStream(of: InteractiveEvent.self)
        let keyTask = Task {
            while !Task.isCancelled {
                do {
                    continuation.yield(.key(try await session.readKey()))
                } catch is CancellationError {
                    break
                } catch TerminalSessionError.interrupted {
                    continuation.yield(.key(.interrupted))
                    break
                } catch {
                    continuation.yield(.terminate)
                    break
                }
            }
            continuation.finish()
        }
        let clockTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !Task.isCancelled { continuation.yield(.tick) }
            }
        }
        var tasks: [Task<Void, Never>] = []

        session.write(renderer.start())
        session.write(renderer.render(ViewRenderer.frame(state: &state, terminal: session.size())))
        startFetch(state: &state, tasks: &tasks, continuation: continuation)

        var outcome = InteractiveOutcome.cancel
        eventLoop: for await event in events {
            switch await handle(
                event: event,
                state: &state,
                tasks: &tasks,
                continuation: continuation,
                saver: saver
            ) {
            case .redraw:
                session.write(renderer.render(ViewRenderer.frame(state: &state, terminal: session.size())))
            case let .finish(value):
                outcome = value
                break eventLoop
            case .ignore:
                continue
            }
        }

        continuation.finish()
        keyTask.cancel()
        clockTask.cancel()
        tasks.forEach { $0.cancel() }
        await keyTask.value
        for task in tasks { await task.value }
        session.write(renderer.finish())
        session.restore()
        await saver.finish()
        return outcome
    }

    private enum EventResult: Sendable {
        case redraw
        case ignore
        case finish(InteractiveOutcome)
    }

    private func handle(
        event: InteractiveEvent,
        state: inout AppState,
        tasks: inout [Task<Void, Never>],
        continuation: AsyncStream<InteractiveEvent>.Continuation,
        saver: SnapshotSaver
    ) async -> EventResult {
        switch event {
        case let .key(key):
            return handleKey(key, state: &state, tasks: &tasks, continuation: continuation)
        case let .list(generation, kind, prs):
            return await applyList(generation: generation, kind: kind, prs: prs, state: &state, saver: saver)
        case let .checks(generation, kind, checks):
            return await applyChecks(generation: generation, kind: kind, checks: checks, state: &state, saver: saver)
        case let .listError(generation, kind, message):
            return applyError(generation: generation, kind: kind, message: message, state: &state)
        case let .checksError(generation, kind, message):
            return applyError(generation: generation, kind: kind, message: message, state: &state)
        case let .external(result):
            switch result {
            case let .success(message): state.notify(.success(message))
            case let .failure(message): state.notify(.failure(message))
            }
            return .redraw
        case .terminate:
            return .finish(.cancel)
        case .tick:
            return .redraw
        }
    }

    private func applyList(
        generation: UInt64,
        kind: ListKind,
        prs: [PullRequest],
        state: inout AppState,
        saver: SnapshotSaver
    ) async -> EventResult {
        guard state.accepts(generation: generation) else { return .ignore }
        state.setList(kind, prs)
        await saver.enqueue(state.snapshot)
        return .redraw
    }

    private func applyChecks(
        generation: UInt64,
        kind: ListKind,
        checks: [PRKey: Checks],
        state: inout AppState,
        saver: SnapshotSaver
    ) async -> EventResult {
        guard state.accepts(generation: generation) else { return .ignore }
        state.setChecks(kind, checks)
        await saver.enqueue(state.snapshot)
        return .redraw
    }

    private func applyError(
        generation: UInt64,
        kind: ListKind,
        message: String,
        state: inout AppState
    ) -> EventResult {
        guard state.accepts(generation: generation) else { return .ignore }
        state.setError(kind, message)
        return .redraw
    }

    private func handleKey(
        _ key: TerminalKey,
        state: inout AppState,
        tasks: inout [Task<Void, Never>],
        continuation: AsyncStream<InteractiveEvent>.Continuation
    ) -> EventResult {
        state.clearNotice()
        switch action(for: key, state: &state, tasks: &tasks, continuation: continuation) {
        case .continue:
            return .redraw
        case .refresh:
            guard !state.isFetching else { return .redraw }
            startFetch(state: &state, tasks: &tasks, continuation: continuation)
            return .redraw
        case let .openAndExit(url):
            return .finish(.open(url))
        case .cancel:
            return .finish(.cancel)
        }
    }

    private func startFetch(
        state: inout AppState,
        tasks: inout [Task<Void, Never>],
        continuation: AsyncStream<InteractiveEvent>.Continuation
    ) {
        let generation = state.startFetch(steps: ListKind.all.count * 2)
        for kind in ListKind.all {
            let listClient = client
            tasks.append(Task {
                do {
                    continuation.yield(.list(generation, kind, try await listClient.fetchList(kind)))
                } catch is CancellationError {
                } catch {
                    continuation.yield(.listError(generation, kind, String(describing: error)))
                }
            })
            let checksClient = client
            tasks.append(Task {
                do {
                    continuation.yield(.checks(generation, kind, try await checksClient.fetchChecks(kind)))
                } catch is CancellationError {
                } catch {
                    continuation.yield(.checksError(generation, kind, String(describing: error)))
                }
            })
        }
    }

    private enum Action: Sendable {
        case `continue`
        case refresh
        case openAndExit(String)
        case cancel
    }

    private func action(
        for key: TerminalKey,
        state: inout AppState,
        tasks: inout [Task<Void, Never>],
        continuation: AsyncStream<InteractiveEvent>.Continuation
    ) -> Action {
        if let result = closeHelp(for: key, state: &state) { return result }
        if key == .function(1) || (key == .character("?") && state.query.isEmpty) {
            state.setHelp(true)
            return .continue
        }
        if let result = finishAction(for: key, state: state) { return result }
        if let result = externalAction(
            for: key,
            state: &state,
            tasks: &tasks,
            continuation: continuation
        ) { return result }
        applyMovement(for: key, state: &state)
        applyEditing(for: key, state: &state)
        return .continue
    }

    private func closeHelp(for key: TerminalKey, state: inout AppState) -> Action? {
        guard state.help else { return nil }
        state.setHelp(false)
        switch key {
        case .escape, .enter, .function(1): return .continue
        case .character("?") where state.query.isEmpty: return .continue
        default: return nil
        }
    }

    private func finishAction(for key: TerminalKey, state: AppState) -> Action? {
        switch key {
        case .escape, .control("c"), .control("q"), .interrupted: return .cancel
        case .enter: return state.selected.map { .openAndExit($0.url) } ?? .continue
        default: return nil
        }
    }

    private func externalAction(
        for key: TerminalKey,
        state: inout AppState,
        tasks: inout [Task<Void, Never>],
        continuation: AsyncStream<InteractiveEvent>.Continuation
    ) -> Action? {
        switch key {
        case .control("r"):
            return .refresh
        case .character("O"):
            guard let url = state.selected?.url else { return .continue }
            tasks.append(Task {
                do {
                    try await Browser.open(url: url)
                    guard !Task.isCancelled else { return }
                    continuation.yield(.external(.success("opened \(url)")))
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.external(.failure(String(describing: error))))
                    }
                }
            })
            return .continue
        case .character("Y"):
            guard let url = state.selected?.url else { return .continue }
            tasks.append(Task {
                do {
                    try await Clipboard.copy(url)
                    guard !Task.isCancelled else { return }
                    continuation.yield(.external(.success("copied \(url)")))
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.external(.failure(String(describing: error))))
                    }
                }
            })
            return .continue
        case .character("N"):
            guard let selected = state.selected else { return .continue }
            let number = String(selected.number)
            tasks.append(Task {
                do {
                    try await Clipboard.copy(number)
                    guard !Task.isCancelled else { return }
                    continuation.yield(.external(.success("copied #\(number)")))
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.external(.failure(String(describing: error))))
                    }
                }
            })
            return .continue
        default:
            return nil
        }
    }

    private func applyMovement(for key: TerminalKey, state: inout AppState) {
        switch key {
        case .tab, .right: state.nextTab()
        case .backTab, .left: state.previousTab()
        case .down, .control("n"), .control("j"): state.moveCursor(by: 1)
        case .up, .control("p"), .control("k"): state.moveCursor(by: -1)
        case .pageDown: state.moveCursor(by: 10)
        case .pageUp: state.moveCursor(by: -10)
        default: break
        }
    }

    private func applyEditing(for key: TerminalKey, state: inout AppState) {
        switch key {
        case .backspace, .control("h"): state.popCharacter()
        case .control("w"): state.popWord()
        case .control("u"): state.clearQuery()
        case .control("f"): state.nextScope()
        case .control("t"): state.nextMode()
        case let .character(character): state.push(character)
        default: break
        }
    }
}

private enum Browser {
    static func open(url: String) async throws {
        let result = try await Subprocess.run(executable: "gh", arguments: ["pr", "view", url, "--web"])
        guard result.succeeded else {
            let detail = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrowserError.failed(url: url, detail: detail.isEmpty ? "gh exited with status \(result.status)" : detail)
        }
    }

    private enum BrowserError: Error, CustomStringConvertible, Sendable {
        case failed(url: String, detail: String)
        var description: String {
            switch self { case let .failed(url, detail): "could not open \(url): \(detail)" }
        }
    }
}

private enum Clipboard {
    static func copy(_ text: String) async throws {
        let candidates: [(String, [String])] = {
            #if os(macOS)
            [("pbcopy", [])]
            #else
            [
                ("wl-copy", []),
                ("xclip", ["-selection", "clipboard"]),
                ("xsel", ["--clipboard", "--input"]),
            ]
            #endif
        }()
        for (program, arguments) in candidates {
            do {
                let result = try await Subprocess.run(executable: program, arguments: arguments, stdin: Data(text.utf8))
                if result.succeeded { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw ClipboardError.unavailable
    }

    private enum ClipboardError: Error, CustomStringConvertible, Sendable {
        case unavailable
        var description: String { "no clipboard command found" }
    }
}
