import Foundation

/// Detects whether Touch ID for sudo is enabled: an uncommented
/// `auth … pam_tid.so` line in `/etc/pam.d/sudo_local` (Apple's standard mechanism,
/// survives macOS updates; enabled by copying sudo_local.template).
enum TouchIDSudo {
    static func isEnabled(sudoLocalPath: String = "/etc/pam.d/sudo_local") -> Bool {
        guard let content = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8) else { return false }
        return hasPamTid(content)
    }

    static func hasPamTid(_ content: String) -> Bool {
        content.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("auth") && trimmed.contains("pam_tid.so")
        }
    }
}
