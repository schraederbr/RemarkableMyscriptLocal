#!/usr/bin/env node
// Upsert HWR NOTE.md / HANDOFF.json into jonobones by exact title.
// Optionally uploads page SVGs as Joplin resources and rewrites ![Page N](file.svg) → :/id.
// Updates REPLACE the marked HWR block (<!-- rm2hwr:begin --> … <!-- rm2hwr:end -->)
// instead of appending forever; user content outside the markers is preserved.
// Always POST /sync + wait for idle (GET /status) BEFORE title match so the local
// vault has latest Cloud notes; triggers sync again after create/update to push.
// Usage:
//   node joplin-upsert.js /home/root/hwr/out/<doc-uuid>
//   node joplin-upsert.js --handoff /path/HANDOFF.json
// Env:
//   JONOBONES_URL (default http://127.0.0.1:26637/v1)
//   JONOBONES_TOKEN or read from ~/.config/jonobones/default/{lock.json,config.json5}
//   JONOBONES_PARENT_ID optional notebook id for creates (wins over TITLE)
//   JONOBONES_PARENT_TITLE optional exact notebook title for creates (if PARENT_ID unset)
//   If both PARENT_* unset: create under the notebook with the most notes
//     (paginate GET /notes?fields=id,parent_id; count by parent_id among GET /notebooks;
//      tie-break: keep first max). Logs: using notebook <id> <title> (N notes)
//   Also loads /home/root/hwr/conf/jonobones.env if present (does not override existing env).
//   UPLOAD_MODE text|svg|both (fallback when payload.uploadMode missing; default text)
//   JONOBONES_SYNC_TIMEOUT_MS (default 180000) / JONOBONES_SYNC_POLL_MS (default 500)
//   JONOBONES_SYNC_IDLE_GRACE_MS (default 2000) — wait before accepting idle if syncing not seen

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

/** Load KEY=VALUE lines into process.env without overriding existing keys. */
function loadEnvFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return;
  const raw = fs.readFileSync(filePath, 'utf8').replace(/\r/g, '');
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const eq = t.indexOf('=');
    if (eq <= 0) continue;
    const key = t.slice(0, eq).trim();
    let val = t.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (process.env[key] === undefined || process.env[key] === '') {
      process.env[key] = val;
    }
  }
}

function maybeLoadJonobonesEnv() {
  const candidates = [
    process.env.JONOBONES_ENV,
    '/home/root/hwr/conf/jonobones.env',
    path.join(__dirname, '..', 'conf', 'jonobones.env'),
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      loadEnvFile(c);
      break;
    }
  }
}

async function listAll(base, token, route, fields) {
  const items = [];
  let page = 1;
  for (;;) {
    const q = new URLSearchParams({
      page: String(page),
      limit: '100',
      fields: fields,
    });
    const list = await api(base, token, 'GET', route + '?' + q.toString());
    const batch = (list && list.items) || [];
    items.push(...batch);
    if (!list || !list.has_more) break;
    page++;
  }
  return items;
}

/**
 * Resolve notebook parent for creates:
 * - JONOBONES_PARENT_ID if set
 * - else exact title match for JONOBONES_PARENT_TITLE
 * - else notebook with the most notes (tie-break: first max among notebooks list order)
 */
async function resolveParentId(base, token) {
  const parentIdEnv = (process.env.JONOBONES_PARENT_ID || '').trim();
  if (parentIdEnv) return { parentId: parentIdEnv, title: '', noteCount: null, how: 'env-id' };

  const notebooks = await listAll(base, token, '/notebooks', 'id,title,parent_id');
  if (!notebooks.length) die('no notebooks; create one in Joplin or set JONOBONES_PARENT_ID');

  const parentTitle = (process.env.JONOBONES_PARENT_TITLE || '').trim();
  if (parentTitle) {
    const match = notebooks.find((n) => n.title === parentTitle);
    if (!match) die('JONOBONES_PARENT_TITLE not found among notebooks: ' + JSON.stringify(parentTitle));
    const notes = await listAll(base, token, '/notes', 'id,parent_id');
    let n = 0;
    for (const note of notes) {
      if (note.parent_id === match.id) n++;
    }
    console.log('using notebook', match.id, match.title || '', '(' + n + ' notes)');
    return { parentId: match.id, title: match.title || '', noteCount: n, how: 'env-title' };
  }

  const notes = await listAll(base, token, '/notes', 'id,parent_id');
  const counts = Object.create(null);
  for (const note of notes) {
    const pid = note.parent_id || '';
    if (!pid) continue;
    counts[pid] = (counts[pid] || 0) + 1;
  }

  let best = notebooks[0];
  let bestCount = counts[best.id] || 0;
  for (let i = 1; i < notebooks.length; i++) {
    const nb = notebooks[i];
    const c = counts[nb.id] || 0;
    if (c > bestCount) {
      best = nb;
      bestCount = c;
    }
  }
  console.log('using notebook', best.id, best.title || '', '(' + bestCount + ' notes)');
  return { parentId: best.id, title: best.title || '', noteCount: bestCount, how: 'most-notes' };
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
  const mdText = fs.readFileSync(md, 'utf8');
  const titleLine = mdText.split(/\r?\n/)[0] || '';
  // Legacy NOTE.md started with "# <visibleName>"; current bodies start with Remarkable:
  let title = '';
  if (/^#\s+/.test(titleLine) && !/^#+\s*Page\s+\d+/i.test(titleLine)) {
    title = titleLine.replace(/^#\s*/, '').trim();
  }
  if (!title) title = path.basename(dir);
  return {
    payload: { title, fullText: mdText, docUuid: path.basename(dir) },
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


/** Strip a leading "# <title>" H1 when it duplicates the Joplin note title field. */
function stripLeadingTitleH1(body, title) {
  const t = String(title || '').trim();
  if (!t) return String(body || '');
  const re = new RegExp('^#\\s+' + escapeRegExp(t) + '\\s*\\r?\\n+', '');
  return String(body || '').replace(re, '');
}

async function buildBodyWithResources(base, token, payload, dir, mode) {
  let body = payload.fullText || '';
  if (!body && Array.isArray(payload.pages)) {
    // No H1 title in body — Joplin already displays the note title field.
    const lines = [];
    let first = true;
    for (const p of payload.pages) {
      if (p.status !== 'OK' && p.status !== 'EMPTY' && p.status !== 'SKIP') continue;
      const pageN = (p.index | 0) + 1;
      const hasSvg = wantSVG(mode) && p.svgPath;
      const text = wantText(mode) ? String(p.text || '').replace(/\n+$/, '') : '';
      if (!hasSvg && !text) continue;
      if (!first) lines.push('', '---', '');
      first = false;
      lines.push('Remarkable:', 'Page ' + pageN, '');
      if (hasSvg) lines.push('![Page ' + pageN + '](' + path.basename(p.svgPath) + ')', '');
      if (text) lines.push(text);
    }
    body = lines.join('\n') + '\n';
  } else {
    // Drop legacy "# <title>" H1 from older HANDOFF/NOTE.md so Joplin body has no duplicate heading.
    body = stripLeadingTitleH1(body, payload.title);
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
      // Prefer new plain lines: Remarkable:\nPage N  (or bare Page N); else legacy ## Page N
      const remarkable = 'Remarkable:\nPage ' + pageN;
      const barePage = 'Page ' + pageN;
      const legacy = '## Page ' + pageN;
      let insertAt = -1;
      let idx = body.indexOf(remarkable);
      if (idx >= 0) {
        insertAt = idx + remarkable.length;
      } else {
        const reBare = new RegExp('(?:^|\n)(Page ' + pageN + ')(?=\n|$)');
        const m = reBare.exec(body);
        if (m) {
          insertAt = m.index + (m[0].startsWith('\n') ? 1 : 0) + barePage.length;
        } else {
          idx = body.indexOf(legacy);
          if (idx >= 0) insertAt = idx + legacy.length;
        }
      }
      if (insertAt >= 0) {
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
  // Current HWR: plain Remarkable: / Page N (no leading H1 title)
  if (/^Remarkable:\s*\nPage\s+\d+/.test(t)) return true;
  // Legacy: leading # title plus ## Page N or Remarkable: / Page N
  if (/^#\s/.test(t) && (/##\s+Page\s+\d+/.test(t) || /(?:^|\n)Remarkable:\s*\nPage\s+\d+/.test(t))) return true;
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


/**
 * Trigger jonobones sync and wait until settled.
 * POST /sync -> 202 {syncing, alreadyRunning}; poll GET /status until
 * sync.state is idle|error|unconfigured (or timeout).
 * @returns {object|null} last /status payload, or null on hard failure
 */
async function syncAndWait(base, token, label) {
  const tag = label || 'sync';
  const timeoutMs = parseInt(process.env.JONOBONES_SYNC_TIMEOUT_MS || '180000', 10) || 180000;
  const pollMs = parseInt(process.env.JONOBONES_SYNC_POLL_MS || '500', 10) || 500;
  // Avoid accepting a pre-trigger idle snapshot before the background sync flips to syncing.
  const idleGraceMs = parseInt(process.env.JONOBONES_SYNC_IDLE_GRACE_MS || '2000', 10) || 2000;

  let beforeCompleted = null;
  try {
    const before = await api(base, token, 'GET', '/status');
    beforeCompleted = before && before.sync ? before.sync.lastCompletedAt : null;
  } catch (_) {
    // proceed; POST /sync will fail loudly if the daemon is down
  }

  try {
    const res = await api(base, token, 'POST', '/sync', {});
    const already = res && res.alreadyRunning ? ' (already running)' : '';
    console.log(tag + ' triggered' + already);
  } catch (e) {
    console.error(tag + ' trigger failed:', e.message || e);
  }

  const start = Date.now();
  let lastStatus = null;
  let sawSyncing = false;
  for (;;) {
    try {
      lastStatus = await api(base, token, 'GET', '/status');
    } catch (e) {
      console.error(tag + ' status poll failed:', e.message || e);
      return null;
    }
    const sync = (lastStatus && lastStatus.sync) || {};
    const state = sync.state || '';
    if (state === 'syncing') sawSyncing = true;

    if (state === 'error' || state === 'unconfigured') {
      const result = sync.lastResult != null ? String(sync.lastResult) : '';
      console.log(tag + ' settled state=' + state + (result ? ' lastResult=' + result : ''));
      console.error('joplin-upsert: warn: ' + tag + ' state=' + state + '; proceeding with local vault');
      return lastStatus;
    }

    if (state === 'idle') {
      const completed = sync.lastCompletedAt;
      const completedAdvanced =
        beforeCompleted != null && completed != null && String(completed) !== String(beforeCompleted);
      const elapsed = Date.now() - start;
      // Require evidence the sync ran: saw syncing, lastCompletedAt advanced, or idle grace elapsed.
      if (sawSyncing || completedAdvanced || elapsed >= idleGraceMs) {
        const result = sync.lastResult != null ? String(sync.lastResult) : '';
        console.log(
          tag + ' settled state=idle' +
          (result ? ' lastResult=' + result : '') +
          (sawSyncing ? '' : completedAdvanced ? ' (completedAt advanced)' : ' (idle grace)')
        );
        return lastStatus;
      }
    }

    if (Date.now() - start > timeoutMs) {
      console.error(
        'joplin-upsert: warn: ' + tag + ' wait timed out after ' + timeoutMs +
        'ms (state=' + state + '); proceeding with local vault'
      );
      return lastStatus;
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}

async function main() {
  maybeLoadJonobonesEnv();
  const base = (process.env.JONOBONES_URL || 'http://127.0.0.1:26637/v1').replace(/\/$/, '');
  const token = loadToken();
  const { payload, dir } = loadPayload(process.argv);
  const mode = normalizeMode(payload.uploadMode || process.env.UPLOAD_MODE || 'text');
  if (!payload.title) die('handoff missing title');

  // Pull latest notes from sync target BEFORE title match (fixes create-instead-of-update
  // when Cloud already has the note but the tablet vault is stale).
  await syncAndWait(base, token, 'sync-pull');

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
    const resolved = await resolveParentId(base, token);
    const parentId = resolved.parentId;
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

  // Push local create/update upstream (wait so callers see sync progress in logs).
  await syncAndWait(base, token, 'sync-push');
}

main().catch((e) => die(e.message || String(e)));
