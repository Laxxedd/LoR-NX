#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path

FILE = Path(__file__).resolve().parents[1] / 'VERSION'
SEMVER = re.compile(
    r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?'
    r'(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?'
)


def read(path=FILE):
    try:
        text = path.read_text(encoding='utf-8').strip()
    except OSError as e:
        sys.exit(f'{path}: cannot read the version: {e}')
    if not SEMVER.fullmatch(text):
        sys.exit(f'{path}: {text!r} is not a semantic version (MAJOR.MINOR.PATCH, semver.org)')
    return text


def bump(version, part):
    major, minor, patch = (int(n) for n in SEMVER.fullmatch(version).groups()[:3])
    if part == 'major':
        return f'{major + 1}.0.0'
    if part == 'minor':
        return f'{major}.{minor + 1}.0'
    return f'{major}.{minor}.{patch + 1}'


def main(argv=None):
    ap = argparse.ArgumentParser(description='The nxnative version in VERSION: show it, check it or bump it.')
    sub = ap.add_subparsers(dest='cmd')
    sub.add_parser('show')
    sub.add_parser('check')
    b = sub.add_parser('bump')
    b.add_argument('part', choices=('major', 'minor', 'patch'))
    args = ap.parse_args(argv)
    current = read()
    if args.cmd == 'bump':
        new = bump(current, args.part)
        FILE.write_text(new + '\n', encoding='utf-8')
        print(f'{current} -> {new}')
    elif args.cmd == 'check':
        print(f'VERSION {current}: ok')
    else:
        print(current)


if __name__ == '__main__':
    main()
