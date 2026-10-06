import Foundation

/// An explicit development launch gets its own files and preferences. Normal launches
/// keep the existing locations. Hosted unit tests never start the user's services.
enum AppRuntime {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let developmentDirectory: URL? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--dev-data-directory") else { return nil }
        precondition(args.indices.contains(index + 1) && args[index + 1].hasPrefix("/"),
                     "--dev-data-directory requires an absolute path")
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let installedDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDeck")
        precondition(directory.resolvingSymlinksInPath().standardizedFileURL != installedDirectory.resolvingSymlinksInPath().standardizedFileURL,
                     "Development launches require a separate directory")
        return directory
        #else
        return nil
        #endif
    }()

    static var isIsolated: Bool { isTesting || developmentDirectory != nil }

    static var supportDirectory: URL {
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DevDeck-tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        if let directory = developmentDirectory { return directory }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDeck")
    }

    static let preferences: UserDefaults = {
        if isTesting {
            return UserDefaults(suiteName: "DevDeck.tests.\(ProcessInfo.processInfo.processIdentifier)")!
        }
        if let directory = developmentDirectory {
            // Stable for relaunching the same isolated configuration; separate from the app domain.
            let encodedPath = Data(directory.path.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            return UserDefaults(suiteName: "DevDeck.development.\(encodedPath)")!
        }
        return .standard
    }()
}
