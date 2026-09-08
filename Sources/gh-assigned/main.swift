import ArgumentParser
import AssignedCLI

@main
struct GhAssignedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assigned",
        abstract: "Find pull requests that need your attention",
        discussion: AssignedCLI.helpDiscussion
    )

    @Flag(name: .customLong("json"), help: "Fetch all three lists and print JSON")
    var json = false

    mutating func run() async throws {
        try await AssignedCLI.run(json: json)
    }
}
