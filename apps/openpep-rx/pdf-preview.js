// SPDX-License-Identifier: AGPL-3.0-or-later
export async function renderPDF(bytes, target) {
  const pdfjs = await import('./vendor/pdfjs/pdf.mjs');
  const base = new URL('./vendor/pdfjs/', import.meta.url).href;
  pdfjs.GlobalWorkerOptions.workerSrc = base + 'pdf.worker.mjs';
  const loading = pdfjs.getDocument({data: new Uint8Array(bytes.slice(0)), isEvalSupported: false,
    useWasm: false, useSystemFonts: false, cMapUrl: base + 'cmaps/', cMapPacked: true,
    standardFontDataUrl: base + 'standard_fonts/', wasmUrl: base + 'wasm/'});
  const pdf = await loading.promise;
  try {
    if (pdf.numPages > 50) throw Error('Selecione um PDF com até 50 páginas.');
    let pixels = 0;
    for (let n = 1; n <= pdf.numPages; n++) {
      const page = await pdf.getPage(n), natural = page.getViewport({scale: 1});
      const viewport = page.getViewport({scale: Math.min(1.5, 1000 / natural.width)});
      pixels += Math.ceil(viewport.width) * Math.ceil(viewport.height);
      if (pixels > 50_000_000 || viewport.height > 16000) throw Error('As páginas excedem o limite de prévia.');
      const figure = document.createElement('figure'), caption = document.createElement('figcaption'), canvas = document.createElement('canvas');
      figure.dataset.page = String(n); figure.dataset.width = String(natural.width); figure.dataset.height = String(natural.height);
      caption.textContent = `Página ${n} de ${pdf.numPages}`;
      canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
      canvas.setAttribute('aria-label', caption.textContent);
      await page.render({canvasContext: canvas.getContext('2d'), viewport}).promise;
      const accessible = document.createElement('p'); accessible.className = 'sr-only';
      accessible.textContent = (await page.getTextContent()).items.map(item => item.str || '').join(' ');
      const surface = document.createElement('div'); surface.className='pdf-surface'; surface.append(canvas);
      figure.append(caption, surface, accessible); target.append(figure);
      page.cleanup();
    }
  } finally { await loading.destroy(); }
}
