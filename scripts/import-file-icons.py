#!/usr/bin/env python3
"""Import static artwork/rules from a pinned file-icons/atom checkout.
Requires Node and fonttools[woff] 4.60.1 in an isolated tooling environment.
Usage: python scripts/import-file-icons.py /path/to/file-icons-atom
Licenses are maintained separately in the resource directory.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from fontTools.ttLib import TTFont

source = Path(sys.argv[1]).resolve()
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
assert revision == 'fa4bc4850eb5bbc0d192c127fb4be10af3f049b2', revision
out = Path(__file__).resolve().parents[1] / 'Sources/Aletheia/Resources/FileIcons'
fonts = {'fi': 'file-icons', 'mf': 'mfixx', 'devicons': 'devopicons', 'fa': 'fontawesome', 'octicons': 'octicons'}
for name in ['file-icons', 'mfixx', 'devopicons']:
    font = TTFont(source / f'fonts/{name}.woff2')
    font.flavor = None
    font.save(out / f'{name}.ttf')
icons = {}
for name, family, content in re.findall(r'\.([\w-]+):before\s*\{\s*\.(fi|mf|devicons|fa|octicons);\s*content:\s*"([^"]+)"', (source / 'styles/icons.less').read_text()):
    glyph = chr(int(content[1:], 16)) if content.startswith('\\') else content
    icons[name] = {'font': fonts[family], 'glyph': glyph}
js = '''const data = require(process.argv[1])[1][0];
console.log(JSON.stringify(data.filter(r => r[2] instanceof RegExp).map(r => ({
icon:r[0], colors:r[1], pattern:r[2].source, insensitive:r[2].ignoreCase, path:!!r[4]
}))));'''
rules = json.loads(subprocess.check_output(['node', '-e', js, str(source / 'lib/icons/.icondb.js')]))
for name, code in {'circuit-board': 0xf0d6, 'file-pdf': 0xf014, 'file-text': 0xf011, 'mail': 0xf03b, 'paintcan': 0xf0d1, 'star': 0xf02a}.items():
    icons['icon-' + name] = {'font': 'octicons', 'glyph': chr(code)}
missing = sorted(set(r['icon'] for r in rules) - icons.keys())
assert not missing, missing
(out / 'catalog.json').write_text(json.dumps({'icons': icons, 'rules': rules}, ensure_ascii=False, separators=(',', ':')) + '\n')
print(f'{len(icons)} icons, {len(rules)} file rules')
manifest = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [source/'lib/icons/.icondb.js', source/'styles/icons.less', *sorted((source/'fonts').glob('*'))]}
(out / 'upstream.json').write_text(json.dumps({'repository': 'https://github.com/file-icons/atom', 'revision': revision, 'sha256': manifest}, indent=2) + '\n')
