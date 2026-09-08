import Foundation

public struct StackRow: Equatable, Sendable {
    public let pr: PullRequest
    public let depth: Int

    public init(pr: PullRequest, depth: Int) {
        self.pr = pr
        self.depth = depth
    }
}

public enum Stack {
    /// Keeps input order while placing a PR immediately below the PR whose head
    /// branch is its base branch in the same repository.
    public static func arrange(_ prs: [PullRequest]) -> [StackRow] {
        var byHead: [BranchKey: Int] = [:]
        for (index, pr) in prs.enumerated() {
            byHead[BranchKey(repo: pr.repo, branch: pr.headRef)] = index
        }

        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (index, pr) in prs.enumerated() {
            if let parent = byHead[BranchKey(repo: pr.repo, branch: pr.baseRef)], parent != index {
                children[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }

        var rows: [StackRow] = []
        rows.reserveCapacity(prs.count)
        var seen = Set<Int>()
        for root in roots {
            append(root, depth: 0, prs: prs, children: children, seen: &seen, rows: &rows)
        }
        // A malformed cycle has no root. Keep every member visible and flat.
        for index in prs.indices where seen.insert(index).inserted {
            rows.append(StackRow(pr: prs[index], depth: 0))
        }
        return rows
    }

    private static func append(
        _ index: Int,
        depth: Int,
        prs: [PullRequest],
        children: [Int: [Int]],
        seen: inout Set<Int>,
        rows: inout [StackRow]
    ) {
        guard seen.insert(index).inserted else { return }
        rows.append(StackRow(pr: prs[index], depth: depth))
        for child in children[index, default: []] {
            append(child, depth: depth + 1, prs: prs, children: children, seen: &seen, rows: &rows)
        }
    }

    private struct BranchKey: Hashable {
        let repo: String
        let branch: String
    }
}
