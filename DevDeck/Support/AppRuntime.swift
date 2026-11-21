import Foundation

/// An explicit development launch gets its own files and preferences. Normal launches
/// keep the existing locations. Hosted unit tests never start the user's services.
enum AppRuntime {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Info.plist key with a development build's data directory. The acceptance build gets it at
    /// packaging time, so a launch without arguments — from Shortcuts, launchd or Finder — stays
    /// isolated too. Release builds have no such key and ignore it.
    static let developmentDirectoryInfoKey = "DevDeckDevDataDirectory"
    static let developmentDirectoryArgument = "--dev-data-directory"

    static let developmentDirectory: URL? = {
        #if DEBUG
        switch resolveDevelopmentDirectory(arguments: ProcessInfo.processInfo.arguments,
                                           info: Bundle.main.infoDictionary ?? [:],
                                           installed: installedSupportDirectory) {
        case .none: return nil
        case .directory(let url): return url
        case .invalid(let reason): preconditionFailure(reason)
        }
        #else
        return nil
        #endif
    }()

    enum DevelopmentDirectory: Equatable {
        case none
        case directory(URL)
        case invalid(String)
    }

    /// The argument wins over the Info.plist key; neither means a normal launch. Either way the
    /// path must be absolute and must not be the installed app's directory.
    static func resolveDevelopmentDirectory(arguments: [String], info: [String: Any], installed: URL) -> DevelopmentDirectory {
        let raw: String
        if let index = arguments.firstIndex(of: developmentDirectoryArgument) {
            guard arguments.indices.contains(index + 1) else {
                return .invalid("\(developmentDirectoryArgument) requires an absolute path")
            }
            raw = arguments[index + 1]
        } else if let value = info[developmentDirectoryInfoKey] as? String, !value.isEmpty {
            raw = value
        } else {
            return .none
        }
        guard raw.hasPrefix("/") else { return .invalid("\(developmentDirectoryArgument) requires an absolute path") }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        guard directory.resolvingSymlinksInPath().standardizedFileURL != installed.resolvingSymlinksInPath().standardizedFileURL else {
            return .invalid("Development launches require a separate directory")
        }
        return .directory(directory)
    }

    /// `~/Library/Application Support/DevDeck` — the installed app's data.
    static var installedSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDeck", isDirectory: true)
    }

    static var isIsolated: Bool { isTesting || developmentDirectory != nil }

    static var supportDirectory: URL {
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DevDeck-tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        if let directory = developmentDirectory { return directory }
        return installedSupportDirectory
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
