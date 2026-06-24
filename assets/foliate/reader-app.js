// Bridge between the Flutter host and foliate-js. Importing view.js registers
// the <foliate-view> custom element by side effect.
import './foliate-js/view.js'

const view = document.getElementById('viewer')
let currentCss = ''

function post(name, payload) {
  try {
    window.flutter_inappwebview.callHandler(name, payload ?? {})
  } catch (e) {}
}

function serializeToc(items) {
  return (items || []).map((it) => ({
    label: (it.label || '').trim(),
    href: it.href || null,
    subitems: serializeToc(it.subitems || []),
  }))
}

// Some formats ignore the renderer-level stylesheet, so also inject our styles
// into each section document as it loads, and wire a tap handler there.
function styleDoc(doc) {
  if (!doc) return
  try {
    let el = doc.getElementById('absorb-reader-styles')
    if (!el) {
      el = doc.createElement('style')
      el.id = 'absorb-reader-styles'
      doc.head.appendChild(el)
    }
    el.textContent = currentCss
  } catch (e) {}
}

function reinjectStyles() {
  try {
    for (const { doc } of (view.renderer?.getContents?.() || [])) styleDoc(doc)
  } catch (e) {}
}

view.addEventListener('load', (e) => {
  const doc = e.detail?.doc
  if (!doc) return
  styleDoc(doc)
  // Report the tap's x-fraction to Dart, which decides prev/next/toggle. This
  // is a fallback for Android; iOS WKWebView doesn't fire these reliably, so a
  // Flutter-side Listener handles taps there. A shared debounce stops both
  // paths from double-firing. Skips links/buttons and active text selections.
  try {
    doc.addEventListener('click', (ev) => {
      const hit = ev.target?.closest && ev.target.closest('a, button')
      if (hit) return
      const sel = doc.defaultView?.getSelection?.()
      if (sel && String(sel).length > 0) return
      const w = doc.defaultView?.innerWidth || 0
      const frac = w > 0 ? (ev.clientX / w) : 0.5
      post('onTap', { frac })
    }, false)
  } catch (e) {}
})

view.addEventListener('relocate', (e) => {
  const d = e.detail || {}
  post('onRelocate', {
    cfi: d.cfi ?? null,
    fraction: typeof d.fraction === 'number' ? d.fraction : null,
    tocLabel: d.tocItem?.label ? String(d.tocItem.label).trim() : null,
  })
})

window.AbsorbReader = {
  async openBook(url, lastLocation, flow, columns, css) {
    try {
      currentCss = css || ''
      await view.open(url)
      if (view.renderer) {
        if (flow) view.renderer.setAttribute('flow', flow)
        if (columns) view.renderer.setAttribute('max-column-count', String(columns))
      }
      reinjectStyles()
      await view.init({ lastLocation: lastLocation || null })
      const book = view.book || {}
      post('onBookLoaded', {
        title: book.metadata?.title ?? null,
        toc: serializeToc(book.toc || []),
      })
    } catch (err) {
      post('onError', String(err && err.message ? err.message : err))
    }
  },
  next() { try { view.next() } catch (e) {} },
  prev() { try { view.prev() } catch (e) {} },
  goTo(target) { try { view.goTo(target) } catch (e) {} },
  goToFraction(f) { try { view.goToFraction(f) } catch (e) {} },
  setStyles(css) { currentCss = css || ''; try { view.renderer?.setStyles?.(currentCss) } catch (e) {}; reinjectStyles() },
  setFlow(flow) { try { view.renderer?.setAttribute('flow', flow) } catch (e) {} },
  setColumns(n) { try { view.renderer?.setAttribute('max-column-count', String(n)) } catch (e) {} },
}

post('onReady')
