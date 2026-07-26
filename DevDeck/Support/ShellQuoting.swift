import Foundation

/// Wrap a value as one single-quoted shell word.
///
/// Single quotes suppress every expansion zsh performs, so the only character needing attention is
/// the quote itself: close, emit an escaped quote, reopen. The result is safe to concatenate into a
/// command line handed to `zsh -lc`.
///
/// One implementation on purpose. This app builds shell strings in five places — the zsh runner's
/// `cd`/`export` prefix, the sudo runner's, the chain script, the terminal wrapper and the proxy
/// listener — and a quoting rule that exists in five copies is a rule that will eventually differ in
/// one of them. That is not hypothetical here: the proxy listener used to interpolate a password
/// into `'auto://user:pass@:port'` with no quoting at all, so a password containing `'` closed the
/// literal and the rest of it ran as commands.
///
/// It does not make arbitrary data safe to *use* as a command — only safe to carry as a single
/// argument. A value that must not be a command at all belongs in a file, not on a command line.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
