#!/usr/bin/env python3
"""Index real Markdown files for the custom preview test corpus.
Usage: python3 scripts/markdown-corpus.py [root]   (root defaults to ~/workspace)
Writes build/markdown-corpus/manifest.json with paths and metadata only; files are
never copied. See "Test corpus" in docs/custom-markdown-view-plan.md.
"""
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import unquote

MAX_BYTES = 50 << 20
# Path segments of vendored or generated content, left out of the `own` set.
VENDORED = ('node_modules', 'vendor', 'cargo/registry', 'cargo/git', '.cargo', '.build', 'build', 'dist',
            'target', 'Pods', 'Carthage', 'DerivedData', '.git', 'bower_components', '.venv', 'venv',
            'site-packages', '.tox', '.gradle', '.next', '.nuxt', '.cache', '.pnpm-store', '.yarn',
            '.dart_tool', '.pub-cache', '.swiftpm', 'third_party', 'third-party', '__pycache__')
# Feature flag -> the per-file count that sets it, in the plan's inventory order.
FEATURES = {'codeFences': 'codeBlocks', 'tables': 'tables', 'images': 'images', 'remoteImages': 'remoteImages',
            'localImages': 'localImages', 'rawHtml': 'htmlLines', 'emoji': 'emoji', 'htmlImg': 'htmlImages',
            'frontMatter': 'frontMatter', 'taskLists': 'taskItems', 'crlf': 'crlfLines', 'alerts': 'alerts',
            'cjk': 'cjk', 'details': 'details', 'unclosedFence': 'unclosedFence', 'footnotes': 'footnotes',
            'mermaid': 'mermaid', 'rtl': 'rtl', 'math': 'math', 'links': 'links'}
REG = 'dkdmk-worktrees/fog-root-20261002/cargo/registry/src/index.crates.io-1949cf8c6b5b557f'
GEMS = 'serenity-remote-harness/vendor/bundle/ruby/4.0.0/gems'
# name, selector (set, required features, metrics to maximize or a size to approach), preferred path, reason
CURATED = [
    ('largest file', ('smoke', [], ['bytes']), f'{REG}/ratatui-0.29.0/CHANGELOG.md',
     'Largest file (305 KiB), 364 code blocks, HTML <img>'),
    ('largest CRLF file', ('smoke', ['crlf'], ['bytes']), f'{REG}/ratatui-0.26.3/CHANGELOG.md',
     '233 KiB with CRLF line endings'),
    ('most list items', ('smoke', [], ['listItems']), f'{GEMS}/aws-partitions-1.1286.0/CHANGELOG.md',
     '185 KiB of long lists'),
    ('largest own file', ('own', [], ['bytes']), 'bikely/bikely-os/docs/BIKELY_OS_CONTEXT.md',
     'Largest own-project document (98 KiB)'),
    ('most tables', ('smoke', ['tables'], ['tables']), 'dkdmk/agents/docs/systems.md', '106 tables in 38 KiB'),
    ('largest table with remote images', ('smoke', ['tables', 'remoteImages'], ['tableImages']),
     f'{REG}/objc2-0.6.4/src/topics/about_generated/list_data.md', '180-row table with 180 remote images'),
    ('largest own table', ('own', ['tables'], ['maxTableRows']), 'bikely/reports/refund-case-12625-12971/report.md',
     '119-row table (own project)'),
    ('widest table with emoji', ('smoke', ['tables', 'emoji'], ['maxTableColumns', 'emoji']),
     f'{GEMS}/unicode-emoji-4.2.0/README.md', '13-column table, 397 emoji'),
    ('most own task items', ('own', ['taskLists'], ['taskItems']),
     'dkdmk-worktrees/map86-party/original-dk-gameplay-progress.md', '93 task items'),
    ('deepest list nesting', ('smoke', [], ['listDepth', 'taskItems']), f'{REG}/exr-1.74.0/README.md',
     '96 tasks, deepest list nesting'),
    ('most raw HTML', ('smoke', ['rawHtml'], ['htmlLines']), f'{GEMS}/fastlane-2.239.0/README.md', '189 raw HTML lines'),
    ('longest line', ('smoke', [], ['longestLine']),
     f'{GEMS}/fastlane-2.239.0/fastlane/lib/fastlane/actions/docs/run_tests.md', '4,842-character line'),
    ('details', ('smoke', ['details'], ['details']), f'{REG}/axum-0.7.9/CHANGELOG.md', '<details> blocks'),
    ('RTL text', ('smoke', ['rtl'], ['rtl']), 'shaghlaty/CHANGES-SINCE-HANDOVER.md', 'Arabic text (right-to-left)'),
    ('CJK', ('smoke', ['cjk'], ['cjk']), f'{REG}/unicode-truncate-1.1.0/README.md', 'CJK text'),
    ('unclosed fence', ('smoke', ['unclosedFence'], []),
     'bikely/safebikely/scripts/azure-iot-sdk-python/c/doc/devbox_setup.md', 'Unclosed code fence'),
    ('most local images', ('smoke', ['localImages'], ['localImagesFound']),
     'dotfiles/zsh/plugins/zsh-syntax-highlighting/README.md', '8 local images on disk'),
    ('most own local images', ('own', ['localImages'], ['localImagesFound']), 'kombuchakeeper/README.md',
     '6 local images (own project)'),
    ('most own remote images', ('own', ['remoteImages'], ['remoteImages']), 'wdudokvanheel/README.md',
     '42 remote images (own profile README)'),
    ('front matter', ('smoke', ['frontMatter'], []),
     'dotfiles/zsh/plugins/zsh-autosuggestions/.github/ISSUE_TEMPLATE/bug-report.md', 'YAML front matter'),
    ('alerts', ('smoke', ['alerts'], ['alerts']), f'{GEMS}/multi_json-1.21.2/README.md',
     'GitHub alerts (out of scope; must degrade cleanly)'),
    ('footnotes', ('smoke', ['footnotes'], ['footnotes']), f'{REG}/shlex-1.3.0/src/quoting_warning.md',
     'Footnotes (out of scope; must degrade cleanly)'),
    ('own docs with tables and links', ('own', ['tables', 'links'], 32 << 10), 'aletheia/docs/editor-plan.md',
     'Everyday use: own docs with tables and links'),
    ('typical small file', ('own', [], 2 << 10), 'aletheia/AGENTS.md', 'Typical small file (2 KiB)'),
]

FENCE = re.compile(r'(`{3,}|~{3,})\s*([^\s{]*)(.*)')
QUOTE = re.compile(r'(?:[ \t]*>)+ ?')
ALERT = re.compile(r'[ \t]*>[ \t]*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]', re.I)
CODE_SPAN = re.compile(r'(`+).+?\1')
DELIMITER = re.compile(r'[ \t]*:?-+:?[ \t]*')
LIST_ITEM = re.compile(r'([ \t]*)(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$)')
TASK = re.compile(r'\[[ xX]\](?:[ \t]|$)')
IMAGE = re.compile(r'!\[(?:[^\][]|\[[^\]]*\])*\]\([ \t]*<?([^\s)>]*)')
REF_IMAGE = re.compile(r'!\[((?:[^\][]|\[[^\]]*\])*)\]\[([^\]]*)\]')
REF_DEF = re.compile(r'\[([^\]^][^\]]*)\]:[ \t]*<?([^\s>]+)')
LINK = re.compile(r'(?<!!)\[[^\]]*\]\(')
HTML = re.compile(r'<(?:!--|/?(?:a|abbr|b|blockquote|br|center|code|dd|del|details|div|dl|dt|em|figcaption|'
                  r'figure|font|h[1-6]|hr|i|iframe|img|input|ins|kbd|li|ol|p|picture|pre|s|samp|small|source|'
                  r'span|strong|sub|summary|sup|table|tbody|td|tfoot|th|thead|tr|u|ul|video)(?=[\s/>]|$))', re.I)
IMG_SRC = re.compile(r'<img\b[^>]*?\bsrc[ \t]*=[ \t]*["\']?([^"\'\s>]+)', re.I)
FOOTNOTE = re.compile(r'\[\^[^\]]+\]:')
MATH = re.compile(r'^\$\$|\$\$[^$]+\$\$')
EMOJI = re.compile('[\U0001F1E6-\U0001F1FF\U0001F300-\U0001F64F\U0001F680-\U0001F6FF\U0001F900-\U0001FAFF'
                   '\u2600-\u27BF\u2B50\u2B55]')
CJK = re.compile('[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF]')
RTL = re.compile('[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFC]')


def vendored(rel):
    s = '/' + rel
    return any(f'/{v}/' in s for v in VENDORED)


def in_node_modules(rel):
    return '/node_modules/' in '/' + rel


def cells(s):
    s = s.strip()
    s = s[1:] if s.startswith('|') else s
    s = s[:-1] if s.endswith('|') and not s.endswith('\\|') else s
    return s.split('|')


def classify(path):
    """Line-by-line feature heuristics; counts are approximate by design."""
    m = {'lines': 0, 'longestLine': 0, **dict.fromkeys(FEATURES.values(), 0), 'localImagesFound': 0,
         'maxTableRows': 0, 'maxTableColumns': 0, 'tableImages': 0, 'listItems': 0, 'listDepth': 0}
    folder = os.path.dirname(path)
    fence = front = prev = None
    table_rows = -1
    stack, refs, defs = [], [], {}

    def add_image(url):
        m['images'] += 1
        lower = url.lower()
        if lower.startswith(('http://', 'https://', '//')):
            m['remoteImages'] += 1
        elif not lower.startswith('data:'):
            m['localImages'] += 1
            local = unquote(url.split('#')[0].split('?')[0])
            m['localImagesFound'] += bool(local) and os.path.isfile(os.path.join(folder, local))

    with open(path, encoding='utf-8-sig', errors='replace', newline='') as f:
        for raw in f:
            line = raw.rstrip('\r\n')
            m['lines'] += 1
            m['crlfLines'] += raw.endswith('\r\n')
            m['longestLine'] = max(m['longestLine'], len(line))
            if not line.isascii():
                m['emoji'] += len(EMOJI.findall(line))
                m['cjk'] += len(CJK.findall(line))
                m['rtl'] += len(RTL.findall(line))
            if m['lines'] == 1 and line.strip() in ('---', '+++'):
                front = line.strip()
                continue
            if front:
                if line.strip() in (front, '...'):
                    front, m['frontMatter'] = None, 1
                continue
            content = line[QUOTE.match(line).end():] if line.lstrip().startswith('>') else line
            s = content.strip()
            if fence:
                if s.startswith(fence) and s.strip(fence[0]) == '':
                    fence = None
                continue
            if line.lstrip().startswith('>') and ALERT.match(line):
                m['alerts'] += 1
            if s.startswith(('```', '~~~')):
                g = FENCE.match(s)
                if not (g.group(1)[0] == '`' and '`' in g.group(2) + g.group(3)):
                    fence = g.group(1)
                    m['codeBlocks'] += 1
                    m['mermaid'] += g.group(2).lower() == 'mermaid'
                    m['maxTableRows'] = max(m['maxTableRows'], table_rows)
                    table_rows, prev = -1, None
                    continue
            images = m['images']
            t = CODE_SPAN.sub('', content) if '`' in content else content
            if '![' in t:
                for url in IMAGE.findall(t):
                    add_image(url)
                refs += [(ref or alt).lower() for alt, ref in REF_IMAGE.findall(t)]
            if '](' in t:
                m['links'] += len(LINK.findall(t))
            if '<' in t and HTML.search(t):
                m['htmlLines'] += 1
                lower = t.lower()
                m['htmlImages'] += lower.count('<img')
                m['details'] += lower.count('<details')
                for url in IMG_SRC.findall(t):
                    add_image(url)
            if s.startswith('['):
                d = REF_DEF.match(s)
                if d:
                    defs.setdefault(d.group(1).lower(), d.group(2))
                m['footnotes'] += bool(FOOTNOTE.match(s))
            if '$$' in s:
                m['math'] += bool(MATH.search(s))
            if table_rows >= 0:
                if s and '|' in s:
                    table_rows += 1
                    m['tableImages'] += m['images'] - images
                else:
                    m['maxTableRows'] = max(m['maxTableRows'], table_rows)
                    table_rows = -1
            elif prev and '|' in s and '-' in s and '|' in prev:
                row = cells(s)
                if all(DELIMITER.fullmatch(c) for c in row) and len(cells(prev)) == len(row):
                    m['tables'] += 1
                    m['maxTableColumns'] = max(m['maxTableColumns'], len(row))
                    table_rows = 0
            item = LIST_ITEM.match(content)
            if item:
                indent = len(item.group(1).expandtabs(4))
                while stack and stack[-1] >= indent:
                    stack.pop()
                stack.append(indent)
                m['listItems'] += 1
                m['listDepth'] = max(m['listDepth'], len(stack))
                m['taskItems'] += bool(TASK.match(content, item.end()))
            elif s and not content[0].isspace():
                stack = []
            prev = s or None
    m['maxTableRows'] = max(m['maxTableRows'], table_rows)
    m['unclosedFence'] = int(fence is not None)
    for ref in refs:
        if ref in defs:
            add_image(defs[ref])
    return m


def digest(path):
    """(size, sha256) of a readable text file, else the reason it is skipped."""
    try:
        size = os.path.getsize(path)
        if size > MAX_BYTES:
            return 'over 50 MiB'
        sha = hashlib.sha256()
        with open(path, 'rb') as f:
            chunk = f.read(1 << 16)
            if b'\0' in chunk[:8192]:
                return 'binary'
            while chunk:
                sha.update(chunk)
                chunk = f.read(1 << 16)
        return size, sha.hexdigest()
    except OSError:
        return 'unreadable'


def walk(top, skip_dir):
    found = []
    for folder, dirs, names in os.walk(top):
        dirs[:] = [d for d in dirs if d != '.git' and os.path.join(folder, d) != skip_dir]
        found += [os.path.join(folder, n) for n in names if n.lower().endswith('.md')]
    return found


def scan(root, skip_dir, pool):
    # One os.walk of ~/workspace (2.4M entries) takes ~25 s, so each top-level folder walks in its own process.
    entries = list(os.scandir(root))
    tops = [e.path for e in entries if e.is_dir(follow_symlinks=False) and e.name != '.git' and e.path != skip_dir]
    paths = [e.path for e in entries if e.is_file() and e.name.lower().endswith('.md')]
    for found in pool.map(walk, tops, [skip_dir] * len(tops)):
        paths += found
    paths.sort()
    by_hash, sizes, skipped = {}, {}, dict.fromkeys(('over 50 MiB', 'binary', 'unreadable'), 0)
    prefix = len(str(root)) + 1
    for path, result in zip(paths, pool.map(digest, paths, chunksize=256)):
        if isinstance(result, str):
            skipped[result] += 1
        else:
            by_hash.setdefault(result[1], []).append(path[prefix:])
            sizes[result[1]] = result[0]
    return by_hash, sizes, skipped


def select(name, selector, preferred, reason, files, own, path_hash):
    set_name, required, goal = selector
    entry = {'name': name, 'selector': {'set': set_name, 'require': required}, 'preferred': preferred,
             'reason': reason}
    entry['selector']['maximize' if isinstance(goal, list) else 'closestBytes'] = goal

    def fits(rel, f):
        return all(r in f['features'] for r in required) and (set_name == 'smoke' or not vendored(rel))

    def rank(f):
        if isinstance(goal, list):
            return tuple(-f.get(k, 0) for k in goal), f['path']
        return abs(f['bytes'] - goal), f['path']

    hit = path_hash.get(preferred)
    if hit and fits(preferred, files[hit]):
        entry.update(status='preferred', path=preferred, sha256=hit)
    else:
        pool = [f for f in files.values() if fits(f['path'], f) and (set_name == 'smoke' or f['sha256'] in own)]
        best = min(pool, key=rank) if pool else None
        entry.update(status='reselected' if best else 'missing', path=best and best['path'],
                     sha256=best and best['sha256'])
    if entry['sha256'] and isinstance(goal, list):
        entry['value'] = [files[entry['sha256']].get(k, 0) for k in goal]
    return entry


def main():
    started = time.monotonic()
    root = Path(sys.argv[1] if len(sys.argv) > 1 else '~/workspace').expanduser().resolve()
    out = Path(__file__).resolve().parents[1] / 'build/markdown-corpus'
    with ProcessPoolExecutor() as pool:
        by_hash, sizes, skipped = scan(root, str(out), pool)
        reps = {h: min(paths, key=lambda p: (vendored(p), in_node_modules(p), p)) for h, paths in by_hash.items()}
        order = sorted(reps, key=reps.get)
        metrics = list(pool.map(classify, [str(root / reps[h]) for h in order], chunksize=32))
    files = {}
    for h, m in zip(order, metrics):
        entry = {'path': reps[h], 'sha256': h, 'copies': len(by_hash[h]), 'bytes': sizes[h]}
        entry.update((k, v) for k, v in m.items() if v)
        entry['features'] = [k for k, v in FEATURES.items() if m[v]]
        files[h] = entry
    own = {h for h, paths in by_hash.items() if not all(vendored(p) for p in paths)}
    path_hash = {p: h for h, paths in by_hash.items() for p in paths}
    curated = [select(*c, files, own, path_hash) for c in CURATED]
    manifest = {'root': str(root), 'vendored': list(VENDORED), 'features': list(FEATURES),
                'sets': {'smoke': [files[h]['path'] for h in order],
                         'own': [files[h]['path'] for h in order if h in own], 'curated': curated}}
    out.mkdir(parents=True, exist_ok=True)
    head = json.dumps(manifest, indent=1, ensure_ascii=False)[:-2]
    rows = ',\n'.join('  ' + json.dumps(files[h], ensure_ascii=False, separators=(',', ':')) for h in order)
    (out / 'manifest.json').write_text(f'{head},\n "files": [\n{rows}\n ]\n}}\n')

    outside = {h: sum(not in_node_modules(p) for p in by_hash[h]) for h in order}
    inside = [h for h in order if any(in_node_modules(p) for p in by_hash[h])]
    mib = lambda hs: sum(sizes[h] for h in hs) / (1 << 20)
    out_hashes = [h for h in order if outside[h]]
    unique_out = sorted(sizes[h] for h in out_hashes)
    print(f'{root}: {len(path_hash):,} Markdown files in {time.monotonic() - started:.1f} s; '
          f'skipped ' + ', '.join(f'{n} {k}' for k, n in skipped.items()))
    print(f'{"":22}{"files":>8}{"MiB":>8}{"unique":>8}{"MiB":>8}')
    print(f'{"outside node_modules":22}{sum(outside.values()):>8,}'
          f'{sum(sizes[h] * outside[h] for h in order) / (1 << 20):>8.1f}{len(out_hashes):>8,}{mib(out_hashes):>8.1f}')
    print(f'{"inside node_modules":22}{sum(len(by_hash[h]) - outside[h] for h in order):>8,}'
          f'{sum(sizes[h] * (len(by_hash[h]) - outside[h]) for h in order) / (1 << 20):>8.1f}'
          f'{len(inside):>8,}{mib(inside):>8.1f}')
    print(f'{"own (set)":22}{"":>16}{len(own):>8,}{mib(own):>8.1f}')
    print(f'{"smoke (set)":22}{"":>16}{len(order):>8,}{mib(order):>8.1f}')
    if unique_out:
        print(f'unique outside node_modules: median {unique_out[len(unique_out) // 2] / 1024:.1f} KiB, '
              f'p90 {unique_out[len(unique_out) * 9 // 10] / 1024:.1f} KiB, largest {unique_out[-1] / 1024:.0f} KiB')
    print(f'\n{"feature":16}{"own":>8}{"outside*":>10}{"smoke":>8}')
    for feature in FEATURES:
        with_feature = [h for h in order if feature in files[h]['features']]
        print(f'{feature:16}{sum(h in own for h in with_feature):>8,}{sum(outside[h] for h in with_feature):>10,}'
              f'{len(with_feature):>8,}')
    print('* every copy outside node_modules, as the plan\'s inventory counts them')
    status = [c['status'] for c in curated]
    print(f'\ncurated: {len(curated)} entries, ' + ', '.join(f'{status.count(s)} {s}' for s in
                                                            ('preferred', 'reselected', 'missing')))
    for c in curated:
        if c['status'] != 'preferred':
            print(f'  {c["name"]}: {c["status"]} -> {c["path"]}')
    print(f'wrote {out / "manifest.json"}')


if __name__ == '__main__':
    main()
