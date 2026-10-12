#!/usr/bin/env python3
"""Offline installer regressions: no root, downloads, or service operations."""
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = (root / 'deploy/vps-install.sh').read_text()
assert source.rstrip().endswith('main "$@"')
sha = hashlib.sha256(b'locked-release-program').hexdigest()
metadata = json.dumps({'assets': [
    {'name': 'pendingnet-server-linux-amd64', 'id': 11},
    {'name': 'SHA256SUMS', 'id': 12},
]})
mock = '''
source "$1"
WORK_DIR="$2"; ARCH=amd64; REPO=fixture/repo; DETAIL_LOG="$2/log"
sha256sum() { shasum -a 256 "$@"; }
curl_auth() {
 local url="${!#}" dest=""
 printf '%s\\n' "$url" >> "$WORK_DIR/requests"
 while [[ $# -gt 0 ]]; do if [[ "$1" == -o ]]; then dest="$2"; shift 2; else shift; fi; done
 case "$url" in
 */releases/latest) printf '%s' "$FIXTURE_META" ;;
 */assets/11) printf 'locked-release-program' > "$dest" ;;
 */assets/12) printf '%s  pendingnet-server-linux-amd64\\n' "$FIXTURE_SHA" > "$dest" ;;
 *) return 1 ;;
 esac
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = pathlib.Path(folder)
    functions = folder / 'functions.sh'
    functions.write_text(source.rsplit('main "$@"', 1)[0])

    def run(body, digest=sha):
        return subprocess.run(
            ['bash', '-c', mock + body, 'fixture', str(functions), str(folder)],
            env=dict(os.environ, FIXTURE_META=metadata, FIXTURE_SHA=digest,
                     PENDINGNET_RELEASE_BASE_URL='', PENDINGNET_GITHUB_TOKEN=''),
            capture_output=True,
        )

    result = run('''
download_release_binary
[[ $(wc -l < "$WORK_DIR/requests") -eq 3 ]]
[[ $(grep -c /releases/latest "$WORK_DIR/requests") -eq 1 ]]
''')
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    assert run('download_release_binary', '0' * 64).returncode != 0
    result = run('''
download_release_binary() { return 1; }
already_installed() { return 0; }
build_from_source() { touch "$WORK_DIR/unreleased-source"; }
obtain_binary
''')
    assert result.returncode != 0 and not (folder / 'unreleased-source').exists()
    result = run('''
NO_UPGRADE=1
align_release_engines
''')
    assert result.returncode == 0

print('Offline installer checks passed: release snapshot, checksum rejection, no unreleased fallback, no-upgrade')
