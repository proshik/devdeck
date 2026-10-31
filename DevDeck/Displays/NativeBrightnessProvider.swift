import AppKit
import IOKit
import Darwin

/// Optional private macOS interfaces are resolved at runtime; absent symbols mean unsupported.
/// All hardware I/O is serialized on this actor, away from the main thread.
actor NativeBrightnessProvider: DisplayBrightnessProvider {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private var routes: [String: Route] = [:]
    private enum Route { case apple, ddc(DDCBrightnessConnection) }

    private func readApple(_ id: UInt32) -> Double? {
        guard let symbol = displayServices.flatMap({ dlsym($0, "DisplayServicesGetBrightness") }) else { return nil }
        var value: Float = 0
        guard unsafeBitCast(symbol, to: Get.self)(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        let screens = await MainActor.run { NSScreen.screens.compactMap { screen -> BrightnessDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            return BrightnessDisplay(id: id, displayID: displayID, name: screen.localizedName,
                                     bounds: CGDisplayBounds(displayID), builtIn: CGDisplayIsBuiltin(displayID) != 0, value: nil)
        } }
        let connections = DDCBrightnessConnection.discover()
        // Refuse a transport if multiple active screens claim the same registry location.
        let candidates = screens.compactMap { screen -> (String, DDCBrightnessConnection)? in
            guard !screen.builtIn, let connection = DDCBrightnessConnection.match(displayID: screen.displayID, connections: connections) else { return nil }
            return (screen.id, connection)
        }
        let unique = Dictionary(grouping: candidates, by: { ObjectIdentifier($0.1) })
            .values.filter { $0.count == 1 }.compactMap(\.first)
        let ddc = Dictionary(uniqueKeysWithValues: unique)
        routes.removeAll()
        var result: [BrightnessDisplay] = []
        for var screen in screens {
            screen.method = methods[screen.id] ?? .hardware
            if screen.method == .software {
                screen.value = await SoftwareBrightness.shared.value(for: screen.id)
            } else if let value = readApple(screen.displayID) {
                screen.value = value; routes[screen.id] = .apple
            } else if !screen.builtIn, let connection = ddc[screen.id],
                      let reading = connection.read() {
                screen.value = Double(reading.current) / Double(reading.maximum)
                routes[screen.id] = .ddc(connection)
            }
            result.append(screen)
        }
        let softwareIDs = Set(result.filter { $0.method == .software }.map(\.id))
        await SoftwareBrightness.shared.retainOnly(softwareIDs)
        return result
    }

    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        try Task.checkCancellation()
        guard value.isFinite, CGDisplayIsOnline(display.displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue(),
              CFUUIDCreateString(nil, uuid) as String == display.id else { throw BrightnessFailure.unavailable }
        if display.method == .software {
            return try await SoftwareBrightness.shared.set(display, value: value)
        }
        switch routes[display.id] {
        case .apple:
            guard let symbol = displayServices.flatMap({ dlsym($0, "DisplayServicesSetBrightness") }) else { throw BrightnessFailure.write }
            try Task.checkCancellation()
            guard unsafeBitCast(symbol, to: SetBrightness.self)(display.displayID, Float(value)) == 0 else { throw BrightnessFailure.write }
            guard let actual = readApple(display.displayID) else { throw BrightnessFailure.readback }
            return actual
        case .ddc(let connection):
            guard let before = connection.read() else { throw BrightnessFailure.write }
            // A method/screen change can cancel this task during the blocking DDC read.
            try Task.checkCancellation()
            guard connection.write(UInt16((value * Double(before.maximum)).rounded())) else { throw BrightnessFailure.write }
            guard let after = connection.read() else { throw BrightnessFailure.readback }
            return Double(after.current) / Double(after.maximum)
        case nil: throw BrightnessFailure.unavailable
        }
    }
    func reset() async { routes.removeAll(); await SoftwareBrightness.shared.retainOnly([]) }
}

/// IOAV DDC on Apple Silicon. Only an exact, unique IODisplayLocation match is accepted.
/// Ambiguous/unsupported adapters stay unavailable rather than risking another monitor.
private final class DDCBrightnessConnection {
    typealias Create = @convention(c) (CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    static let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    let service: CFTypeRef
    let location: String
    let readFunction: Transfer
    let writeFunction: Transfer
    init(service: CFTypeRef, location: String, read: @escaping Transfer, write: @escaping Transfer) {
        self.service = service; self.location = location; readFunction = read; writeFunction = write
    }
    static func discover() -> [DDCBrightnessConnection] {
        #if arch(arm64)
        guard let createSymbol = io.flatMap({ dlsym($0, "IOAVServiceCreateWithService") }),
              let readSymbol = io.flatMap({ dlsym($0, "IOAVServiceReadI2C") }),
              let writeSymbol = io.flatMap({ dlsym($0, "IOAVServiceWriteI2C") }) else { return [] }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var location = ""
        var result: [DDCBrightnessConnection] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let type = String(cString: name)
            if type == "AppleCLCD2" || type == "IOMobileFramebufferShim" {
                var path = [CChar](repeating: 0, count: 512)
                location = IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS ? String(cString: path) : ""
            } else if type == "DCPAVServiceProxy", !location.isEmpty,
                      let external = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String,
                      external == "External", let service = create(nil, entry)?.takeRetainedValue() {
                result.append(.init(service: service, location: location,
                                    read: unsafeBitCast(readSymbol, to: Transfer.self), write: unsafeBitCast(writeSymbol, to: Transfer.self)))
            }
        }
        return result
        #else
        return []
        #endif
    }
    static func match(displayID: UInt32, connections: [DDCBrightnessConnection]) -> DDCBrightnessConnection? {
        guard let symbol = core.flatMap({ dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }),
              let info = unsafeBitCast(symbol, to: Info.self)(displayID)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String else { return nil }
        let matches = connections.filter { $0.location == location }
        return matches.count == 1 ? matches[0] : nil
    }
    func read() -> (current: UInt16, maximum: UInt16)? {
        for _ in 0..<2 {
            var request = BrightnessDDC.read
            let sent = request.withUnsafeMutableBytes { writeFunction(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            guard sent == 0 else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let received = reply.withUnsafeMutableBytes { readFunction(service, 0x37, 0, $0.baseAddress!, UInt32($0.count)) }
            if received == 0, let value = BrightnessDDC.decode(reply) { return value }
        }
        return nil
    }
    func write(_ value: UInt16) -> Bool {
        var packet = BrightnessDDC.write(value)
        let result = packet.withUnsafeMutableBytes { writeFunction(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        usleep(50_000)
        return result == 0
    }
}

/// Explicit software mode: click-through black overlays, without changing gamma/color profiles.
/// Overlay lifetime is the process lifetime; a crash cannot leave the display permanently dim.
@MainActor private final class SoftwareBrightness {
    static let shared = SoftwareBrightness()
    private var panels: [String: NSPanel] = [:]
    private var values: [String: Double] = [:]
    func value(for id: String) -> Double { values[id] ?? 1 }
    func set(_ display: BrightnessDisplay, value: Double) throws -> Double {
        try Task.checkCancellation()
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { throw BrightnessFailure.unavailable }
        let id = display.id
        let panel = panels[id] ?? NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: true)
        panel.backgroundColor = .black; panel.isOpaque = false; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        let safeValue = max(0.1, min(1, value))
        panel.alphaValue = 1 - safeValue
        panel.orderFrontRegardless()
        panels[id] = panel; values[id] = safeValue
        return safeValue
    }
    func retainOnly(_ ids: Set<String>) {
        for id in Array(panels.keys) {
            let screen = NSScreen.screens.first { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return false }
                return CFUUIDCreateString(nil, uuid) as String == id
            }
            if ids.contains(id), let screen { panels[id]?.setFrame(screen.frame, display: true) }
            else { panels.removeValue(forKey: id)?.orderOut(nil); values.removeValue(forKey: id) }
        }
    }
}
