# MarkdownViewBench

Headless corpus generator and preview benchmark for `docs/custom-markdown-view-plan.md`
(Phases 0 and 1). It measures the app's WebKit preview path or the `MarkdownView` library.
Run it in Release from anywhere inside the repository:

```sh
cd Packages/MarkdownView
swift run -c release MarkdownViewBench generate
swift run -c release MarkdownViewBench run --set curated            # WebKit, 20 repetitions
swift run -c release MarkdownViewBench run --set curated --renderer custom
swift run -c release MarkdownViewBench run --set generated --renderer custom --filter 100k
swift run -c release MarkdownViewBench run --set smoke --renderer custom --reps 1   # crash and hang check
swift run -c release MarkdownViewBench run --set own --limit 200 --reps 3 --idle-seconds 0
```

Default paths are relative to the repository root:

| Option | Default |
| --- | --- |
| `generate --out DIR` | `build/markdown-corpus/generated/` |
| `generate --seed N` | `1` |
| `run --manifest PATH` | `build/markdown-corpus/manifest.json` (from `scripts/markdown-corpus.py`) |
| `run --set` | `curated`; also `own`, `smoke`, `generated` (read from `generated/generated-manifest.json`) |
| `run --renderer` | `webkit`; `custom` measures `MarkdownPreviewView` |
| `run --reps N` | `20` |
| `run --limit N`, `--filter TEXT` | all documents; filter matches the path or curated name |
| `run --skip N` | `0`; skips the first N documents after the filter, to continue after a crash |
| `run --out PATH` | `build/markdown-corpus/results/<renderer>-<set>.json` |
| `run --preview-resources DIR` | `Sources/Aletheia/Resources/Preview` (WebKit only) |
| `run --idle-seconds S` | `3` (`0` for smoke); `0` skips the settles, the idle sample and per-view memory |
| `run --timeout S` | `300` (`30` for smoke) per render, and the watchdog's hang limit |
| `run --onscreen` | off; shows the window and keeps WebKit's occlusion detection, like the app |

## Generator

Deterministic: each file has its own SplitMix64 stream seeded from `--seed` and the file name.
It writes `sizes/` (prose, mixed README-style and code-heavy at 1 KiB to 10 MiB), `tables/`,
`nesting/`, `unicode/`, `links/`, `pathological/`, typing traces in `traces/`, and
`generated-manifest.json` (version 2; `sets.generated[]`: `name`, `group`, `path`, `bytes`,
`sha256`; `traces[]`; `images`).

### Image fixtures (Phase 7)

`images/` holds one document per fixture type, each with a block and an inline image (`png`,
`jpeg`, `gif`, `webp`, `avif`, `gif-animated`, `webp-animated`, `svg`, `svg-external`,
`missing`, `corrupt`, `huge`, `traversal`), plus `images-500.md` (all 500 small images inline),
`badges.md` (230 remote badges, in rows and in a sentence, plus three `http:` badges and a `data:` URL) and
`remote-block.md` (eight large remote block images). These documents are also in
`sets.generated`. The image files are in `images/files/` and `images/small/`:

- PNG, JPEG, GIF and AVIF (64 x 48) and the animated GIF (4 frames, 100 to 500 ms, looping)
  are written by ImageIO. If a format cannot be encoded on this macOS, its encoder is
  `unavailable`, the file is not written and its references expect `missing`.
- WebP (48 x 32) and the animated WebP (3 frames) are embedded bytes: ImageIO has no WebP encoder.
- `valid.svg` is a hand-written shape. `external.svg` also names remote images (`href`,
  `xlink:href`), an `@import`, a font, a paint server and a `<use>`; decoding it must fetch nothing.
- `corrupt.png` is a PNG signature and a valid 64 x 48 IHDR, then 4 KiB of seeded noise.
- `huge-10000.png` is a real 10,000 x 10,000 flat gray PNG (about 450 KiB).
- `small/000.png` to `499.png` are 16 x 16 seeded colors.
- `files/escape.png` links to `../../images-outside/real.png`, outside the folder;
  `files/inside-link.png` links to `valid.png`.

Remote images use `https://img.example.invalid/...`, a host that cannot resolve, so only the
test stub can serve them. Their `width` and `height` are the size the stub should serve.

`images` in the manifest has `encoders` (format to `ImageIO <type>`, `embedded`,
`hand-written` or `unavailable`), `files[]` (`path`, `kind`, `width`, `height`, `frames`,
`bytes`, `sha256`, or `symlink` for a link) and `references[]`, one per image in document
order: `document`, `source` (as written), `placement` (`block` or `inline`), `kind`, `path`
(relative sources only, `..` resolved; a leading `..` means it escapes the root), `width`,
`height`, and `expected`: `ok`, `missing`, `corrupt`, `too-large` or `blocked`. Local SVG
expects `blocked` because local images are raster only; HTTP, `data:`, `file:`, absolute
paths, traversal and the escaping link are `blocked`.

Reruns are byte-identical on the same macOS (checked with `diff -r` on two runs); none of
the encoders embeds a timestamp. ImageIO output can change between macOS versions.

A trace is `{name, description, base, edits: [{location, length, replacement}]}`. Ranges are
UTF-16 and apply in order, each to the text left by the previous edit.

## What is measured

Both renderers use the same window: 900 x 1200 pt on the main screen, transparent and
click-through (`--onscreen` shows it). The header records the backing scale, the screen's
refresh rate, whether the display was asleep, whether the window was occluded and, for
custom, the scroller style (legacy scrollers take 15 pt from the text column). A transparent
window, or any window while the display sleeps, is occluded, and AppKit then displays it at
about 60 Hz instead of the screen's rate; custom latencies that wait for a draw include that.

### WebKit

WebKit mode copies the app's preview path: `PreviewResources` serving the bundle files from
`--preview-resources`, the same `index.html`, CSS and JS, `invalidatePreview`,
`setPreviewSearch`, `renderMarkdown` then `commitPreview`, the 200 ms debounce on edits, and
the System palette theme. The preview turns off WebKit's window occlusion detection (private
`_setWindowOcclusionDetectionEnabled:`), because WebKit stops animation frames for occluded
pages, and a transparent window, or any window while the display sleeps, counts as occluded.

- **rendered:** `commitPreview` has returned (the last point the app can observe), then one
  more `callAsyncJavaScript` forces style and layout and resolves after the next
  `requestAnimationFrame` plus a zero timeout. Images are not awaited.
- **startup:** new preview (web view, configuration, scheme handler, `index.html`) to `didFinish`.
- **open:** new preview to the document rendered; includes startup. Each repetition uses a new preview.
- **tabSwitch:** a warm preview showing a small other document, `show(document)` to rendered.
- **update:** one keystroke typed at the end of the paragraph line nearest the middle (`edit`),
  `contentChanged()` to rendered, including the debounce. **updateWork** starts after the debounce.
- **memoryMiB:** `phys_footprint` of the bench (`task_info`) plus WebKit helpers
  (`proc_pid_rusage`), with one preview showing the document, after a 1 s settle and the idle
  sample. Helpers are XPC children of launchd, so they are found as `com.apple.WebKit.*`
  processes with the bench's responsible process that started after the bench.
- **idleCPUPercent:** user plus system CPU over `idleSeconds`, from 1 s after the last update,
  as a percent of one core.
- Percentiles are nearest rank. The aggregate pools every repetition of every `ok` document.
- Signposts (subsystem `local.aletheia.MarkdownViewBench`, Points of Interest): `document`,
  `open`, `startup`, `tabSwitch`, `update`, `debounce`, `renderMarkdown` (parse and HTML in
  WebKit), `commitPreview` (DOM install), `frame`, `idle`, `scroll`, `generate`. The library
  adds `parse`, `layout`, `install` and `draw` under subsystem `MarkdownView`.

### Custom

Custom mode hosts a `MarkdownPreviewView` as the window's content view, with the standard
palette. It shows a document as the app's `CustomMarkdownPreview` does, `setSource` and then
`scrollFraction = 0` (the document's top). The library has no debounce; the bench applies the
app's 200 ms debounce to edits.

- **rendered:** the view's `onTimings` callback for the complete snapshot
  (`Timings.isComplete`). The view sends it from the main queue right after the first draw
  that follows the install, so it includes AppKit's wait for its next display cycle.
- **startup:** new view placed in the window and tiled, before `setSource`.
- **firstScreen:** `setSource` on the new view until the first snapshot is drawn: the
  visible-area step of an open, or the complete snapshot when that covers the visible area.
- **open:** new view to the document rendered; includes startup. Each repetition uses a new view.
- **tabSwitch:** a warm view showing a small other document, `setSource(document)` to rendered.
- **update:** one keystroke as in WebKit mode, debounce then `setSource`, to rendered.
  **updateWork** starts at `setSource`. **updateMain** is the update's `install + draw`
  from the library's `Timings`: its main-thread time.
- **scrollFrame:** passes from top to bottom in viewport-height steps. Each frame is
  `NSView.scroll`, `setNeedsDisplay(visibleRect)`, `window.displayIfNeeded()` and
  `CATransaction.flush()`; the flush commits and draws, so every frame draws a full screen
  without waiting for AppKit's display cycle. The run loop turns between frames. Passes repeat up to `--reps`, stopping after 5,000 frames once a pass is complete.
  `scroll.over144Hz` counts frames over 1000/144 ms, `scroll.over60Hz` frames over 16.7 ms.
- **library:** the `Timings` of each repetition (`parse`, `layout`, `install`, `draw` in ms,
  `blocks`, `complete`) under `firstScreen`, `open`, `tabSwitch` and `update`. On an open,
  `layout` of the complete report sums both steps.
- **memoryMiB:** `process` is the bench's `phys_footprint` after the idle sample, with one view
  showing the document. `view` is the footprint after a new view rendered the edited document
  and settled for 1 s, minus the footprint before it was created (no other view, a 0.5 s
  settle, `malloc_zone_pressure_relief`). `viewHeap` is the malloc `size_in_use` difference
  over the same span. There are no helper processes. With `--idle-seconds 0`, `process` only,
  right after the scroll passes. `view` is noisy for small documents, since the new view
  reuses pages freed earlier and can come out negative; `viewHeap` is the steadier measure.
- **idleCPUPercent:** the bench's CPU over `idleSeconds`, from 1 s after the scroll passes.

### Smoke set, watchdog and crashes

The smoke set runs a watchdog: a `CFRunLoopObserver` on the main run loop records the longest
span the main thread spent between run loop activities (waits excluded), as `blockedMs` per
document. A document is over the limit when `blockedMs` or any open exceeds 1 s; such
documents and failures are printed, other rows are not, with progress every 500 documents. If
one span exceeds `--timeout`, a watchdog thread ends the run with exit status 3.

Each document's line is written as `{"path":...,"status":"running"}` first and replaced when
it finishes, so the file names the document even if the process is killed. On a fatal signal
(including Swift traps, from any thread) or a hang, the bench replaces that line with the
document as `crashed` (`error` gives the signal) or `hung`, closes the file with
`"aggregate":null,"interrupted":{document, index, reason}`, and prints the `--skip` value that
continues after it. A stack overflow off the main thread cannot run the handler; the
`running` line still names the document.

## Result schema (`aletheia-markdown-bench/2`)

The file is streamed: the header first, one line per finished document, and the aggregate last.
Keys are sorted. Times are in milliseconds. Version 2 adds the custom renderer's fields, the
watchdog, `skip`, the `running` line and the interrupted ending; WebKit-only header fields
became optional.

```
{ "schema": "aletheia-markdown-bench/2",
  "run": { timestamp, renderer, set, manifest, documents, repetitions, limit?, filter?, skip?,
           idleSeconds, debounceMs, previewResources?,
           machine {model, cpu, cores, memoryGiB}, os {version, build}, build, git? {commit, dirty},
           webkit?, window {width, height, backingScale, screenRefreshHz, displayAsleep, placement,
           occluded, occlusionDetection?, scrollerStyle?}, firstPreviewMs, baselineMemoryMiB,
           helperAttribution?, watchdog? {limitMs, hangSeconds}, definitions },
  "documents": [ { path, name?, bytes?, status: ok|failed|skipped|running|crashed|hung, error?,
                   edit? {offset, kind},
                   ms? {startup|firstScreen|open|tabSwitch|update|updateWork|updateMain|scrollFrame:
                        {n, p50, p95, min, max}},
                   memoryMiB? {process, helpers, total, helpersByKind, helperProcesses, view?, viewHeap?},
                   idleCPUPercent? {seconds, process, helpers, total, helpersByKind},
                   library? {firstScreen|open|tabSwitch|update: [{blocks, complete, parse, layout,
                             install, draw}]},
                   scroll? {passes, frames, documentHeight, viewportHeight, over144Hz, over60Hz},
                   blockedMs? } ],
  "aggregate": { documents, ok, failed, skipped, elapsedSeconds,
                 ms {metric: {n, p50, p95, max, worstP95, worstDocument}},
                 memoryTotalMiB? {n, p50, p95, min, max}, memoryViewMiB? {...},
                 idleCPUTotalPercent? {...}, scroll? {frames, over144Hz, over60Hz},
                 watchdog? {limitMs, over [{path, blockedMs, openMs}], worstBlockedMs,
                            worstBlockedDocument, worstOpenMs, worstOpenDocument} } | null,
  "interrupted"?: {document, index, reason: crashed|hung} }
```

`firstPreviewMs` is a warm-up open of a small document, the first preview or view after
launch. Files the app would refuse (not UTF-8, control characters) are `skipped`. `failed`
documents keep the samples taken before the failure.
