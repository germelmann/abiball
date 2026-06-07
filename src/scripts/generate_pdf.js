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
    plugins: { text, image, line, rectangle, ellipse },
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
