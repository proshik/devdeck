import Foundation

/// Only implemented modules belong here. Registration also defines where a newly added
/// module goes when loading a layout made by an older application version.
enum PanelModuleID: String, Codable, CaseIterable, Identifiable, Sendable {
    case commands, daemons, chains, portForwards, proxy, agentTabs
    case mac, containers, energy, brightness, awake
    case clipboard
    var id: String { rawValue }
    var defaultSection: PanelSection {
        switch self {
        case .commands, .daemons, .chains, .portForwards, .proxy, .agentTabs: .environment
        case .mac, .containers, .energy: .monitoring
        case .awake, .brightness: .displays
        case .clipboard: .clipboard
        }
    }
    var title: String {
        switch self {
        case .commands: L10n.commands
        case .daemons: L10n.daemons
        case .chains: L10n.chains
        case .portForwards: L10n.deckPorts
        case .proxy: L10n.proxy
        case .agentTabs: L10n.claudeTabsSection
        case .mac: L10n.deckThisMac
        case .containers: L10n.deckContainers
        case .energy: L10n.deckEnergy
        case .awake: L10n.awakeTitle
        case .brightness: L10n.brightnessTitle
        case .clipboard: L10n.clipboardHistory
        }
    }
    var symbol: String {
        switch self {
        case .commands: "terminal"
        case .daemons: "gearshape.2"
        case .chains: "link"
        case .portForwards: "arrow.left.arrow.right"
        case .proxy: "network"
        case .agentTabs: "macwindow"
        case .mac: "waveform.path.ecg"
        case .containers: "shippingbox"
        case .energy: "battery.100percent"
        case .awake: "cup.and.saucer"
        case .brightness: "sun.max"
        case .clipboard: "clipboard"
        }
    }
    var settingsSelection: MainSelection {
        switch self {
        case .commands, .daemons, .chains: .commands
        case .portForwards: .ports
        case .proxy: .proxy
        case .agentTabs: .claudeTabs
        case .mac: .monitoring
        case .containers: .containers
        case .energy: .energy
        case .brightness: .displays
        case .awake: .awake
        case .clipboard: .clipboard
        }
    }
    // No dependence on a collection flag or the presence of commands: an empty/disabled
    // function is still configurable. Hardware-specific measurements report their own state.
    var isAvailable: Bool { true }
}

struct PanelModulePlacement: Codable, Equatable, Identifiable {
    var id: String
    var isVisible = true
    init(id: String, isVisible: Bool = true) { self.id = id; self.isVisible = isVisible }
    enum CodingKeys: String, CodingKey { case id, isVisible }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
    }
}

struct PanelSectionLayout: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    var icon: String?
    var isVisible = true
    var modules: [PanelModulePlacement]
    var title: String { name ?? PanelSection(rawValue: id)?.title ?? L10n.panelNewTab }
    var symbol: String { icon ?? PanelSection(rawValue: id)?.symbol ?? "square.grid.2x2" }
    init(id: String, name: String? = nil, icon: String? = nil, isVisible: Bool = true, modules: [PanelModulePlacement] = []) {
        self.id = id; self.name = name; self.icon = icon; self.isVisible = isVisible; self.modules = modules
    }
    enum CodingKeys: String, CodingKey { case id, name, icon, isVisible, modules }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        modules = try c.decodeIfPresent([PanelModulePlacement].self, forKey: .modules) ?? []
    }
}

/// Layout is separate from Settings: moving/hiding a block never changes its function.
struct PanelConfiguration: Codable, Equatable {
    var sections: [PanelSectionLayout]
    // Explicit removals distinguish deliberate customization from older partial layouts.
    var removedModuleIDs: [String] = []
    var removedSectionIDs: [String] = []
    var rememberLastSection = true
    var initialSection = PanelSection.environment.rawValue
    var lastSection: String?
    var showMemoryInEnvironment = false

    static var standard: Self {
        Self(sections: PanelSection.allCases.map { section in
            PanelSectionLayout(id: section.rawValue, modules: PanelModuleID.allCases
                .filter { $0.defaultSection == section }.map { PanelModulePlacement(id: $0.rawValue) })
        })
    }

    init(sections: [PanelSectionLayout], rememberLastSection: Bool = true,
         initialSection: String = PanelSection.environment.rawValue, lastSection: String? = nil,
         showMemoryInEnvironment: Bool = false) {
        self.sections = sections; self.rememberLastSection = rememberLastSection
        self.initialSection = initialSection; self.lastSection = lastSection
        self.showMemoryInEnvironment = showMemoryInEnvironment
    }
    enum CodingKeys: String, CodingKey {
        case sections, removedModuleIDs, removedSectionIDs, rememberLastSection, initialSection, lastSection, showMemoryInEnvironment
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent([PanelSectionLayout].self, forKey: .sections) ?? Self.standard.sections
        removedModuleIDs = try c.decodeIfPresent([String].self, forKey: .removedModuleIDs) ?? []
        removedSectionIDs = try c.decodeIfPresent([String].self, forKey: .removedSectionIDs) ?? []
        rememberLastSection = try c.decodeIfPresent(Bool.self, forKey: .rememberLastSection) ?? true
        initialSection = try c.decodeIfPresent(String.self, forKey: .initialSection) ?? PanelSection.environment.rawValue
        lastSection = try c.decodeIfPresent(String.self, forKey: .lastSection)
        showMemoryInEnvironment = try c.decodeIfPresent(Bool.self, forKey: .showMemoryInEnvironment) ?? false
    }

    /// First occurrence wins globally. Ignore unknown IDs and append missing modules to their
    /// default section, except for explicitly removed tabs/modules. Never undo a removal.
    func normalized() -> Self {
        var result = self
        var seenSections: Set<String> = [], seenModules: Set<String> = []
        result.sections = sections.compactMap { section in
            guard PanelSection(rawValue: section.id) != nil, seenSections.insert(section.id).inserted else { return nil }
            var section = section
            section.name = section.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if section.name?.isEmpty == true { section.name = nil }
            section.icon = section.icon?.trimmingCharacters(in: .whitespacesAndNewlines)
            if section.icon?.isEmpty == true { section.icon = nil }
            section.modules = section.modules.filter {
                PanelModuleID(rawValue: $0.id)?.isAvailable == true && seenModules.insert($0.id).inserted
            }
            return section
        }
        result.removedModuleIDs = Array(Set(removedModuleIDs.filter {
            PanelModuleID(rawValue: $0) != nil && !seenModules.contains($0)
        })).sorted()
        result.removedSectionIDs = Array(Set(removedSectionIDs.filter { id in
            PanelSection.allCases.contains(where: { $0.rawValue == id }) && !seenSections.contains(id)
        })).sorted()
        for section in PanelSection.allCases where !seenSections.contains(section.rawValue)
            && !result.removedSectionIDs.contains(section.rawValue) {
            result.sections.append(PanelSectionLayout(id: section.rawValue))
        }
        for module in PanelModuleID.allCases where module.isAvailable && !seenModules.contains(module.rawValue)
            && !result.removedModuleIDs.contains(module.rawValue) {
            guard let index = result.sections.firstIndex(where: { $0.id == module.defaultSection.rawValue }) else { continue }
            result.sections[index].modules.append(PanelModulePlacement(id: module.rawValue))
        }
        if !result.sections.contains(where: { $0.id == result.initialSection }) {
            result.initialSection = result.sections.contains(where: { $0.id == PanelSection.environment.rawValue })
                ? PanelSection.environment.rawValue : result.sections.first?.id ?? PanelSection.environment.rawValue
        }
        if let last = result.lastSection, !result.sections.contains(where: { $0.id == last }) { result.lastSection = nil }
        return result
    }

    var visibleSections: [PanelSection] {
        visibleSectionLayouts.compactMap { PanelSection(rawValue: $0.id) }
    }
    var visibleSectionLayouts: [PanelSectionLayout] {
        sections.filter { section in
            section.isVisible && (section.modules.contains { $0.isVisible && PanelModuleID(rawValue: $0.id)?.isAvailable == true }
                || (section.id == PanelSection.environment.rawValue && showMemoryInEnvironment))
        }
    }
    var availableModules: [PanelModuleID] {
        let placed = Set(sections.flatMap(\.modules).map(\.id))
        return PanelModuleID.allCases.filter { $0.isAvailable && !placed.contains($0.rawValue) }
    }
    func visibleModules(in section: PanelSection) -> [PanelModuleID] {
        guard let layout = sections.first(where: { $0.id == section.rawValue }), layout.isVisible else { return [] }
        return layout.modules.filter(\.isVisible).compactMap { PanelModuleID(rawValue: $0.id) }.filter(\.isAvailable)
    }
    func isShown(_ module: PanelModuleID) -> Bool {
        sections.contains { $0.isVisible && $0.modules.contains { $0.id == module.rawValue && $0.isVisible } }
    }
    func resolvedSection(preferred: PanelSection?) -> PanelSection? {
        let visible = visibleSections
        return preferred.flatMap { visible.contains($0) ? $0 : nil } ?? visible.first
    }
    var openingSection: PanelSection? {
        resolvedSection(preferred: PanelSection(rawValue: (rememberLastSection ? lastSection : nil) ?? initialSection))
    }

    mutating func setModuleVisible(_ module: PanelModuleID, _ visible: Bool) {
        for s in sections.indices {
            if let m = sections[s].modules.firstIndex(where: { $0.id == module.rawValue }) {
                sections[s].modules[m].isVisible = visible
            }
        }
    }
    mutating func setSectionVisible(_ section: PanelSection, _ visible: Bool) {
        if let index = sections.firstIndex(where: { $0.id == section.rawValue }) { sections[index].isVisible = visible }
    }
    mutating func revealModule(_ module: PanelModuleID) {
        setModuleVisible(module, true)
        if let index = sections.firstIndex(where: { $0.modules.contains { $0.id == module.rawValue } }) {
            sections[index].isVisible = true
        }
    }
    mutating func moveModule(_ module: PanelModuleID, to section: PanelSection, before target: PanelModuleID? = nil) {
        guard target != module, let destination = sections.firstIndex(where: { $0.id == section.rawValue }) else { return }
        let placement: PanelModulePlacement
        if let source = sections.firstIndex(where: { $0.modules.contains { $0.id == module.rawValue } }),
           let index = sections[source].modules.firstIndex(where: { $0.id == module.rawValue }) {
            placement = sections[source].modules.remove(at: index)
        } else {
            placement = PanelModulePlacement(id: module.rawValue)
        }
        removedModuleIDs.removeAll { $0 == module.rawValue }
        let insertion = target.flatMap { id in sections[destination].modules.firstIndex { $0.id == id.rawValue } }
            ?? sections[destination].modules.count
        sections[destination].modules.insert(placement, at: insertion)
    }
    mutating func removeModule(_ module: PanelModuleID) {
        for index in sections.indices { sections[index].modules.removeAll { $0.id == module.rawValue } }
        if !removedModuleIDs.contains(module.rawValue) { removedModuleIDs.append(module.rawValue) }
    }
    @discardableResult mutating func addSection(name: String, icon: String = "square.grid.2x2") -> PanelSection {
        let section = PanelSection(rawValue: "custom-" + UUID().uuidString)!
        sections.append(PanelSectionLayout(id: section.rawValue, name: name, icon: icon))
        return section
    }
    mutating func renameSection(_ section: PanelSection, name: String, icon: String) {
        guard let index = sections.firstIndex(where: { $0.id == section.rawValue }) else { return }
        sections[index].name = name
        sections[index].icon = icon
    }
    mutating func removeSection(_ section: PanelSection) {
        guard let index = sections.firstIndex(where: { $0.id == section.rawValue }) else { return }
        let modules = sections[index].modules.compactMap { PanelModuleID(rawValue: $0.id) }
        for module in modules { removeModule(module) }
        sections.remove(at: index)
        if PanelSection.allCases.contains(section), !removedSectionIDs.contains(section.rawValue) {
            removedSectionIDs.append(section.rawValue)
        }
        if lastSection == section.rawValue { lastSection = nil }
        if initialSection == section.rawValue { initialSection = sections.first?.id ?? PanelSection.environment.rawValue }
    }
    mutating func restoreStandardLayout() {
        sections = Self.standard.sections
        removedModuleIDs = []
        removedSectionIDs = []
    }
    mutating func shiftModule(_ module: PanelModuleID, by offset: Int) {
        guard let s = sections.firstIndex(where: { $0.modules.contains { $0.id == module.rawValue } }),
              let m = sections[s].modules.firstIndex(where: { $0.id == module.rawValue }) else { return }
        let next = m + offset
        guard sections[s].modules.indices.contains(next) else { return }
        sections[s].modules.swapAt(m, next)
    }
    mutating func moveSection(_ section: PanelSection, before target: PanelSection) {
        guard section != target, let source = sections.firstIndex(where: { $0.id == section.rawValue }) else { return }
        let layout = sections.remove(at: source)
        guard let destination = sections.firstIndex(where: { $0.id == target.rawValue }) else {
            sections.insert(layout, at: source); return
        }
        sections.insert(layout, at: destination)
    }
    mutating func shiftSection(_ section: PanelSection, by offset: Int) {
        guard let index = sections.firstIndex(where: { $0.id == section.rawValue }), sections.indices.contains(index + offset) else { return }
        sections.swapAt(index, index + offset)
    }
    mutating func moveSection(_ section: PanelSection, after target: PanelSection) {
        guard section != target, let source = sections.firstIndex(where: { $0.id == section.rawValue }) else { return }
        let layout = sections.remove(at: source)
        guard let destination = sections.firstIndex(where: { $0.id == target.rawValue }) else {
            sections.insert(layout, at: source); return
        }
        sections.insert(layout, at: destination + 1)
    }
}
