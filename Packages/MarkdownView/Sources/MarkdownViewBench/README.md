# MarkdownViewBench

Headless corpus generator and preview benchmark for `docs/custom-markdown-view-plan.md`
(Phases 0, 1 and 4). It measures the app's WebKit preview path or the `MarkdownView` library.
Run it in Release from anywhere inside the repository:

```sh
cd Packages/MarkdownView
swift run -c release MarkdownViewBench generate
swift run -c release MarkdownViewBench run --set curated            # WebKit, 20 repetitions
swift run -c release MarkdownViewBench run --set curated --renderer custom
swift run -c release MarkdownViewBench run --set generated --renderer custom --filter 100k
swift run -c release MarkdownViewBench run --set smoke --renderer custom --reps 1   # crash and hang check
swift run -c release MarkdownViewBench run --set generated --renderer custom --filter images --reps 5
swift run -c release MarkdownViewBench run --verify-images                        # image provider self-check
swift run -c release MarkdownViewBench run --set own --limit 200 --reps 3 --idle-seconds 0
swift run -c release MarkdownViewBench trace --renderer custom --trace all --reps 5   # typing traces
swift run -c release MarkdownViewBench trace --renderer webkit --trace table-cell-1m --interval 50
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
| `run --image-latency MS` | `0`; custom only, delays each remote image to simulate the network (also for `trace`) |
| `run --verify-images` | off; only runs the image provider self-check against `--manifest` (default the generated manifest) and exits 1 on a mismatch |
| `trace --manifest PATH` | `build/markdown-corpus/generated/generated-manifest.json` (its `traces[]`) |
| `trace --renderer` | `webkit`; `custom` |
| `trace --trace` | `all`; or names separated by commas |
| `trace --reps N` | `5`; each repetition replays the whole trace in a new preview |
| `trace --interval MS` | `0`: each edit once the previous one rendered; above 0, edits fire on that schedule |
| `trace --out PATH` | `build/markdown-corpus/results/<renderer>-traces.json`, `-traces-<MS>ms.json` with an interval |
| `trace --preview-resources DIR`, `--timeout S` | as for `run`; the timeout (`60`) is per wait for a render |

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

### Image provider (custom mode)

The library never reads files itself, so custom mode gives every view `BenchImageProvider`
(`BenchImageProvider.swift`), a small bench-only provider written to the plan's Phase 7 rules
rather than importing the app's `PreviewImageLoader`:

- **Local:** a source resolves against a per-request document base, as the WebKit page does,
  so `..` out of the document's folder and absolute paths are `blocked`. The file is then
  canonicalized (symlinks resolved) and must still be inside the canonical folder (`blocked`
  otherwise, also for a dangling escaping link), exist as a regular file (`missing`) and have a
  raster extension, PNG, JPEG, GIF, WebP or AVIF (`blocked`: local SVG).
- **Remote:** HTTPS only, without credentials; `http:`, `data:`, `file:` and every other scheme
  are `blocked`. `https://img.example.invalid/...` is served by `RemoteFixtures`, with no
  network: `/fixtures/NAME` is `images/files/NAME`, and the other manifest references
  (`/badge/...`, `/block/...`) are synthesized once at run start at the manifest's `width` and
  `height`: PNG, JPEG and GIF by ImageIO, SVG and extensionless badges as a hand-written SVG,
  and WebP as PNG bytes (ImageIO has no WebP encoder; the decoder sniffs the bytes). Any other
  host is a `network` failure. `--image-latency MS` sleeps before serving each remote image
  (cancellable), so loads overlap as they would on a network; local files have no delay.
  Remote SVG is rasterized with AppKit's renderer at the display size, as the app does.
- **Decoding** runs off the main thread: ImageIO reads the header, refuses over 50 M pixels
  (`too-large`) or an image that does not decode completely (`corrupt`), and creates a thumbnail
  at most the display box times the scale. Animated GIF and WebP keep their `CGImageSource` and
  give the view `frameDelays` and a frame function. There is no decoded-image cache (the app has
  a 64 MiB one), so every request decodes; remote bytes are in memory, like a warm disk cache.

`run --verify-images` loads every reference in `images.references` (762, one per document and
source) and checks the outcome against `expected`, the natural size of each `ok` image against
`width` and `height`, the frame count of the animated files, and that a request for half the
natural width at scale 1 comes back downsampled.

Reruns are byte-identical on the same macOS (checked with `diff -r` on two runs); none of
the encoders embeds a timestamp. ImageIO output can change between macOS versions.

A trace is `{name, description, base, edits: [{location, length, replacement}]}`. Ranges are
UTF-16 and apply in order, each to the text left by the previous edit. There are five, on
`sizes/mixed-100k.md` and `tables/rows-1500-cols-4.md` (row 750), and the same five with a
`-1m` suffix on `sizes/mixed-1m.md` and a 7,200-row, 4-column table of about 1 MiB (row 3,600;
seeded as `rows-7200-cols-4`, only written as the trace's base) for the Phase 4 exit. The `-1m`
traces left the 100 KiB traces and every other file byte-identical.

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
- **Images:** the bench's scheme handler is the app's, so local raster images inside the
  document's canonical folder are served exactly as in the app, and everything else is refused.
  **WebKit shows no remote images, by the owner's decision:** the app's page removes remote,
  absolute, `data:` and `file:` images before insertion and its CSP allows only
  `aletheia-preview://document`, so the badge and remote-block documents show no images there
  while custom mode loads them from the fixtures. WebKit loads every image of the page, not
  only the visible ones, and has no pixel cap (it decodes `huge-10000.png`).
  **imagesLoaded:** after each open, new preview until every `img` element has loaded or failed.
  `images`: `requested` is the `img` elements left in the page (block and inline references of
  one file count twice), `loaded` those that decoded; `served` and `refused` count the scheme
  handler's image requests over the opens.
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
- **Images:** each view gets the bench's image provider, with the document's folder as the base
  for relative sources. After every render that asked for images (opens, tab switches, updates
  and the scroll passes) the bench waits until no request is in flight and neither the provider
  nor the view did anything for 150 ms, then drops the relayout renders, so no measurement takes
  an image relayout for its own render. That wait is not part of any other metric.
  **imagesLoaded:** per open, new view until the last image load or failure reached the view.
  The view asks only for the visible images and those within a screen below and above (at most
  8 at a time, by source, so a block and an inline reference to one file are one request), and
  may ask again at a sharper size once the natural size is known; all of those count.
  **imagesShown:** per open with a loaded image, new view until its last complete draw by then:
  the open's own render when every load finished before it, else the last relayout for image
  sizes. `images` per document: `requested`, `loaded`, `failed`, `cancelled` and `failures` by
  reason for the last open; `retainedCount` and `retainedBytes` (the view's
  `retainedImageCount`/`retainedImageBytes`) once that open's images settled, `endRetained*` after
  the scroll passes and the idle sample, and `documentRequests` over the whole measurement.
  `memoryMiB` includes the decoded images the view keeps (16 MiB cap per view).

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

## Trace replay (`trace`)

Each repetition opens a new preview on the trace's base document (`open`, as in `run`),
scrolls so the first edit's position is 30% down the viewport, settles for 300 ms, then
applies the edits to an `NSMutableString` as an editor would and hands the preview the result:

- **custom:** `setSource(text)` at once, no debounce; the view runs one update at a time,
  coalesces sources set meanwhile and pauses after slow updates (`UpdatePolicy.standard`,
  recorded in the header). The view has the bench's image provider (relative sources resolve in
  `traces/`; the current bases have no images), and the open waits for any images to settle
  before the scroll. The scroll target comes from the snapshot's block tops,
  interpolated within the block, so a table row deep in one block is approximate.
- **webkit:** the document text changes, then `contentChanged()`, with the app's 200 ms
  debounce. `workMs` starts after the debounce, as `updateWork` does in `run`. The scroll is
  a fraction of the page height.

**rendered** is as in `run`: the custom view's `onTimings` for the complete snapshot, or
WebKit's commit plus the frame script. An edit's `ms` is its keystroke (the call above) to the
render that shows it. With `--interval 0` the next edit is applied right after that render.
With an interval, edit k fires at (k - 1) x interval whatever has rendered, and the
repetition ends when the last edit has rendered.

**Coalescing.** A render can show a later edit than the one that started it: WebKit renders
the text at the end of the debounce, and the custom view takes the newest source when an
update starts. Edits between two renders that were never shown are `coalescedInto` the edit
the next render showed; that edit records `coalesced` (how many) and `sinceOldestMs` (the
oldest covered edit's keystroke to the render), and its own `ms` runs from its own keystroke.
`finalMs` is the last edit's `ms`, the latency of the final state. An installed custom
snapshot that was replaced before it drew never reports `onTimings` and counts as coalesced.

**Which edit a render showed.** WebKit: the bench stamps the document with the edit number
and the render reports the number it copied. Custom: the view does not say. Because an update
takes the newest source when it starts, which is inside `setSource` or right after the
previous install, install r shows one of the edits from the newest at install r - 1 to the
newest at install r. Each install keeps the blocks (`sourceRange`, `sourceText`) around the
candidate edits; after the repetition the texts are replayed and the newest candidate those
blocks match is taken. Texts that differ only outside every block (a trailing newline) render
alike and count as the newer edit. `verified: false` (and `unverified` per repetition) means
none matched and the newest candidate was used; sequential runs must show every edit rendered.

Custom records per edit `mainMs` (`Timings.mainThread`, install plus first draw), `wallMs`,
`pauseMs`, `reusedBlocks`, `laidOutBlocks` and `library` (`LibraryTimings` as in `run`).
Summaries pool every rendered edit of every repetition (nearest rank): `ms.update`,
`ms.updateWork` (WebKit), `ms.updateMain`, `ms.updateWall`, `ms.pause` (custom), `ms.open`,
`ms.final`, `laidOutBlocks`, and the counts `fired`, `rendered`, `coalesced`, `over16ms`,
`overMain4ms`. The signposts add `trace` per repetition and a `keystroke` event per edit.

Caveats: in sequential mode each keystroke lands just after a draw, so a custom update waits
nearly a whole display interval for its first draw (16.7 ms at the transparent window's
60 Hz, see above); `wallMs` is the library's cost without that wait, and burst mode lands
keystrokes at arbitrary frame phases. An edit outside the visible area, or one the view finds
invisible, installs without a draw and reports at once.

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
           helperAttribution?, watchdog? {limitMs, hangSeconds}, definitions,
           imageProvider? {provider, latencyMs, remoteFixtures} },
  "documents": [ { path, name?, bytes?, status: ok|failed|skipped|running|crashed|hung, error?,
                   edit? {offset, kind},
                   ms? {startup|firstScreen|open|tabSwitch|update|updateWork|updateMain|scrollFrame:
                        {n, p50, p95, min, max}},
                   memoryMiB? {process, helpers, total, helpersByKind, helperProcesses, view?, viewHeap?},
                   idleCPUPercent? {seconds, process, helpers, total, helpersByKind},
                   library? {firstScreen|open|tabSwitch|update: [{blocks, complete, parse, layout,
                             install, draw}]},
                   scroll? {passes, frames, documentHeight, viewportHeight, over144Hz, over60Hz},
                   images? {requested, loaded, failed, cancelled?, failures?, retainedCount?, retainedBytes?,
                            endRetainedCount?, endRetainedBytes?, documentRequests?, served?, refused?},
                   blockedMs? } ],
  "aggregate": { documents, ok, failed, skipped, elapsedSeconds,
                 ms {metric: {n, p50, p95, max, worstP95, worstDocument}},
                 memoryTotalMiB? {n, p50, p95, min, max}, memoryViewMiB? {...},
                 idleCPUTotalPercent? {...}, scroll? {frames, over144Hz, over60Hz},
                 watchdog? {limitMs, over [{path, blockedMs, openMs}], worstBlockedMs,
                            worstBlockedDocument, worstOpenMs, worstOpenDocument} } | null,
  "interrupted"?: {document, index, reason: crashed|hung} }
```

The image fields (`run.imageProvider`, `documents[].images`, and `imagesLoaded` and
`imagesShown` under `ms` and the aggregate) are optional additions to version 2: documents
without images and older readers are unaffected.

`firstPreviewMs` is a warm-up open of a small document, the first preview or view after
launch. Files the app would refuse (not UTF-8, control characters) are `skipped`. `failed`
documents keep the samples taken before the failure.

## Trace schema (`aletheia-markdown-bench/3`)

Version 3 is the `trace` file; `run` still writes version 2, unchanged. The file is written
once at the end. `run` is the version 2 header (with `imageProvider` for custom) with `set: "traces"`, `documents` the number
of traces, `filter` the `--trace` names, `debounceMs` 0 for custom, and the trace definitions.

```
{ "schema": "aletheia-markdown-bench/3",
  "run": { ...version 2 header... },
  "trace": { mode: sequential|burst, intervalMs, updatePolicy? {budgetMs, pauseFactor, maximumPauseMs} },
  "traces": [ { name, description, path, baseBytes, edits, status: ok|failed, error?,
                ms? {open|update|updateWork|updateMain|updateWall|pause|final: {n, p50, p95, min, max}},
                laidOutBlocks?, fired, rendered, coalesced, over16ms, overMain4ms?,
                repetitions: [ { openMs, scrollY, elapsedMs, rendered, coalesced, unverified?, finalMs?,
                                 edits: [ { edit, firedAtMs, rendered, ms?, coalescedInto?, coalesced?,
                                            sinceOldestMs?, workMs?, mainMs?, wallMs?, pauseMs?,
                                            reusedBlocks?, laidOutBlocks?, verified?,
                                            library? {blocks, complete, parse, layout, install, draw} } ] } ] } ] }
```
