import Foundation

public enum ListKind: Int, CaseIterable, Codable, Sendable {
    case mine = 0
    case reviewRequested = 1
    case assigned = 2

    public static let all: [ListKind] = [.mine, .reviewRequested, .assigned]

    public var label: String {
        switch self {
        case .mine: "Mine"
        case .reviewRequested: "Review requested"
        case .assigned: "Assigned"
        }
    }

    public var searchFilter: String {
        switch self {
        case .mine: "author:@me"
        case .reviewRequested: "review-requested:@me"
        case .assigned: "assignee:@me"
        }
    }

    public var next: ListKind { Self.all[(rawValue + 1) % Self.all.count] }
    public var previous: ListKind { Self.all[(rawValue + Self.all.count - 1) % Self.all.count] }
}

public enum Checks: String, Codable, Sendable, CaseIterable {
    case success = "Success"
    case failure = "Failure"
    case pending = "Pending"
    case none = "None"
}

public enum Review: String, Codable, Sendable, CaseIterable {
    case approved = "Approved"
    case changesRequested = "ChangesRequested"
    case pending = "Pending"
    case none = "None"
}

public struct PullRequest: Codable, Equatable, Sendable {
    public var repo: String
    public var number: UInt64
    public var title: String
    public var url: String
    public var author: String
    public var isDraft: Bool
    public var baseRef: String
    public var headRef: String
    public var checks: Checks
    public var review: Review

    public init(
        repo: String,
        number: UInt64,
        title: String,
        url: String,
        author: String,
        isDraft: Bool,
        baseRef: String,
        headRef: String,
        checks: Checks = .none,
        review: Review = .none
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.isDraft = isDraft
        self.baseRef = baseRef
        self.headRef = headRef
        self.checks = checks
        self.review = review
    }

    public var key: PRKey { PRKey(repo: repo, number: number) }

    public var shortRepo: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    private enum CodingKeys: String, CodingKey {
        case repo, number, title, url, author
        case isDraft = "is_draft"
        case baseRef = "base_ref"
        case headRef = "head_ref"
        case checks, review
    }
}

public struct PRKey: Hashable, Sendable {
    public let repo: String
    public let number: UInt64

    public init(repo: String, number: UInt64) {
        self.repo = repo
        self.number = number
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var lists: [[PullRequest]]

    public init(lists: [[PullRequest]] = [[], [], []]) {
        self.lists = lists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([[PullRequest]].self, forKey: .lists)
        guard decoded.count == ListKind.all.count else {
            throw SnapshotError.invalidListCount(decoded.count)
        }
        lists = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lists, forKey: .lists)
    }

    private enum CodingKeys: String, CodingKey { case lists }

    public subscript(kind: ListKind) -> [PullRequest] {
        get { lists[kind.rawValue] }
        set { lists[kind.rawValue] = newValue }
    }

    public static let empty = Snapshot()
}

public enum SnapshotError: Error, Equatable, Sendable {
    case invalidListCount(Int)
}
