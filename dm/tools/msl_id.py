#!/usr/bin/env python3
"""Identity and staging of the iOS shader libraries for a build that keeps them out of the app (DM_COPY_SHADERS=NO).

The libraries are the folder <root>/<sub> (sub: b-<chain version>, vk or gl), as build_ipa.sh would pack it to <App>/msl/<sub>. A slim app carries <App>/msl.id, one ASCII line,
  DMMSLID1 files=<count> bytes=<total size> tree=<16 hex digits>
and uses only a Documents/msl whose own msl.id is the same line and whose files add up to that count and size (main.m, msl_locate): a copy cut off partway, or the shaders of another build, are never used.
tree is a SHA-256 over the sorted relative paths and sizes of the files (and over inputs.tsv, the full build's stamp, when there is one). Names starting with "." are not shipped or counted.

  msl_id.py --identity <root> <sub> [--skip-suffix <suffix>]...         print the line
  msl_id.py --stage <root> <sub> <out> [--skip-suffix <suffix>]...      make <out>/msl/<sub>/ (hard links where the volume allows, else copies) and <out>/msl/msl.id, print the line
                                                                         <out>/msl is what scripts/push_shaders.sh copies to the phone's Documents/msl
--skip-suffix leaves out the files with that ending, as pack_ipa.py's option of the same name does for the IPA (the pulling vertex libraries, _bp.metallib, when the app does not read them).
"""
import hashlib
import os
from pathlib import Path
import shutil
import sys

MAGIC = 'DMMSLID1'


def listing(root, sub, skip=()):
    """[(path relative to root, size)] of the files shipped under root/sub, sorted"""
    base = Path(root) / sub
    if not base.is_dir(): raise SystemExit(f'msl_id: no shader library folder {base}')
    rows = []
    for d, dirs, files in os.walk(base):
        dirs[:] = sorted(n for n in dirs if not n.startswith('.'))
        for n in files:
            if n.startswith('.') or any(n.endswith(s) for s in skip): continue
            p = Path(d) / n
            rows.append((p.relative_to(root).as_posix(), p.stat().st_size))
    if not rows: raise SystemExit(f'msl_id: no files under {base}')
    return sorted(rows)


def identity(root, sub, skip=()):
    rows = listing(root, sub, skip)
    h = hashlib.sha256()
    for rel, size in rows: h.update(f'{rel}\0{size}\n'.encode())
    stamp = Path(root) / sub / 'inputs.tsv'
    if stamp.is_file(): h.update(stamp.read_bytes())
    return f'{MAGIC} files={len(rows)} bytes={sum(s for _, s in rows)} tree={h.hexdigest()[:16]}', rows


def stage(root, sub, out, skip=()):
    line, rows = identity(root, sub, skip)
    dest = Path(out) / 'msl'
    if dest.exists(): shutil.rmtree(dest)
    link = True
    for rel, _ in rows:
        src, dst = Path(root) / rel, dest / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if link:
            try: os.link(src, dst); continue
            except OSError: link = False   # another volume, or one without hard links: copy from here on
        shutil.copyfile(src, dst)
    (dest / 'msl.id').write_text(line + '\n')
    return line


def main(argv):
    skip = []
    while '--skip-suffix' in argv:
        i = argv.index('--skip-suffix')
        if i + 1 >= len(argv): raise SystemExit(__doc__)
        skip.append(argv[i + 1]); del argv[i:i + 2]
    if len(argv) == 3 and argv[0] == '--identity': print(identity(argv[1], argv[2], skip)[0])
    elif len(argv) == 4 and argv[0] == '--stage': print(stage(argv[1], argv[2], argv[3], skip))
    else: raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
