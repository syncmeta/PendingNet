#!/usr/bin/env python3
"""Prevent TestFlight from reusing a Libbox built from another source lock."""
import argparse
import hashlib
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MARKER = '.pendingnet-source.json'


def fingerprint(folder):
    digest = hashlib.sha256()
    for path in sorted(folder.rglob('*')):
        if path.name == MARKER or not path.is_file():
            continue
        name = path.relative_to(folder).as_posix().encode()
        digest.update(len(name).to_bytes(8, 'big'))
        digest.update(name)
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('framework', type=pathlib.Path)
    parser.add_argument('--write', action='store_true', help='build script only: record freshly built artifact')
    args = parser.parse_args()
    locked = json.loads((ROOT / 'internal/pnserver/upstream-lock.json').read_text())['sing_box']
    assert args.framework.is_dir(), 'Libbox.xcframework missing'
    expected = dict(locked, tree_sha256=fingerprint(args.framework))
    marker = args.framework / MARKER
    if args.write:
        marker.write_text(json.dumps(expected, indent=2) + '\n')
    else:
        assert marker.is_file(), 'Libbox source marker missing; run scripts/build-libbox-xcframework.sh'
        assert json.loads(marker.read_text()) == expected, 'Libbox differs from release source lock; rebuild it'
    print('Libbox matches release lock:', locked['version'], locked['commit'])


if __name__ == '__main__':
    main()
