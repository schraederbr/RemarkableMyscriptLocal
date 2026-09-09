#!/usr/bin/env node
// Upsert HWR NOTE.md / HANDOFF.json into jonobones by exact title.
// Optionally uploads page SVGs as Joplin resources and rewrites ![Page N](file.svg) → :/id.
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
    // minimal json5: allow trailing commas stripped roughly via JSON after comment strip
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
 * If your build returns 404, confirm jonobones exposes /resources like desktop Joplin Clipper API.
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
    // Minimal rebuild if fullText missing
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
      // Append under the matching heading if present, else append at end of page section.
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

function separator(docUuid) {
  const ts = new Date().toISOString();
  return `\n\n---\n\n<!-- rm2hwr ${ts} doc=${docUuid || ''} -->\n\n`;
}

async function main() {
  const base = (process.env.JONOBONES_URL || 'http://127.0.0.1:26637/v1').replace(/\/$/, '');
  const token = loadToken();
  const { payload, dir } = loadPayload(process.argv);
  const mode = normalizeMode(payload.uploadMode || process.env.UPLOAD_MODE || 'text');
  if (!payload.title) die('handoff missing title');

  const noteBody = await buildBodyWithResources(base, token, payload, dir, mode);
  if (!noteBody || !String(noteBody).trim()) die('handoff missing body (fullText / pages)');

  // Find by exact title (paginate)
  let page = 1;
  let found = null;
  for (;;) {
    const q = new URLSearchParams({
      page: String(page),
      limit: '100',
      fields: 'id,title,body,parent_id',
      order_by: 'updated_time',
      order_dir: 'desc',
    });
    const list = await api(base, token, 'GET', '/notes?' + q.toString());
    const items = (list && list.items) || [];
    found = items.find((n) => n.title === payload.title) || null;
    if (found || !list.has_more) break;
    page++;
  }

  if (found) {
    const body = (found.body || '') + separator(payload.docUuid) + noteBody;
    await api(base, token, 'PATCH', '/notes/' + found.id, { body });
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
      body: noteBody,
    });
    console.log('created note', created && created.id, JSON.stringify(payload.title), 'mode=' + mode);
  }

  try {
    await api(base, token, 'POST', '/sync', {});
    console.log('sync triggered');
  } catch (e) {
    console.error('sync trigger failed:', e.message);
  }
}

main().catch((e) => die(e.message || String(e)));
