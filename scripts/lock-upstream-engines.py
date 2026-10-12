#!/usr/bin/env python3
"""Release preparation only: freeze upstream stable releases before committing."""
import datetime
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def github(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def main():
    lock = {'schema': 1, 'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    project = (ROOT / 'app/project.yml').read_text()
    lock['pendingnet'] = {
        'version': re.findall(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', project, re.M)[0],
        'build': re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)', project, re.M)[0],
    }
    for name, repo, assets in (
        ('xray', 'XTLS/Xray-core', {'amd64': 'Xray-linux-64.zip', 'arm64': 'Xray-linux-arm64-v8a.zip'}),
        ('hysteria2', 'apernet/hysteria', {'amd64': 'hysteria-linux-amd64', 'arm64': 'hysteria-linux-arm64'}),
    ):
        release = github('repos/' + repo + '/releases/latest')
        assert not release['prerelease'] and not release['draft']
        engine = {'version': release['tag_name'], 'assets': {}}
        for arch, filename in assets.items():
            asset = next(x for x in release['assets'] if x['name'] == filename)
            digest = asset['digest']
            assert digest.startswith('sha256:') and len(digest) == 71
            int(digest[7:], 16)
            engine['assets'][arch] = {'url': asset['browser_download_url'], 'digest': digest}
        lock[name] = engine
    release = github('repos/SagerNet/sing-box/releases/latest')
    assert not release['prerelease'] and not release['draft']
    commit = github('repos/SagerNet/sing-box/commits/' + release['tag_name'])['sha']
    assert len(commit) == 40
    lock['sing_box'] = {'version': release['tag_name'], 'commit': commit}
    path = ROOT / 'internal/pnserver/upstream-lock.json'
    tmp = path.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(lock, indent=2) + '\n')
    tmp.replace(path)
    print('Locked upstream engines; commit this manifest with the PendingNet release:')
    for name in ('xray', 'hysteria2', 'sing_box'):
        print(name, lock[name]['version'])


if __name__ == '__main__':
    main()
