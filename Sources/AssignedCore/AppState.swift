import Foundation

public enum AppStatus: Equatable, Sendable {
    case fetching(showingCache: Bool)
    case fresh
    case error(String)
}

public enum Notice: Equatable, Sendable {
    case success(String)
    case failure(String)
}

public struct AppState: Sendable {
    public private(set) var snapshot: Snapshot
    public private(set) var rows: [StackRow] = []
    public private(set) var filtered: [Int] = []
    public private(set) var highlights: [SearchHighlight] = []
    public private(set) var tab: ListKind = .mine
    public private(set) var query = ""
    public private(set) var scope: SearchScope = .all
    public private(set) var mode: SearchMode = .fuzzy
    public private(set) var cursor = 0
    public private(set) var help = false
    public private(set) var notice: Notice?

    private var showingCache: Bool
    private var pendingSteps = 0
    private var generation: UInt64 = 0
    private var error: String?
    private var checks: [PRKey: Checks] = [:]
    private var scrollOffset = 0

    public init(cached: Snapshot? = nil) {
        snapshot = cached ?? .empty
        showingCache = cached != nil
        rebuildRows()
    }

    public var status: AppStatus {
        if pendingSteps > 0 { return .fetching(showingCache: showingCache) }
        if let error { return .error(error) }
        return .fresh
    }

    public var isFetching: Bool { pendingSteps > 0 }
    public var currentGeneration: UInt64 { generation }
    public var selected: PullRequest? {
        guard let rowIndex = filtered[safe: cursor] else { return nil }
        return rows[rowIndex].pr
    }

    public func count(_ kind: ListKind) -> Int { snapshot[kind].count }

    public func highlight(at position: Int) -> SearchHighlight {
        highlights[safe: position] ?? SearchHighlight()
    }

    public func visibleRows(maxRows: Int) -> ArraySlice<Int> {
        guard !filtered.isEmpty, maxRows > 0 else { return filtered[0..<0] }
        let start = min(scrollOffset, max(0, filtered.count - 1))
        let end = min(filtered.count, start + maxRows)
        return filtered[start..<end]
    }

    public mutating func ensureCursorVisible(maxRows: Int) {
        guard maxRows > 0 else { return }
        if cursor < scrollOffset { scrollOffset = cursor }
        if cursor >= scrollOffset + maxRows { scrollOffset = cursor - maxRows + 1 }
        let maxOffset = max(0, filtered.count - maxRows)
        scrollOffset = min(scrollOffset, maxOffset)
    }

    @discardableResult
    public mutating func startFetch(steps: Int) -> UInt64 {
        generation &+= 1
        pendingSteps = steps
        error = nil
        generation = max(generation, 1)
        return generation
    }

    public func accepts(generation: UInt64) -> Bool { generation == self.generation }

    public mutating func setList(_ kind: ListKind, _ prs: [PullRequest]) {
        var updated = prs
        let cachedChecks = Dictionary(uniqueKeysWithValues: snapshot[kind].map { ($0.key, $0.checks) })
        for index in updated.indices {
            if let check = checks[updated[index].key] ?? cachedChecks[updated[index].key] {
                updated[index].checks = check
            }
        }
        snapshot[kind] = updated
        showingCache = false
        finishStep(kind)
    }

    public mutating func setChecks(_ kind: ListKind, _ newChecks: [PRKey: Checks]) {
        checks.merge(newChecks) { _, newest in newest }
        var updated = snapshot[kind]
        for index in updated.indices where newChecks[updated[index].key] != nil {
            updated[index].checks = newChecks[updated[index].key]!
        }
        snapshot[kind] = updated
        finishStep(kind)
    }

    public mutating func setError(_ kind: ListKind, _ message: String) {
        error = "\(kind.label): \(message)"
        pendingSteps = max(0, pendingSteps - 1)
    }

    public mutating func nextTab() {
        tab = tab.next
        rebuildRows()
    }

    public mutating func previousTab() {
        tab = tab.previous
        rebuildRows()
    }

    public mutating func moveCursor(by delta: Int) {
        guard !filtered.isEmpty else {
            cursor = 0
            scrollOffset = 0
            return
        }
        cursor = min(max(0, cursor + delta), filtered.count - 1)
    }

    public mutating func push(_ character: Character) {
        query.append(character)
        refilterKeepingSelection()
    }

    public mutating func popCharacter() {
        guard !query.isEmpty else { return }
        query.removeLast()
        refilterKeepingSelection()
    }

    public mutating func popWord() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let boundary = trimmed.lastIndex(of: " ") {
            query = String(trimmed[...boundary])
        } else {
            query = ""
        }
        refilterKeepingSelection()
    }

    public mutating func clearQuery() {
        query = ""
        refilterKeepingSelection()
    }

    public mutating func nextScope() {
        scope = scope.next(showAuthor: tab != .mine)
        mode = mode.allowed(in: scope)
        refilterKeepingSelection()
    }

    public mutating func nextMode() {
        mode = mode.next(scope: scope)
        refilterKeepingSelection()
    }

    public mutating func setHelp(_ value: Bool) { help = value }
    public mutating func clearNotice() { notice = nil }

    public mutating func notify(_ result: Notice) { notice = result }

    private mutating func finishStep(_ kind: ListKind) {
        pendingSteps = max(0, pendingSteps - 1)
        if kind == tab { rebuildRows() }
    }

    private mutating func rebuildRows() {
        let previous = selected?.key
        rows = Stack.arrange(snapshot[tab])
        if scope == .author, tab == .mine {
            scope = .all
            mode = mode.allowed(in: scope)
        }
        refilterKeepingSelection(previous: previous)
    }

    private mutating func refilterKeepingSelection() {
        refilterKeepingSelection(previous: selected?.key)
    }

    private mutating func refilterKeepingSelection(previous: PRKey? = nil) {
        let previousKey = previous
        let matches = SearchEngine.search(
            rows: rows,
            query: query,
            scope: scope,
            mode: mode,
            showAuthor: tab != .mine
        )
        filtered = matches.map(\.rowIndex)
        highlights = matches.map { match in
            SearchEngine.highlight(
                match: match,
                row: rows[match.rowIndex],
                scope: scope,
                showAuthor: tab != .mine
            )
        }
        if let previousKey,
           let position = filtered.firstIndex(where: { rows[$0].pr.key == previousKey }) {
            cursor = position
        } else {
            cursor = min(cursor, max(0, filtered.count - 1))
        }
        if filtered.isEmpty { cursor = 0 }
        ensureCursorVisible(maxRows: Int.max)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
