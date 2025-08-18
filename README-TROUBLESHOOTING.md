## Nostr Stack Troubleshooting Guide

This guide shows how to inspect logs and diagnose issues across the stack:

- strfry relay
- Blossom media server (and nginx in front)
- nostr-auth-proxy (NIP-98/24242 + NIP-05 gate)
- Dashboard services (optional)

All commands assume a Linux host with systemd and docker, and the default unit names from this repo.

### General systemd tips

- Service status and last lines of logs:
```bash
sudo systemctl --no-pager --full status <service>
sudo journalctl -u <service> -n 200 --no-pager
```
- Live tail:
```bash
sudo journalctl -fu <service>
```

### nostr-auth-proxy

Service name: `nostr-auth-proxy.service` (containerized)

- Live logs with structured JSON decisions:
```bash
sudo journalctl -fu nostr-auth-proxy.service
```

- Filter only accept/reject decisions (requires `jq` for pretty JSON):
```bash
sudo journalctl -u nostr-auth-proxy.service -n 1000 --no-pager \
| jq -c 'select(.msg? | startswith("auth "))'
```

- Show only rejects with reasons (missing auth, mismatch, not verified, etc.):
```bash
sudo journalctl -u nostr-auth-proxy.service -n 2000 --no-pager \
| jq -c 'select(.msg? == "auth reject") | {time,reason,mode,scheme,pubkey,host,uri,method,nip05,domain}'
```

- Confirm env settings used by the proxy:
```bash
sudo cat /etc/default/nostr-auth-proxy
```

- Force rebuild/restart cleanly (container name/port conflicts are auto-cleaned by the unit, but this is explicit):
```bash
sudo systemctl daemon-reload
sudo systemctl restart nostr-auth-proxy.service
```

Common symptoms:
- Exit code 125 in logs → container name or port conflict. The unit now pre-kills/removes any old container; verify those ExecStartPre lines exist in the unit.
- 401 responses → missing/invalid Authorization or unsupported event format. Check logs for `reason:"missing/invalid authorization"`.
- 403 responses → authorization parsed but failed policy (not in allowlist, nip05/pubkey mismatch, not verified on required domain).
- 204 responses → CORS preflight/HEAD from nginx (no proxy involvement).

### Blossom media server

Service name: `blossom.service` (containerized)

- Logs:
```bash
sudo journalctl -fu blossom.service
```

- Nginx in front of Blossom (domain `BLOSSOM_DOMAIN`):
  - Access log (requests, status codes):
```bash
sudo tail -f /var/log/nginx/access.log | grep "$(hostname -f)" -n || true
```
  - Error log:
```bash
sudo tail -f /var/log/nginx/error.log
```

- Focus on upload path only:
```bash
sudo tail -f /var/log/nginx/access.log | grep '/upload'
```

- Verify nginx auth wiring is active (when gate is not `open`):
```bash
sudo grep -n 'auth_request /__auth;' /etc/nginx/sites-enabled/* | grep blossom || true
```

### Strfry relay

Service name: `strfry.service`

- Live logs:
```bash
sudo journalctl -fu strfry.service
```

- Check write-policy rejections (NIP-05 gate plugin messages):
```bash
sudo journalctl -u strfry.service -n 1000 --no-pager | grep -i 'write policy blocked\|blocked:'
```

- Confirm config path and plugin wiring in the service:
```bash
sudo systemctl show -p ExecStart strfry.service
sudo grep -n 'writePolicy' /home/deploy/.strfry/strfry.conf
```

### Dashboard (optional)

Service names: `relay-dashboard.service`, `relay-dashboard-stats.service`

```bash
sudo journalctl -fu relay-dashboard.service
sudo journalctl -fu relay-dashboard-stats.service
```

### Network and container diagnostics

- Is anything listening on a port?
```bash
sudo ss -lntp | grep -E ':3310|:3300|:7777'
```

- Is the auth proxy container stuck?
```bash
sudo docker ps -a | grep nostr-auth-proxy || true
```

### End-to-end upload test (manual)

Generate a NIP‑98 header in a browser console using an extension that exposes `window.nostr`:
```javascript
const ev = await window.nostr.signEvent({
  kind: 27235,
  content: '',
  created_at: Math.floor(Date.now()/1000),
  tags: [
    ['u','https://<BLOSSOM_DOMAIN>/upload'],
    ['method','POST']
  ]
});
const auth = 'Nostr ' + btoa(JSON.stringify(ev)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
console.log(auth)
```

Then, from a shell:
```bash
curl -i -X POST \
  -H "Authorization: <paste-auth>" \
  -F "file=@/path/to/file.png" \
  https://<BLOSSOM_DOMAIN>/upload
```

Watch the proxy logs for `auth ok` or `auth reject` with a reason.


