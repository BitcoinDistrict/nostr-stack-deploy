import http from 'node:http';
import { Router } from 'itty-router';
import fetch from 'node-fetch';
import { secp256k1 } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';

const PORT = Number(process.env.PORT || 3000);
const CACHE_TTL = Number(process.env.CACHE_TTL || 300);
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';
const GATE_MODE = process.env.GATE_MODE || 'nip05';
const ALLOWLIST_FILE = process.env.ALLOWLIST_FILE || '';
const SKEW_SECONDS = Number(process.env.SKEW_SECONDS || 60);
// If provided, when X-NIP05 is absent we will verify that the signer pubkey
// appears in this domain's .well-known/nostr.json names map
const REQUIRED_NIP05_DOMAIN = (process.env.REQUIRED_NIP05_DOMAIN || process.env.NOSTR_AUTH_REQUIRED_NIP05_DOMAIN || '').toLowerCase();

const log = (level, msg, ctx = {}) => {
  const levels = ['error', 'warn', 'info', 'debug'];
  if (levels.indexOf(level) <= levels.indexOf(LOG_LEVEL)) {
    console.log(JSON.stringify({ level, msg, ...ctx }))
  }
};

const nip05Cache = new Map();
const domainJsonCache = new Map();

async function readAllowlist() {
  if (!ALLOWLIST_FILE) return new Set();
  try {
    const fs = await import('node:fs/promises');
    const text = await fs.readFile(ALLOWLIST_FILE, 'utf8');
    return new Set(
      text
        .split(/\r?\n/)
        .map((s) => s.trim().toLowerCase())
        .filter((s) => s)
    );
  } catch (e) {
    log('warn', 'allowlist read failed', { error: String(e) });
    return new Set();
  }
}

function bytesToHex(bytes) { return Buffer.from(bytes).toString('hex'); }
function hexToBytes(hex) { return Buffer.from(hex, 'hex'); }

function verifyNip98(authHeader, ctx = {}) {
  if (!authHeader || !authHeader.startsWith('Nostr ')) return null;
  const payloadB64 = authHeader.slice('Nostr '.length).trim();
  let event;
  try {
    const json = Buffer.from(payloadB64, 'base64url').toString('utf8');
    event = JSON.parse(json);
  } catch (e) {
    return null;
  }

  const { pubkey, sig, id, kind, created_at, tags, content } = event || {};
  if (!pubkey || !sig || !id || typeof kind !== 'number' || !Array.isArray(tags)) return null;
  if (kind !== 27235) return null;

  // created_at MUST be within a reasonable time window (default 60s)
  const now = Math.floor(Date.now() / 1000);
  if (typeof created_at !== 'number' || Math.abs(now - created_at) > SKEW_SECONDS) {
    return null;
  }

  try {
    const serialized = JSON.stringify([0, pubkey, created_at, kind, tags, content ?? '']);
    const recomputed = bytesToHex(sha256(Buffer.from(serialized)));
    if (recomputed !== id.toLowerCase()) return null;
    const ok = secp256k1.schnorr.verify(hexToBytes(sig), hexToBytes(id), hexToBytes(pubkey));
    if (!ok) return null;
  } catch (_) {
    return null;
  }

  const urlTag = (tags || []).find((t) => Array.isArray(t) && t[0] === 'u');
  const methodTag = (tags || []).find((t) => Array.isArray(t) && t[0] === 'method');
  if (urlTag && ctx.expectedUrl && typeof urlTag[1] === 'string') {
    const signed = urlTag[1].replace(/\/$/, '');
    const expected = ctx.expectedUrl.replace(/\/$/, '');
    if (signed !== expected) return null;
  }
  if (methodTag && ctx.expectedMethod && typeof methodTag[1] === 'string') {
    if (methodTag[1].toUpperCase() !== ctx.expectedMethod.toUpperCase()) return null;
  }
  return pubkey.toLowerCase();
}

function verifyLegacy24242(authHeader, ctx = {}) {
  if (!authHeader || !authHeader.startsWith('Nostr ')) return null;
  const payloadB64 = authHeader.slice('Nostr '.length).trim();
  let event;
  try {
    const json = Buffer.from(payloadB64, 'base64url').toString('utf8');
    event = JSON.parse(json);
  } catch (e) {
    return null;
  }

  const { pubkey, sig, id, kind, created_at, tags, content } = event || {};
  if (!pubkey || !sig || !id || typeof kind !== 'number' || !Array.isArray(tags)) return null;
  if (kind !== 24242) return null;

  try {
    const serialized = JSON.stringify([0, pubkey, created_at, kind, tags, content ?? '']);
    const recomputed = bytesToHex(sha256(Buffer.from(serialized)));
    if (recomputed !== id.toLowerCase()) return null;
    const ok = secp256k1.schnorr.verify(hexToBytes(sig), hexToBytes(id), hexToBytes(pubkey));
    if (!ok) return null;
  } catch (_) {
    return null;
  }

  // Require tag t=upload
  const tTag = (tags || []).find((t) => Array.isArray(t) && t[0] === 't');
  if (!tTag || String(tTag[1]).toLowerCase() !== 'upload') return null;
  // Require not expired per expiration tag
  const expTag = (tags || []).find((t) => Array.isArray(t) && t[0] === 'expiration');
  if (!expTag) return null;
  const exp = Number(expTag[1] || 0);
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(exp) || now > exp) return null;

  return pubkey.toLowerCase();
}

function verifyAnyAuth(authHeader, ctx = {}) {
  const pk98 = verifyNip98(authHeader, ctx);
  if (pk98) return { pubkey: pk98, scheme: 'nip98' };
  const pk24242 = verifyLegacy24242(authHeader, ctx);
  if (pk24242) return { pubkey: pk24242, scheme: '24242' };
  return null;
}

async function resolveNip05(nameAtDomain) {
  const key = nameAtDomain.toLowerCase();
  const cached = nip05Cache.get(key);
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expiresAt > now) return cached.pubkey;

  const [name, domain] = key.split('@');
  if (!name || !domain) return null;
  try {
    const url = `https://${domain}/.well-known/nostr.json?name=${encodeURIComponent(name)}`;
    const res = await fetch(url, { timeout: 5000 });
    if (!res.ok) return null;
    const data = await res.json();
    const mapping = data?.names || {};
    const pk = (mapping[name] || '').toLowerCase();
    if (pk) {
      nip05Cache.set(key, { pubkey: pk, expiresAt: now + CACHE_TTL });
      return pk;
    }
    return null;
  } catch (e) {
    log('warn', 'nip05 resolve failed', { key, error: String(e) });
    return null;
  }
}

async function domainHasPubkey(domain, pubkey) {
  const key = `domain:${domain}`;
  const cached = domainJsonCache.get(key);
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expiresAt > now) return cached.pubkeys.has(pubkey);

  try {
    const url = `https://${domain}/.well-known/nostr.json`;
    const res = await fetch(url, { timeout: 5000 });
    if (!res.ok) return false;
    const data = await res.json();
    const names = (data?.names) || {};
    const set = new Set(Object.values(names).map((v) => String(v || '').toLowerCase()).filter(Boolean));
    domainJsonCache.set(key, { pubkeys: set, expiresAt: now + CACHE_TTL });
    return set.has(pubkey);
  } catch (e) {
    log('warn', 'domain nostr.json fetch failed', { domain, error: String(e) });
    return false;
  }
}

const router = Router();
router.get('/health', () => new Response('ok'));

router.all('/auth', async (request) => {
  if (GATE_MODE === 'open') return new Response('ok', { status: 200 });

  const authz = request.headers.get('authorization') || request.headers.get('Authorization');
  const nip05 = request.headers.get('x-nip05') || request.headers.get('X-NIP05');
  const host = request.headers.get('x-original-host') || request.headers.get('host');
  const uri = request.headers.get('x-original-uri') || '/';
  const method = request.headers.get('x-original-method') || 'POST';
  const requestScheme = request.headers.get('x-original-scheme') || 'https';
  const expectedUrl = `${requestScheme}://${host}${uri}`;

  const verified = verifyAnyAuth(authz, { expectedUrl, expectedMethod: method });
  if (!verified) {
    log('info', 'auth reject', { reason: 'missing/invalid authorization', host, uri, method });
    return new Response('missing/invalid authorization', { status: 401 });
  }
  const { pubkey, scheme } = verified;

  if (GATE_MODE === 'allowlist') {
    const list = await readAllowlist();
    if (list.has(pubkey)) {
      log('info', 'auth ok', { mode: GATE_MODE, scheme, pubkey, host, uri, method });
      return new Response('ok', { status: 200 });
    }
    log('info', 'auth reject', { reason: 'not in allowlist', mode: GATE_MODE, scheme, pubkey, host, uri, method });
    return new Response('forbidden', { status: 403 });
  }

  // nip05 mode
  if (nip05) {
    const resolved = await resolveNip05(nip05);
    if (!resolved) { log('info', 'auth reject', { reason: 'nip05 not found', nip05, scheme, pubkey, host, uri, method }); return new Response('nip05 not found', { status: 403 }); }
    if (resolved !== pubkey) { log('info', 'auth reject', { reason: 'nip05/pubkey mismatch', nip05, scheme, pubkey, host, uri, method }); return new Response('nip05/pubkey mismatch', { status: 403 }); }
    log('info', 'auth ok', { mode: GATE_MODE, scheme, pubkey, nip05, host, uri, method });
    return new Response('ok', { status: 200 });
  }

  if (REQUIRED_NIP05_DOMAIN) {
    const ok = await domainHasPubkey(REQUIRED_NIP05_DOMAIN, pubkey);
    if (!ok) { log('info', 'auth reject', { reason: 'not verified on required domain', domain: REQUIRED_NIP05_DOMAIN, scheme, pubkey, host, uri, method }); return new Response('nip05 not verified on required domain', { status: 403 }); }
    log('info', 'auth ok', { mode: GATE_MODE, scheme, pubkey, domain: REQUIRED_NIP05_DOMAIN, host, uri, method });
    return new Response('ok', { status: 200 });
  }

  log('info', 'auth reject', { reason: 'missing X-NIP05', scheme, pubkey, host, uri, method });
  return new Response('missing X-NIP05', { status: 400 });
  return new Response('ok', { status: 200 });
});

const server = http.createServer(async (req, res) => {
  try {
    const url = `http://local${req.url}`;
    const request = new Request(url, { method: req.method, headers: req.headers, body: ['GET', 'HEAD'].includes(req.method || 'GET') ? undefined : req });
    const response = await router.handle(request);
    if (!response) { res.statusCode = 404; return void res.end('not found'); }
    res.statusCode = response.status;
    response.headers.forEach((v, k) => res.setHeader(k, v));
    const buf = Buffer.from(await response.arrayBuffer());
    res.end(buf);
  } catch (e) { res.statusCode = 500; res.end('error'); }
});

server.listen(PORT, () => log('info', 'auth proxy listening', { port: PORT, mode: GATE_MODE }));


