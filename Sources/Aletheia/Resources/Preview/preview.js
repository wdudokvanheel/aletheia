'use strict';
// Raw HTML is deliberately omitted. Marked handles Markdown; DOMPurify is the
// security boundary for its generated HTML, including dangerous Markdown URLs.
const parser = new marked.Marked({ gfm: true, renderer: { html() { return ''; } } });
const config = {
  ALLOWED_TAGS: ['p','br','hr','h1','h2','h3','h4','h5','h6','blockquote','ul','ol','li',
    'strong','em','del','pre','code','a','img','table','thead','tbody','tr','th','td','input'],
  ALLOWED_ATTR: ['href','src','alt','title','start','align','type','checked','disabled'],
  ALLOW_DATA_ATTR: false,
  ALLOW_ARIA_ATTR: false
};
let generation = 0;
let committed = null;
let restoration = null;
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
    document.getElementById('content').replaceChildren();
  }
}
function renderMarkdown(markdown, base) {
  const fragment = DOMPurify.sanitize(parser.parse(markdown), { ...config, RETURN_DOM_FRAGMENT: true });
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
  const holder = document.createElement('div');
  holder.append(fragment);
  return holder.innerHTML;
}
function commitPreview(html, value, resetScroll, token = '', position = { x: 0, y: 0 }) {
  if (value !== generation) return false;
  const valid = n => Number.isFinite(n) ? Math.max(0, n) : 0;
  const target = resetScroll ? { x: valid(position.x), y: valid(position.y) }
                             : { x: window.scrollX, y: window.scrollY };
  const identity = { generation: value, token };
  committed = identity;
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
  return true;
}
