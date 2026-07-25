# Cutover: SFM → PendingNet (standalone sing-box + sbtally)

This is the real-machine step. It swaps SFM for PendingNet — a standalone sing-box
CLI (so per-app process attribution works) plus the sbtally stats daemon, both under
launchd. The PendingNet.app GUI controls both via the Clash API. **It is verified
here, at cutover — not in CI.** Do it when you're ready to switch your proxy over.

## What you get after cutover

- Real per-app traffic stats (process names) in the dashboard + CLI.
- Runtime switching of **VPS / protocol / routing mode** from the dashboard
  (Clash API — instant, no restart, no privilege).
- TUN is always-on in the generated config, so all traffic is captured.

Deferred to the optional privileged helper (not required for the above):
runtime **TUN on/off** and **system-proxy** toggles, and live per-app-rule edits.

## Dual-variant configs

During config generation, you produce both `master-tun.json` (TUN mode) and
`master-notun.json` (system-proxy fallback). The installer places both under
`/usr/local/etc/sbtally/` and writes the active mode to `/usr/local/etc/sbtally/mode`.
PendingNet.app and the Clash API read this mode file to switch between configs.
Toggling mode in the PendingNet.app Control tab updates this file and reloads sing-box.

## Steps

1. **Quit and disable SFM** (System Settings → General → Login Items, and quit the
   app). Two TUN providers conflict.

2. **Install sing-box**: `brew install sing-box`

3. **Generate your master config** from your existing sing-box config(s):

       sbtally config import ~/path/to/your-sfm-config.json     # see the outbounds
       sbtally config generate \
           --vps vpsA=~/path/vpsA.json \
           --vps vpsB=~/path/vpsB.json \
           --clash-secret "$(openssl rand -hex 16)" \
           --out ~/master.json

   (One file with all outbounds? Use a single `--vps main=file.json`.) Note the
   secret you chose — you pass it to the installer.

4. **Run the installer** (reviews then performs sudo/launchctl actions):

       deploy/install.sh ~/master.json <the-clash-secret>

   Or do its steps by hand — read `deploy/install.sh`, it's short.

## Final verification (the "verify last" gate)

After cutover, confirm the things only a real sing-box can prove:

- [ ] `sbtally apps --since 1h` shows **real app names** (Safari, Telegram, …) —
      proves `find_process` works in TUN mode on your machine.
- [ ] Dashboard **Live** tab shows moving per-app rates.
- [ ] Dashboard **Control** tab lists your VPS and protocols; switching **VPS**
      and **protocol** takes effect (check `curl -s 127.0.0.1:9090/proxies`).
- [ ] Switching **mode** (规则/全局/直连) changes routing (e.g. a CN site goes
      direct in 规则, proxied in 全局).
- [ ] **Takeover mode** toggles between TUN and system-proxy (verify in
      `/usr/local/etc/sbtally/mode`).
- [ ] **Rule-sets** are present: geosite-cn, geoip-cn, geosite-geolocation-noncn,
      geosite-category-ads-all, geosite-gfw (`.srs` files in `/usr/local/etc/sbtally/`).
- [ ] Connectivity is healthy on each VPS/protocol.

If per-app names are blank, check `/var/log/sbtally-singbox.log` — process
matching needs the standalone CLI build (this), not SFM.

## Rollback

Uninstall commands are printed at the end of `install.sh`. Then re-enable SFM.
