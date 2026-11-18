# vibetube architecture and decisions

**Audience:** a future conversation that needs to work on this codebase without
first re-deriving everything. Read this before changing behaviour.

**Status:** applies to v1.0 (`src/` at the `v1.0` freeze). Everything below is
described as implemented, not aspirational.

---

## 1. What the app is

A windowed Windows program with three inputs (URL, output folder, speed limit)
and one action (Download). It shells out to `yt-dlp` to fetch and transcode, then
renames the result according to its own filename rules.

It is deliberately **not** a library wrapper, a service, or a media framework.
The entire media pipeline is one external process invocation.

---

## 2. Stack decision

**Odin + raylib/raygui, single static executable.**

| Option considered | Why rejected |
|---|---|
| Electron / web UI | Hundreds of MB, a browser process, and the opposite of "native" |
| .NET WinForms | Requires the runtime, and the toolchain is heavier than the problem |
| Raw Win32 + D3D11 in Odin | Fully native but every widget is hand-written; raygui provides buttons, a progress bar and a style system for free |
| Webview2 shell | Ships a browser view; also a runtime dependency |

Odin was chosen because `vendor:raylib` ships with the compiler (no package
manager, no vendoring, no build system), and the app is about 1,570 lines of
non-test code across ten files. `raylib.lib` is statically linked, so the
deliverable is one file.

Consequence worth remembering: **raylib is a game library.** It has a frame loop,
a key queue and a box-drawing API, but no widgets. Anything beyond raygui's ~60
controls is ours to write — which is exactly why the text field (§7) is custom.

---

## 3. Runtime architecture

Two threads and a mutex-guarded queue.

```
main thread (60 fps)                    worker thread
────────────────────                    ─────────────
drain(&app)  ── pop events ──┐          spawn yt-dlp
draw_ui(&app)                │          read pipe, split lines
  ├─ text fields             │          parse → _push(&event)
  ├─ buttons                 │               ▲
  └─ progress bar            └── [events] ───┘
config_save
```

**Why a thread at all:** `yt-dlp` takes seconds to minutes. A blocking call in
the frame loop freezes the window and the OS paints it as "not responding".

**Why a queue rather than shared state:** the worker must never touch raylib or
the UI state. It produces immutable events; the UI thread owns all rendering and
application state. The only shared mutable data is the queue itself.

```odin
Event :: struct {
	kind:    Event_Kind,   // Meta, Progress, Stage, Log, Done, Failed
	percent: f32,
	text:    string,       // owned by the queue
}
```

Queue rules, all in `src/download.odin`:

- `_push` takes ownership of `text`; the consumer `delete`s it after handling.
- **Progress events coalesce**: if a `Progress` event is already queued, it is
  replaced. Without this, a 60 fps download would enqueue a progress event per
  line and the UI would render stale percentages for a second.
- The queue is capped at `MAX_EVENTS` (256); the oldest non-progress event is
  dropped, so a chatty run cannot grow memory without bound.
- Drain is a simple pop-until-empty loop at the top of each frame.

**Termination:** `download_is_running` is set false by the worker *after* the
final event is pushed. The main loop therefore does one extra `drain` before
breaking on completion — without that, the `Saved:` / error event is pushed
after the last drain and is never shown (see §12, trap 6).

**Shutdown:** closing the window calls `download_cancel`, which sets a flag and
kills the child process. Doing this is load-bearing: without it, a closed GUI
leaves an orphaned `yt-dlp`/`ffmpeg` downloading invisibly.

---

## 4. The yt-dlp contract

Built in `_worker` (`src/download.odin`) as an argument array, never a shell
string:

```
yt-dlp
  -f ba/b                     best audio, never a video stream
  -x                          extract audio, discard video
  --audio-format mp3
  --audio-quality 160K        LAME CBR 160 kbps via ffmpeg
  --no-playlist               a watch URL stays one video
  --newline                   one status line per update (line-oriented parsing)
  --progress                  keep progress even though --print implies --quiet
  --no-simulate               REQUIRED, see below
  --print META-ID:%(id)s
  --print META-CHANNEL:%(channel)s
  --print META-TITLE:%(title)s
  -P <dir>                    output directory
  -o %(id)s.%(ext)s           temporary ASCII name
  [--limit-rate <bytes>]      only when a limit is set
  <url>
```

### Decisions and their reasons

**`--no-simulate` is mandatory.** `--print` implies `--simulate` (and `--quiet`).
Without `--no-simulate` the process exits 0 having downloaded nothing. This cost
an afternoon; it is trap 1.

**`-o %(id)s.%(ext)s`, not the pretty name.** yt-dlp writes
`dWRCooFKk3c.mp3` — a video ID, guaranteed `[A-Za-z0-9_-]` and unique. The
human-readable name is built by us (§5) and applied with `os.rename` **after**
yt-dlp exits 0. Reasons:

- No Unicode or quoting ever reaches a command line.
- Filename rules live in one testable function instead of yt-dlp flags.
- If the rename fails, the ID-named file is still a valid MP3, so nothing is lost.

**Metadata via three `--print` lines, not `--dump-json`.** `--dump-json` would
need a JSON parser in Odin; three prefixed lines need `has_prefix`. Prefixes make
the parse unambiguous even if a title or channel literally contains `META-ID:`.

**Merged stdout and stderr on one pipe.** `--print` writes to stdout, progress to
stderr. One pipe means one reader and one line parser; interleaving is harmless
because every line is independently classified.

**UTF-8 environment.** `os.set_env("PYTHONUTF8", "1")` and
`PYTHONIOENCODING=utf-8` are set once in `main`; the child inherits them. Without
this, non-ASCII titles arrive as ANSI-codepage mangling through the pipe.

### Output parsing

Line classification in `_process_line`:

| Line shape | Action |
|---|---|
| `META-ID:…` / `META-CHANNEL:…` / `META-TITLE:…` | store (trimmed, cloned) |
| `[download] …%…` | parse the number before `%`, push `Progress` |
| `[ExtractAudio]` / `[ffmpeg]` | push `Stage` ("Converting to mp3…") |
| `ERROR: …` | store as `last_error`, push `Log` |
| anything else | ignored |

Percentage parsing walks back from the `%` over digits and `.`, then
`strconv.parse_f32`. It tolerates `100%`, `37.9%`, and yt-dlp's padded output.

On failure the UI shows yt-dlp's own `ERROR:` text rather than a generic message.
That single decision is why most failures are self-explanatory.

### Speed limiting

`--limit-rate` takes **bytes per second**, and its `K`/`M` suffixes are
**1024-based mebibytes**. `--limit-rate 16M` would be ~134 Mbit/s — 8× the
intended cap and completely silent about it.

So the UI takes Mbit/s and the app converts to raw bytes:

```odin
// src/main.odin
mbit_to_bytes :: proc(mbit: f32) -> int {
	if mbit <= 0 { return 0 }
	return int(mbit * 1_000_000.0 / 8.0)   // 16 -> 2_000_000
}
```

`--limit-rate` is an average cap per stream, not a shaper: brief overshoot at the
start of a file is expected.

---

## 5. Filename pipeline (`src/naming/`)

The package is pure — no OS calls, no raylib — so it is unit-testable offline.
Contract:

```
<sanitised channel>_<sanitised title>_160k.mp3
≤ 180 bytes total, ASCII only, charset [A-Za-z0-9_-] plus the final "."
```

Algorithm (`sanitize_into`):

```odin
for r in s {
	if r < 0x80 {
		c := u8(r)
		keep := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		        (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !keep { pending_sep = true; continue }
		if pending_sep && n > 0 { dst[n] = '_'; n += 1 }
		pending_sep = false
		dst[n] = c; n += 1
		continue
	}
	if a := _accent(r); len(a) > 0 { /* emit transliteration */ }
	else { pending_sep = true }
}
for n > 0 && dst[n-1] == '_' { n -= 1 }
```

Decisions:

- **Run-collapsing to a single `_`**, rather than deleting disallowed characters.
  Deleting turns `"Rock & Roll"` into `"RockRoll"`; collapsing keeps words apart.
- **Non-ASCII dropped, not underscored per byte.** UTF-8 continuation bytes would
  otherwise produce several underscores per character.
- **Latin transliteration table** for `À-ž`, `ß→ss`, `æ→ae`, `ø→o`, `þ→th`.
  Stripping alone turns `Café` into `Caf`, which reads as a bug.
- **Case preserved.** Lowercasing was considered and rejected: it looks lossy and
  gains nothing for filesystem compatibility here.
- **`unknown_160k.mp3` fallback** so two unnameable videos cannot collide.
- **Writes into a caller buffer**, no allocation; `build_filename` returns a slice
  of `dst`.

23 tests cover accents, emoji, CJK, quotes, truncation, the charset guarantee and
the real metadata fixture.

> **Odin gotcha:** a proc may not be named `string` inside a package — it shadows
> the builtin type for the whole package. The accessor is called `value`.

---

## 6. Spawning without a console (`src/spawn.odin`, `src/winargs/`)

`os.process_start` cannot be used. It hardcodes
`CREATE_UNICODE_ENVIRONMENT | NORMAL_PRIORITY_CLASS` and exposes no flag field.
A **windowed** app spawning a **console** app without `CREATE_NO_WINDOW` makes
Windows allocate the child its own console — the cmd box that used to flash
behind the GUI.

So `spawn_hidden` calls `CreateProcessW` directly:

```odin
started := win32.CreateProcessW(
	nil,
	cast(cstring16)raw_data(cmd_line_w),
	nil, nil,
	true,   // inherit handles (the pipe)
	win32.CREATE_UNICODE_ENVIRONMENT | win32.CREATE_NO_WINDOW | win32.NORMAL_PRIORITY_CLASS,
	nil,    // inherit our environment (PYTHONUTF8 lives here)
	nil,
	&si,    // STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW, SW_HIDE
	&pi,
)
```

It returns an `os.Process{pid, handle}`, so `os.process_wait` and
`os.process_kill` work unchanged on the handle.

**This makes command-line quoting our problem.** Windows passes one string, and
the child re-splits it with `CommandLineToArgvW` rules. A path like
`C:\Users\Phil\My Music` must be quoted or yt-dlp sees two arguments and
downloads into the wrong place — silently. `src/winargs/winargs.odin` implements
the rules:

```odin
append(buf, '"')
backslashes := 0
for c in arg {
	if c == '\\' { backslashes += 1; continue }
	if c == '"' {
		for _ in 0 ..< backslashes * 2 + 1 { append(buf, '\\') }
		append(buf, '"'); backslashes = 0; continue
	}
	for _ in 0 ..< backslashes { append(buf, '\\') }
	backslashes = 0
	append(buf, c)
}
for _ in 0 ..< backslashes * 2 { append(buf, '\\') }   // before closing quote
append(buf, '"')
```

Six unit tests, plus an end-to-end run into `_space dir\sub folder` to prove it
against real yt-dlp.

> Allocation note: the UTF-16 command line uses `context.allocator` with
> `defer delete`, **not** `temp_allocator`. `temp_allocator` is a ring that is
> only reset by a per-frame guard, and this runs on the worker thread, where
> nothing resets it.

---

## 7. Text input (`src/textfield/`, `src/text_input.odin`)

raygui's `GuiTextBox` was removed after it proved unusable: it owns its edit-mode
state, toggles on click in ways that fight the caller, and consumes raylib's key
queue. Typing did nothing.

Replacement is split in two:

- **`textfield`** — pure editing model: `[512]u8` buffer, `len`, `cursor`,
  `scroll`. Operations `insert_byte`, `insert_str`, `backspace`,
  `delete_forward`, `move_left/right/home/end`, `set`, `clear`. No imports beyond
  `core:unicode`; **9 tests**.
- **`text_input`** — raylib glue: drawing, caret, horizontal scrolling, key
  dispatch.

### Keys come from the queue, not from state

```odin
for {
	key := rl.GetKeyPressed()
	if key == .KEY_NULL { break }
	...
}
```

`IsKeyPressed` samples state at poll time, so a key whose down **and** up both
land inside one 16 ms frame is invisible to it. This is not theoretical: it broke
Enter-to-download and the Ctrl+V chord in automated testing, and a fast enough
real tap would hit it too. The event queue records every keydown.

Characters still come from `rl.GetCharPressed()` (a separate queue). Typed input
is restricted to printable ASCII; pasted bytes ≥ 0x20 pass through so UTF-8 paths
survive.

`Frame_Keys` carries `ctrl`, `enter`, `tab`, `esc` booleans so each is decided
once per frame by whoever needs it, instead of being consumed in an arbitrary
order.

Repeat: holding Backspace/Delete/Left/Right auto-repeats after 18 frames, then
every 2 — a counter in `Repeat_State`, not `IsKeyDown` alone.

### What is still hand-rolled

Horizontal scroll keeps the caret visible; text is clipped with
`BeginScissorMode`; the status line is clipped with a binary-search ellipsis
(`draw_clipped`). There is no selection, no undo, no double-click word select.

---

## 8. Configuration (`src/config.odin`)

`%LOCALAPPDATA%\vibetube\config.ini`, resolved with `SHGetKnownFolderPath` and
`FOLDERID_LocalAppData` (not a hardcoded path, so moved/redirected profiles work).

```ini
paths.last_dir=C:\Users\you\Downloads\vibetube
download.limit_mbit=16
```

- **Local, not Roaming:** both values are machine-specific. Roaming them would
  carry a `F:\…` path to a machine with no F: drive.
- **Flat `key=value` with `;` comments.** No section parser needed; unknown keys
  are ignored so the file is forward-compatible.
- **Atomic writes:** write `config.ini.tmp`, then `os.rename` (which is
  `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`). A crash cannot truncate it.
- **Never blocks startup:** unreadable/garbage input falls back to defaults and is
  rewritten. A missing key is repaired on next save.
- Default folder is `%USERPROFILE%\Downloads\vibetube`, created on demand.

Ownership: `Config` fields are heap strings owned by the struct; setters free the
old value. `config_set_*` save immediately.

---

## 9. Folder picker (`src/folder_picker.odin`)

Modern COM dialog, all bindings already in `core:sys/windows`:

```
CoCreateInstance(CLSID_FileOpenDialog, …, IID_IFileOpenDialog)
GetOptions / SetOptions(… | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST)
Show(nil)
GetResult → IShellItem.GetDisplayName(SIGDN.FILESYSPATH)
CoTaskMemFree
```

`CoInitializeEx(APARTMENTTHREADED)` is called once in `main` and released with
`CoUninitialize` — raylib does not initialise COM, so we own that.

The dialog is modal and blocks the frame loop while open. That is normal Windows
behaviour, not a bug. It opens wherever Windows last left it; `SetFolder` to the
current path is a known, small improvement not yet done.

---

## 10. Icons (`tools/make_icon.py`, `assets/`)

Two independent mechanisms, because Windows uses two:

1. **Window icon** — `SetWindowIcons` with five sizes (16/24/32/48/64), embedded
   in the binary via `#load` and decoded with `LoadImageFromMemory`. Drives the
   title bar, taskbar button and Alt-Tab.
2. **Executable icon** — `assets/vibetube.rc` (`1 ICON "assets/vibetube.ico"`)
   compiled into the exe with `-resource:`. Drives Explorer, shortcuts, and the
   *pinned* taskbar entry, which ignores the window icon.

```odin
icon32 :: #load("../assets/icon32.png")   // path is relative to the .odin file
```

The mark: a red rounded tile with a white **inverted pyramid**, reading as a "V"
for vibetube. It was originally a right-pointing play triangle and was changed
deliberately to avoid resembling a certain video platform's logo.

`tools/make_icon.py` draws at 1024 px and downsamples with LANCZOS to every size.
Pillow is a **build-time authoring tool only** — the app has no Python dependency,
and the generated PNGs/ICO are committed.

`assets/*.res` is a resource-compiler intermediate; `build.bat` deletes it and
`.gitignore` covers it.

---

## 11. Verification strategy

There is no GUI test framework here, so verification is layered:

1. **Pure unit tests**, `odin test src/<pkg>` — 26 tests across `naming`,
   `textfield`, `winargs`. Offline, instant, and they cover the parts where a bug
   is silent and data-destroying (filenames, quoting).
2. **`--selftest`** — runs the real `_worker` headlessly and prints every event.
   This is how the media pipeline is checked without the GUI.
3. **`--demo`** — drives the GUI's own `start_download` path (the exact function
   the button calls), waits for completion, optionally `--shot`s the final frame.
4. **`--shot`** — renders the UI into a render texture and exports a PNG, so UI
   changes can be inspected without a human screenshot. (A render texture is used
   because reading the window framebuffer mid-frame returns only the clear
   colour — trap 5.)
5. **Live input injection** — Win32 `mouse_event`/`keybd_event` plus
   `WM_GETICON`, `WM_GETTEXT`, `MainWindowHandle` checks to prove real clicking,
   typing, pasting, and that a child process has no console.

When adding a feature, prefer extending (1) and (2): they run in milliseconds and
need no window.

---

## 12. Traps already hit (do not re-learn these)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Exit 0, nothing downloaded | `--print` implies `--simulate` | pass `--no-simulate` |
| 2 | Text field ignores typing | raygui `GuiTextBox` owns edit mode + key queue | custom `textfield` |
| 3 | Enter / Ctrl+V silently ignored | `IsKeyPressed` samples once per poll | read `GetKeyPressed` queue |
| 4 | Fast typing loses characters | raylib char queue holds 16 per frame | accepted; paste bypasses it |
| 5 | Screenshot is blank/clear-colour | geometry is batched until `EndDrawing` | render to a texture instead |
| 6 | Success status never appears | loop breaks before draining final events | one extra `drain` before break |
| 7 | Tests fail randomly, garbage strings | `odin test` runs tests on parallel threads | `@(thread_local)` scratch buffer |
| 8 | Package-wide compile errors | a proc named `string` shadows the builtin | rename to `value` |
| 9 | cmd window flashes per download | console child of a windowed parent | own `CreateProcessW` + `CREATE_NO_WINDOW` |
| 10 | Downloads 8× too fast | yt-dlp `M` means mebibytes | convert Mbit/s to raw bytes |
| 11 | `-resource` build fails or icon missing | rc path resolution | path relative to project root; verify with `ExtractAssociatedIcon` |
| 12 | Stale icon after rebuild | Explorer icon cache | sign out; not a build problem |
| 13 | Build fails, file in use | the running exe is locked | close the app before rebuilding |

Odin specifics that bit once:

- **Parameters are immutable.** Clamp into a local (`budget := max_len`).
- **`os.Error` is `#shared_nil` union**, so compare with `nil`, not `.None`.
- **`^T` cannot be indexed**; cast to `[^]T` first.
- **`-subsystem:windows`** is required or the app gets a console. Verify the PE
  subsystem (2 = GUI) rather than assuming.

---

## 13. Extension points

**Cancel button** — `download_cancel(&d)` already exists, kills the child and
makes the worker emit `Failed: Cancelled.`. Add a second button that is enabled
only while running.

**Format / bitrate picker** — `--audio-format` and `--audio-quality` are literal
strings in `_worker`. The filename suffix `_160k` is `naming.SUFFIX`; making it
dynamic means passing the chosen bitrate into `build_filename`.

**Queue / multiple downloads** — the event queue and `Download` struct are
single-job by design (`running`, one child handle). A pool needs `Download` per
job plus a scheduler; keep `spawn_hidden` as-is, it is thread-safe per call.

**Playlists** — remove `--no-playlist`, and `%(id)s` becomes multiple IDs. The
rename step assumes one output; it would become a per-item callback
(`--print after_move:filepath` is the closer fit at that point).

**Persistence of last URL / window size** — config is already a flat key/value
store; add keys and the loader ignores unknown ones.

**Open-folder button** — `ShellExecuteW`; nothing else in the app needs it.

---

## 14. File map

| File | Responsibility |
|---|---|
| `src/main.odin` | `main`, version/title, arg parsing for dev flags, window lifecycle, capture, selftest driver |
| `src/ui.odin` | `App` state, layout, focus order, status drain, `draw_clipped` |
| `src/text_input.odin` | raylib text-field drawing + `Frame_Keys` collection + key dispatch |
| `src/download.odin` | `Download` state, worker thread, yt-dlp args, line parser, rename, event queue |
| `src/spawn.odin` | `CreateProcessW` with `CREATE_NO_WINDOW` |
| `src/config.odin` | known folders, config load/save, atomic write |
| `src/folder_picker.odin` | `IFileOpenDialog` wrapper |
| `src/textfield/` | pure single-line editor + tests |
| `src/naming/` | filename rules + tests |
| `src/winargs/` | command-line quoting + tests |
| `assets/` | icon set, `.ico`, `.rc` |
| `tools/make_icon.py` | regenerates the icon set |
| `build.bat` | `bin\vibetube.exe`, or `bin\vibetube-dev.exe` with `dev` |

---

## 15. Build and release checklist

```bat
build.bat                    :: release
build.bat dev                :: console build for --selftest/--demo
odin test src/naming         :: 11 tests
odin test src/textfield      ::  9 tests
odin test src/winargs        ::  6 tests
```

Before tagging a release:

1. Close any running instance (the exe is locked while running).
2. `build.bat` and `build.bat dev`, both exit 0.
3. All three test packages pass.
4. `bin\vibetube-dev.exe --selftest <url> <dir> --limit 16` downloads and renames.
5. `bin\vibetube-dev.exe --shot docs\screenshot.png --fill <url>` renders cleanly.
6. Window title reads `vibetube - vX.Y`; `ICON_BIG`/`ICON_SMALL` are non-zero.
7. Copy `bin\vibetube.exe`, record size and SHA-256 in `RELEASE.md`.
8. Bump `VERSION` in `src/main.odin` (it feeds the title bar only).
