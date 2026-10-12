#!/usr/bin/env python3
"""Release gate: version bumps require a new, committed upstream snapshot."""
import json
import pathlib
import re
import urllib.parse
import datetime

root = pathlib.Path(__file__).resolve().parent.parent
lock = json.loads((root / 'internal/pnserver/upstream-lock.json').read_text())
assert lock['schema'] == 1
datetime.datetime.fromisoformat(lock['captured_at'])
for name, owners in (('xray', ('XTLS/Xray-core',)), ('hysteria2', ('apernet/hysteria', 'HyNetworks/hysteria'))):
    engine = lock[name]
    assert engine['version']
    for arch in ('amd64', 'arm64'):
        asset = engine['assets'][arch]
        url = urllib.parse.urlparse(asset['url'])
        assert url.scheme == 'https' and url.netloc == 'github.com' and not url.query and not url.fragment
        assert any(url.path.startswith('/' + repo + '/releases/download/' + engine['version'] + '/') for repo in owners)
        assert re.fullmatch(r'sha256:[0-9a-fA-F]{64}', asset['digest'])
assert re.fullmatch(r'[0-9a-f]{40}', lock['sing_box']['commit'])
assert re.fullmatch(r'v\d+\.\d+\.\d+', lock['sing_box']['version'])
project = (root / 'app/project.yml').read_text()
versions = re.findall(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', project, re.M)
builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)', project, re.M)
assert len(set(versions)) == len(set(builds)) == 1, 'project versions disagree'
assert lock['pendingnet'] == {'version': versions[0], 'build': builds[0]}, \
    'release engine snapshot is stale; run scripts/lock-upstream-engines.py and commit it before building'
print('Upstream snapshot matches PendingNet', versions[0], builds[0])
