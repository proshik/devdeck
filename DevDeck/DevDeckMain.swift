import Foundation

/// Process entry. `DevDeck automation …` is a command-line client of the running app and must
/// not become a second app instance, so it is dispatched before `NSApplication` exists; anything
/// else starts the menu bar app as before.
@main
enum DevDeckMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == AutomationCLI.verb {
            exit(AutomationCLI.main(Array(arguments.dropFirst(2))))
        }
        DevDeckApp.main()
    }
}
