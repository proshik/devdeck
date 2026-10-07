import Foundation

/// Read-only activity used by the summary when detailed service controls are hidden.
enum PanelActivity {
    static func activeModules(commands: [Command], states: [UUID: ProcessManager.RunState],
                              chains: [Chain], chainStates: [UUID: ProcessManager.ChainState],
                              proxyActive: Bool, agentCaptureEnabled: Bool, awakeActive: Bool) -> [PanelModuleID] {
        var active: Set<PanelModuleID> = []
        for command in commands where StatusIndicator.forCommand(states[command.id]).isStop {
            active.insert(command.port != nil ? .portForwards : command.isDaemon ? .daemons : .commands)
        }
        if chains.contains(where: { StatusIndicator.forChain(chainStates[$0.id]).isStop }) { active.insert(.chains) }
        if proxyActive { active.insert(.proxy) }
        if agentCaptureEnabled { active.insert(.agentTabs) }
        if awakeActive { active.insert(.awake) }
        return PanelModuleID.allCases.filter { active.contains($0) }
    }
}
