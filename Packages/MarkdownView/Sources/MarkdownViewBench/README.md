# MarkdownViewBench

Headless corpus generator and preview benchmark for `docs/custom-markdown-view-plan.md`
(Phase 0). Run it in Release from anywhere inside the repository:

```sh
cd Packages/MarkdownView
swift run -c release MarkdownViewBench generate
swift run -c release MarkdownViewBench run --set curated            # 20 repetitions
swift run -c release MarkdownViewBench run --set generated --filter 100k --reps 5
swift run -c release MarkdownViewBench run --set own --limit 200 --reps 3 --idle-seconds 0
```

Default paths are relative to the repository root:

| Option | Default |
| --- | --- |
| `generate --out DIR` | `build/markdown-corpus/generated/` |
| `generate --seed N` | `1` |
| `run --manifest PATH` | `build/markdown-corpus/manifest.json` (from `scripts/markdown-corpus.py`) |
| `run --set` | `curated`; also `own`, `smoke`, `generated` (read from `generated/generated-manifest.json`) |
| `run --renderer` | `webkit`; `custom` is reserved and reports that it is unavailable |
| `run --reps N` | `20` |
| `run --limit N`, `--filter TEXT` | all documents; filter matches the path or curated name |
| `run --out PATH` | `build/markdown-corpus/results/<renderer>-<set>.json` |
| `run --preview-resources DIR` | `Sources/Aletheia/Resources/Preview` |
| `run --idle-seconds S` | `3`; `0` skips the settle and the idle sample |
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

WebKit mode copies the app's preview path: `PreviewResources` serving the bundle files from
`--preview-resources`, the same `index.html`, CSS and JS, `invalidatePreview`,
`setPreviewSearch`, `renderMarkdown` then `commitPreview`, the 200 ms debounce on edits, and
the System palette theme. The window is 900 x 1200 pt on the main screen, transparent and
click-through. The preview turns off WebKit's window occlusion detection (private
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
  WebKit), `commitPreview` (DOM install), `frame`, `idle`, `generate`.

## Result schema (`aletheia-markdown-bench/1`)

The file is streamed: the header first, one line per finished document, and the aggregate last.
Keys are sorted. Times are in milliseconds.

```
{ "schema": "aletheia-markdown-bench/1",
  "run": { timestamp, renderer, set, manifest, documents, repetitions, limit?, filter?,
           idleSeconds, debounceMs, previewResources,
           machine {model, cpu, cores, memoryGiB}, os {version, build}, build, git? {commit, dirty},
           webkit, window {width, height, backingScale, screenRefreshHz, displayAsleep, placement,
           occlusionDetection}, firstPreviewMs, baselineMemoryMiB, helperAttribution, definitions },
  "documents": [ { path, name?, bytes?, status: ok|failed|skipped, error?, edit? {offset, kind},
                   ms? {startup|open|tabSwitch|update|updateWork: {n, p50, p95, min, max}},
                   memoryMiB? {process, helpers, total, helpersByKind, helperProcesses},
                   idleCPUPercent? {seconds, process, helpers, total, helpersByKind} } ],
  "aggregate": { documents, ok, failed, skipped, elapsedSeconds,
                 ms {metric: {n, p50, p95, max, worstP95, worstDocument}},
                 memoryTotalMiB? {n, p50, p95, min, max}, idleCPUTotalPercent? {...} } }
```

`firstPreviewMs` is a warm-up open of a small document, the first preview after launch. Files
the app would refuse (not UTF-8, control characters) are `skipped`. `failed` documents keep the
samples taken before the failure.
