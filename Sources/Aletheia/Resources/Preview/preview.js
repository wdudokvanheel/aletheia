'use strict';
// Raw HTML is deliberately omitted. Marked handles Markdown; DOMPurify is the
// security boundary for its generated HTML, including dangerous Markdown URLs.
// Source positions are attached only to Marked tokens that can be located exactly.
// Transformed/omitted syntax falls back to its enclosing top-level block.
const renderer = new marked.Renderer();
const sourceRenderer = { html() { return ''; } };
for (const type of ['text', 'codespan', 'code']) {
  sourceRenderer[type] = function(token) {
    const html = renderer[type].call(this, token);
    if (token.sourceStart === undefined || token.tokens) return html;
    const offset = token.raw.indexOf(token.text);
    if (offset < 0) return html;
    const attrs = `data-text-start="${token.sourceStart + offset}"`;
    return type === 'code' ? html.replace('<code', `<code ${attrs}`)
                          : `<span ${attrs}>${html}</span>`;
  };
}
const parser = new marked.Marked({ gfm: true, renderer: sourceRenderer });
const config = {
  ALLOWED_TAGS: ['p','br','hr','h1','h2','h3','h4','h5','h6','blockquote','ul','ol','li',
    'div','span','strong','em','del','pre','code','a','img','table','thead','tbody','tr','th','td','input'],
  ALLOWED_ATTR: ['href','src','alt','title','start','align','type','checked','disabled','data-source-start','data-source-end','data-text-start'],
  ALLOW_DATA_ATTR: false,
  ALLOW_ARIA_ATTR: false
};
let generation = 0;
let committed = null;
let restoration = null;
let search = null;
let committedSource = '';
let renderedSource = '';
let sourceOffsets = [];

function setPreviewSearch(query, range, token, value) {
  search = query && range ? { query, range, token, generation: value } : null;
  window.getSelection()?.removeAllRanges();
  applyPreviewSearch();
}
function applyPreviewSearch() {
  if (!search || !committed || search.token !== committed.token ||
      search.generation !== committed.generation || generation !== committed.generation) return;
  const { location, length } = search.range;
  if (committedSource.slice(location, location + length) !== search.query) return;
  const blocks = [...document.querySelectorAll('[data-source-start]')]
    .filter(node => node.childElementCount > 0);
  // Multi-block matches use their start. Definitions/omitted HTML/blank lines
  // have no box, so navigate to the following visible block (or the last one).
  const block = blocks.find(node => Number(node.dataset.sourceStart) <= location &&
    Number(node.dataset.sourceEnd) > location) ??
    blocks.find(node => Number(node.dataset.sourceStart) > location) ?? blocks.at(-1);
  if (!block) return;
  restoration = null;
  // Text spans carry original UTF-16 offsets, so hidden destinations and earlier
  // occurrences cannot shift the selected rendered occurrence.
  for (const span of block.querySelectorAll('[data-text-start]')) {
    const start = Number(span.dataset.textStart);
    if (committedSource.slice(start, start + span.textContent.length) !== span.textContent) continue;
    const offset = location - start;
    if (offset < 0 || offset + length > span.textContent.length ||
        span.textContent.slice(offset, offset + length) !== search.query) continue;
    const walker = document.createTreeWalker(span, NodeFilter.SHOW_TEXT);
    let node, consumed = 0, first = null, last = null;
    while ((node = walker.nextNode())) {
      const end = consumed + node.length;
      if (!first && offset < end) first = [node, offset - consumed];
      if (first && offset + length <= end) { last = [node, offset + length - consumed]; break; }
      consumed = end;
    }
    if (first && last) {
      const range = document.createRange();
      range.setStart(...first); range.setEnd(...last);
      window.getSelection()?.addRange(range);
      const rect = range.getBoundingClientRect();
      window.scrollTo(window.scrollX, window.scrollY + rect.top - window.innerHeight / 2);
      return;
    }
  }
  block.scrollIntoView({ block: 'center' });
}

function sourceHTML(markdown) {
  // Marked normalizes line endings before lexing. Keep a UTF-16 boundary map.
  const normalized = markdown.replace(/\r\n?/g, '\n');
  sourceOffsets = [0];
  for (let i = 0; i < markdown.length; i++) {
    if (markdown[i] === '\r' && markdown[i + 1] === '\n') i++;
    sourceOffsets.push(i + 1);
  }
  const tokens = parser.lexer(normalized);
  function locate(children, raw, base) {
    let cursor = 0;
    for (const token of children) {
      const text = token.raw ?? token.text;
      const offset = typeof text === 'string' ? raw.indexOf(text, cursor) : -1;
      if (offset < 0) continue;
      const start = base + offset;
      token.sourceStart = start;
      if (token.tokens) locate(token.tokens, text, start);
      if (token.items) locate(token.items, text, start);
      if (Array.isArray(token.header)) locate([...token.header, ...token.rows.flat()], text, start);
      cursor = offset + text.length;
    }
  }
  locate(tokens, normalized, 0);
  return tokens.map(token => {
    const one = [token]; one.links = tokens.links;
    const html = parser.parser(one);
    if (token.sourceStart === undefined) return html;
    return `<div data-source-start="${sourceOffsets[token.sourceStart]}" data-source-end="${sourceOffsets[token.sourceStart + token.raw.length]}">${html}</div>`;
  }).join('');
}
function reportScroll() {
  if (!committed || restoration) return;
  window.webkit?.messageHandlers.previewScroll?.postMessage({
    ...committed, x: window.scrollX, y: window.scrollY
  });
}
window.addEventListener('scroll', reportScroll, { passive: true });
// A user's navigation takes precedence over late image sizing.
for (const event of ['wheel', 'touchstart', 'keydown']) {
  window.addEventListener(event, () => { restoration = null; }, { passive: true });
}
function invalidatePreview(value, clear) {
  generation = value;
  restoration = null;
  if (clear) {
    committed = null;
    committedSource = '';
    window.getSelection()?.removeAllRanges();
    document.getElementById('content').replaceChildren();
  }
}
function renderMarkdown(markdown, base) {
  renderedSource = markdown;
  const fragment = DOMPurify.sanitize(sourceHTML(markdown), { ...config, RETURN_DOM_FRAGMENT: true });
  for (const image of fragment.querySelectorAll('img')) {
    const source = image.getAttribute('src');
    // Only relative images from the document directory. No network, data, SVG,
    // file:// or other active resource schemes, even before DOM insertion.
    if (!source || /^(?:[a-z][a-z0-9+.-]*:|\/|\\)/i.test(source)) { image.remove(); continue; }
    if (!URL.canParse(source, base)) { image.remove(); continue; }
    const url = new URL(source, base);
    if (url.protocol !== 'aletheia-preview:' || url.hostname !== 'document') { image.remove(); continue; }
    image.setAttribute('src', url.href);
  }
  for (const link of fragment.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    if (!URL.canParse(href, base)) { link.removeAttribute('href'); continue; }
    const url = new URL(href, base);
    if (!['http:', 'https:', 'mailto:', 'aletheia-preview:'].includes(url.protocol)) link.removeAttribute('href');
    else link.setAttribute('href', url.href);
  }
  for (const input of fragment.querySelectorAll('input')) {
    if (input.getAttribute('type') !== 'checkbox') input.remove();
    else input.setAttribute('disabled', '');
  }
  for (const span of fragment.querySelectorAll('[data-text-start]')) {
    span.dataset.textStart = sourceOffsets[Number(span.dataset.textStart)];
  }
  const holder = document.createElement('div');
  holder.append(fragment);
  return holder.innerHTML;
}
function commitPreview(html, value, resetScroll, token = '', position = { x: 0, y: 0 }, source = renderedSource) {
  if (value !== generation) return false;
  const valid = n => Number.isFinite(n) ? Math.max(0, n) : 0;
  const target = resetScroll ? { x: valid(position.x), y: valid(position.y) }
                             : { x: window.scrollX, y: window.scrollY };
  const identity = { generation: value, token };
  committed = identity;
  committedSource = source;
  restoration = target;
  const content = document.getElementById('content');
  content.innerHTML = html;
  const images = [...content.querySelectorAll('img')].filter(image => !image.complete);
  let remaining = images.length;
  const restore = () => {
    if (committed !== identity || generation !== value || restoration !== target) return;
    window.scrollTo(target.x, target.y); // WebKit clamps to the rendered document bounds.
    if (remaining === 0) {
      restoration = null;
      reportScroll();
    }
  };
  for (const image of images) {
    const settled = () => { remaining--; restore(); };
    image.addEventListener('load', settled, { once: true });
    image.addEventListener('error', settled, { once: true });
  }
  restore();
  applyPreviewSearch();
  return true;
}
