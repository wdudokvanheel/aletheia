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
| `run --out PATH` | `build/markdown-corpus/results/<renderer>-<set>.json` |
| `run --preview-resources DIR` | `Sources/Aletheia/Resources/Preview` (WebKit only) |
| `run --idle-seconds S` | `3`; `0` skips the settles, the idle sample and per-view memory |
| `run --timeout S` | `300` per render |
| `run --onscreen` | off; shows the window and keeps WebKit's occlusion detection, like the app |

## Generator

Deterministic: each file has its own SplitMix64 stream seeded from `--seed` and the file name.
It writes `sizes/` (prose, mixed README-style and code-heavy at 1 KiB to 10 MiB), `tables/`,
`nesting/`, `unicode/`, `links/`, `pathological/`, typing traces in `traces/`, and
`generated-manifest.json` (`sets.generated[]`: `name`, `group`, `path`, `bytes`, `sha256`;
`traces[]`). Image fixtures are Phase 7 and are listed under `pending`.

A trace is `{name, description, base, edits: [{location, length, replacement}]}`. Ranges are
UTF-16 and apply in order, each to the text left by the previous edit.

## What is measured

Both renderers use the same window: 900 x 1200 pt on the main screen, transparent and
click-through (`--onscreen` shows it). The header records the backing scale, the screen's
refresh rate, whether the display was asleep and, for custom, the scroller style (legacy
scrollers take 15 pt from the text column).

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
  `CATransaction.flush()`, so every frame draws a full screen; the run loop turns between
  frames. Passes repeat up to `--reps`, stopping after 5,000 frames once a pass is complete.
  `scroll.over144Hz` counts frames over 1000/144 ms, `scroll.over60Hz` frames over 16.7 ms.
- **library:** the `Timings` of each repetition (`parse`, `layout`, `install`, `draw` in ms,
  `blocks`, `complete`) under `firstScreen`, `open`, `tabSwitch` and `update`. On an open,
  `layout` of the complete report sums both steps.
- **memoryMiB:** `process` is the bench's `phys_footprint` after the idle sample, with one view
  showing the document. `view` is the footprint after a new view rendered the edited document
  and settled for 1 s, minus the footprint before it was created (no other view, a 0.5 s
  settle, `malloc_zone_pressure_relief`). `viewHeap` is the malloc `size_in_use` difference
  over the same span. There are no helper processes. With `--idle-seconds 0`, `process` only,
  right after the scroll passes.
- **idleCPUPercent:** the bench's CPU over `idleSeconds`, from 1 s after the scroll passes.

## Result schema (`aletheia-markdown-bench/2`)

The file is streamed: the header first, one line per finished document, and the aggregate last.
Keys are sorted. Times are in milliseconds. Version 2 adds the custom renderer's fields; WebKit-only
header fields became optional.

```
{ "schema": "aletheia-markdown-bench/2",
  "run": { timestamp, renderer, set, manifest, documents, repetitions, limit?, filter?,
           idleSeconds, debounceMs, previewResources?,
           machine {model, cpu, cores, memoryGiB}, os {version, build}, build, git? {commit, dirty},
           webkit?, window {width, height, backingScale, screenRefreshHz, displayAsleep, placement,
           occlusionDetection?, scrollerStyle?}, firstPreviewMs, baselineMemoryMiB,
           helperAttribution?, definitions },
  "documents": [ { path, name?, bytes?, status: ok|failed|skipped, error?,
                   edit? {offset, kind},
                   ms? {startup|firstScreen|open|tabSwitch|update|updateWork|updateMain|scrollFrame:
                        {n, p50, p95, min, max}},
                   memoryMiB? {process, helpers, total, helpersByKind, helperProcesses, view?, viewHeap?},
                   idleCPUPercent? {seconds, process, helpers, total, helpersByKind},
                   library? {firstScreen|open|tabSwitch|update: [{blocks, complete, parse, layout,
                             install, draw}]},
                   scroll? {passes, frames, documentHeight, viewportHeight, over144Hz, over60Hz} } ],
  "aggregate": { documents, ok, failed, skipped, elapsedSeconds,
                 ms {metric: {n, p50, p95, max, worstP95, worstDocument}},
                 memoryTotalMiB? {n, p50, p95, min, max}, memoryViewMiB? {...},
                 idleCPUTotalPercent? {...}, scroll? {frames, over144Hz, over60Hz} } }
```

`firstPreviewMs` is a warm-up open of a small document, the first preview or view after
launch. Files the app would refuse (not UTF-8, control characters) are `skipped`. `failed`
documents keep the samples taken before the failure.
