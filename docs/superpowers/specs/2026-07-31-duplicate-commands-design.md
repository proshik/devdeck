# Design: Duplicate Commands, Daemons and Chains

> Date: 2026-07-31. Status: designed, ready to implement.
> Touches the sidebar (`DevDeck/MainWindow/MainWindowView.swift`) and the store
> (`DevDeck/Store/CommandStore.swift`).

## Problem

Building a second command that differs from an existing one by a flag or a directory means
retyping all of it. `Command` carries fourteen fields — name, command line, working directory,
five toggles, a port, an env dictionary and a list of apps to quit. A `port-forward` daemon for a
second cluster, or a `claude` command bound to another project, is the same record with one field
changed, and today the only way to get one is to fill the whole editor again by hand.

There is no way to copy an existing entry. The sidebar has no context menu at all: the only
per-item action anywhere is Delete, and it lives in the editor toolbar.

## Decisions

| Question | Decision |
|---|---|
| Where the action lives | Context menu on the sidebar row, in the main window |
| What the menu contains | A single item, "Duplicate". Delete stays in the editor toolbar |
| What can be duplicated | Commands, daemons and chains — every section of the sidebar |
| How a chain is copied | Shallow: new `id`, same `commandIDs`. Member commands are not multiplied |
| Name of the copy | `<name> (copy)`, then `(copy 2)`, `(copy 3)` on collision |
| Where the copy lands | Immediately after the original |
| Selection after the action | Moves to the copy, which opens its editor — same as `addCommand()` |
| Which fields are copied | All of them except `id` and `name`, verbatim |

## Components

### `DuplicateNaming` — new, `DevDeck/Store/DuplicateNaming.swift`

One pure static function, no dependencies:

```swift
static func nextName(base: String, marker: String,
                     knownMarkers: [String], existing: Set<String>) -> String
```

It does not import `L10n` — the word "copy" arrives as a parameter. That keeps the unit test free
of the app's global language state and lets one test cover both locales.

**Base extraction.** `base` is passed in raw — the original's name, unmodified — and the function
strips a trailing copy marker from it itself. Duplicating a copy therefore yields `X (copy 2)`
rather than `X (copy) (copy)`. The pattern is `\s\((copy|копия)( \d+)?\)$`, assembled from
`knownMarkers`.

**Candidate search.** First `"<base> (<marker>)"`, then `"<base> (<marker> 2)"`, `3`, and so on;
the first one absent from `existing` wins. A gap in the numbering is filled rather than skipped —
the search returns the lowest free candidate, not the highest used plus one.

**Both markers are always recognized**, whatever the current language. Names live in `config.json`
and outlive a language switch; matching only the active marker would make the deduplication miss
copies made in the other language and produce a duplicate name.

**An empty name** yields `"(copy)"` — no leading space. Commands with a blank name render as
`(untitled)` in the sidebar and are legal in the config.

### `CommandStore` — two methods

Next to the existing `upsert` / `delete` mutations:

```swift
@discardableResult func duplicate(commandID: UUID) -> UUID?
@discardableResult func duplicate(chainID: UUID) -> UUID?
```

Each finds the original by id, builds the copy with a fresh `UUID` and a name from
`DuplicateNaming`, inserts it at `originalIndex + 1`, and persists through the existing private
`persist(_:)`. The new id is returned so the view can move the selection onto it.

The existing `upsert(_:)` cannot be reused: it appends to the end of the array and has no notion of
position.

`existing` is the set of all command names for a command, and of all chain names for a chain.
Names are cosmetic — `id` is the key — so uniqueness is only about keeping the sidebar readable.

### `MainWindowView` — the context menu

`.contextMenu` on the rows of all three sections, one item each. The handler calls the store and
assigns the returned id to `appModel.selection`.

Commands and daemons share `sidebarRow(_:icon:)`, so the command menu is written once. The chain
rows are built inline in the `Section(L10n.chains)` block.

### `L10n` — three entries

| Entry | English | Russian |
|---|---|---|
| `duplicate` | Duplicate | Дублировать |
| `copyMarker` | copy | копия |

Plus `copyMarkers: [String]` — a non-localized constant holding both markers (`["copy", "копия"]`),
used for recognition rather than display.

## What the copy carries

Every field except `id` and `name` is copied verbatim. `Command` and `Chain` are value types whose
stored properties are all values, so Swift's assignment already deep-copies `env` and `appsToQuit`.

`isDaemon` is copied, which is what keeps the copy in the same sidebar section as the original.

`port` is copied too. A duplicated port-forward daemon therefore claims the same local port as its
original until the user edits it. This is deliberate: the port is the field most likely to be
edited right after duplicating, so carrying it over shows what needs changing, and the
occupied-port check is informational — it reports state, it does not block a run.

Runtime state is not inherited, and no code is needed for that: `ProcessManager` keys its state and
its ring buffer by command `id`, and the copy has a new one. The copy starts `idle` with an empty
log.

Duplication reads the **saved** command. An unsaved draft in an open editor does not participate —
what gets copied is what the sidebar shows.

## Insertion and ordering

The copy is inserted at the original's index in `config.commands` plus one. The sidebar sections
are filters over that single array (`filter { !$0.isDaemon }` and `filter(\.isDaemon)`), and the
copy preserves `isDaemon`, so being adjacent in the backing array makes it adjacent in the rendered
section as well.

Chains are inserted the same way into `config.chains`, which the sidebar renders unfiltered.

Existing `moveCommands` / `moveChains` reordering is unaffected: it operates on whatever order the
array happens to hold.

## Failure modes

The one real failure is the original disappearing between the menu opening and the click — an
external edit to `config.json` picked up by the FileWatcher. Both methods return `nil` and change
nothing.

A write failure needs no new handling: `persist(_:)` already routes it into `store.error`, which
the UI shows as a banner.

## Testing

`DuplicateNamingTests` — new. Base extraction from a plain name and from a name that already ends
in a marker; the first copy; a collision resolving to `2`; a gap in the numbering being filled;
an empty base; recognition of a marker written in the other language.

`CommandStoreDuplicateTests` — new, following `CommandStoreMutationTests` for the temp-file store
setup. The copy gets a fresh `id`; it sits directly after the original; every other field matches;
a duplicated daemon keeps `isDaemon` and stays in the daemon section; a duplicated chain keeps its
`commandIDs`; duplicating an unknown id is a no-op returning `nil`; the copy survives a
save/`reload()` round-trip.

## Files

| File | Change |
|---|---|
| `DevDeck/Store/DuplicateNaming.swift` | new — pure naming helper |
| `DevDeck/Store/CommandStore.swift` | two `duplicate` methods |
| `DevDeck/MainWindow/MainWindowView.swift` | `.contextMenu` on the three row kinds |
| `DevDeck/Localization/L10n.swift` | `duplicate`, `copyMarker`, `copyMarkers` |
| `DevDeckTests/DuplicateNamingTests.swift` | new |
| `DevDeckTests/CommandStoreDuplicateTests.swift` | new |

Both targets are `PBXFileSystemSynchronizedRootGroup`, so the new files need no `project.pbxproj`
edit.

## Out of scope

- Duplicate from the menu bar popover. The popover is the control deck; editing lives in the main
  window.
- Delete or Rename in the context menu. Delete keeps its editor-toolbar home; renaming is what the
  editor that opens on the copy is already for.
- A keyboard shortcut for duplicating.
- Deep chain copy — duplicating a chain's member commands along with it.
