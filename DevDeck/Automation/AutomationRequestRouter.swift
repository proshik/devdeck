import Foundation

/// The app side of `DevDeck automation …`: turns a request from the socket into an
/// `AutomationService` call and the result into the streams and exit code the client prints.
/// Every check is the service's — the same ones the Shortcuts actions get.
@MainActor
final class AutomationRequestRouter {
    private let service: AutomationService

    init(service: AutomationService) {
        self.service = service
    }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        guard request.version == AutomationRequest.currentVersion else {
            return Self.error(AutomationExitCode.communication, L10n.automationVersionMismatch(request.version))
        }
        do {
            if request.operation == .list { return list() }
            guard let kind = request.kind, let target = request.target,
                  !target.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Self.error(AutomationExitCode.usage, L10n.automationIncompleteRequest)
            }
            let id = try service.resolve(kind, target)
            let report = try await perform(request, kind: kind, id: id)
            let code = AutomationExitCode.code(for: report, operation: request.operation)
            return AutomationResponse(exitCode: code, stdout: report.text, stderr: "")
        } catch let refusal as AutomationRefusal {
            return Self.error(AutomationExitCode.refused, refusal.message)
        } catch {
            return Self.error(AutomationExitCode.communication, error.localizedDescription)
        }
    }

    private func perform(_ request: AutomationRequest, kind: AutomationReport.Kind, id: UUID) async throws -> AutomationReport {
        let timeout = AutomationLimits.timeout(seconds: request.timeoutSeconds)
        switch (request.operation, kind) {
        case (.run, .command): return try await service.runCommand(id, directory: request.directory, timeout: timeout)
        case (.run, .chain): return try await service.runChain(id, timeout: timeout)
        case (.stop, .command): return try await service.stopCommand(id)
        case (.stop, .chain): return try await service.stopChain(id)
        case (.status, .command): return try service.commandStatus(id)
        case (.status, .chain): return try service.chainStatus(id)
        case (.list, _): preconditionFailure("list is handled before resolving a target")
        }
    }

    private func list() -> AutomationResponse {
        do {
            let items = try service.listing()
            guard !items.isEmpty else {
                return AutomationResponse(exitCode: AutomationExitCode.success, stdout: "", stderr: L10n.automationListEmpty)
            }
            let lines = items.map { item in
                let name = item.name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                return "\(item.kind.rawValue)\t\(item.id.uuidString)\t\(name)"
            }
            return AutomationResponse(exitCode: AutomationExitCode.success, stdout: lines.joined(separator: "\n"), stderr: "")
        } catch let refusal as AutomationRefusal {
            return Self.error(AutomationExitCode.refused, refusal.message)
        } catch {
            return Self.error(AutomationExitCode.communication, error.localizedDescription)
        }
    }

    private static func error(_ code: Int32, _ message: String) -> AutomationResponse {
        AutomationResponse(exitCode: code, stdout: "", stderr: message)
    }
}
