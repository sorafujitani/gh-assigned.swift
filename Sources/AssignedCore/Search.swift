import Foundation

public enum SearchScope: String, CaseIterable, Sendable {
    case all
    case repo
    case title
    case author

    public var label: String { rawValue }

    public func next(showAuthor: Bool) -> SearchScope {
        switch self {
        case .all: .repo
        case .repo: .title
        case .title where showAuthor: .author
        case .title, .author: .all
        }
    }
}

public enum SearchMode: String, CaseIterable, Sendable {
    case fuzzy
    case substring
    case exact

    public var label: String { rawValue }

    public func next(scope: SearchScope) -> SearchMode {
        switch self {
        case .fuzzy: .substring
        case .substring where scope == .all: .fuzzy
        case .substring: .exact
        case .exact: .fuzzy
        }
    }

    public func allowed(in scope: SearchScope) -> SearchMode {
        self == .exact && scope == .all ? .substring : self
    }
}

public struct SearchHighlight: Equatable, Sendable {
    public var repo: [Int] = []
    public var title: [Int] = []
    public var author: [Int] = []

    public init(repo: [Int] = [], title: [Int] = [], author: [Int] = []) {
        self.repo = repo
        self.title = title
        self.author = author
    }
}

public struct SearchMatch: Equatable, Sendable {
    public let rowIndex: Int
    public let hits: [Int]
    public let score: Int

    public init(rowIndex: Int, hits: [Int], score: Int) {
        self.rowIndex = rowIndex
        self.hits = hits
        self.score = score
    }
}

public enum SearchEngine {
    public static func search(
        rows: [StackRow],
        query: String,
        scope: SearchScope,
        mode: SearchMode,
        showAuthor: Bool
    ) -> [SearchMatch] {
        guard !query.isEmpty else {
            return rows.indices.map { SearchMatch(rowIndex: $0, hits: [], score: 0) }
        }

        var matches: [SearchMatch] = []
        for (index, row) in rows.enumerated() {
            let haystack = Haystack(row: row, showAuthor: showAuthor)
            guard let field = haystack.field(scope),
                  let result = match(query: Array(query), in: field, mode: mode)
            else { continue }
            matches.append(SearchMatch(rowIndex: index, hits: result.hits, score: result.score))
        }
        return matches.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.rowIndex < rhs.rowIndex : lhs.score > rhs.score
        }
    }

    public static func highlight(
        match: SearchMatch,
        row: StackRow,
        scope: SearchScope,
        showAuthor: Bool
    ) -> SearchHighlight {
        switch scope {
        case .repo: return SearchHighlight(repo: match.hits)
        case .title: return SearchHighlight(title: match.hits)
        case .author: return SearchHighlight(author: match.hits)
        case .all: break
        }
        let haystack = Haystack(row: row, showAuthor: showAuthor)
        var highlight = SearchHighlight()
        for hit in match.hits {
            if hit < haystack.repo.count {
                highlight.repo.append(hit)
            } else if hit > haystack.repo.count && hit < haystack.titleStart {
                highlight.title.append(hit - haystack.titleStart)
            } else if hit >= haystack.titleStart && hit < haystack.authorStart {
                highlight.title.append(hit - haystack.titleStart)
            } else if showAuthor && hit >= haystack.authorStart {
                highlight.author.append(hit - haystack.authorStart)
            }
        }
        return highlight
    }

    private static func match(
        query: [Character],
        in haystack: [Character],
        mode: SearchMode
    ) -> (score: Int, hits: [Int])? {
        switch mode {
        case .exact:
            guard query.count == haystack.count,
                  zip(query, haystack).allSatisfy(equal)
            else { return nil }
            return (0, Array(haystack.indices))
        case .substring:
            guard query.count <= haystack.count else { return nil }
            for start in 0...(haystack.count - query.count) {
                let end = start + query.count
                if zip(query, haystack[start..<end]).allSatisfy(equal) {
                    return (100_000 - start, Array(start..<end))
                }
            }
            return nil
        case .fuzzy:
            var cursor = 0
            var hits: [Int] = []
            var contiguous = 0
            for needle in query {
                guard let found = haystack[cursor...].firstIndex(where: { equal(needle, $0) }) else {
                    return nil
                }
                if let previous = hits.last, found == previous + 1 { contiguous += 1 }
                hits.append(found)
                cursor = found + 1
            }
            let first = hits.first ?? 0
            return (50_000 + contiguous * 100 - first * 10 - (hits.last ?? first), hits)
        }
    }

    private static func equal(_ lhs: Character, _ rhs: Character) -> Bool {
        String(lhs).lowercased() == String(rhs).lowercased()
    }

    private struct Haystack {
        let all: [Character]
        let repo: [Character]
        let title: [Character]
        let author: [Character]?
        let titleStart: Int
        let authorStart: Int

        init(row: StackRow, showAuthor: Bool) {
            repo = Array(row.pr.shortRepo)
            title = Array(row.pr.title)
            author = showAuthor ? Array(row.pr.author) : nil
            titleStart = repo.count + 1
            authorStart = repo.count + 1 + title.count + 1
            var combined = repo + [" "] + title
            if let author {
                combined += [" "] + author
            }
            all = combined
        }

        func field(_ scope: SearchScope) -> [Character]? {
            switch scope {
            case .all: all
            case .repo: repo
            case .title: title
            case .author: author
            }
        }
    }
}
