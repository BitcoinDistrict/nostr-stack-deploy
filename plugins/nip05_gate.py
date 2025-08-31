#!/usr/bin/env python3

import argparse
import json
import os
import sys
import time
import threading
import random
import urllib.request
import urllib.error
import urllib.parse
from collections import OrderedDict
from typing import Dict, Set, Tuple, Iterable, Optional


def log_err(message: str) -> None:
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


def bech32_polymod(values):
    generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= generator[i] if ((b >> i) & 1) else 0
    return chk


def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_decode(bech: str) -> Tuple[str, bytes]:
    bech = bech.strip()
    if any(ord(x) < 33 or ord(x) > 126 for x in bech):
        return "", b""
    if bech.lower() != bech and bech.upper() != bech:
        return "", b""
    bech = bech.lower()
    pos = bech.rfind("1")
    if pos < 1 or pos + 7 > len(bech):
        return "", b""
    hrp = bech[:pos]
    data_part = bech[pos + 1 :]
    charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    try:
        data = [charset.index(x) for x in data_part]
    except ValueError:
        return "", b""
    if bech32_polymod(bech32_hrp_expand(hrp) + data) != 1:
        return "", b""
    return hrp, bytes(data[:-6])  # strip checksum


def convertbits(data: bytes, frombits: int, tobits: int, pad: bool = True) -> bytes:
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    max_acc = (1 << (frombits + tobits - 1)) - 1
    for value in data:
        if value < 0 or (value >> frombits):
            return b""
        acc = ((acc << frombits) | value) & max_acc
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        return b""
    return bytes(ret)


def npub_to_hex(npub: str) -> str:
    hrp, data = bech32_decode(npub)
    if hrp != "npub" or not data:
        return ""
    eight_bit = convertbits(data, 5, 8, False)
    if not eight_bit or len(eight_bit) != 32:
        return ""
    return eight_bit.hex()


class Nip05MultiCache:
    def __init__(self, urls: Tuple[str, ...], ttl_seconds: int, fields: Tuple[str, ...]) -> None:
        self.urls = tuple(u for u in (x.strip() for x in urls) if u)
        self.ttl_seconds = max(5, ttl_seconds)
        self.fields = tuple(f for f in (x.strip() for x in fields) if f)
        self._last_success_ts = 0.0
        self._allowed_hex_pubkeys: Set[str] = set()
        # Maintain per-url snapshots to avoid dropping keys when one source fails
        self._per_url_allowed: Dict[str, Set[str]] = {u: set() for u in self.urls}
        # Backoff state per URL
        self._next_retry_ts: Dict[str, float] = {u: 0.0 for u in self.urls}
        self._backoff_seconds: Dict[str, float] = {u: 0.0 for u in self.urls}
        # HTTP caching: conditional fetch support
        self._etag_by_url: Dict[str, str] = {u: "" for u in self.urls}
        self._last_modified_by_url: Dict[str, str] = {u: "" for u in self.urls}
        self._lock = threading.Lock()
        self._stop = False
        self._refresh_thread: threading.Thread | None = None
        self._last_refresh_started_ts: float = 0.0

    def _fetch_one(self, url: str) -> Tuple[Optional[Set[str]], bool]:
        # Returns (allowed_set or None if not-modified, was_not_modified)
        headers = {
            "User-Agent": "strfry-nip05-gate/1.1 (+https://bitcoindistrict.org)",
            "Accept": "application/json",
        }
        etag = self._etag_by_url.get(url, "")
        last_mod = self._last_modified_by_url.get(url, "")
        if etag:
            headers["If-None-Match"] = etag
        if last_mod:
            headers["If-Modified-Since"] = last_mod
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                status = getattr(resp, "status", 200)
                if status == 304:
                    return None, True
                if status != 200:
                    raise urllib.error.HTTPError(url, status, "bad status", resp.headers, None)
                payload = resp.read()
                # Capture caching headers on success
                try:
                    new_etag = resp.headers.get("ETag") or ""
                    new_last_mod = resp.headers.get("Last-Modified") or ""
                    if new_etag:
                        self._etag_by_url[url] = new_etag
                    if new_last_mod:
                        self._last_modified_by_url[url] = new_last_mod
                except Exception:
                    pass
        except urllib.error.HTTPError as e:
            # Some urllib versions raise for 304
            if getattr(e, "code", None) == 304:
                return None, True
            raise

        doc = json.loads(payload.decode("utf-8"))
        fields_to_scan: Tuple[str, ...] = self.fields or ("names",)
        allowed: Set[str] = set()

        def iter_field_values(doc_obj: dict, field_names: Iterable[str]) -> Iterable[str]:
            for fname in field_names:
                values = doc_obj.get(fname, {}) or {}
                if isinstance(values, dict):
                    for val in values.values():
                        if isinstance(val, str):
                            yield val

        for raw in iter_field_values(doc, fields_to_scan):
            v = raw.strip()
            if v.startswith("npub1"):
                hexpk = npub_to_hex(v)
                if hexpk:
                    allowed.add(hexpk)
            else:
                hexpk = v.lower()
                if len(hexpk) == 64 and all(c in "0123456789abcdef" for c in hexpk):
                    allowed.add(hexpk)
        return allowed, False

    def _refresh_once(self) -> None:
        now = time.time()
        merged: Set[str] = set()
        successes = 0
        for url in self.urls:
            # per-URL backoff gate
            if now < self._next_retry_ts.get(url, 0.0):
                continue
            try:
                subset, not_modified = self._fetch_one(url)
                if not_modified:
                    successes += 1
                    # reset backoff on success - set retry time to far future to avoid immediate retries
                    self._backoff_seconds[url] = 0.0
                    self._next_retry_ts[url] = now + self.ttl_seconds
                    # Only log 304s occasionally to reduce log spam
                    if int(now) % 60 == 0:  # Log once per minute at most
                        log_err(f"[nip05-gate] {url} not modified (304)")
                else:
                    assert subset is not None
                    with self._lock:
                        self._per_url_allowed[url] = subset
                    successes += 1
                    # reset backoff on success - set retry time to far future to avoid immediate retries
                    self._backoff_seconds[url] = 0.0
                    self._next_retry_ts[url] = now + self.ttl_seconds
                    log_err(f"[nip05-gate] loaded {len(subset)} pubkeys from {url}")
            except Exception as e:
                # increase backoff with jitter
                prev = self._backoff_seconds.get(url, 0.0) or 0.0
                base = 10.0 if prev <= 0.0 else min(prev * 2.0, 300.0)
                jitter = random.uniform(0.8, 1.2)
                delay = base * jitter
                self._backoff_seconds[url] = base
                self._next_retry_ts[url] = now + delay
                log_err(f"[nip05-gate] fetch failed for {url}: {e} (backoff {int(base)}s, retry in ~{int(delay)}s)")

        # rebuild merged snapshot from per-url caches to avoid dropping keys on failures
        with self._lock:
            for subset in self._per_url_allowed.values():
                merged |= subset
            if successes > 0:
                self._allowed_hex_pubkeys = merged
                self._last_success_ts = now
            if successes > 0:
                log_err(
                    f"[nip05-gate] merged allowlist size = {len(self._allowed_hex_pubkeys)} from {successes}/{len(self.urls)} sources"
                )
            else:
                log_err(
                    f"[nip05-gate] no sources succeeded; serving last good snapshot (size={len(self._allowed_hex_pubkeys)})"
                )

    def _refresh_loop(self) -> None:
        # Initial immediate attempt
        self._last_refresh_started_ts = time.time()
        try:
            self._refresh_once()
        except Exception as e:
            log_err(f"[nip05-gate] initial refresh error: {e}")
        # periodic refresh respecting TTL
        while not self._stop:
            now = time.time()
            due = (now - self._last_success_ts) >= self.ttl_seconds
            # Also attempt refresh opportunistically if any URL's backoff expired
            should_try_url = any(now >= self._next_retry_ts.get(u, 0.0) for u in self.urls)
            if due or should_try_url:
                self._last_refresh_started_ts = now
                try:
                    self._refresh_once()
                except Exception as e:
                    log_err(f"[nip05-gate] refresh error: {e}")
            time.sleep(1.0)

    def start_background_refresh(self) -> None:
        if self._refresh_thread is not None:
            return
        self._refresh_thread = threading.Thread(target=self._refresh_loop, name="nip05-refresh", daemon=True)
        self._refresh_thread.start()

    def allowed(self, pubkey_hex: str) -> bool:
        # Non-blocking membership check on the last snapshot (read-only set reference)
        return pubkey_hex in self._allowed_hex_pubkeys


class TokenBucket:
    def __init__(self, capacity: int, refill_per_second: float) -> None:
        self.capacity = max(1, int(capacity))
        self.refill_per_second = max(0.01, float(refill_per_second))
        self.tokens = float(self.capacity)
        self.last_ts = time.time()

    def allow(self, now: float) -> bool:
        elapsed = max(0.0, now - self.last_ts)
        if elapsed:
            self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_per_second)
        # Always update last seen timestamp for GC even if elapsed is very small
        self.last_ts = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True
        return False


# In-memory per-pubkey buckets for ephemeral kinds with LRU + TTL GC
_ephemeral_buckets: "OrderedDict[str, TokenBucket]" = OrderedDict()
_ephemeral_lock = threading.Lock()
_ephemeral_evictions = 0
_metrics_lock = threading.Lock()

def _ephemeral_get_or_create(pubkey: str, capacity: int, rate: float, max_buckets: int) -> TokenBucket:
    global _ephemeral_evictions
    with _ephemeral_lock:
        bucket = _ephemeral_buckets.get(pubkey)
        if bucket is not None:
            # LRU touch
            _ephemeral_buckets.move_to_end(pubkey, last=True)
            return bucket
        # create new
        bucket = TokenBucket(capacity=capacity, refill_per_second=rate)
        _ephemeral_buckets[pubkey] = bucket
        _ephemeral_buckets.move_to_end(pubkey, last=True)
        # capacity check & evict LRU
        if len(_ephemeral_buckets) > max_buckets:
            try:
                _ephemeral_buckets.popitem(last=False)
                with _metrics_lock:
                    _ephemeral_evictions += 1
            except KeyError:
                pass
        return bucket

def _ephemeral_gc_loop(ttl_seconds: int) -> None:
    # Periodically prune buckets not touched within ttl_seconds
    while True:
        try:
            now = time.time()
            with _ephemeral_lock:
                to_delete = []
                for pk, bucket in _ephemeral_buckets.items():
                    if (now - bucket.last_ts) > ttl_seconds:
                        to_delete.append(pk)
                for pk in to_delete:
                    try:
                        del _ephemeral_buckets[pk]
                    except KeyError:
                        pass
        except Exception as e:
            log_err(f"[nip05-gate] ephemeral GC error: {e}")
        time.sleep(60.0)

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="NIP-05 gate plugin for strfry")
    parser.add_argument(
        "--url",
        action="append",
        help="URL to fetch nostr.json from (can be supplied multiple times)",
    )
    parser.add_argument(
        "--ttl",
        type=int,
        default=int(os.environ.get("NIP05_CACHE_TTL", "300")),
        help="Cache TTL seconds for nostr.json",
    )
    parser.add_argument(
        "--nip05-field",
        type=str,
        default=os.environ.get("NIP05_FIELD", "names"),
        help="Field(s) to accept from nostr.json: names, verified_names, or both",
    )
    parser.add_argument(
        "--allow-import",
        type=str,
        default=os.environ.get("ALLOW_IMPORT", "false"),
        help="If true, allow Import/Sync/Stream sources regardless of NIP-05",
    )
    parser.add_argument(
        "--eph-rate",
        type=float,
        default=float(os.environ.get("EPHEMERAL_RATE", "2.0")),
        help="Token refill rate per second for ephemeral kinds (kind 20000-29999)",
    )
    parser.add_argument(
        "--eph-burst",
        type=int,
        default=int(os.environ.get("EPHEMERAL_BURST", "10")),
        help="Token bucket capacity (burst) for ephemeral kinds (kind 20000-29999)",
    )
    parser.add_argument(
        "--eph-max-buckets",
        type=int,
        default=int(os.environ.get("EPHEMERAL_MAX_BUCKETS", "10000")),
        help="Maximum number of ephemeral buckets to keep in memory (LRU)",
    )
    parser.add_argument(
        "--eph-ttl-seconds",
        type=int,
        default=int(os.environ.get("EPHEMERAL_TTL_SECONDS", "900")),
        help="Evict ephemeral buckets idle for more than this many seconds",
    )
    parser.add_argument(
        "--startup-grace-seconds",
        type=int,
        default=int(os.environ.get("STARTUP_GRACE_SECONDS", "0")),
        help="Fail-open for regular kinds until first cache success or N seconds",
    )
    parser.add_argument(
        "--allowed-kinds-no-nip05",
        type=str,
        default=os.environ.get("ALLOWED_KINDS_NO_NIP05", "0,3,5,7,9734,9735,10002,22242"),
        help="Comma-separated list of event kinds to allow without NIP-05 verification",
    )
    parser.add_argument(
        "--gate-mode",
        type=str,
        default=os.environ.get("STRFRY_GATE_MODE", "nip05"),
        help="Gate mode: 'open' (accept all), 'nip05' (NIP-05 verification), default is nip05",
    )
    return parser.parse_args()


def resolve_urls(args: argparse.Namespace) -> Tuple[str, ...]:
    # Priority: CLI --url (can be multiple) > NIP05_JSON_URLS (comma-separated) > NIP05_JSON_URL (single) > default
    if args.url:
        return tuple(args.url)
    env_urls = os.environ.get("NIP05_JSON_URLS", "").strip()
    if env_urls:
        parts = [p.strip() for p in env_urls.split(",") if p.strip()]
        if parts:
            return tuple(parts)
    single = os.environ.get("NIP05_JSON_URL", "").strip()
    if single:
        return (single,)
    return ("https://bitcoindistrict.org/.well-known/nostr.json",)


def should_bypass_source(source_type: str, allow_import_flag: str) -> bool:
    if allow_import_flag.lower() not in ("1", "true", "yes", "y"):  # default off
        return False
    return source_type in ("Import", "Sync", "Stream")


def parse_allowed_kinds(allowed_kinds_str: str) -> Set[int]:
    """
    Parse comma-separated string of event kinds into a set of integers.
    Returns empty set if parsing fails.
    """
    if not allowed_kinds_str.strip():
        return set()
    
    try:
        kinds = set()
        for kind_str in allowed_kinds_str.split(","):
            kind_str = kind_str.strip()
            if kind_str:
                kinds.add(int(kind_str))
        return kinds
    except (ValueError, TypeError):
        log_err(f"[nip05-gate] failed to parse allowed kinds: {allowed_kinds_str}")
        return set()


def should_allow_kind_without_nip05(kind: int, allowed_kinds: Set[int]) -> bool:
    """
    Determine if an event kind should be allowed regardless of NIP-05 verification.
    These kinds are beneficial for relay performance and network health.
    """
    return kind in allowed_kinds


def main() -> None:
    args = parse_args()
    urls = resolve_urls(args)
    # Determine fields
    nip05_field = (args.nip05_field or "names").strip().lower()
    if nip05_field == "both":
        fields = ("names", "verified_names")
    elif nip05_field in ("names", "verified_names"):
        fields = (nip05_field,)
    else:
        fields = ("names",)

    # Parse allowed kinds from configuration
    allowed_kinds = parse_allowed_kinds(args.allowed_kinds_no_nip05)

    cache = Nip05MultiCache(urls=urls, ttl_seconds=args.ttl, fields=fields)
    # Only start background refresh in nip05 mode
    if args.gate_mode.lower() != "open":
        cache.start_background_refresh()

    # Startup summary
    url_hosts = []
    for u in urls:
        try:
            url_hosts.append(urllib.parse.urlparse(u).hostname or u)
        except Exception:
            url_hosts.append(u)
    log_err(
        "[nip05-gate] startup: gate_mode="
        + args.gate_mode
        + " urls="
        + ",".join(url_hosts)
        + f" ttl={args.ttl}s fields="
        + ",".join(fields)
        + f" allow_import={args.allow_import.lower()} eph_rate={args.eph_rate} eph_burst={args.eph_burst} eph_max={args.eph_max_buckets} eph_ttl={args.eph_ttl_seconds}s startup_grace={args.startup_grace_seconds}s allowed_kinds={sorted(allowed_kinds)}"
    )

    # Start ephemeral GC
    gc_thread = threading.Thread(
        target=_ephemeral_gc_loop,
        args=(int(args.eph_ttl_seconds),),
        name="ephemeral-gc",
        daemon=True,
    )
    gc_thread.start()

    # Metrics logger thread
    def _metrics_loop() -> None:
        while True:
            time.sleep(60.0)
            try:
                age = max(0, int(time.time() - cache._last_success_ts))
                with _metrics_lock:
                    accepts = _metrics_accepts
                    rejects = _metrics_rejects
                    evictions = _ephemeral_evictions
                log_err(
                    f"[nip05-gate] metrics: accepts={accepts} rejects={rejects} allowlist_size={len(cache._allowed_hex_pubkeys)} cache_age_s={age} eph_buckets={len(_ephemeral_buckets)} evictions={evictions}"
                )
            except Exception as e:
                log_err(f"[nip05-gate] metrics error: {e}")

    _metrics_accepts = 0
    _metrics_rejects = 0
    threading.Thread(target=_metrics_loop, name="nip05-metrics", daemon=True).start()

    startup_ts = time.time()
    while True:
        line = sys.stdin.readline()
        if line == "":
            # EOF
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log_err("[nip05-gate] invalid JSON input line")
            continue

        if req.get("type") != "new":
            log_err("[nip05-gate] unexpected request type, ignoring")
            continue

        event = req.get("event") or {}
        event_id = event.get("id", "")
        pubkey = event.get("pubkey", "").lower()
        source_type = req.get("sourceType", "")
        kind = event.get("kind", 0)

        response = {"id": event_id}

        if not (event_id and len(pubkey) == 64 and all(c in "0123456789abcdef" for c in pubkey)):
            response.update({
                "action": "reject",
                "msg": "blocked: invalid event or pubkey",
            })
            print(json.dumps(response), flush=True)
            continue

        # Check gate mode - if open, accept all valid events
        if args.gate_mode.lower() == "open":
            response.update({"action": "accept"})
            with _metrics_lock:
                _metrics_accepts += 1
            print(json.dumps(response), flush=True)
            continue

        # Special handling for ephemeral events (kind 20000-29999)
        if 20000 <= kind <= 29999:
            # Per-pubkey token-bucket rate limit with LRU and cap
            bucket = _ephemeral_get_or_create(
                pubkey=pubkey,
                capacity=args.eph_burst,
                rate=args.eph_rate,
                max_buckets=args.eph_max_buckets,
            )
            now_ts = time.time()
            if bucket.allow(now_ts):
                response.update({"action": "accept"})
                with _metrics_lock:
                    _metrics_accepts += 1
            else:
                response.update({
                    "action": "reject",
                    "msg": "blocked: rate limited (ephemeral)",
                })
                with _metrics_lock:
                    _metrics_rejects += 1
            print(json.dumps(response), flush=True)
            continue

        if should_bypass_source(source_type, args.allow_import):
            response.update({"action": "accept"})
            with _metrics_lock:
                _metrics_accepts += 1
            print(json.dumps(response), flush=True)
            continue

        # Allow beneficial event kinds regardless of NIP-05 verification
        if should_allow_kind_without_nip05(kind, allowed_kinds):
            response.update({"action": "accept"})
            with _metrics_lock:
                _metrics_accepts += 1
            # Optional: log kind bypasses for monitoring (comment out if too verbose)
            # log_err(f"[nip05-gate] accepted kind {kind} event {event_id[:8]}... via kind bypass")
            print(json.dumps(response), flush=True)
            continue

        # Startup grace: fail-open for regular kinds until first success or timeout
        if (
            args.startup_grace_seconds > 0
            and cache._last_success_ts <= 0.0
            and (time.time() - startup_ts) < args.startup_grace_seconds
        ):
            response.update({"action": "accept"})
            with _metrics_lock:
                _metrics_accepts += 1
            print(json.dumps(response), flush=True)
            continue

        if cache.allowed(pubkey):
            response.update({"action": "accept"})
            with _metrics_lock:
                _metrics_accepts += 1
        else:
            response.update({
                "action": "reject",
                "msg": "blocked: pubkey not in allowed NIP-05 list",
            })
            with _metrics_lock:
                _metrics_rejects += 1

        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass


