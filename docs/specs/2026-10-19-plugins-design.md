# Plugins — Design

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-plugins.md

## Goal

Let people extend NoteIt with small JavaScript plugins that add commands to the command palette, transform
the text of a note, and show simple inspector panels next to the editor, without putting notes, the Mac or the app's
speed at risk. A plugin can do only what its manifest asks for and the user approved. It has no network and no
file access unless granted, runs in a separate sandboxed process, and is stopped if it hangs or uses too much
memory. Plugins can be installed from a file or from a community directory that is reviewed in the open
through pull requests on GitHub. There is still no NoteIt server and no account.

## What the user gets

### Running plugin commands

- Plugin commands appear in the command palette next to NoteIt's own, titled **<Plugin name>: <Command title>**,
  for example **Sort Lines: Sort A to Z**. They show the plugin's symbol, or `puzzlepiece.extension` when it
  has none. Typing the plugin name finds all of its commands.
- A **Plugins** menu appears in the menu bar once at least one enabled plugin has commands. It has one submenu
  per plugin with its commands, a separator, and **Manage Plugins…**, which opens Settings › Plugins. The
  palette also has a **Manage Plugins…** command.
- Plugin commands have no keyboard shortcuts in v1 (see Open questions).
- A command that needs a note (`"when": "note"`) or a selection (`"when": "selection"`) is hidden in the
  palette and greyed out in the menu when there isn't one, exactly like **Version History…** today.
- Changes a command makes in the editor are one undo step named after the command, such as
  **Undo Sort A to Z**.

### Notices, questions and panels

- A plugin can show a short notice in the same top-right notice NoteIt uses for captures. The plugin's name is
  shown under the message so the user always knows who sent it.
- A plugin can ask a question in a sheet on the main window: a title, an optional message, one text field,
  **Cancel** and a confirm button (default **OK**). The sheet's header always reads **<Plugin name> asks**.
  It can also ask for a yes/no confirmation in the same sheet without the text field.
- A plugin with the `ui:panel` permission can add inspector panels: extra tabs in the inspector, the
  right-hand pane that shows Links and Outline (owned by `linking`, ⌥⌘I). Each panel is a tab with the
  plugin's symbol and the panel title, after Links and Outline; the tab tooltip reads
  **<Panel title> — <Plugin name>**. Plugins never add sidebar sections or rows. Panels are built from a
  small set of native controls (text, buttons, text fields, toggles, pickers, lists, dividers, progress).
  There is no web content.
- The palette gets **Show <Panel title> Panel** for each enabled panel. It opens the inspector on that tab.

### Installing

- **Settings › Plugins** has an **Add** (`+`) menu with:
  - **Browse Plugins…** — the community directory (fetched only when this is opened);
  - **Install from File…** — a `.noteitplugin` file;
  - **Examples** — the three plugins bundled with NoteIt (Word Count, Sort Lines, Insert Date);
  - **Load Development Plugin…** — a folder on disk, only shown when **Developer mode** is on.
- Double-clicking a `.noteitplugin` file in Finder, or dropping it on the Settings › Plugins list, opens the
  same install sheet.
- The install sheet shows the plugin's name, version, author, description and where it came from:
  - **Listed in the NoteIt plugin directory**, or
  - **Not reviewed — installed from a file. Only install plugins from people you trust.**
- It shows the file's SHA-256 (first 16 characters, the full value with **Copy**) and then one row per
  permission in plain words (table below). If the plugin can both read notes and connect to a host, a warning
  line says **This plugin can send your notes to <host>.**
- Buttons: **Cancel** and **Install**. Installing grants every listed permission and turns the plugin on. A
  plugin that asks for nothing shows **This plugin doesn't need any permissions.**
- Installing a plugin that is already installed shows **Update from 1.0.0 to 1.1.0** or, for an older version,
  **Replace 1.1.0 with the older version 1.0.0**. New permissions are highlighted with **New**.

| Manifest permission | Shown as |
|---|---|
| `notes:read` | Read all your notes |
| `notes:write` | Create notes and change their text |
| `editor` | Read and change the note you're editing when you use this plugin |
| `clipboard` | Read and write the clipboard |
| `network:<host>` | Connect to <host> (one row per host) |
| `ui:panel` | Show panels in the inspector next to your notes |

### Settings › Plugins

A new tab, **Plugins** (raw value `plugins`, symbol `puzzlepiece.extension`), ninth in the Settings window,
after Integrations and before About, as fixed by the program's Settings tabs table.
`noteit://settings?tab=plugins` opens it.

- **Allow plugins**, on by default. Turning it off stops every plugin process at once and hides plugin
  commands, menus and panels; installed plugins and their settings are kept.
- A list of installed plugins. Each row has the icon, name and version, a status line and an on/off switch.
  Status lines:
  - **Running · 18 MB**, **Not running** (idle plugins stop after 5 minutes),
  - **Turned off: it stopped responding 3 times. Turn On Again**,
  - **Turned off: its files changed on disk. Review…**,
  - **Turned off: removed from the directory — <reason>**,
  - **Needs NoteIt 0.6 or later**,
  - **Development** (development plugins, with a **Reload** button).
- **Details…** on a row opens a sheet with:
  - author, homepage, license, source (directory, file or folder), installed date, SHA-256;
  - **Permissions** with a switch per permission. Turning one off revokes it right away; the plugin's calls
    that need it fail with a permission error. Turning it back on needs no prompt.
  - **Settings** built from the plugin's manifest (text fields, switches and pickers);
  - **Commands** and **Panels** it adds;
  - **Log**: the last 200 lines the plugin wrote, plus NoteIt's own lines about it (started, stopped, limits
    hit, permission errors). **Copy**, **Clear** and **Show in Finder**.
  - **Uninstall…**, which confirms with **Remove “Word Count”? Its settings and stored data are deleted too.
    Your notes aren't changed.**
- **Updates**: **Check for plugin updates automatically** (off by default; once a day while NoteIt runs,
  directory plugins only) and **Check Now**. Available updates show an **Update** button per plugin and
  **Update All**. Updates are never installed without a click.
- **Developer mode** (off by default) shows **Load Development Plugin…** and the **Reload** buttons.
- A footnote: **Plugins run in a separate, sandboxed process. They can't see your files, and they can't use
  the network unless you allow a specific host.**

### Problems the user can see

- A plugin that hangs or uses more than its memory allowance is stopped. The notice reads
  **“Sort Lines” stopped responding and was stopped.** After the third time in 24 hours it is turned off and
  the notice says so.
- A command that fails shows **“Sort Lines” couldn't finish: <message>**. Details go to the plugin's log.
- A plugin that needs a newer NoteIt can't be installed: **Needs NoteIt 0.6 or later.**
- A command that changed more than one note ends with the notice **“Tidy Tags” changed 12 notes.**
  and an **Undo** button (§4.2). Each changed note also has its previous text in Version History.

## Design

### 1. Runtime

**Process model.** Each enabled plugin runs in its own process, `NoteItPluginHost`, a small helper shipped in
`NoteIt.app/Contents/Helpers/`. The host evaluates the plugin's `main.js` in one `JSContext` on its own
`JSVirtualMachine` (JavaScriptCore, a system framework). Out of process means a stuck or greedy plugin can be
killed without touching the app, and the kernel sandbox can enforce the "no network, no files" rule rather
than relying on what the JavaScript bindings happen to expose.

- **Targets.** `NoteItPlugins` is a macOS library that depends on `NoteItCore` only. It holds the manifest,
  permissions, the host protocol and the runtime, with no AppKit. Platforms are package-wide, so it also
  compiles on iOS; any macOS-only code in it sits under `#if os(macOS)`. `NoteItPluginHost` is an executable
  target that depends on `NoteItPlugins`. Only the Mac app links `NoteItPlugins`; nothing else does.
- **Bundling and signing.** The helper is one row in the embeds table in `scripts/build_app.sh` (created in
  foundations task 5.5, owned by `automation`): path in bundle `Helpers/NoteItPluginHost`, source the
  `NoteItPluginHost` product, no build step, entitlements `Resources/NoteItPluginHost.entitlements`. Its identifier,
  `io.github.rutbergphilip.noteit.plugin-host`, comes from its embedded `Info.plist`. The script signs every
  embed inside-out without `--deep`, with the app last, so the helper keeps its own entitlements.
- **Entitlements.** The entitlements file contains only `com.apple.security.app-sandbox`. No network client
  entitlement, no file access entitlements, no JIT entitlement.
- **No JIT in v1.** In distribution builds the helper is signed with the hardened runtime, like everything in
  the bundle (ad-hoc builds sign without it, so the no-JIT measurement uses a distribution-signed build). Without
  `com.apple.security.cs.allow-jit` (and without `allow-unsigned-executable-memory` or
  `disable-executable-page-protection`), the kernel refuses writable and executable memory, so JavaScriptCore
  runs only in its interpreter tiers. Plugins are small and this is fast enough. The plan measures startup
  and a 10,000-line sort in interpreter mode on a distribution-signed build against a budget of 300 ms for
  startup and 1 s for the sort. A miss is recorded in `docs/known-limitations.md`; adding the JIT entitlement
  to the helper would be a later change to the program contract, not a v1 fallback.
- **Info.plist.** A single-file helper carries its `Info.plist` in the `__TEXT,__info_plist` section, which
  the sandbox uses for the helper's identity. `build_app.sh` builds the helper product on its own with the
  linker flags that embed `Sources/NoteItPluginHost/Info.plist` from the repository root. `Package.swift`
  carries no `unsafeFlags` and no relative `-sectcreate` path, so `swift build` and `swift test` work from any
  directory; unbundled builds have no embedded plist and aren't sandboxed (below).
- The app talks to the host over the host's stdin and stdout: length-prefixed JSON frames (4-byte big-endian
  length, at most 8 MB per frame). stderr goes to the plugin's log.
- The host receives the plugin source in its first frame, so it never opens files. In unbundled development
  runs (`swift run`) the helper isn't sandboxed; Settings › Plugins shows **Plugins aren't sandboxed in this
  development build.**
- The JavaScript environment has the standard library (including `Intl`, `Date`, `Promise`, `JSON`), plus the
  `noteit` global, `console.log/info/warn/error`, and `setTimeout`/`clearTimeout`/`setInterval`/
  `clearInterval` (at most 100 pending timers, intervals at least 100 ms). There is no `fetch`,
  `XMLHttpRequest`, `require`, `import` or file API. `main.js` is a single classic script (bundlers produce
  one; the SDK's template does).
- Every API call is asynchronous and returns a Promise, because it crosses the process boundary. The app is
  the only authority on permissions; the host checks them too only to fail fast with a clear message.

**Lifecycle.**

- A plugin starts when it's first needed: one of its commands runs, one of its panels is shown, or an event it
  declared fires. Plugins that declare events start 5 seconds after launch.
- A plugin with no visible panel, no declared events and no call in flight for 5 minutes is stopped.
- At most 8 plugin processes run at once; starting a ninth stops the one idle longest.
- Turning a plugin off, uninstalling it, updating it or turning off **Allow plugins** stops its process.
- On quit, NoteIt sends `shutdown` and kills any host still running after 1 second.

**Limits and watchdog.** Enforced by the app, which owns the clock:

| Limit | Value | What happens |
|---|---|---|
| Startup: process launched, script evaluated, `ready` received | 5 s | stopped, counts as a strike |
| Responsiveness while busy: the host answers `ping` (sent every 1 s while a call is in flight) | 3 s without a reply | killed, strike |
| Command, panel action: until its Promise settles | 30 s, not counting time a prompt or confirm sheet is open | the call fails with `Timeout`, process killed, strike |
| Event handler | 5 s | as above |
| Memory (`ri_phys_footprint`, sampled every 2 s) | 128 MB | killed, strike |
| Calls in flight per plugin | 32 | further calls fail with `RateLimited` |
| Notes written (`create`, `update`, `append`) | 50 per command run, 120 per minute | `RateLimited` |
| Notices | 1 per second | dropped, logged |
| Prompts | 1 open per plugin; closes itself after 5 minutes | resolves `null` |
| Panel renders | 10 per second | coalesced to the latest |
| `noteit.storage` | 1 MB per plugin | `TooLarge` |

Three strikes within 24 hours turn the plugin off with the reason shown in Settings. The strike log is per
plugin and cleared by **Turn On Again**.

### 2. Manifest: `plugin.json`

```json
{
  "manifestVersion": 1,
  "id": "io.github.noteit.sort-lines",
  "name": "Sort Lines",
  "version": "1.0.0",
  "minAppVersion": "0.6.0",
  "description": "Sort or de-duplicate the selected lines.",
  "author": { "name": "NoteIt", "url": "https://github.com/rutbergphilip/NoteIt" },
  "license": "AGPL-3.0-or-later",
  "homepage": "https://github.com/rutbergphilip/NoteIt",
  "main": "main.js",
  "icon": "icon.png",
  "permissions": ["editor"],
  "commands": [
    { "id": "sortAsc", "title": "Sort A to Z", "symbol": "arrow.up", "keywords": ["order"], "when": "selection" }
  ],
  "panels": [],
  "events": [],
  "settings": [
    { "key": "caseSensitive", "type": "toggle", "title": "Case sensitive", "default": false }
  ]
}
```

Validation rules (`ManifestValidator`); any failure refuses the install with the rule that failed:

- `manifestVersion` is `1`.
- `id`: lowercase reverse-DNS, `^[a-z0-9]+(\.[a-z0-9-]+)+$`, 3–100 characters. `io.github.noteit.*` is
  reserved for the bundled examples.
- `name` 1–40 characters; `description` up to 200; `version` and `minAppVersion` are semantic versions.
  `minAppVersion` must be at most the running app's version. Unbundled builds report `0.0.0-dev`, which counts
  as newer than everything.
- `main` is a relative path to a `.js` file inside the package, at most 2 MB. `icon` is an optional PNG,
  at most 512 KB, shown at 32 pt.
- `permissions`: only the six kinds in the table above. `network:<host>` takes an exact host name or one
  leading wildcard label (`network:*.example.com`); IP literals other than `127.0.0.1` and `localhost`, bare
  `*`, ports and schemes are refused. At most 10 network hosts.
- `commands`: at most 50, ids `^[a-zA-Z0-9_-]{1,40}$`, unique; titles 1–60 characters; `symbol` an SF Symbol
  name (unknown names fall back to the default at display time); `when` is `always` (default), `note` or
  `selection`.
- `panels`: at most 3, same id rules, title 1–30 characters; requires `ui:panel`.
- `events`: names from §4.6. Events that need a permission require it in `permissions`.
- `settings`: at most 20. `type` is `text` (with optional `placeholder`, max length 500), `toggle`, or
  `choice` (with `options: [{ "value", "title" }]`). Keys are unique, `^[a-zA-Z0-9_]{1,40}$`.
- Unknown top-level keys are refused, so typos don't silently do nothing.

The SDK ships the same rules as a JSON Schema (`plugins-sdk/schema/plugin.schema.json`). Swift is the
authority; a shared fixture set keeps the two in agreement.

### 3. Storage on disk

Plugins live with the app's data, not with the notes, so a Markdown library folder (`markdown-storage`) or a
synced folder never contains plugin code.

```
Application Support/NoteIt/plugins/        ($NOTEIT_DATA_DIR/plugins when that is set)
  installed/<id>/                         unpacked package: plugin.json, main.js, icon.png, README.md, LICENSE, …
  state.json                              PluginStateFile: per plugin enabled, granted permissions, source,
                                          package SHA-256, main.js SHA-256, installed date, strikes, disabled reason,
                                          development folder path
  data/<id>.json                          noteit.storage contents
  settings/<id>.json                      values of the manifest settings
  logs/<id>.log                           rotated at 256 KB, one previous file kept (<id>.1.log)
  staging/                                installs in progress; emptied at launch
  directory-cache.json                    last directory index and its signature, with ETag
```

- `state.json` is written atomically and decoded leniently (unknown plugins are dropped, missing fields get
  defaults), like `library.json`.
- On every start, the host's `main.js` is hashed and compared with `mainSHA256` from install. A mismatch (the
  file was changed by something other than NoteIt) turns the plugin off with **its files changed on disk** and
  **Review…** shows the install sheet again with the new hash. Development plugins skip this check.
- Plugin data isn't synced between Macs in v1, and isn't part of Export or the sync remote.

### 4. API surface (API version 1)

All methods return Promises. Errors reject with a `NoteItError` (`name: "NoteItError"`, `code`, `message`).
Codes: `PermissionDenied`, `NotFound`, `InvalidArgument`, `NoEditor`, `NoteChanged`, `NoteLocked`,
`ReadOnly`, `RateLimited`, `TooLarge`, `Timeout`, `NetworkBlocked`, `NetworkFailed`, `Cancelled`, `Internal`.

The TypeScript declarations in `plugins-sdk/types/index.d.ts` are the reference; this is the shape:

```ts
declare namespace noteit {
  const plugin: { id: string; version: string; appVersion: string; apiVersion: 1 };

  namespace commands {
    function register(id: string, handler: (ctx: CommandContext) => void | Promise<void>): void;
  }
  interface CommandContext { commandId: string; noteId: string | null; hasSelection: boolean }

  namespace notes {                                   // notes:read for reads, notes:write for writes
    function current(): Promise<string | null>;
    function get(id: string): Promise<Note>;
    function search(query: string, opts?: { limit?: number; notebookId?: string; tag?: string }): Promise<NoteSummary[]>;
    function list(opts?: { notebookId?: string; tag?: string; limit?: number; updatedSince?: string }): Promise<NoteSummary[]>;
    function create(input: { markdown: string; title?: string; notebookId?: string }): Promise<NoteSummary>;
    function update(id: string, input: { markdown: string }): Promise<NoteSummary>;
    function append(id: string, markdown: string): Promise<NoteSummary>;
  }
  namespace notebooks { function list(): Promise<Notebook[]> }   // notes:read

  namespace editor {                                  // editor
    function text(): Promise<string | null>;
    function selection(): Promise<Selection | null>;
    function lines(): Promise<Line[] | null>;
    function replaceSelection(text: string): Promise<void>;
    function insert(text: string): Promise<void>;
    function replaceLines(lines: Array<{ from: number } | { text: string }>): Promise<void>;
  }

  namespace ui {
    function toast(message: string, opts?: { style?: "info" | "success" | "warning" }): Promise<void>;
    function prompt(opts: { title: string; message?: string; placeholder?: string; defaultValue?: string; okTitle?: string }): Promise<string | null>;
    function confirm(opts: { title: string; message?: string; okTitle?: string }): Promise<boolean>;
    function panel(id: string): Panel;              // ui:panel
  }
  interface Panel {
    render(root: UINode): Promise<void>;
    onAction(handler: (action: { elementId: string; value?: string | boolean }) => void | Promise<void>): void;
    onShow(handler: () => void): void;
    readonly isVisible: boolean;
  }

  namespace clipboard {                               // clipboard
    function readText(): Promise<string | null>;
    function writeText(text: string): Promise<void>;
  }
  namespace net {                                     // network:<host>
    function fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<HttpResponse>;
  }
  namespace storage {                                 // no permission; per plugin
    function get<T = unknown>(key: string): Promise<T | undefined>;
    function set(key: string, value: unknown): Promise<void>;
    function remove(key: string): Promise<void>;
  }
  namespace settings {                                // no permission; values of the manifest settings
    function get<T = unknown>(key: string): Promise<T>;
    function onChange(handler: (key: string) => void): void;
  }
  namespace events {
    function on(name: EventName, handler: (payload: EventPayload) => void | Promise<void>): () => void;
  }
}
```

#### 4.1 Commands

- `commands.register` binds a handler to a command declared in the manifest. Registering an undeclared id
  throws synchronously; a declared command with no handler after startup fails with `Internal` and a log line.
- Running a command: the palette or menu calls `PluginManager.run`, which starts the host if needed and
  sends `invokeCommand` with the context. While a command or panel action is running, the plugin holds an
  **interaction window**: it may change the open note through `editor` and open prompts. Outside an
  interaction window `editor` write calls fail with `PermissionDenied` ("only while you use the plugin"), so a
  plugin can never edit the note on its own.
- Palette commands are built from manifests, so the palette lists them without starting any plugin.

#### 4.2 Notes

- Notes cross the API as Markdown, converted by `NoteItMarkdown` (`markdown-storage`), the only lossless
  Markdown path: the body goes through `DocConverter` to a `noteit-doc` body container and through
  `MarkdownCodec` in the `library` flavour (`MarkdownProfile.library`), the program's flavour for plugins,
  and back the same way. This is the only body format in API version 1; writes go through Version History
  and Undo as the safety net. Formatting plain Markdown has no syntax for (underline, colours, highlights, font
  sizes, alignment, indentation) is written as the inline HTML and `<!-- noteit: … -->` comments that flavour
  defines, so a plugin that reads a note and writes the same
  Markdown back changes nothing. Only what `noteit-doc` itself drops is lost. The old `MarkdownWriter` and
  `MarkdownReader` are not used.
- `Note` is `{ id, title, notebookId, tags, pinned, locked, createdAt, updatedAt, markdown, text }` with
  ISO 8601 dates. `NoteSummary` is the same without `markdown` and `text`, plus `preview`.
- Images and files in a note appear as `![name](noteit-attachment/<filename>)`. When a plugin writes Markdown
  back with those references unchanged, the original attachments are kept; unknown references are dropped.
- Every write goes through `NoteStore.editBody` (built in foundations task 4.5, shape owned by `organise`),
  the only way code outside the editor changes note text. It applies the change inside the open editor when
  the note is open in the main window or a floating note, as one undo step named after the command
  (**Undo Sort A to Z**); read-only surfaces such as cheat sheets mirror it through `OpenEditorRegistry.registerObserver(_:for:)`. A
  closed note is saved. With its default `versioning: .recordCurrent`, `editBody` records the note's current
  body in Version History exactly once, open or closed; plugin code never records a version itself. A locked note is refused (`BodyEditError.locked`,
  `NoteLocked`). Plugins have no other write path.
- `update` replaces the whole body; `append` adds Markdown at the end and never touches existing text. Before
  either changes a note, `editBody` records the note's current body in Version History.
- **Changes to many notes.** When one command run, panel action or event handler changes more than one
  existing note, each note's first write in the run goes through `editBody` with `versioning: .recordCurrent`,
  so its body from before the run is in Version History; later writes to the same note in that run pass
  `versioning: .none`. The run keeps the revision and body each note had before it (program §6). When the run settles it shows the
  notice **“<Plugin name>” changed N notes.** with **Undo**. Undo puts back the recorded version of every note
  that hasn't changed since the plugin wrote it, through `editBody`, and says how many it left alone. Notes
  the run created are kept.
- `create` uses `NoteStore.createNote(in:initial:)` with the body converted from Markdown; with no
  `notebookId` it uses the notebook for new notes (Settings › Editor › New Notes). `title`, when given,
  becomes the first line as a title.
- Notes in Recently Deleted are invisible: `get` returns `NotFound`, they're excluded from `search` and `list`.
  Notes whose body can't be read or written (`NoteStore.isBodyWriteBlocked`) return `ReadOnly` on writes.
- **Locked notes** (`sync-security`) follow the program's locked-note rule, read from `NoteMeta.isLocked`:
  - `list` and `search` include them with `locked: true` and an empty `preview`; `search` matches their title
    only.
  - `get`, `update` and `append` fail with `NoteLocked`, even while the note is unlocked in the editor.
  - Plugins never see the body of a locked note through any API.
- `search` uses `organise`'s ranked search (`NoteStore.searchResults(for:search:order:)`), the same matching
  as the sidebar search. `limit` defaults to 50, max 200.
- All note access goes through `NoteStore`, so it works the same for the RTFD library, the `noteit-doc` body
  format, and the Markdown folder library from `markdown-storage`.

#### 4.3 Editor

- Works on the note in the main window's editor (`EditorController.active()`), whichever plugin call comes in.
  No main window or no live note: `NoEditor`. A locked note in the editor, even unlocked for this session,
  fails every `editor` call with `NoteLocked`.
- Each call made during a command carries the command's `noteId`. If the open note has changed since, the call
  fails with `NoteChanged`, so a slow plugin can't write into the wrong note.
- `text()` is the note's plain text; `selection()` is `{ text, start, length }` in UTF-16 units of `text()`.
- Reads come from the live editor. Writes are computed against the editor's text and applied through
  `NoteStore.editBody`, like every other change from outside the editor (§4.2).
- `replaceSelection` and `insert` type plain text with the attributes at the selection start, like pasting
  plain text. `insert` replaces the selection if there is one, otherwise inserts at the caret.
- `lines()` returns the paragraphs the selection touches (the paragraph at the caret if nothing is selected)
  as `{ index, text, kind }`, where `kind` is `body`, `title`, `heading`, `subheading`, `bullet`, `numbered`,
  `checklist`, `checked`, `quote` or `code`. `text` excludes list markers.
- `replaceLines` replaces those paragraphs. `{ from: i }` reuses paragraph `i` with all its formatting, list
  marker and checkbox; `{ text }` adds a plain body paragraph. This is how plugins sort, de-duplicate or
  reorder without losing formatting. Numbered lists are renumbered afterwards.
- Every change is one undo step named after the command, and the result is selected.
- Limits: `text()` returns at most 5 MB; larger notes fail with `TooLarge`.

#### 4.4 UI

- `toast` maps to `CaptureToastController` with the plugin name as the message line. 200 characters max.
- `prompt` and `confirm` show a sheet on the main window (bringing it forward). Only during an interaction
  window; otherwise `PermissionDenied`. **Cancel** or Esc resolves `null` / `false`.
- **Panels** render a declarative tree natively in SwiftUI (`PluginPanelView`). No HTML, no Markdown, no web
  view; all strings are shown as plain text.

  | Node | Fields |
  |---|---|
  | `vstack`, `hstack` | `children`, `spacing` (0–24) |
  | `text` | `text`, `style`: `body`, `caption`, `headline`, `title`, `mono`; `color`: `primary`, `secondary`, `accent`, `red`, `green`, `orange` |
  | `button` | `id`, `title`, `symbol?`, `style`: `plain`, `bordered`, `prominent`; `disabled?` |
  | `textField` | `id`, `placeholder?`, `value?`, `submitOnEnter?` |
  | `toggle` | `id`, `title`, `value` |
  | `picker` | `id`, `title`, `value`, `options: [{ value, title }]` |
  | `list` | `id`, `items: [{ id, title, subtitle?, symbol? }]`, `selection?` |
  | `noteLink` | `noteId`, `title?` — opens the note |
  | `link` | `url` (https only), `title` — opens in the default browser |
  | `divider`, `spacer` | — |
  | `progress` | `value?` (0–1; indeterminate when absent) |

  Limits: depth 8, 500 nodes, 10,000 characters per string, 256 KB per tree. An invalid tree is rejected with
  `InvalidArgument` naming the path (`children[2].items[0].title`) and the panel keeps its last good tree.
  User input (button presses, text submitted, toggles, picker and list choices) reaches the plugin through
  `onAction` and opens an interaction window, so a panel button can edit the note.
- Panels show **This plugin isn't running** with **Start** when the host has stopped, and an empty state with
  the plugin name before the first render.

#### 4.5 Clipboard and network

- `clipboard.readText` / `writeText` use plain text only on the general pasteboard.
- `net.fetch` is performed by the app (`PluginNetworkGate`) through `web-clipper`'s address-pinned
  `PinnedHTTPClient`, the same transport the clipper uses for images, not `URLSession`: no cookies, no cache, no
  credentials, no proxies or proxy-auth prompts.
  - HTTPS only; `http` only for `localhost` and `127.0.0.1`, and only if granted by name.
  - The URL's host must match a granted `network:` host. Redirects are followed only to granted hosts (max 5).
  - Every request and every redirect resolves the host once and is refused (`NetworkBlocked`) if any address
    isn't public, so a granted host can't be pointed at the local network by its DNS answer. The one exception
    is loopback (`127.0.0.0/8`, `::1`) for a host the user granted as `network:localhost` or
    `network:127.0.0.1`; other private addresses are refused even then.
  - The connection goes to the address that was checked, with no second lookup (no DNS rebinding). HTTPS uses
    the original host for TLS SNI and certificate validation.
  - Methods `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`. Headers `Cookie`, `Host`, `Origin`,
    `Proxy-Authorization` are refused.
  - Request body ≤ 1 MB, response ≤ 5 MB, timeout 15 s, 30 requests per minute.
  - The response is `{ status, headers, url, text(), json() }`; the body is decoded as UTF-8.
  - Every request is logged with method, host and status (not the body or query string).

#### 4.6 Events

| Event | Needs | Payload | When |
|---|---|---|---|
| `noteCreated` | `notes:read` | `{ id }` | a note is created on this Mac |
| `noteEdited` | `notes:read` | `{ id }` | edits to a note settle (2 s with no further change) |
| `noteDeleted` | `notes:read` | `{ id }` | a note is moved to Recently Deleted or deleted on this Mac |
| `currentNoteChanged` | `editor` | `{ noteId }` | the open note changes, or its edits settle |
| `appWillQuit` | — | `{}` | before quit; 1 s budget |

- Events are built on the `localNoteChange` notification (foundations task 4.5), which `NoteStore` posts
  with `userInfo["noteID"]` and `userInfo["kind"]` (`created`, `edited` or `deleted`) after a local action
  only: creating a note, a local body edit (editor save, `editBody`, and Restore Version, which goes through `editBody`), and moving a note to
  Recently Deleted or deleting it. It is never posted for a change that arrives through sync. It is the one
  extra hook the program allows in `NoteStore`, so plugins add no notification of their own. `noteCreated`,
  `noteEdited` and `noteDeleted` map to the three kinds; the edit part of `currentNoteChanged` comes from
  `edited`, and the note switch part comes from the main window's selection. Changes applied by sync don't
  fire events in v1.
- Changes a plugin makes don't send events back to the same plugin, so plugins can't loop on themselves.
- Events are coalesced per note and per plugin; at most 1 event per note per 2 s.

### 5. Packaging and installation

- A `.noteitplugin` file is a ZIP archive with `plugin.json` at its root. Uniform type
  `io.github.rutbergphilip.noteit.plugin`, conforming to `public.zip-archive`; NoteIt registers it as a
  document type it can open (viewer role) in `Info.plist`.
- Limits: archive ≤ 10 MB, unpacked ≤ 20 MB, ≤ 200 entries. Refused: absolute paths, `..` components,
  symlinks, hard links, files that aren't regular files or directories, and names that collide when
  case-folded.
- Steps (`PluginInstaller`):
  1. Copy the archive to `staging/<uuid>/package.zip` and compute its SHA-256 (CryptoKit).
  2. List entries with `/usr/bin/zipinfo` and validate them (`PackageValidator`) before extracting anything.
  3. Extract with `/usr/bin/ditto -x -k` into `staging/<uuid>/content`, then re-walk the tree and validate
     again (symlinks, sizes).
  4. Validate `plugin.json`, then hash `main` for `mainSHA256`.
  5. Show the install sheet. On **Install**, stop any running host for that id, move the old folder to
     `staging/<uuid>/previous`, move the new one into `installed/<id>`, write `state.json`, delete the old
     folder. A failure at any step puts the previous version back.
- Plugin settings and storage are kept across updates. Setting keys that the new manifest no longer declares
  are dropped.
- **Development plugins** are loaded in place from a folder chosen with an open panel. The path is stored in
  `state.json`. NoteIt watches `plugin.json` and `main.js` and restarts the host when they change, without
  re-asking for permissions unless the permission list grows.

### 6. Community directory

- The directory is a public GitHub repository, `rutbergphilip/noteit-plugins`. Each plugin has a file
  `plugins/<id>.json`; CI builds `index.json` and its signature on every merge to `main`. Adding or updating a
  plugin is a pull request. This sub-project creates the repository, its `README.md` and `CONTRIBUTING.md`, the
  entry and index format (JSON schemas) and the pull-request check; the scripts live in this repository under
  `plugins-sdk/directory/`.
- The website has a `/plugins/` page, also owned here: what plugins can do, the safety model in short, how to
  install one, how to write one (`docs/plugins.md`) and how to submit one (the directory's `CONTRIBUTING.md`).
  It uses growth's shared header, footer and stylesheet, passes `scripts/check_site.py`, and follows growth's rule
  that anything not in a full release yet is written as planned.
- NoteIt fetches `https://raw.githubusercontent.com/rutbergphilip/noteit-plugins/main/index.json` and
  `index.json.sig`, only when the user opens **Browse Plugins…**, presses **Check Now**, or has turned on
  automatic update checks. The URL can be overridden with the hidden default `pluginDirectoryURL` for testing.
- Index format:

  ```json
  {
    "schemaVersion": 1,
    "generatedAt": "2026-11-02T10:00:00Z",
    "plugins": [{
      "id": "com.example.daily-quote", "name": "Daily Quote", "description": "…",
      "author": { "name": "…", "url": "https://…" }, "homepage": "https://github.com/…", "license": "MIT",
      "versions": [{
        "version": "1.2.0", "minAppVersion": "0.6.0", "permissions": ["editor", "network:api.quotable.io"],
        "download": "https://github.com/example/daily-quote/releases/download/v1.2.0/com.example.daily-quote-1.2.0.noteitplugin",
        "sha256": "<64 hex>", "size": 12345, "publishedAt": "2026-11-01T09:00:00Z"
      }]
    }],
    "revoked": [{ "id": "com.example.bad", "versions": ["1.0.0"], "reason": "Sent notes to an undisclosed host." }]
  }
  ```

- **Integrity.**
  - `index.json.sig` is an Ed25519 signature over the exact bytes of `index.json`, made in the directory's CI
    with a key kept as a repository secret. The public key is compiled into NoteIt (`PluginDirectory.publicKey`).
    An index that fails verification is not used: **The plugin directory couldn't be verified.**
  - Downloads must be `https://github.com/<owner>/<repo>/releases/download/…`. The downloaded archive's size and
    SHA-256 must match the index entry, and its manifest's `id`, `version` and `permissions` must match the
    entry exactly; otherwise the install is refused.
- **Choosing a version.** NoteIt offers the newest version whose `minAppVersion` it satisfies.
- **Revocation.** When an index is fetched, installed plugins whose id and version are listed under `revoked`
  are turned off with the reason. The user can still uninstall them; turning them back on asks again with the
  reason shown.
- **Review** happens on the pull request. The directory repo's CI (scripts maintained in this repository under
  `plugins-sdk/directory/`) checks that the entry is valid, downloads the asset, checks size and hash, unpacks
  it with the same rules as the app and validates the manifest. Reviewers check the source at the release tag
  against `main.js`, that the permissions are justified in the README, and that `main.js` isn't obfuscated.
  Minified code is accepted only with its source in the same repository. The review checklist is in the
  directory repo's `CONTRIBUTING.md`.
- The **Browse Plugins…** sheet lists entries with search, name, author, description, permissions (in plain
  words) and **Install** / **Installed** / **Update**. It uses the cached index when offline and says
  **Showing the list from <date>.**

### 7. Updates

- Only directory-installed plugins get update offers. File-installed plugins update by installing a newer
  file; development plugins reload from their folder.
- An update with the same or fewer permissions installs on **Update** without another sheet. An update that
  adds permissions shows the install sheet with **New** next to them; until it's accepted, the old version
  keeps running.
- **Check for plugin updates automatically** fetches only the index and its signature. The fetch is listed in
  the network inventory from `sync-security`.

### 8. Safety model

What a plugin can't do, whatever it asks for:

- open files, sockets or processes (kernel sandbox on the host process);
- load native code, open a web view, or render HTML;
- see notes in Recently Deleted, or read or write the body of a locked note (`NoteLocked`);
- delete notes, notebooks or attachments (no delete API in v1);
- edit the open note, open prompts or panels when the user isn't using it (interaction windows);
- slow the app down for more than a few seconds or take more than 128 MB (watchdog);
- hold a Local API token or open a socket to NoteIt;
- call other plugins or read their storage.

What a plugin can do if granted, and what that means, is stated in the install sheet in plain words. The
residual risk is explicit: a plugin with `notes:read` and a network host can send notes to that host. NoteIt
highlights that combination at install and in Details, logs every request with its host, and the directory
review checks it, but can't prove what the remote end does with the data.

Supply chain: directory installs are pinned by SHA-256 to a reviewed index, signed in CI with a key that isn't
in the repository, so editing `index.json` alone can't change what NoteIt installs; installed files are
checked against their hashes on every start; revocation reaches users the next time the index is fetched.

### 9. TypeScript SDK

- `plugins-sdk/` at the repository root is the npm package `@noteit/plugin-sdk` (Node 24, pnpm, TypeScript 5
  strict). It contains:
  - `types/index.d.ts` — the global `noteit` declarations, API version 1;
  - `schema/plugin.schema.json` — the manifest JSON Schema;
  - the `noteit-plugin` command: `init <id>` (template with `plugin.json`, `src/main.ts`, an esbuild bundle
    step and a README with the review checklist), `lint` (schema plus the app's extra rules), `pack` (writes
    `<id>-<version>.noteitplugin` and prints its SHA-256 and size for the directory entry);
  - `directory/` — the scripts the directory repo's CI runs (`validate-entry.mjs`, `build-index.mjs`,
    `sign-index.mjs`).
- Published to npm from GitHub Actions on tags `plugins-sdk-v<version>`, with npm provenance. The SDK's major
  version follows the API version.

### 10. Example plugins (shipped and used as acceptance tests)

Bundled in the app as `Sources/NoteIt/ExamplePlugins/<id>/` and offered under **Add › Examples**. The folder
is a `.copy` resource, not `.process`, so the bundle keeps each plugin's files byte for byte in their folders.
Plain JavaScript with JSDoc types, so the Swift build needs no Node; the SDK type-checks them in CI.

1. **Word Count** (`io.github.noteit.word-count`) — permissions `editor`, `ui:panel`.
   - Command **Count Words** (`when: note`): notice **1,234 words · 6,789 characters · 6 min read** for the
     selection if there is one, otherwise the whole note.
   - Panel **Word Count**: the same numbers plus paragraphs, refreshed on `currentNoteChanged`.
   - Reading time uses the setting **Words per minute** (`choice`: 200, 238, 300; default 238).
2. **Sort Lines** (`io.github.noteit.sort-lines`) — permission `editor`.
   - Commands **Sort A to Z**, **Sort Z to A**, **Remove Duplicate Lines** (`when: selection`), all through
     `editor.lines()` / `replaceLines` so checklists and formatting survive. Sorting uses
     `Intl.Collator(undefined, { numeric: true })`, honouring the **Case sensitive** setting.
3. **Insert Date** (`io.github.noteit.insert-date`) — permission `editor`.
   - Commands **Insert Date**, **Insert Date and Time**, **Insert Date in Format…** (`when: note`).
   - Settings **Date format** (default `YYYY-MM-DD`) and **Date and time format** (default
     `YYYY-MM-DD HH:mm`). Tokens: `YYYY YY MMMM MMM MM M DD D dddd ddd HH H hh h mm ss A`, text in `[brackets]`
     kept literally; names from `Intl` in the system locale.
   - **Insert Date in Format…** asks with `ui.prompt`, prefilled with the last format used (kept in
     `noteit.storage`).

Each example has an automated end-to-end test that installs it, runs its commands against a fixture note
through the real host process and checks the note text and undo.

## Dependencies

Plugins are in wave 3. Everything below ships before them, so nothing here needs a stub or a fallback.

- **Foundations (wave 0)**: the `NoteItCore` target this project's library depends on, the package-wide
  platforms (so `NoteItPlugins` also compiles on iOS), `NoteMeta.isLocked`, `NoteStore.editBody`,
  `OpenEditorRegistry` and the `localNoteChange` notification (task 4.5), `LocalAPIRouteRegistry` (5.2), the
  embeds table in `scripts/build_app.sh` (5.5), and the frozen Settings tab table (6.3), which already has the
  `plugins` row, hidden until this project makes it available.
- **`automation` (01), Local API.** Not needed for plugins to work. Plugins themselves never hold a Local API
  token and never open a socket; `automation` has no plugin client kind. Outside tools that want to react to
  note changes use `automation`'s `/v1/events` feed.
  - **Embeds table.** `scripts/build_app.sh` gets one row for `Helpers/NoteItPluginHost` (§1).
  - **Routes**, registered by this project (milestone 5) through `LocalAPIRouteRegistry.register`, with
    errors from `APIErrorCode` only, in the nested error body (`{"error":{"code":…,"message":…}}`):
    - `plugins.list`: `GET /v1/plugins` (scope `read`): installed plugins, enabled state, commands;
    - `plugins.runCommand`: `POST /v1/plugins/{pluginID}/commands/{commandID}` (scope `write`): run a plugin
      command and return when it settles. Commands that need an open editor (`"when": "note"` or
      `"selection"`) return `409 editor_required`. Unknown or turned-off plugins and commands return
      `404 not_found`. Plugin errors map to `APIErrorCode`: `NoteLocked` → `423 note_locked`,
      `NoEditor` → `409 editor_required`, `NotFound` → `404 not_found`, `RateLimited` → `429 rate_limited`,
      `TooLarge` → `413 too_large`, anything else → `500 internal` with the plugin's message.
  - **App Intents**: **Run Plugin Command** with a plugin-command entity, built on the same call.
  - **Gate.** Milestone 5 starts only after `automation`'s App Intents spike (its T19) succeeds. If the spike
    fails, plugin commands still appear in the Plugins menu and the command palette; they are only missing
    from Shortcuts and the Local API (no intents and no Local API routes).
- **`linking` (03)** owns the inspector (`.inspector` on the editor column, `Views/LinksPanelView.swift`,
  preferences `inspectorVisible` and `inspectorTab`, ⌥⌘I). Plugin panels are inspector panels: extra tabs
  after Links and Outline. Their `inspectorTab` value is `plugin.<pluginID>.<panelID>`, and a value whose
  plugin or panel is gone falls back to `links`.
- **`organise` (04)**: owns the shapes of `NoteStore.editBody` and `OpenEditorRegistry`, which foundations
  builds (the only write path, §4.2, §4.3), and the ranked search behind `notes.search`.
- **`markdown-storage` (02)**: `NoteItMarkdown` for Markdown in and out of notes (§4.2), in the `library`
  flavour. Because the API is lossless through it, no separate `doc` field is planned.
- **`sync-security` (08)** owns locked notes and the network inventory. The API reads `NoteMeta.isLocked` and
  follows the locked-note rule (§4.2, §4.3). The inventory lists the directory fetch, plugin downloads and
  "requests made by plugins you allowed, to the hosts you allowed".
- **`web-clipper` (07)** owns `PinnedHTTPClient` (`Sources/NoteIt/Net/`, in the `NoteIt` app target; wave 2):
  resolve once, address checks, connect to the checked address with TLS to the original host, redirects. Plugins
  pass their own policy (§4.5 methods, body and response limits, loopback only when granted) and add no transport.
- **`surfaces-polish` (12)**: the accessibility audit covers the plugin sheets and panel renderer.
- **`growth` (13)**: owns the website's shared header, footer, stylesheet and `scripts/check_site.py`, which the
  plugins page follows. The `noteit-plugins` repository, its contribution guide, the index format and its CI
  check, and the website's `/plugins/` page are owned by this sub-project (plan Task 19), not by growth.
- **`mobile` (11)** and the web app don't run plugins.

## Non-goals

- Web views, HTML or Markdown rendering in panels, custom CSS, themes.
- Native plugins, Node.js or npm at runtime, file system access, raw sockets, spawning processes.
- Custom editor rendering, syntax, decorations or new block types.
- Keyboard shortcuts and global hotkeys for plugin commands.
- Deleting notes or notebooks, editing attachments, managing tags or notebooks through the API.
- Running when NoteIt isn't running, or scheduled background jobs.
- Plugin-to-plugin calls, shared storage, dependencies between plugins.
- Syncing plugins or their settings between Macs.
- Paid plugins, accounts, ratings, download counts, or any server NoteIt runs.
- Plugins on iPhone, iPad or the web app.
- Automatic installation of updates.

## Open questions

1. **Keyboard shortcuts for plugin commands.** Default: none in v1. `MenuShortcutCommand` and `HotkeyAction`
   are closed enums; supporting dynamic commands needs a separate design.
2. **Events for changes from sync.** Default: not fired, to avoid plugins reacting to the same change on
   every Mac.
3. **Signing the directory index.** Default: signed with Ed25519, public key compiled in. Rotating the key
   needs an app release; the app accepts a list of keys so the next key can ship before rotation.
4. **Default for "Allow plugins".** Default: on, since nothing runs until the user installs a plugin.
5. **Process per plugin versus one shared host.** Default: one per plugin, for kill isolation and per-plugin
   memory limits (about 12 MB each), capped at 8 running.
6. **Strike policy.** Default: 3 strikes in 24 hours turns a plugin off.
