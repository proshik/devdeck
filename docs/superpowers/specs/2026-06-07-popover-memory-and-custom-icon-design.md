# Memory Header in Popover + Custom Icon

Date: 2026-06-07. Status: approved, ready for implementation. Post-MVP.

## Context

MVP + logging are complete (78 tests). Two cosmetic/functional additions: (1) show system
memory in the tray control deck header with auto-update every second; (2) replace the default
SF Symbol in the menu bar with a custom "control deck/faders" glyph + a colour `.app` logo.

## Decisions (approved with the user)

- Memory: system "used / total GB · %", updated every second while the popover is open.
- "Used" = (active + wired + compressed) × pageSize (same as "Memory Used" in Activity Monitor),
  NOT "physical − free".
- Icon motif: control deck/faders. Menu bar glyph — monochrome, drawn in code. `.app` logo — colour,
  generated via banana-skill, placed in AppIcon.

## Components

### SystemMemory (`Diagnostics/SystemMemory.swift`)
```swift
struct SystemMemory: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    var fraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    static func current() -> SystemMemory   // host_statistics64(HOST_VM_INFO64) + physicalMemory
    static func format(usedBytes: UInt64, totalBytes: UInt64) -> String  // "18.2 / 32 GB · 57%"
}
```
- `current()`: `host_statistics64` → `vm_statistics64`; `used = (active_count + wire_count +
  compressor_page_count) × vm_page_size` (clamped ≤ total); `total = ProcessInfo.physicalMemory`.
- `format(...)`: pure function (decimal GB, used with 1 decimal place, total as integer, %). Unit-tested.

### Memory header (`MenuBar/PopoverView.swift`)
- At the top of the popover: `TimelineView(.periodic(from: .now, by: 1))` wraps the memory row —
  inside it, `SystemMemory.current()` is re-read on each tick (only ticks while the view is visible).
- Appearance: "Memory 18.2 / 32 GB · 57%" (monospaced digits) + a thin progress bar; bar colour
  by load: < 70% green, < 85% yellow, otherwise red. A thin separator below the header.

### Menu bar glyph (`MenuBar/TrayIcon.swift`)
- `TrayIcon.image() -> NSImage`: draws a "control deck" — a rounded rectangle border + 2–3
  horizontal faders (a track line + a rectangular knob at different positions), using
  `NSImage(size:flipped:) { … NSBezierPath … }`. `isTemplate = true` (adapts to the menu bar).
- `MenuBarController` uses `TrayIcon.image()` instead of `NSImage(systemSymbolName: "terminal")`.

### App logo (Assets)
- Use banana-skill to generate a colour macOS-style logo (rounded square, fader motif) at the
  required sizes; place in `DevDeck/Resources/Assets.xcassets/AppIcon.appiconset`
  (Contents.json already exists — populate with images). There is no Dock icon (LSUIElement), but
  the `.app` in Finder/Archive will have the logo.

## Testing

- `SystemMemory.format(...)` — pure unit test on known values (GB/%/rounding).
- `current()` (system call) and visual inspection of the glyph/logo — verified by eye (menu bar; `.app`).

## Implementation Order

1. `SystemMemory` + memory header (TDD on `format`) + `TimelineView`.
2. `TrayIcon` glyph (code) → wire into `MenuBarController`.
3. Logo (banana → PNG → AppIcon.appiconset).

## Risks / Notes

- `host_statistics64` is a system call; wrap it, show "—" on failure instead of crashing.
- `TimelineView(.periodic)` only ticks while the view is in the hierarchy (popover open) — no background timer.
- banana produces a raster; not suitable for the menu bar (needs monochrome template) — so the menu bar glyph is drawn in code.
- AppIcon without alpha and exact sizes will trigger a validator warning; generate a correct set.
