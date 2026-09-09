#!/usr/bin/env node
// Upsert HWR NOTE.md / HANDOFF.json into jonobones by exact title.
// Optionally uploads page SVGs as Joplin resources and rewrites ![Page N](file.svg) → :/id.
// Updates REPLACE the marked HWR block (<!-- rm2hwr:begin --> … <!-- rm2hwr:end -->)
// instead of appending forever; user content outside the markers is preserved.
// Usage:
//   node joplin-upsert.js /home/root/hwr/out/<doc-uuid>
//   node joplin-upsert.js --handoff /path/HANDOFF.json
// Env:
//   JONOBONES_URL (default http://127.0.0.1:26637/v1)
//   JONOBONES_TOKEN or read from ~/.config/jonobones/default/{lock.json,config.json5}
//   JONOBONES_PARENT_ID optional notebook id for creates
//   UPLOAD_MODE text|svg|both (fallback when payload.uploadMode missing; default text)

const fs = require('fs');
const path = require('path');
const os = require('os');

const HWR_BEGIN = '<!-- rm2hwr:begin -->';
const HWR_END = '<!-- rm2hwr:end -->';
// Legacy append separators from earlier joplin-upsert versions
const OLD_SEP_RE = /<!--\s*rm2hwr\b(?!:begin|:end)[^>]*-->/;

function die(msg, code = 1) {
  console.error('joplin-upsert:', msg);
  process.exit(code);
}

function loadToken() {
  if (process.env.JONOBONES_TOKEN) return process.env.JONOBONES_TOKEN.trim();
  const profile = process.env.JONOBONES_PROFILE || path.join(os.homedir(), '.config/jonobones/default');
  const lockPath = path.join(profile, 'lock.json');
  if (fs.existsSync(lockPath)) {
    const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
    if (lock.token) return lock.token;
  }
  const cfgPath = path.join(profile, 'config.json5');
  if (fs.existsSync(cfgPath)) {
    const raw = fs.readFileSync(cfgPath, 'utf8').replace(/^\s*\/\/.*$/gm, '');
    try {
      const cfg = JSON.parse(raw);
      if (cfg.api && cfg.api.token) return cfg.api.token;
    } catch (_) {
      const m = raw.match(/token\s*:\s*['"]([^'"]+)['"]/);
      if (m) return m[1];
    }
  }
  die('no API token (set JONOBONES_TOKEN or run jonobones init)');
}

function normalizeMode(mode) {
  const m = String(mode || '').trim().toLowerCase();
  if (m === 'svg' || m === 'both') return m;
  return 'text';
}

function loadPayload(argv) {
  let handoffPath = null;
  let dir = null;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--handoff') handoffPath = argv[++i];
    else dir = argv[i];
  }
  if (handoffPath) {
    const payload = JSON.parse(fs.readFileSync(handoffPath, 'utf8'));
    return { payload, dir: dir || path.dirname(handoffPath) };
  }
  if (!dir) die('usage: joplin-upsert.js <out-doc-dir> | --handoff HANDOFF.json');
  const p = path.join(dir, 'HANDOFF.json');
  if (fs.existsSync(p)) {
    return { payload: JSON.parse(fs.readFileSync(p, 'utf8')), dir };
  }
  const md = path.join(dir, 'NOTE.md');
  if (!fs.existsSync(md)) die('no HANDOFF.json or NOTE.md in ' + dir);
  const titleLine = fs.readFileSync(md, 'utf8').split(/\r?\n/)[0] || '';
  const title = titleLine.replace(/^#\s*/, '').trim() || path.basename(dir);
  return {
    payload: { title, fullText: fs.readFileSync(md, 'utf8'), docUuid: path.basename(dir) },
    dir,
  };
}

async function api(base, token, method, route, body) {
  const res = await fetch(base + route, {
    method,
    headers: {
      Authorization: 'Bearer ' + token,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch (_) {}
  if (!res.ok) {
    const msg = json && json.error ? json.error.message : text;
    throw new Error(method + ' ' + route + ' → ' + res.status + ' ' + msg);
  }
  return json;
}

/**
 * Upload an SVG as a Joplin resource.
 * Joplin / jonobones: POST /resources multipart with fields:
 *   data = file, props = JSON string (required even if "{}")
 * Endpoint is under the same /v1 base as notes (e.g. http://127.0.0.1:26637/v1/resources).
 */
async function uploadResource(base, token, filePath, title) {
  const buf = fs.readFileSync(filePath);
  const form = new FormData();
  const blob = new Blob([buf], { type: 'image/svg+xml' });
  form.append('data', blob, path.basename(filePath));
  form.append('props', JSON.stringify({ title: title || path.basename(filePath) }));
  const res = await fetch(base + '/resources', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    body: form,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch (_) {}
  if (!res.ok) {
    const msg = json && json.error ? json.error.message : text;
    throw new Error('POST /resources → ' + res.status + ' ' + msg);
  }
  if (!json || !json.id) {
    throw new Error('POST /resources: response missing id: ' + text.slice(0, 200));
  }
  return json.id;
}

function wantSVG(mode) {
  return mode === 'svg' || mode === 'both';
}

function wantText(mode) {
  return mode === 'text' || mode === 'both';
}

async function buildBodyWithResources(base, token, payload, dir, mode) {
  let body = payload.fullText || '';
  if (!body && Array.isArray(payload.pages)) {
    const lines = ['# ' + (payload.title || '')];
    let first = true;
    for (const p of payload.pages) {
      if (p.status !== 'OK' && p.status !== 'EMPTY' && p.status !== 'SKIP') continue;
      const pageN = (p.index | 0) + 1;
      const hasSvg = wantSVG(mode) && p.svgPath;
      const text = wantText(mode) ? String(p.text || '').replace(/\n+$/, '') : '';
      if (!hasSvg && !text) continue;
      lines.push(first ? '' : '');
      if (!first) lines.push('---', '');
      first = false;
      lines.push('## Page ' + pageN, '');
      if (hasSvg) lines.push('![Page ' + pageN + '](' + path.basename(p.svgPath) + ')', '');
      if (text) lines.push(text);
    }
    body = lines.join('\n') + '\n';
  }

  if (!wantSVG(mode)) return body;

  const pages = Array.isArray(payload.pages) ? payload.pages : [];
  for (const p of pages) {
    if (!p || !p.svgPath) continue;
    const pageN = (p.index | 0) + 1;
    const rel = p.svgPath;
    const abs = path.isAbsolute(rel) ? rel : path.join(dir, rel);
    if (!fs.existsSync(abs)) {
      console.error('joplin-upsert: warn: missing SVG', abs);
      continue;
    }
    const resTitle = 'Page ' + pageN + ' — ' + (payload.title || 'page') + '.svg';
    let resourceId;
    try {
      resourceId = await uploadResource(base, token, abs, resTitle);
    } catch (e) {
      console.error('joplin-upsert: warn: resource upload failed for', abs, e.message || e);
      continue;
    }
    const baseName = path.basename(rel);
    const localRe = new RegExp('!\\[Page ' + pageN + '\\]\\(' + escapeRegExp(baseName) + '\\)', 'g');
    const embed = '![Page ' + pageN + '](:/' + resourceId + ')';
    if (localRe.test(body)) {
      body = body.replace(localRe, embed);
    } else {
      const heading = '## Page ' + pageN;
      const idx = body.indexOf(heading);
      if (idx >= 0) {
        const insertAt = idx + heading.length;
        body = body.slice(0, insertAt) + '\n\n' + embed + body.slice(insertAt);
      } else {
        body += '\n\n' + embed + '\n';
      }
    }
    console.log('uploaded resource', resourceId, baseName);
  }
  return body;
}

function escapeRegExp(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Wrap HWR markdown in stable HTML-comment markers for replace-on-update. */
function wrapHwrBlock(hwrBody, docUuid) {
  const ts = new Date().toISOString();
  const meta = '<!-- rm2hwr:meta ts=' + ts + ' doc=' + (docUuid || '') + ' -->';
  const inner = String(hwrBody || '').replace(/^\n+/, '').replace(/\n+$/, '');
  return HWR_BEGIN + '\n' + meta + '\n\n' + inner + '\n\n' + HWR_END;
}

function looksLikeHwrOnly(body) {
  const t = String(body || '').trim();
  if (!t) return true;
  if (/^#\s/.test(t) && /##\s+Page\s+\d+/.test(t)) return true;
  const m = t.match(OLD_SEP_RE);
  if (m) {
    const before = t.slice(0, t.indexOf(m[0])).trim();
    if (!before || before === '---') return true;
  }
  return false;
}

/**
 * Merge new HWR into an existing note body:
 * - If <!-- rm2hwr:begin -->…<!-- rm2hwr:end --> exist, replace that span.
 * - Else migrate legacy <!-- rm2hwr … --> append separators into one marked block
 *   (preserve content before the first separator).
 * - Else if body looks like only prior HWR output, overwrite with marked block.
 * - Else append a new marked block (preserves unknown user content once).
 */
function mergeHwrIntoBody(existingBody, hwrBody, docUuid) {
  const marked = wrapHwrBlock(hwrBody, docUuid);
  const existing = existingBody == null ? '' : String(existingBody);

  const beginIdx = existing.indexOf(HWR_BEGIN);
  const endIdx = existing.indexOf(HWR_END);
  if (beginIdx >= 0 && endIdx > beginIdx) {
    const afterEnd = endIdx + HWR_END.length;
    const before = existing.slice(0, beginIdx).replace(/\s+$/, '');
    const after = existing.slice(afterEnd).replace(/^\s+/, '');
    const parts = [];
    if (before) parts.push(before);
    parts.push(marked.trimEnd());
    if (after) parts.push(after);
    return parts.join('\n\n') + (after ? '' : '\n');
  }

  const oldMatch = existing.match(OLD_SEP_RE);
  if (oldMatch) {
    const idx = existing.indexOf(oldMatch[0]);
    let before = existing.slice(0, idx).replace(/\s+$/, '').replace(/\n*---\s*$/, '').replace(/\s+$/, '');
    if (!before || looksLikeHwrOnly(before)) {
      return marked + '\n';
    }
    return before + '\n\n' + marked + '\n';
  }

  if (looksLikeHwrOnly(existing)) {
    return marked + '\n';
  }

  const trimmed = existing.replace(/\s+$/, '');
  return trimmed + '\n\n' + marked + '\n';
}

async function main() {
  const base = (process.env.JONOBONES_URL || 'http://127.0.0.1:26637/v1').replace(/\/$/, '');
  const token = loadToken();
  const { payload, dir } = loadPayload(process.argv);
  const mode = normalizeMode(payload.uploadMode || process.env.UPLOAD_MODE || 'text');
  if (!payload.title) die('handoff missing title');

  const noteBody = await buildBodyWithResources(base, token, payload, dir, mode);
  if (!noteBody || !String(noteBody).trim()) die('handoff missing body (fullText / pages)');

  let page = 1;
  let found = null;
  for (;;) {
    const q = new URLSearchParams({
      page: String(page),
      limit: '100',
      fields: 'id,title,body,parent_id',
      order_by: 'updated_time',
      order_dir: 'DESC',
    });
    const list = await api(base, token, 'GET', '/notes?' + q.toString());
    const items = (list && list.items) || [];
    found = items.find((n) => n.title === payload.title) || null;
    if (found || !list.has_more) break;
    page++;
  }

  let noteId = null;
  if (found) {
    const body = mergeHwrIntoBody(found.body || '', noteBody, payload.docUuid);
    await api(base, token, 'PATCH', '/notes/' + found.id, { body });
    noteId = found.id;
    console.log('updated note', found.id, JSON.stringify(payload.title), 'mode=' + mode);
  } else {
    let parentId = process.env.JONOBONES_PARENT_ID || '';
    if (!parentId) {
      const nb = await api(base, token, 'GET', '/notebooks?limit=100&fields=id,title,parent_id');
      const notebooks = (nb && nb.items) || [];
      if (!notebooks.length) die('no notebooks; create one in Joplin or set JONOBONES_PARENT_ID');
      parentId = notebooks[0].id;
      console.log('using notebook', parentId, notebooks[0].title || '');
    }
    const created = await api(base, token, 'POST', '/notes', {
      parent_id: parentId,
      title: payload.title,
      body: wrapHwrBlock(noteBody, payload.docUuid) + '\n',
    });
    noteId = created && created.id;
    console.log('created note', noteId, JSON.stringify(payload.title), 'mode=' + mode);
  }

  if (noteId) {
    console.log('NOTE_ID=' + noteId);
  }

  try {
    await api(base, token, 'POST', '/sync', {});
    console.log('sync triggered');
  } catch (e) {
    console.error('sync trigger failed:', e.message);
  }
}

main().catch((e) => die(e.message || String(e)));
