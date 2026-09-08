import Foundation

#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

public struct CacheStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileURL = fileURL ?? Self.defaultURL(environment: environment)
    }

    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    public func store(_ snapshot: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        try data.write(to: temporary, options: .atomic)
        let result = temporary.path.withCString { source in
            fileURL.path.withCString { destination in
                rename(source, destination)
            }
        }
        guard result == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        #if os(Linux)
        let base = environment["XDG_CACHE_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".cache", isDirectory: true)
        #else
        let base = environment["XDG_CACHE_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
        #endif
        return base.appendingPathComponent("gh-assigned/snapshot.json")
    }
}
