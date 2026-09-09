#!/usr/bin/env node
// Upsert HWR NOTE.md / HANDOFF.json into jonobones by exact title.
// Usage:
//   node joplin-upsert.js /home/root/hwr/out/<doc-uuid>
//   node joplin-upsert.js --handoff /path/HANDOFF.json
// Env:
//   JONOBONES_URL (default http://127.0.0.1:26637/v1)
//   JONOBONES_TOKEN or read from ~/.config/jonobones/default/{lock.json,config.json5}
//   JONOBONES_PARENT_ID optional notebook id for creates

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
      const m = raw.match(/token\s*:\s*['\"]([^'\"]+)['\"]/);
      if (m) return m[1];
    }
  }
  die('no API token (set JONOBONES_TOKEN or run jonobones init)');
}

function loadPayload(argv) {
  let handoffPath = null;
  let dir = null;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--handoff') handoffPath = argv[++i];
    else dir = argv[i];
  }
  if (handoffPath) {
    return JSON.parse(fs.readFileSync(handoffPath, 'utf8'));
  }
  if (!dir) die('usage: joplin-upsert.js <out-doc-dir> | --handoff HANDOFF.json');
  const p = path.join(dir, 'HANDOFF.json');
  if (fs.existsSync(p)) return JSON.parse(fs.readFileSync(p, 'utf8'));
  const md = path.join(dir, 'NOTE.md');
  if (!fs.existsSync(md)) die('no HANDOFF.json or NOTE.md in ' + dir);
  const titleLine = fs.readFileSync(md, 'utf8').split(/\r?\n/)[0] || '';
  const title = titleLine.replace(/^#\s*/, '').trim() || path.basename(dir);
  return { title, fullText: fs.readFileSync(md, 'utf8'), docUuid: path.basename(dir) };
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

function separator(docUuid) {
  const ts = new Date().toISOString();
  return `\n\n---\n\n<!-- rm2hwr ${ts} doc=${docUuid || ''} -->\n\n`;
}

async function main() {
  const base = (process.env.JONOBONES_URL || 'http://127.0.0.1:26637/v1').replace(/\/$/, '');
  const token = loadToken();
  const payload = loadPayload(process.argv);
  if (!payload.title || !payload.fullText) die('handoff missing title/fullText');

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
    const body = (found.body || '') + separator(payload.docUuid) + payload.fullText;
    await api(base, token, 'PATCH', '/notes/' + found.id, { body });
    console.log('updated note', found.id, JSON.stringify(payload.title));
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
      body: payload.fullText,
    });
    console.log('created note', created && created.id, JSON.stringify(payload.title));
  }

  try {
    await api(base, token, 'POST', '/sync', {});
    console.log('sync triggered');
  } catch (e) {
    console.error('sync trigger failed:', e.message);
  }
}

main().catch((e) => die(e.message || String(e)));
