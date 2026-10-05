# Closed-lid keep-awake

The popover offers **Work with lid closed** for 30 minutes, one hour, two hours
(default), or **Indefinitely**. The indefinite option has no helper deadline; manual
stop, app exit, battery and thermal cutoffs still restore sleep. It keeps all local
processes running, including coding harnesses launched outside DevDeck. The display may turn off. This is a manual lease;
it does not infer whether an agent is actively working.

## Accepted scenarios

- Enabling uses the same administrator authorization as ordinary sudo commands:
  Touch ID when enabled for sudo, otherwise the native password dialog. Failed
  Touch ID authorization falls back to that dialog. Waiting for authorization is
  not reported as an active session. Cancelling leaves no active lease.
- A synthetic daemon runs through `ProcessManager`; no new supervision engine or
  persisted user command is introduced. Normal sudo daemon restrictions remain.
- The privileged helper journals the previous global `SleepDisabled` value before
  changing it. A receipt is published only after `pmset` confirms the new value.
- Disabling, timeout, application death and quitting revoke the lease. The helper
  restores the original value before completing. It is never offered as a daemon
  to leave in the background at quit.
- Battery operation is allowed above 20%. The helper checks charge before enabling
  and every two seconds afterwards, independently of the optional battery UI.
- Serious/critical macOS thermal pressure refuses a new lease and revokes a live
  one. The app monitors this even with the popover closed. Sleep recovery
  remains available under thermal pressure and cannot be cancelled by lease controls;
  restoration failures stay visible and can be retried.
- A kernel file lock permits one helper at a time across app instances. Its inode
  is kept, so acquiring the lock cannot race an unlink or reuse of a process ID.
- If the helper itself is forcibly killed or restoration fails, its root-owned
  journal remains. **Restore sleep** requests authorization and retries restoration;
  beginning another lease also recovers that journal first.

## Boundaries

`caffeinate` alone does not implement the closed-lid requirement. This feature uses
`/usr/bin/pmset -a disablesleep`, which changes a system-wide setting and also blocks
other requests for sleep during the lease. Existing third-party ownership is respected:
if sleep was already disabled, ending the lease restores that disabled value.

The privileged program is embedded in Swift and passed literally to sudo or
AppleScript, with an AppleScript timeout longer than the maximum lease. It never
executes a writable helper file and never writes to a user-controlled path as root.
Its root-owned paths are
`/var/db/devdeck-awake.previous` and `/var/run/devdeck-awake.{lock,ready}`. The user-owned
0600 lease under DevDeck Application Support is only checked for existence.

The app's force quit is handled by the surviving helper. Force-killing the helper
itself cannot run cleanup; use recovery on the next launch. Thermal cutoff requires
a responsive app; the battery cutoff and timed-session deadline live in the helper.
For indefinite sessions the AppleScript fallback uses its maximum transport timeout
(about 68 years), so it does not impose the timed sessions’ two-hour limit.

## Validation

`AwakeTests` exercise routing, authorization readiness, cancellation, revocation,
thermal cutoff and recovery with fake runners/leases; no power settings are changed.
The full Xcode suite is the usual project check. A separate isolated shell exercise
runs the generated helper with a fake `pmset` and temporary lock/journal paths to
check timeout, charge limits, app death, competing helpers and crash recovery.
Physical closed-lid operation and the administrator dialog need a hardware check.
