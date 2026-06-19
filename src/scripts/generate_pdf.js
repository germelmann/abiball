#!/usr/bin/env node
// Generate a PDF from one or more pdfme jobs.
// Reads { jobs: [{template, inputs}], fonts? } from stdin and writes PDF bytes to stdout.
// Each job is generated independently; the resulting PDFs are concatenated via pdf-lib.
//   fonts: { [fontName]: { data: <base64>, fallback?: bool } }
//
// Legacy single-job payloads of the shape { template, inputs, fonts? } are also accepted.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const { generate } = require('@pdfme/generator');
const { text, image, line, rectangle, ellipse } = require('@pdfme/schemas');
const { PDFDocument } = require('pdf-lib');

// ---------- DEBUG LOG ---------------------------------------------------
// A build marker lets us confirm at runtime that the *current* version of
// this script is the one Ruby invoked (and not a stale copy still cached in
// the running container). Bump the date when you touch this file.
const BUILD_MARKER = 'yearbook-pdf-gen 2026-06-19.emoji-autoscale';
const DEBUG_LOG_PATH = '/gen/log/yearbook_pdf_debug.log';
const RUN_ID = crypto.randomBytes(4).toString('hex');

function dbg(line) {
  const stamp = new Date().toISOString();
  const msg = `[${stamp}] [${RUN_ID}] ${line}\n`;
  try {
    fs.mkdirSync(path.dirname(DEBUG_LOG_PATH), { recursive: true });
    fs.appendFileSync(DEBUG_LOG_PATH, msg);
  } catch (_) { /* log dir may be read-only — ignore */ }
  // Also mirror to stderr so Ruby's Open3 capture sees it when something fails.
  process.stderr.write(msg);
}

dbg(`startup: ${BUILD_MARKER}, node=${process.version}, script=${__filename}`);

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
  // @pdfme/pdf-lib's embed{Png,Jpg} reject a Node Buffer (their type check only accepts a
  // plain Uint8Array or a base64 string); a Buffer silently fails with "not a PNG file".
  return new Uint8Array(Buffer.from(b64, 'base64'));
}

function describeContent(s) {
  if (s === undefined) return 'undefined';
  if (s === null) return 'null';
  if (typeof s !== 'string') return `non-string(${typeof s})`;
  if (s === '') return 'empty-string';
  return `string len=${s.length} prefix=${JSON.stringify(s.slice(0, 32))}`;
}

async function embedCovered(arg) {
  // Use the pdf-lib instance pdfme passes in (the @pdfme/pdf-lib fork): operators and
  // images must come from the same module that created `page`/`pdfDoc`.
  const { schema, value, pdfDoc, page, pdfLib, _cache } = arg;
  const tag = `image[name=${JSON.stringify(schema && schema.name)}]`;

  if (!pdfLib) {
    dbg(`${tag}: arg.pdfLib is missing — pdfme version too old?`);
    throw new Error('pdfLib missing in plugin arg');
  }
  const {
    pushGraphicsState, popGraphicsState,
    moveTo, lineTo, closePath, clip, endPath,
    concatTransformationMatrix,
  } = pdfLib;
  for (const [k, v] of Object.entries({ pushGraphicsState, popGraphicsState, moveTo, lineTo, closePath, clip, endPath, concatTransformationMatrix })) {
    if (typeof v !== 'function') {
      dbg(`${tag}: pdfLib.${k} is ${typeof v} — operator missing`);
      throw new Error(`pdfLib.${k} not a function`);
    }
  }

  const content = (value !== undefined && value !== null && value !== '')
    ? value
    : (schema.content || '');
  dbg(`${tag}: value=${describeContent(value)} schema.content=${describeContent(schema.content)} chose=${describeContent(content).slice(0, 80)}`);

  if (typeof content !== 'string' || !content.startsWith('data:')) {
    dbg(`${tag}: no data: URL — skipping (empty image placeholder)`);
    return;
  }

  // Embed once per document; the same uploaded photo can recur across pages.
  const cacheKey = 'cover:' + content;
  let img = _cache && _cache.get(cacheKey);
  if (!img) {
    const isPng = content.startsWith('data:image/png');
    const bytes = dataUrlToBytes(content);
    dbg(`${tag}: embed ${isPng ? 'PNG' : 'JPG'} ${bytes.length}B (Uint8Array)`);
    img = isPng ? await pdfDoc.embedPng(bytes) : await pdfDoc.embedJpg(bytes);
    if (_cache) _cache.set(cacheKey, img);
  } else {
    dbg(`${tag}: image found in _cache`);
  }

  const pageHeight = page.getHeight();
  const boxW = mm2pt(schema.width);
  const boxH = mm2pt(schema.height);
  // Box centre in PDF coordinates (origin bottom-left). pdfme's UI position is the
  // top-left corner in mm with a top-down Y axis.
  const cx = mm2pt(schema.position && schema.position.x) + boxW / 2;
  const cy = pageHeight - mm2pt(schema.position && schema.position.y) - boxH / 2;

  // Scale so the image covers the box (fill, never letterbox), then centre the overflow.
  const scale = Math.max(boxW / img.width, boxH / img.height);
  const drawW = img.width * scale;
  const drawH = img.height * scale;

  const opacity = typeof schema.opacity === 'number' ? schema.opacity : 1;

  // pdfme rotates clockwise in the UI; PDF rotates counter-clockwise, so the render
  // angle is the negation (matching pdfme's own convertForPdfLayoutProps).
  const rotateDeg = -Number(schema.rotate || 0);
  const theta = (rotateDeg * Math.PI) / 180;
  const cos = Math.cos(theta);
  const sin = Math.sin(theta);

  dbg(`${tag}: COVER applied — box=${boxW.toFixed(1)}x${boxH.toFixed(1)}pt img=${img.width}x${img.height}px scale=${scale.toFixed(3)} draw=${drawW.toFixed(1)}x${drawH.toFixed(1)}pt centre=(${cx.toFixed(1)},${cy.toFixed(1)}) rotate=${rotateDeg} opacity=${opacity}`);

  // Work in a coordinate frame centred on the box and rotated with it: the box and the
  // cover-scaled image are both centred at the origin, so clipping to the box rectangle
  // crops the image's overflow on all sides regardless of rotation.
  //   device = point × R × T × CTM_old  ->  emit translate first, then rotate.
  page.pushOperators(
    pushGraphicsState(),
    concatTransformationMatrix(1, 0, 0, 1, cx, cy),          // translate to box centre
    concatTransformationMatrix(cos, sin, -sin, cos, 0, 0),   // rotate about that centre
    moveTo(-boxW / 2, -boxH / 2),
    lineTo(boxW / 2, -boxH / 2),
    lineTo(boxW / 2, boxH / 2),
    lineTo(-boxW / 2, boxH / 2),
    closePath(),
    clip(),
    endPath(),
  );
  // drawImage wraps itself in q…Q, so the clip and CTM set above stay in effect for it
  // and are restored by our popGraphicsState. No rotate here — the CTM already rotates.
  page.drawImage(img, { x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH, opacity });
  page.pushOperators(popGraphicsState());
}

let imageCallCount = 0;
const coverImage = Object.assign({}, image, {
  pdf: async (arg) => {
    imageCallCount += 1;
    const schema = arg && arg.schema;
    const tag = `image#${imageCallCount}[name=${JSON.stringify(schema && schema.name)}, type=${JSON.stringify(schema && schema.type)}]`;
    const rotate = schema ? Number(schema.rotate || 0) : 0;
    dbg(`${tag}: pdf() called rotate=${rotate} pos=${JSON.stringify(schema && schema.position)} size=${schema && schema.width}x${schema && schema.height}mm objectFit=${JSON.stringify(schema && schema.objectFit)}`);
    try {
      return await embedCovered(arg);
    } catch (e) {
      dbg(`${tag}: cover render THREW: ${(e && e.stack) || e} — falling back to stock contain renderer`);
      return image.pdf(arg);
    }
  },
});

dbg(`coverImage override installed (image.pdf=${typeof image.pdf}, coverImage.pdf=${typeof coverImage.pdf})`);

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

const EMOJI_FONT_NAME = 'NotoColorEmoji';

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

  // Promote NotoColorEmoji to the pdfme fallback font so emoji codepoints that
  // are absent from admin-supplied fonts (e.g. Roboto) resolve to a visible glyph
  // rather than a tofu box.  Any other fallback flag in the payload is cleared.
  if (registry[EMOJI_FONT_NAME]) {
    for (const n of Object.keys(registry)) registry[n].fallback = false;
    registry[EMOJI_FONT_NAME].fallback = true;
    hasFallback = true;
    dbg(`emoji fallback: promoting ${EMOJI_FONT_NAME} to fallback font`);
  }

  if (!hasFallback) registry[Object.keys(registry)[0]].fallback = true;
  return registry;
}

function normalizeJobs(payload) {
  if (Array.isArray(payload.jobs) && payload.jobs.length > 0) return payload.jobs;
  if (payload.template) return [{ template: payload.template, inputs: payload.inputs }];
  throw new Error('payload contains neither "jobs" nor "template"');
}

// Snapshot the schema layout of a job for the debug log, without dumping the
// (possibly multi-MB) image data URLs.
function summarizeJob(job, idx) {
  const pages = (job.template && job.template.schemas) || [];
  const lines = [`job#${idx}: pages=${pages.length}`];
  pages.forEach((page, pIdx) => {
    if (!Array.isArray(page)) return;
    page.forEach((entry, eIdx) => {
      if (!entry || typeof entry !== 'object') return;
      const name = entry.name;
      const type = entry.type;
      const ro = entry.readOnly;
      const objFit = entry.objectFit;
      const contentInfo = type === 'image'
        ? describeContent(entry.content)
        : (typeof entry.content === 'string' ? `text len=${entry.content.length}` : 'no-content');
      lines.push(`  job#${idx}.page${pIdx}.entry${eIdx}: name=${JSON.stringify(name)} type=${JSON.stringify(type)} readOnly=${ro} objectFit=${JSON.stringify(objFit)} ${contentInfo}`);
    });
  });
  const inputs = job.inputs || [];
  inputs.forEach((inp, iIdx) => {
    if (!inp || typeof inp !== 'object') return;
    for (const k of Object.keys(inp)) {
      const v = inp[k];
      const info = typeof v === 'string' ? describeContent(v) : `non-string(${typeof v})`;
      lines.push(`  job#${idx}.inputs[${iIdx}].${k}: ${info}`);
    }
  });
  return lines.join('\n');
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
    dbg(`stdin received: ${raw.length} bytes`);
    const payload = JSON.parse(raw);
    const jobs = normalizeJobs(payload);
    dbg(`payload parsed: ${jobs.length} job(s)`);
    jobs.forEach((j, i) => dbg(summarizeJob(j, i)));

    const options = {};
    const font = buildFontRegistry(payload.fonts);
    if (font) {
      options.font = font;
      dbg(`fonts registered: ${Object.keys(font).join(', ')}`);
    } else {
      dbg('no fonts registered');
    }

    const rendered = [];
    for (let i = 0; i < jobs.length; i++) {
      dbg(`generating job#${i}…`);
      rendered.push(await generateOne(jobs[i], options));
      dbg(`job#${i} done (image renders so far: ${imageCallCount})`);
    }
    const merged = await mergePdfs(rendered);
    dbg(`merged ${rendered.length} PDF(s) -> ${merged.length}B; total image renders=${imageCallCount}`);
    process.stdout.write(Buffer.from(merged));
  } catch (err) {
    const msg = 'pdfme-generate-error: ' + (err && err.stack ? err.stack : String(err));
    dbg(msg);
    process.stderr.write(msg + '\n');
    process.exit(1);
  }
})();
