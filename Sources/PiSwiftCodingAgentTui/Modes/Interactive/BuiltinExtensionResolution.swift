import PiSwiftCodingAgent

/// Resolve built-in flags with PiSwift. Package resources need no second resolution.
public func resolveBuiltinExtensionPaths(settingsManager: SettingsManager, names: [String], cwd: String, agentDir: String, projectTrusted: Bool = true) async throws -> ResolvedPaths {
    var global = Settings()
    global.extensions = settingsManager.getGlobalSettings().extensions
    let settings = SettingsManager.inMemory(global)
    if projectTrusted { settings.setProjectExtensionPaths(settingsManager.getProjectSettings().extensions ?? []) }
    return try await DefaultPackageManager(cwd: cwd, agentDir: agentDir, settingsManager: settings,
        projectTrusted: projectTrusted, offline: true, builtinExtensions: names).resolve()
}
