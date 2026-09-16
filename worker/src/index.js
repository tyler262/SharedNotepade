/**
 * Shared Notepad relay.
 *
 * A mailbox that lets two phones exchange notes when they are not on the same
 * Wi-Fi. It is deliberately dumb: it stores one blob per (pad, device), never
 * looks inside, and never merges anything. All merging happens on the phones,
 * which remain the source of truth.
 *
 * Each device writes only its own slot, so concurrent writes cannot collide
 * and there is no locking, versioning or retry logic to get wrong.
 *
 *   POST /v1/pads                              register a pad
 *   PUT  /v1/pads/:padId/slots/:deviceId       upload this device's notes
 *   GET  /v1/pads/:padId/slots?since=&exclude= download the other devices'
 *   GET  /health
 *
 * Auth is a bearer token: the pad secret, which the phones already share.
 * Only a hash of it is stored here. Traffic is HTTPS end to end.
 */

const MAX_BLOB_BYTES = 1_000_000;
const encoder = new TextEncoder();

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Compares two equal-length hex strings without leaking position via timing. */
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function bearer(request) {
  const header = request.headers.get('authorization') || '';
  return header.startsWith('Bearer ') ? header.slice(7) : null;
}

/** Ids come from the phones and land in SQL params, but keep them tidy anyway. */
function validId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{4,64}$/.test(value);
}

/** Resolves the pad and checks the caller's secret. Returns an error Response on failure. */
async function authorize(env, padId, request) {
  if (!validId(padId)) return { error: json({ error: 'bad pad id' }, 400) };

  const secret = bearer(request);
  if (!secret) return { error: json({ error: 'missing bearer token' }, 401) };

  const row = await env.DB.prepare('SELECT secret_hash FROM pads WHERE pad_id = ?')
    .bind(padId)
    .first();
  if (!row) return { error: json({ error: 'no such pad' }, 404) };

  if (!safeEqual(await sha256Hex(secret), row.secret_hash)) {
    return { error: json({ error: 'bad secret' }, 403) };
  }
  return { ok: true };
}

async function registerPad(env, request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'bad json' }, 400);
  }

  const { padId, secret } = body || {};
  if (!validId(padId)) return json({ error: 'bad pad id' }, 400);
  if (typeof secret !== 'string' || secret.length < 16) {
    return json({ error: 'secret too short' }, 400);
  }

  const hash = await sha256Hex(secret);
  const existing = await env.DB.prepare('SELECT secret_hash FROM pads WHERE pad_id = ?')
    .bind(padId)
    .first();

  if (existing) {
    // Re-registering with the same secret is a no-op, so the phones can call
    // this freely without tracking whether they have done it before.
    return safeEqual(hash, existing.secret_hash)
      ? json({ padId, created: false })
      : json({ error: 'pad already exists' }, 409);
  }

  await env.DB.prepare('INSERT INTO pads (pad_id, secret_hash, created_at) VALUES (?, ?, ?)')
    .bind(padId, hash, Date.now())
    .run();
  return json({ padId, created: true }, 201);
}

async function putSlot(env, padId, deviceId, request) {
  if (!validId(deviceId)) return json({ error: 'bad device id' }, 400);

  const blob = await request.text();
  if (blob.length > MAX_BLOB_BYTES) return json({ error: 'payload too large' }, 413);
  try {
    JSON.parse(blob);
  } catch {
    return json({ error: 'bad json' }, 400);
  }

  const updatedAt = Date.now();
  await env.DB.prepare(
    `INSERT INTO slots (pad_id, device_id, blob, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT (pad_id, device_id) DO UPDATE SET blob = excluded.blob, updated_at = excluded.updated_at`,
  )
    .bind(padId, deviceId, blob, updatedAt)
    .run();

  return json({ updatedAt });
}

async function getSlots(env, padId, url) {
  const since = Number(url.searchParams.get('since') || 0);
  const exclude = url.searchParams.get('exclude') || '';

  const { results } = await env.DB.prepare(
    `SELECT device_id, blob, updated_at FROM slots
     WHERE pad_id = ? AND updated_at >= ? AND device_id != ?
     ORDER BY updated_at ASC`,
  )
    .bind(padId, Number.isFinite(since) ? since : 0, exclude)
    .all();

  return json({
    now: Date.now(),
    slots: (results || []).map((r) => ({
      deviceId: r.device_id,
      updatedAt: r.updated_at,
      // Passed through untouched — the relay does not parse note contents.
      notes: JSON.parse(r.blob).notes ?? [],
    })),
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/health') return json({ ok: true });

    // /v1/pads
    if (request.method === 'POST' && parts.length === 2 && parts[0] === 'v1' && parts[1] === 'pads') {
      return registerPad(env, request);
    }

    // /v1/pads/:padId/slots[/:deviceId]
    if (parts[0] === 'v1' && parts[1] === 'pads' && parts[3] === 'slots') {
      const padId = parts[2];
      const auth = await authorize(env, padId, request);
      if (auth.error) return auth.error;

      if (request.method === 'PUT' && parts.length === 5) {
        return putSlot(env, padId, parts[4], request);
      }
      if (request.method === 'GET' && parts.length === 4) {
        return getSlots(env, padId, url);
      }
    }

    return json({ error: 'not found' }, 404);
  },
};
