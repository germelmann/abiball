#!/usr/bin/env node
// Generate a PDF from one or more pdfme jobs.
// Reads { jobs: [{template, inputs}], fonts? } from stdin and writes PDF bytes to stdout.
// Each job is generated independently; the resulting PDFs are concatenated via pdf-lib.
//   fonts: { [fontName]: { data: <base64>, fallback?: bool } }
//
// Legacy single-job payloads of the shape { template, inputs, fonts? } are also accepted.

const { generate } = require('@pdfme/generator');
const { text, image, line, rectangle, ellipse } = require('@pdfme/schemas');
const { PDFDocument } = require('pdf-lib');

// pdfme's stock image plugin renders images "contain" (whole image fitted inside the
// box, centred, leaving empty bars when the aspect ratios differ). The yearbook wants
// "cover": fill the entire box, cropping the overflow, never distorting. pdfme exposes
// no objectFit option in the PDF render path, so we override the image plugin's `pdf`
// renderer to scale-to-cover and clip to the box. Rotated images fall back to the
// stock renderer (clipping a rotated box needs a transform we don't need in practice).
const MM_TO_PT = 72 / 25.4;
const mm2pt = (mm) => Number(mm) * MM_TO_PT;

function dataUrlToBytes(dataUrl) {
  const comma = dataUrl.indexOf(',');
  const b64 = comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl;
  return Buffer.from(b64, 'base64');
}

async function embedCovered(arg) {
  // Use the pdf-lib instance pdfme passes in (the @pdfme/pdf-lib fork): operators and
  // images must come from the same module that created `page`/`pdfDoc`.
  const { schema, value, pdfDoc, page, pdfLib, _cache } = arg;
  const {
    pushGraphicsState, popGraphicsState,
    moveTo, lineTo, closePath, clip, endPath,
  } = pdfLib;

  const content = (value !== undefined && value !== null && value !== '')
    ? value
    : (schema.content || '');
  if (typeof content !== 'string' || !content.startsWith('data:')) return;

  // Embed once per document; the same uploaded photo can recur across pages.
  const cacheKey = 'cover:' + content;
  let img = _cache && _cache.get(cacheKey);
  if (!img) {
    const isPng = content.startsWith('data:image/png');
    const bytes = dataUrlToBytes(content);
    img = isPng ? await pdfDoc.embedPng(bytes) : await pdfDoc.embedJpg(bytes);
    if (_cache) _cache.set(cacheKey, img);
  }

  const pageHeight = page.getHeight();
  const boxW = mm2pt(schema.width);
  const boxH = mm2pt(schema.height);
  const boxX = mm2pt(schema.position.x);
  const boxY = pageHeight - mm2pt(schema.position.y) - boxH;

  // Scale so the image covers the box, then centre the overflow.
  const scale = Math.max(boxW / img.width, boxH / img.height);
  const drawW = img.width * scale;
  const drawH = img.height * scale;
  const drawX = boxX + (boxW - drawW) / 2;
  const drawY = boxY + (boxH - drawH) / 2;

  const opacity = typeof schema.opacity === 'number' ? schema.opacity : 1;

  page.pushOperators(
    pushGraphicsState(),
    moveTo(boxX, boxY),
    lineTo(boxX + boxW, boxY),
    lineTo(boxX + boxW, boxY + boxH),
    lineTo(boxX, boxY + boxH),
    closePath(),
    clip(),
    endPath(),
  );
  page.drawImage(img, { x: drawX, y: drawY, width: drawW, height: drawH, opacity });
  page.pushOperators(popGraphicsState());
}

const coverImage = Object.assign({}, image, {
  pdf: async (arg) => {
    const rotate = arg && arg.schema ? Number(arg.schema.rotate || 0) : 0;
    if (rotate) return image.pdf(arg);
    try {
      return await embedCovered(arg);
    } catch (_) {
      // Any decoding/embedding hiccup falls back to the stock renderer.
      return image.pdf(arg);
    }
  },
});

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

function buildFontRegistry(fontsPayload) {
  if (!fontsPayload || typeof fontsPayload !== 'object') return null;
  const names = Object.keys(fontsPayload);
  if (names.length === 0) return null;

  const registry = {};
  let hasFallback = false;
  for (const name of names) {
    const entry = fontsPayload[name] || {};
    if (!entry.data) continue;
    registry[name] = {
      data: Buffer.from(entry.data, 'base64'),
      fallback: !!entry.fallback,
    };
    if (entry.fallback) hasFallback = true;
  }
  if (Object.keys(registry).length === 0) return null;
  if (!hasFallback) registry[Object.keys(registry)[0]].fallback = true;
  return registry;
}

function normalizeJobs(payload) {
  if (Array.isArray(payload.jobs) && payload.jobs.length > 0) return payload.jobs;
  if (payload.template) return [{ template: payload.template, inputs: payload.inputs }];
  throw new Error('payload contains neither "jobs" nor "template"');
}

async function generateOne(job, options) {
  if (!job.template || !Array.isArray(job.template.schemas)) {
    throw new Error('job.template.schemas missing or invalid');
  }
  const inputs = Array.isArray(job.inputs) && job.inputs.length > 0 ? job.inputs : [{}];
  return generate({
    template: job.template,
    inputs,
    plugins: { text, image: coverImage, line, rectangle, ellipse },
    options,
  });
}

async function mergePdfs(pdfBufs) {
  if (pdfBufs.length === 1) return pdfBufs[0];
  const out = await PDFDocument.create();
  for (const buf of pdfBufs) {
    const src = await PDFDocument.load(buf);
    const copied = await out.copyPages(src, src.getPageIndices());
    for (const p of copied) out.addPage(p);
  }
  return await out.save();
}

(async () => {
  try {
    const raw = await readStdin();
    const payload = JSON.parse(raw);
    const jobs = normalizeJobs(payload);

    const options = {};
    const font = buildFontRegistry(payload.fonts);
    if (font) options.font = font;

    const rendered = [];
    for (const job of jobs) {
      rendered.push(await generateOne(job, options));
    }
    const merged = await mergePdfs(rendered);
    process.stdout.write(Buffer.from(merged));
  } catch (err) {
    process.stderr.write('pdfme-generate-error: ' + (err && err.stack ? err.stack : String(err)) + '\n');
    process.exit(1);
  }
})();
