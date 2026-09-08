import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public protocol CommandExecuting: Sendable {
    func run(executable: String, arguments: [String], stdin: Data?) async throws -> CommandResult
}

public struct GitHubClient: Sendable {
    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = SubprocessExecutor()) {
        self.executor = executor
    }

    public func fetchList(_ kind: ListKind) async throws -> [PullRequest] {
        let response = try await execute(query: searchQuery(kind: kind, fields: Self.prFields))
        let data = try parseResponse(response.stdout, as: RawListData<RawPullRequest>.self)
        return data.search.nodes.compactMap { $0 }.map(PullRequest.init(raw:))
    }

    public func fetchChecks(_ kind: ListKind) async throws -> [PRKey: Checks] {
        let response = try await execute(query: searchQuery(kind: kind, fields: Self.checkFields))
        let data = try parseResponse(response.stdout, as: RawListData<RawCheckNode>.self)
        let entries: [(PRKey, Checks)] = data.search.nodes.compactMap { (node: RawCheckNode?) -> (PRKey, Checks)? in
            guard let node else { return nil }
            return (PRKey(repo: node.repository.nameWithOwner, number: node.number), node.checks)
        }
        return entries.reduce(into: [PRKey: Checks]()) { result, entry in
            result[entry.0] = entry.1
        }
    }

    public func fetchAll() async throws -> Snapshot {
        let parts = try await withThrowingTaskGroup(of: FetchPart.self) { group in
            for kind in ListKind.all {
                group.addTask { .list(kind, try await fetchList(kind)) }
                group.addTask { .checks(kind, try await fetchChecks(kind)) }
            }
            var lists: [ListKind: [PullRequest]] = [:]
            var checks: [ListKind: [PRKey: Checks]] = [:]
            while let part = try await group.next() {
                switch part {
                case let .list(kind, prs): lists[kind] = prs
                case let .checks(kind, result): checks[kind] = result
                }
            }
            var snapshot = Snapshot()
            for kind in ListKind.all {
                var prs = lists[kind] ?? []
                for index in prs.indices where checks[kind]?[prs[index].key] != nil {
                    prs[index].checks = checks[kind]![prs[index].key]!
                }
                snapshot[kind] = prs
            }
            return snapshot
        }
        return parts
    }

    private func execute(query: String) async throws -> CommandResult {
        let result = try await executor.run(
            executable: "gh",
            arguments: ["api", "graphql", "-f", "query=\(query)"],
            stdin: nil
        )
        if result.succeeded || responseHasData(result.stdout) { return result }
        let message = oneLine(String(decoding: result.stderr, as: UTF8.self))
        if !message.isEmpty { throw GitHubError.command(message) }
        throw GitHubError.exitStatus(result.status)
    }

    private static let pageSize = 100
    private static let prFields = "number title url isDraft baseRefName headRefName repository { nameWithOwner } author { login } reviewDecision"
    private static let checkFields = "number repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }"

    private func searchQuery(kind: ListKind, fields: String) -> String {
        "query { search(query: \"is:pr is:open archived:false sort:updated-desc \(kind.searchFilter)\", type: ISSUE, first: \(Self.pageSize)) { nodes { ... on PullRequest { \(fields) } } } }"
    }

    private func parseResponse<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let response = try JSONDecoder().decode(RawResponse<T>.self, from: data)
        if let value = response.data { return value }
        let messages = response.errors?.map(\.message).joined(separator: "; ")
        throw GitHubError.graphQL(messages ?? "GraphQL response has no data")
    }

    private func responseHasData(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["data"]
        else { return false }
        return !(value is NSNull)
    }

    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "gh: ", with: "", options: [.anchored]) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    private enum FetchPart: Sendable {
        case list(ListKind, [PullRequest])
        case checks(ListKind, [PRKey: Checks])
    }
}

public enum GitHubError: Error, Equatable, Sendable, CustomStringConvertible {
    case command(String)
    case exitStatus(Int32)
    case graphQL(String)
    case invalidResponse

    public var description: String {
        switch self {
        case let .command(message), let .graphQL(message): message
        case let .exitStatus(status): "gh exited with status \(status)"
        case .invalidResponse: "unexpected GraphQL response"
        }
    }
}

private struct RawResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [RawGraphQLError]?
}

private struct RawGraphQLError: Decodable {
    let message: String
}

private struct RawListData<T: Decodable>: Decodable {
    let search: RawSearch<T>
}

private struct RawSearch<T: Decodable>: Decodable {
    let nodes: [T?]
}

private struct RawPullRequest: Decodable {
    let number: UInt64
    let title: String
    let url: String
    let isDraft: Bool
    let baseRefName: String
    let headRefName: String
    let repository: RawRepository
    let author: RawAuthor?
    let reviewDecision: RawReviewDecision?
}

private struct RawCheckNode: Decodable {
    let number: UInt64
    let repository: RawRepository
    let commits: RawCommits

    var checks: Checks {
        switch commits.nodes.first?.commit.statusCheckRollup?.state {
        case .success: .success
        case .failure, .error: .failure
        case .pending, .expected: .pending
        case .none, .some(.other): .none
        }
    }
}

private struct RawRepository: Decodable { let nameWithOwner: String }
private struct RawAuthor: Decodable { let login: String }
private struct RawCommits: Decodable { let nodes: [RawCommitNode] }
private struct RawCommitNode: Decodable { let commit: RawCommit }
private struct RawCommit: Decodable { let statusCheckRollup: RawRollup? }
private struct RawRollup: Decodable { let state: RawRollupState }

private enum RawReviewDecision: String, Decodable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
    case other

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = RawReviewDecision(rawValue: value) ?? .other
    }
}

private enum RawRollupState: String, Decodable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
    case other

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = RawRollupState(rawValue: value) ?? .other
    }
}

private func reviewValue(_ decision: RawReviewDecision?) -> Review {
    switch decision {
    case .approved: .approved
    case .changesRequested: .changesRequested
    case .reviewRequired: .pending
    case .none, .other: .none
    }
}

private extension PullRequest {
    init(raw: RawPullRequest) {
        self.init(
            repo: raw.repository.nameWithOwner,
            number: raw.number,
            title: raw.title,
            url: raw.url,
            author: raw.author?.login ?? "",
            isDraft: raw.isDraft,
            baseRef: raw.baseRefName,
            headRef: raw.headRefName,
            checks: .none,
            review: reviewValue(raw.reviewDecision)
        )
    }
}

public struct SubprocessExecutor: CommandExecuting, Sendable {
    public init() {}

    public func run(executable: String, arguments: [String], stdin: Data?) async throws -> CommandResult {
        try await Subprocess.run(executable: executable, arguments: arguments, stdin: stdin)
    }
}
