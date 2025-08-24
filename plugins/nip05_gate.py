#!/usr/bin/env python3

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from typing import Dict, Set, Tuple


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
    def __init__(self, urls: Tuple[str, ...], ttl_seconds: int) -> None:
        self.urls = tuple(u for u in (x.strip() for x in urls) if u)
        self.ttl_seconds = max(5, ttl_seconds)
        self._last_fetch_ts = 0.0
        self._allowed_hex_pubkeys: Set[str] = set()

    def _fetch_one(self, url: str) -> Set[str]:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "strfry-nip05-gate/1.1 (+https://bitcoindistrict.org)",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                raise urllib.error.HTTPError(url, resp.status, "bad status", resp.headers, None)
            payload = resp.read()
        doc = json.loads(payload.decode("utf-8"))
        names: Dict[str, str] = doc.get("names", {}) or {}

        allowed: Set[str] = set()
        for _, val in names.items():
            if not isinstance(val, str):
                continue
            v = val.strip()
            if v.startswith("npub1"):
                hexpk = npub_to_hex(v)
                if hexpk:
                    allowed.add(hexpk)
            else:
                hexpk = v.lower()
                if len(hexpk) == 64 and all(c in "0123456789abcdef" for c in hexpk):
                    allowed.add(hexpk)
        return allowed

    def _fetch_all(self) -> None:
        merged: Set[str] = set()
        successes = 0
        for url in self.urls:
            try:
                subset = self._fetch_one(url)
                merged |= subset
                log_err(f"[nip05-gate] loaded {len(subset)} pubkeys from {url}")
                successes += 1
            except Exception as e:
                log_err(f"[nip05-gate] fetch failed for {url}: {e}")
        if successes > 0:
            self._allowed_hex_pubkeys = merged
            self._last_fetch_ts = time.time()
            log_err(f"[nip05-gate] merged allowlist size = {len(merged)} from {successes}/{len(self.urls)} sources")

    def allowed(self, pubkey_hex: str) -> bool:
        now = time.time()
        if now - self._last_fetch_ts > self.ttl_seconds or not self._allowed_hex_pubkeys:
            self._fetch_all()
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
            self.last_ts = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True
        return False


# In-memory per-pubkey buckets for ephemeral kinds
_ephemeral_buckets: Dict[str, TokenBucket] = {}

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


def main() -> None:
    args = parse_args()
    urls = resolve_urls(args)
    cache = Nip05MultiCache(urls=urls, ttl_seconds=args.ttl)

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

        if not event_id or not pubkey or len(pubkey) != 64:
            response.update({
                "action": "reject",
                "msg": "blocked: invalid event or pubkey",
            })
            print(json.dumps(response), flush=True)
            continue

        # Special handling for ephemeral events (kind 20000-29999)
        if 20000 <= kind <= 29999:
            # Per-pubkey token-bucket rate limit
            bucket = _ephemeral_buckets.get(pubkey)
            if bucket is None:
                bucket = TokenBucket(capacity=args.eph_burst, refill_per_second=args.eph_rate)
                _ephemeral_buckets[pubkey] = bucket
            now_ts = time.time()
            if bucket.allow(now_ts):
                response.update({"action": "accept"})
            else:
                response.update({
                    "action": "reject",
                    "msg": "blocked: rate limited (ephemeral)",
                })
            print(json.dumps(response), flush=True)
            continue

        if should_bypass_source(source_type, args.allow_import):
            response.update({"action": "accept"})
            print(json.dumps(response), flush=True)
            continue

        if cache.allowed(pubkey):
            response.update({"action": "accept"})
        else:
            response.update({
                "action": "reject",
                "msg": "blocked: not NIP-05 verified with bitcoindistrict.org",
            })

        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass


