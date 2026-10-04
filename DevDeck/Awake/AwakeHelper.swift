import Foundation

/// The privileged program is passed literally to osascript, never loaded from a user-writable
/// script. The only user-owned input is a lease's existence; root never executes or writes it.
/// A kernel file lock serializes DevDeck instances without relying on reusable PIDs. A root-owned
/// journal is retained until restoration succeeds, including across a forced helper kill/reboot.
enum AwakeHelper {
    static let marker = "devdeck:keep-awake"
    static let daemonID = UUID(uuidString: "0CAFE100-0000-4000-8000-000000000001")!
    static let readyURL = URL(fileURLWithPath: "/var/run/devdeck-awake.ready")
    static let journalURL = URL(fileURLWithPath: "/var/db/devdeck-awake.previous")

    static func script(lease: URL, owner: UUID, parentPID: Int32, seconds: Int,
                       recoveryOnly: Bool = false) -> String {
        // All interpolated data are either bounded integers or single-quoted shell words.
        """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        umask 077
        lock=/var/run/devdeck-awake.lock
        journal=/var/db/devdeck-awake.previous
        ready=/var/run/devdeck-awake.ready
        lease=\(shellQuote(lease.path))
        owner=\(shellQuote(owner.uuidString))
        parent=\(max(1, parentPID))
        duration=\(min(7200, max(1, seconds)))
        # Keep this inode: unlinking a flock file would let two owners lock different inodes.
        exec 9>"$lock" || exit 1
        /usr/bin/lockf -s -t 0 9 || { echo 'Another DevDeck keep-awake session is active.' >&2; exit 1; }
        restore() {
            if [ -f "$journal" ]; then
                previous=$(/bin/cat "$journal")
                case "$previous" in 0|1) ;; *) echo 'Invalid sleep recovery journal.' >&2; return 1 ;; esac
                /usr/bin/pmset -a disablesleep "$previous" || return 1
                /bin/rm -f "$journal" || return 1
            fi
            /bin/rm -f "$ready"
        }
        cleanup() {
            result=$?
            trap - EXIT HUP INT TERM PIPE
            if ! restore; then
                echo 'Sleep restoration failed. Use Restore sleep in DevDeck.' >&2
                result=1
            fi
            exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM PIPE
        # Recover a journal left by a killed helper before beginning another session.
        restore || exit 1
        \(recoveryOnly ? "exit 0" : "")
        [ -f "$lease" ] && kill -0 "$parent" 2>/dev/null || exit 0
        check_battery() {
            battery=$(/usr/bin/pmset -g batt) || exit 1
            case "$battery" in
                *"'Battery Power'"*)
                    charge=$(printf '%s\\n' "$battery" | /usr/bin/sed -n 's/.*[[:space:]]\\([0-9][0-9]*\\)%;.*/\\1/p')
                    case "$charge" in ''|*[!0-9]*) echo 'Cannot read battery charge; restoring sleep.'; exit 0 ;; esac
                    [ "$charge" -gt 20 ] || { echo 'Battery reached 20%; restoring sleep.'; exit 0; }
                    ;;
            esac
        }
        check_battery
        settings=$(/usr/bin/pmset -g) || exit 1
        previous=$(printf '%s\\n' "$settings" | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }')
        case "$previous" in '') previous=0 ;; 0|1) ;; *) exit 1 ;; esac
        printf '%s\\n' "$previous" > "$journal" || exit 1
        /usr/bin/pmset -a disablesleep 1 || exit 1
        settings=$(/usr/bin/pmset -g) || exit 1
        printf '%s\\n' "$settings" | /usr/bin/awk '$1 == "SleepDisabled" && $2 == 1 { found=1 } END { exit !found }' || exit 1
        printf '%s\\n' "$owner" > "$ready" || exit 1
        /bin/chmod 644 "$ready" || exit 1
        deadline=$(( $(/bin/date +%s) + duration ))
        while [ -f "$lease" ] && kill -0 "$parent" 2>/dev/null && [ "$(/bin/date +%s)" -lt "$deadline" ]; do
            check_battery
            /bin/sleep 2 9>&-
        done
        """
    }
}
