import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

struct AuthLogoutSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Remove the stored credentials; environment variables and models.json stay",
        usage: "pi auth logout <provider>"
    )

    @Argument(help: "Provider name") var provider: String?

    mutating func run() async throws {
        markCodingAgentEnvironment()
        let storage = AuthStorage.create(getAuthPath())
        let registry = ModelRegistry(storage, getAgentDir(), modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let result = await runAuthLogout(providerRef: provider, registry: registry, storage: storage,
                                         output: ProcessAuthOutput())
        if result != 0 { Darwin.exit(result) }
    }
}

@MainActor
protocol AuthOutput: AnyObject, Sendable {
    func write(_ line: String)
    func error(_ line: String)
}

@MainActor
final class ProcessAuthOutput: AuthOutput {
    func write(_ line: String) { fputs("\(line)\n", stdout) }
    func error(_ line: String) { fputs("\(line)\n", stderr) }
}

@MainActor
func runAuthLogout(
    providerRef: String?, registry: ModelRegistry, storage: AuthStorage, output: any AuthOutput,
    localRefresh: (@Sendable () async -> ModelsRefreshResult)? = nil
) async -> Int32 {
    guard let providerRef, !providerRef.isEmpty, !providerRef.hasPrefix("-") else {
        output.error("Usage: pi auth logout <provider>")
        return 1
    }
    let stored = storage.listCredentials()
    let provider = matchingLoginProvider(providerRef, in: registry.getLoginProviders().filter { $0.id != "radius" })
    let resolvedId = provider?.id ?? providerRef
    let credential = stored.first { $0.providerId == resolvedId && $0.providerId != "radius" }
    guard provider != nil || credential != nil else {
        output.error("Unknown provider \"\(authSafeText(providerRef))\".")
        let ids = stored.filter { $0.providerId != "radius" }.map(\.providerId).sorted()
        output.error("Stored credentials: \(ids.isEmpty ? "none" : ids.joined(separator: ", "))")
        return 1
    }
    let name = provider?.name ?? providerRef
    guard let credential else {
        output.write("No stored credentials for \(name). Environment variables and models.json config are unchanged.")
        return 0
    }
    await registry.logout(credential.providerId)
    if let failure = storage.drainErrors().first {
        output.error("Logout failed: \(failure)")
        return 1
    }
    if storage.has(credential.providerId) {
        output.error("Logout failed: credentials could not be removed")
        return 1
    }
    let result: ModelsRefreshResult
    if let localRefresh { result = await localRefresh() }
    else { result = await registry.refresh(ModelsRefreshOptions(allowNetwork: false)) }
    if let failure = result.errors[credential.providerId] {
        output.error("Credentials removed for \(name), but local model state could not be synchronized: \(failure.localizedDescription)")
        return 1
    }
    if credential.type == .oauth {
        output.write("Logged out of \(name).")
    } else {
        output.write("Removed stored API key for \(name). Environment variables and models.json config are unchanged.")
    }
    return 0
}
