import Foundation

/// Docker Desktop is up when its app runs and the engine socket accepts a connection.
///
/// The socket stays up while Resource Saver has put the VM to sleep — that still counts as
/// running; waking the VM to find out more is exactly what must not happen. `com.docker.vmnetd`
/// and `com.docker.socket` are launchd daemons that outlive the app, so they are never a signal.
struct DockerDesktopEngine: ContainerEngine {
    static let bundleID = "com.docker.docker"

    let kind = ContainerEngineKind.dockerDesktop
    let displayName = "Docker Desktop"

    private let home: String
    private let apps: any AppPresenceProbing
    private let sockets: any UnixSocketProbing

    init(home: String = NSHomeDirectory(), apps: any AppPresenceProbing = LiveAppPresence(),
         sockets: any UnixSocketProbing = LiveUnixSocketProbe()) {
        self.home = home
        self.apps = apps
        self.sockets = sockets
    }

    func isInstalled() -> Bool { apps.isInstalled(bundleID: Self.bundleID) }

    func isRunning() -> Bool {
        apps.isRunning(bundleID: Self.bundleID) && sockets.canConnect(to: home + "/.docker/run/docker.sock")
    }
}