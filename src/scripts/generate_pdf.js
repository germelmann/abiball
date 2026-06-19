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
const BUILD_MARKER = 'yearbook-pdf-gen 2026-06-19.emoji-perglyph';
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

// ---------- pdfme internal text helpers (per-glyph emoji fallback) ----------
// pdfme renders exactly ONE font per text field; its `fallback` font is only the
// default when a schema has no fontName — it is NOT a per-glyph fallback. Emoji
// codepoints absent from the admin body font therefore render as tofu (.notdef).
// To fix that we replace pdfme's stock `text` plugin with our own pdf renderer
// (customTextPdfRender below) that splits each line into runs and draws emoji
// graphemes with NotoColorEmoji while keeping body text in the admin font.
//
// That renderer is a 1:1 port of pdfme's own text/pdfRender.js, so we reuse its
// internal layout helpers (line breaking, metrics, colour/rotation math) to keep
// pure-text output identical to the stock renderer. Those helpers live behind the
// package "exports" map (only "." and "./utils" are public). We resolve the
// package's main entry — an allowed export — then require the sibling files by
// ABSOLUTE path, which bypasses the exports gate. If pdfme ever relocates these
// files the require throws, we log it, and the plugin falls back to stock `text`
// (no emoji fallback, but no crash). A future-proof alternative is to vendor the
// helper functions (MIT) into a repo file and require that instead — a one-line swap.
let pdfmeText = null; // populated on success; null disables per-glyph fallback
try {
  const schemasMain = require.resolve('@pdfme/schemas'); // ".": allowed by exports
  const cjsSrc = path.dirname(schemasMain);              // .../dist/cjs/src
  pdfmeText = {
    helper: require(path.join(cjsSrc, 'text', 'helper.js')),
    constants: require(path.join(cjsSrc, 'text', 'constants.js')),
    sUtils: require(path.join(cjsSrc, 'utils.js')),
    common: require('@pdfme/common'),
  };
  // Sanity-check that the helpers we rely on are actually present.
  const need = ['getFontKitFont', 'splitTextToSize', 'widthOfTextAtSize', 'heightOfFontAtSize', 'getFontDescentInPt', 'calculateDynamicFontSize'];
  const missing = need.filter((k) => typeof pdfmeText.helper[k] !== 'function');
  if (missing.length) throw new Error(`missing helpers: ${missing.join(',')}`);
  dbg('pdfme text helpers loaded — per-glyph emoji fallback enabled');
} catch (e) {
  pdfmeText = null;
  dbg(`pdfme text helpers unavailable (${(e && e.message) || e}) — stock text renderer, emoji fallback DISABLED`);
}

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

  // NotoColorEmoji is registered as an ordinary font (fallback:false). It must NOT be
  // pdfme's fallback font: that fallback is only the *default* font for schemas without
  // a fontName, so promoting the emoji font would render such fields entirely in emoji
  // glyphs (Latin text -> tofu). Per-glyph emoji substitution is instead handled by our
  // customTextPdfRender, which draws emoji graphemes with NotoColorEmoji while keeping
  // body text in the admin font. pdfme still requires exactly one fallback font, so make
  // sure a non-emoji body font carries the flag.
  const bodyNames = Object.keys(registry).filter((n) => n !== EMOJI_FONT_NAME);
  if (registry[EMOJI_FONT_NAME]) registry[EMOJI_FONT_NAME].fallback = false;
  hasFallback = bodyNames.some((n) => registry[n].fallback);
  if (!hasFallback && bodyNames.length > 0) {
    registry[bodyNames[0]].fallback = true;
  } else if (!hasFallback) {
    // Only the emoji font is present (no admin body fonts) — it has to be the fallback.
    registry[EMOJI_FONT_NAME].fallback = true;
  }
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

// ---------- per-glyph emoji fallback text renderer ----------------------------
// A port of pdfme's text/pdfRender.js. The only change versus the stock renderer is
// the per-line draw step: each line is split into runs that the admin/body font can
// render vs. runs that need the emoji font, and each run is drawn with its own font.
// All layout maths (line breaking, vertical alignment, baseline, colour, rotation)
// are taken verbatim from the stock renderer so pure-text output stays unchanged.

// One grapheme segmenter for the whole process (cheap to reuse, expensive to recreate).
const GRAPHEME_SEGMENTER = (() => {
  try { return new Intl.Segmenter(undefined, { granularity: 'grapheme' }); }
  catch (_) { return null; }
})();
// Fallback when Intl.Segmenter is unavailable (small-ICU node): keep emoji codepoints,
// trailing variation selectors (FE0E/FE0F), skin-tone modifiers (1F3FB-1F3FF), ZWJ (200D)
// joins and flag regional-indicator (RI) pairs together as one cluster.
const EMOJI_MOD = '[\\uFE0E\\uFE0F]?(?:[\\u{1F3FB}-\\u{1F3FF}])?';
const EMOJI_GRAPHEME_RE = new RegExp(
  `\\p{RI}\\p{RI}|\\p{Extended_Pictographic}${EMOJI_MOD}(?:\\u200D\\p{Extended_Pictographic}${EMOJI_MOD})*`,
  'u',
);

function segmentGraphemes(str) {
  if (GRAPHEME_SEGMENTER) {
    const out = [];
    for (const s of GRAPHEME_SEGMENTER.segment(str)) out.push(s.segment);
    return out;
  }
  // Regex fallback: split out emoji clusters, leave the rest as single code points.
  const out = [];
  let i = 0;
  while (i < str.length) {
    EMOJI_GRAPHEME_RE.lastIndex = 0;
    const rest = str.slice(i);
    const m = EMOJI_GRAPHEME_RE.exec(rest);
    if (m && m.index === 0) {
      out.push(m[0]);
      i += m[0].length;
    } else {
      const cp = str.codePointAt(i);
      const ch = String.fromCodePoint(cp);
      out.push(ch);
      i += ch.length;
    }
  }
  return out;
}

// The codepoint that decides which font draws a grapheme: the base character, ignoring
// combining marks that have no standalone glyph (variation selectors, ZWJ, skin tones).
function baseCodePoint(grapheme) {
  for (const ch of grapheme) {
    const cp = ch.codePointAt(0);
    if (cp === 0x200d) continue;                       // ZWJ
    if (cp >= 0xfe00 && cp <= 0xfe0f) continue;        // variation selectors
    if (cp >= 0x1f3fb && cp <= 0x1f3ff) continue;      // skin-tone modifiers
    return cp;
  }
  return grapheme.codePointAt(0);
}

// Split a line into [{ font: 'body'|'emoji', text }] runs by glyph coverage.
function splitIntoRuns(lineStr, bodyFK, emojiFK) {
  // Fast path: nothing outside Latin-1 can be an emoji — one body run, no segmentation.
  if (!/[^\u0000-\u00FF]/.test(lineStr)) return [{ font: 'body', text: lineStr }];
  const runs = [];
  let cur = null;
  for (const g of segmentGraphemes(lineStr)) {
    const cp = baseCodePoint(g);
    let kind = 'body';
    if (!bodyFK.hasGlyphForCodePoint(cp) && emojiFK && emojiFK.hasGlyphForCodePoint(cp)) {
      kind = 'emoji';
    }
    if (cur && cur.font === kind) cur.text += g;
    else { cur = { font: kind, text: g }; runs.push(cur); }
  }
  return runs;
}

// Embed every registered font into this pdfDoc once, cached by pdfDoc (mirrors pdfme).
async function embedAndGetFontObj(pdfDoc, font, _cache) {
  if (_cache.has(pdfDoc)) return _cache.get(pdfDoc);
  const names = Object.keys(font);
  const values = await Promise.all(names.map((n) => pdfDoc.embedFont(font[n].data, {
    subset: typeof font[n].subset === 'undefined' ? true : font[n].subset,
  })));
  const obj = names.reduce((acc, n, i) => Object.assign(acc, { [n]: values[i] }), {});
  _cache.set(pdfDoc, obj);
  return obj;
}

async function customTextPdfRender(arg) {
  const { value, pdfDoc, pdfLib, page, options, schema, _cache } = arg;
  if (!value) return;

  const { helper, constants: C, sUtils, common } = pdfmeText;
  const { font = common.getDefaultFont(), colorType } = options;
  const bodyFontName = schema.fontName ? schema.fontName : common.getFallbackFontName(font);

  // No emoji font in the registry -> nothing to fall back to; use the stock renderer.
  if (!font[EMOJI_FONT_NAME]) return text.pdf(arg);
  // Rotated text fields need per-run pivot maths we don't replicate; block text is never
  // rotated in practice, so defer those rare cases to the stock single-font renderer.
  if (Number(schema.rotate || 0) !== 0) return text.pdf(arg);

  const [pdfFontObj, bodyFK, emojiFK] = await Promise.all([
    embedAndGetFontObj(pdfDoc, font, _cache),
    helper.getFontKitFont(schema.fontName, font, _cache),
    helper.getFontKitFont(EMOJI_FONT_NAME, font, _cache),
  ]);
  const pdfBodyFont = pdfFontObj[bodyFontName];
  const pdfEmojiFont = pdfFontObj[EMOJI_FONT_NAME];

  // ----- font properties (verbatim from pdfme getFontProp) -----
  const fontSize = schema.dynamicFontSize
    ? helper.calculateDynamicFontSize({ textSchema: schema, fontKitFont: bodyFK, value })
    : (schema.fontSize ?? C.DEFAULT_FONT_SIZE);
  const color = sUtils.hex2PrintingColor(schema.fontColor || C.DEFAULT_FONT_COLOR, colorType);
  const alignment = schema.alignment ?? C.DEFAULT_ALIGNMENT;
  const verticalAlignment = schema.verticalAlignment ?? C.DEFAULT_VERTICAL_ALIGNMENT;
  const lineHeight = schema.lineHeight ?? C.DEFAULT_LINE_HEIGHT;
  const characterSpacing = schema.characterSpacing ?? C.DEFAULT_CHARACTER_SPACING;

  // Scale emoji so their cap height matches the body font's, keeping them on the baseline.
  const bodyAscentRatio = bodyFK.ascent / bodyFK.unitsPerEm;
  const emojiAscentRatio = emojiFK.ascent / emojiFK.unitsPerEm;
  const emojiSize = fontSize * (emojiAscentRatio > 0 ? bodyAscentRatio / emojiAscentRatio : 1);

  const runWidth = (run) => (run.font === 'emoji'
    ? helper.widthOfTextAtSize(run.text, emojiFK, emojiSize, characterSpacing)
    : helper.widthOfTextAtSize(run.text, bodyFK, fontSize, characterSpacing));

  // ----- layout (verbatim from pdfme pdfRender) -----
  const pageHeight = page.getHeight();
  const { width, height, rotate, position: { x, y }, opacity } =
    sUtils.convertForPdfLayoutProps({ schema, pageHeight, applyRotateTranslate: false });

  if (schema.backgroundColor) {
    const bg = sUtils.hex2PrintingColor(schema.backgroundColor, colorType);
    page.drawRectangle({ x, y, width, height, rotate, color: bg });
  }

  const firstLineTextHeight = helper.heightOfFontAtSize(bodyFK, fontSize);
  const descent = helper.getFontDescentInPt(bodyFK, fontSize);
  const halfLineHeightAdjustment = lineHeight === 0 ? 0 : ((lineHeight - 1) * fontSize) / 2;

  const lines = helper.splitTextToSize({ value, characterSpacing, fontSize, fontKitFont: bodyFK, boxWidthInPt: width });

  let yOffset = 0;
  if (verticalAlignment === C.VERTICAL_ALIGN_TOP) {
    yOffset = firstLineTextHeight + halfLineHeightAdjustment;
  } else {
    const otherLinesHeight = lineHeight * fontSize * (lines.length - 1);
    if (verticalAlignment === C.VERTICAL_ALIGN_BOTTOM) {
      yOffset = height - otherLinesHeight + descent - halfLineHeightAdjustment;
    } else if (verticalAlignment === C.VERTICAL_ALIGN_MIDDLE) {
      yOffset = (height - otherLinesHeight - firstLineTextHeight + descent) / 2 + firstLineTextHeight;
    }
  }

  let emojiRuns = 0;
  lines.forEach((rawLine, rowIndex) => {
    const trimmed = rawLine.replace('\n', '');
    if (trimmed === '') return; // empty line: advance a row, draw nothing
    const runs = splitIntoRuns(trimmed, bodyFK, emojiFK);
    const lineWidth = runs.reduce((w, r) => w + runWidth(r), 0);
    const rowYOffset = lineHeight * fontSize * rowIndex;

    let xCursor = x;
    if (alignment === 'center') xCursor += (width - lineWidth) / 2;
    else if (alignment === 'right') xCursor += width - lineWidth;
    const yLine = pageHeight - common.mm2pt(schema.position.y) - yOffset - rowYOffset;

    page.pushOperators(pdfLib.setCharacterSpacing(characterSpacing));
    for (const run of runs) {
      const isEmoji = run.font === 'emoji';
      if (isEmoji) emojiRuns += 1;
      page.drawText(run.text, {
        x: xCursor,
        y: yLine,
        rotate,
        size: isEmoji ? emojiSize : fontSize,
        color,
        lineHeight: lineHeight * fontSize,
        font: isEmoji ? pdfEmojiFont : pdfBodyFont,
        opacity,
      });
      xCursor += runWidth(run) + characterSpacing;
    }
  });

  if (emojiRuns > 0) {
    dbg(`text[name=${JSON.stringify(schema.name)}]: ${emojiRuns} emoji run(s) via ${EMOJI_FONT_NAME} (seg=${GRAPHEME_SEGMENTER ? 'Intl.Segmenter' : 'regex'}, emojiSize=${emojiSize.toFixed(1)})`);
  }
}

// Use the per-glyph fallback renderer when the pdfme helpers loaded; otherwise stock text.
const emojiText = pdfmeText
  ? Object.assign({}, text, {
      pdf: async (arg) => {
        try {
          return await customTextPdfRender(arg);
        } catch (e) {
          dbg(`customTextPdfRender THREW: ${(e && e.stack) || e} — falling back to stock text renderer`);
          return text.pdf(arg);
        }
      },
    })
  : text;

async function generateOne(job, options) {
  if (!job.template || !Array.isArray(job.template.schemas)) {
    throw new Error('job.template.schemas missing or invalid');
  }
  const inputs = Array.isArray(job.inputs) && job.inputs.length > 0 ? job.inputs : [{}];
  return generate({
    template: job.template,
    inputs,
    plugins: { text: emojiText, image: coverImage, line, rectangle, ellipse },
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
