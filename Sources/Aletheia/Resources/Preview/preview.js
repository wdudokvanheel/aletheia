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
function invalidatePreview(value, clear) {
  generation = value;
  if (clear) document.getElementById('content').replaceChildren();
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
function commitPreview(html, value, resetScroll) {
  if (value !== generation) return false;
  const y = resetScroll ? 0 : window.scrollY;
  document.getElementById('content').innerHTML = html;
  window.scrollTo(0, y);
  return true;
}
