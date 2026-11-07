#!/usr/bin/env python3
"""Select the mods a build includes (mods/<id>/, see mods/README.md).

    python3 scripts/apply_mods.py [--mods speed-dice[,other]] [--out DIR]

Every mod in mods/ is built in unless --mods names a subset. A mod is off at run time until the player turns it on (the launcher's Mods section, or its env switch = 1).

For the selected mods it
  - reads the Atmosphere exefs patches (.ips / .pchtxt) of a mod's "exefs" folder and writes each patched word as a switchable patch, DIR/patches.json "SWITCH": the rewriter (dm/tools/patch_nso.py "Switchable patches") makes the word run
    as the patch says when the mod's env switch is 1 and as the game has it otherwise; the env names go to dm/host/hle_modsw_gen.h, which the host (hle_modsw.c) turns into the switch bytes at the start;  - gives every gate in their mod.json an observation-gate number (32..63) and writes dm/host/hle_mods_gen.h with MODGATE_<MOD>_<GATE> defines;
  - copies each mod's host.c to dm/host/hle_mod_<id>.c (the host Makefile takes hle_*.c by wildcard; a mod attaches its callbacks from a constructor, as hle_svc.c does);
  - writes DIR/patches.json, the gates for the rewriter (dm/tools/patch_nso.py reads it through DM_MODS_PATCHES);
  - copies each mod's romfs folder to DIR/romfs/<mod id>/, which build_ipa.sh packs into the app as <App>/modromfs/<mod id>/ (DM_MODS_ROMFS, also exported through $GITHUB_ENV); the host (hle_fs.c) adds
    the folder of every mod whose switch is 1 to the RomFS overlay by itself, so the player copies nothing and sets no DM_ROMFS_OVERLAY. The mods with a romfs folder are listed in dm/host/hle_modromfs_gen.h;
  - writes DIR/launcher_mods.json, one off-by-default toggle per mod under the launcher section "Mods" (dm/games/settings.py adds it to the app's launcher.json when DM_MODS_SETTINGS names it).
With --mods none it removes what an earlier run left. In GitHub Actions it also exports DM_MODS_PATCHES through $GITHUB_ENV.
"""
import argparse, glob, json, os, re, shutil, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIRST_GATE, LAST_GATE = 32, 63
CATEGORIES = ('Performance', 'Quality of Life', 'Content', 'Miscellaneous', 'Cheats')   # the groups of the launcher's mods page, in the order shown; mod.json launcher "category" (default Miscellaneous)
NSO_HEADER = 0x100   # Atmosphere's IPS offsets and the .pchtxt addresses of a patch without offset_shift count from the start of the NSO file, whose header is 0x100 bytes: the text starts there
MAX_SWITCHES = 0xE00   # dm/tools/nso_switch.py SWITCH_MAX

def available():
    return sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(ROOT, 'mods', '*', 'mod.json')))

def ident(s): return re.sub(r'[^0-9A-Za-z]', '_', s).upper()

def parse_ips(path):
    """(build ID, [(text offset, bytes)]) of an Atmosphere .ips / IPS32 file named by the NSO build ID (64 hex digits; the first 32 are the key of mod.json's obs)"""
    d = open(path, 'rb').read()
    ips32 = d[:5] == b'IPS32'
    if not ips32 and d[:5] != b'PATCH': sys.exit(f'[RED] {path}: not an IPS file')
    ow, end = (4, b'EEOF') if ips32 else (3, b'EOF')
    i, out = 5, []
    while d[i:i + len(end)] != end:
        if i + ow + 2 > len(d): sys.exit(f'[RED] {path}: truncated record')
        off, size = int.from_bytes(d[i:i + ow], 'big'), int.from_bytes(d[i + ow:i + ow + 2], 'big'); i += ow + 2
        if size:
            data = d[i:i + size]; i += size
        else:   # an RLE record: a length and one byte
            n, v = int.from_bytes(d[i:i + 2], 'big'), d[i + 2]; i += 3; data = bytes([v]) * n
        if off < NSO_HEADER: sys.exit(f'[RED] {path}: a record at {off:#x} is in the NSO header')
        out.append((off - NSO_HEADER, data))
    m = re.fullmatch(r'([0-9A-Fa-f]{64})(\.ips)?', os.path.basename(path))
    if not m: sys.exit(f'[RED] {path}: an .ips file is named by the NSO build ID (64 hex digits)')
    return m.group(1)[:32].lower(), out

def parse_pchtxt(path):
    """(build ID, [(text offset, bytes)]) of the @enabled sections of an IPSwitch .pchtxt (hex patches; offset_shift as the file sets it)"""
    bid, shift, enabled, out = None, 0, False, []
    for ln, line in enumerate(open(path, encoding='utf-8').read().splitlines(), 1):
        t = line.split('//')[0].strip()
        if not t: continue
        if t.startswith('@nsobid-'): bid = t[8:40].lower(); continue
        if t.startswith('@flag'):
            f = t.split()
            if len(f) == 3 and f[1] == 'offset_shift': shift = int(f[2], 0)
            continue
        if t == '@enabled': enabled = True; continue
        if t in ('@disabled', '@stop'): enabled = False; continue
        if t.startswith('@'): continue
        if not enabled: continue
        a = t.split()
        if len(a) != 2 or not re.fullmatch(r'[0-9A-Fa-f]+', a[0]) or not re.fullmatch(r'(?:[0-9A-Fa-f]{2})+', a[1]):
            sys.exit(f'[RED] {path}:{ln}: only "<hex offset> <hex bytes>" patches are supported, not {t!r}')
        off = int(a[0], 16) + shift - NSO_HEADER
        if off < 0: sys.exit(f'[RED] {path}:{ln}: offset {a[0]} is in the NSO header')
        out.append((off, bytes.fromhex(a[1])))
    if not bid or not re.fullmatch(r'[0-9a-f]{32}', bid): sys.exit(f'[RED] {path}: no @nsobid- line')
    return bid, out

def exefs_rows(mid, folder, reason_of):
    """{build ID: [(text offset, patched word as 8 hex digits, reason)]}: every file of the mod's exefs folder, split into words (a switch can only turn whole instructions on)"""
    rows = {}
    files = sorted(glob.glob(os.path.join(folder, '*.ips')) + glob.glob(os.path.join(folder, '*.pchtxt')))
    if not files: sys.exit(f'[RED] {mid}: no .ips or .pchtxt file in {folder}')
    for f in files:
        bid, patches = parse_ips(f) if f.endswith('.ips') else parse_pchtxt(f)
        for off, data in patches:
            if off % 4 or len(data) % 4: sys.exit(f'[RED] {mid}: {os.path.basename(f)}: the patch at text offset {off:#x} ({len(data)} bytes) does not cover whole instructions')
            for k in range(0, len(data), 4):
                rows.setdefault(bid, []).append((off + k, f'{struct.unpack("<I", data[k:k + 4])[0]:08x}', reason_of(os.path.basename(f))))
    return rows

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mods', default='all', help="comma- or space-separated mod IDs, 'all' (default) or 'none'")
    ap.add_argument('--out', default=os.path.join(ROOT, 'build', 'mods'), help='where patches.json and romfs/ go')
    a = ap.parse_args()
    have = available()
    want = [m for m in re.split(r'[,\s]+', a.mods.strip()) if m]
    if want == ['all']: want = have
    elif want == ['none']: want = []
    bad = [m for m in want if m not in have]
    if bad: sys.exit(f'[RED] unknown mod {", ".join(bad)}; available: {", ".join(have) or "none"}')
    host = os.path.join(ROOT, 'dm', 'host')
    for old in glob.glob(os.path.join(host, 'hle_mod_*.c')) + [os.path.join(host, 'hle_mods_gen.h'), os.path.join(host, 'hle_modsw_gen.h'), os.path.join(host, 'hle_modromfs_gen.h')]:
        if os.path.exists(old): os.remove(old)
    shutil.rmtree(a.out, ignore_errors=True)
    if not want:
        print('no mods selected'); return
    os.makedirs(a.out)
    defs, obs, number, launcher, switch, switch_env, romfs_mods = [], {}, FIRST_GATE, [], {}, [], []
    launcher_groups = []   # (launcher.order, mod id, rows): the Mods section lists the mods by order, then id (mod.json launcher "order", default 0; the launcher's mods page groups them by launcher "category")
    for mid in sorted(set(want)):
        d = os.path.join(ROOT, 'mods', mid)
        with open(os.path.join(d, 'mod.json'), encoding='utf-8') as f: mod = json.load(f)
        assert mod['id'] == mid, f'mods/{mid}/mod.json names {mod["id"]}'
        nums = {}
        for g in mod.get('gates', []):
            if number > LAST_GATE: sys.exit(f'[RED] more than {LAST_GATE - FIRST_GATE + 1} gates selected')
            nums[g] = number; defs.append(f'#define MODGATE_{ident(mid)}_{ident(g)} {number}   // {mid}: {g}'); number += 1
        n_rows = 0
        for bid, rows in mod.get('obs', {}).items():
            if bid.startswith('_') or bid.startswith('EXAMPLE'): continue
            if not re.fullmatch(r'[0-9a-f]{32}', bid): sys.exit(f'[RED] {mid}: build ID {bid!r} is not 32 lowercase hex digits (the first 16 bytes of the module ID)')
            for r in rows:
                if r['gate'] not in nums: sys.exit(f'[RED] {mid}: row names the gate {r["gate"]!r}, which mod.json does not declare')
                if not re.fullmatch(r'[0-9a-f]{8}', r['word']): sys.exit(f'[RED] {mid}: word {r["word"]!r} is not 8 hex digits')
                obs.setdefault(bid, []).append([int(r['offset'], 0), nums[r['gate']] | int(r.get('param', 0)) << 8, r['word'], f'mod {mid}: {r.get("reason", r["gate"])}'])
                n_rows += 1
        lc = mod.get('launcher', {})
        env = lc.get('env', f'DM_MOD_{ident(mid)}')
        if not re.fullmatch(r'DM_[A-Z0-9_]+', env): sys.exit(f'[RED] {mid}: launcher env {env!r} must match DM_[A-Z0-9_]+')
        category = lc.get('category', 'Miscellaneous')
        if category not in CATEGORIES: sys.exit(f'[RED] {mid}: launcher category {category!r} must be one of {", ".join(CATEGORIES)}')
        rows = [{'env': env, 'kind': 'toggle', 'section': 'Mods', 'category': category, 'label': lc.get('label', mod.get('title', mid)),
                 'note': lc.get('note', mod.get('description', '')), 'default': '0', 'on': '1', 'off': '0'}]
        if lc.get('forced'):   # "<VAR>=<value>": the switch follows that launcher setting (on while it has that value, off otherwise) and is not offered on the mods page (touch-ui follows Touchscreen Mode)
            if not re.fullmatch(r'DM_[A-Z0-9_]+=[^;=]+', lc['forced']): sys.exit(f'[RED] {mid}: launcher forced {lc["forced"]!r} must be <DM_VAR>=<value>')
            rows[0]['forced'] = lc['forced']
        for st in mod.get('settings', []):
            if not re.fullmatch(r'DM_[A-Z0-9_]+', st.get('env', '')): sys.exit(f'[RED] {mid}: setting env {st.get("env")!r} must match DM_[A-Z0-9_]+')
            kind = st.get('kind', 'toggle')
            if kind not in ('toggle', 'range', 'choice'): sys.exit(f'[RED] {mid}: setting {st["env"]} has kind {kind!r}')
            row = {'env': st['env'], 'kind': kind, 'section': 'Mods', 'label': st['label'], 'note': st.get('note', ''), 'default': str(st.get('default', '0')), 'needs': f'{env}=1'}
            if kind == 'toggle':
                on, off = str(st.get('on', '1')), str(st.get('off', '0'))   # an "inverted" switch (a Disable ... switch) takes on 0 / off 1: the variable keeps its meaning, the switch reads the other way
                if on == off: sys.exit(f'[RED] {mid}: setting {st["env"]} has the same value for on and off')
                row.update({'on': on, 'off': off})
                if row['default'] not in (on, off): sys.exit(f'[RED] {mid}: setting {st["env"]} defaults to {row["default"]!r}, which is neither {on!r} nor {off!r}')
            elif kind == 'range':
                row.update({k: st[k] for k in ('min', 'max', 'step')})
                if st.get('format'):
                    if st['format'] not in ('multiplier',): sys.exit(f'[RED] {mid}: setting {st["env"]} has format {st["format"]!r}')
                    row['format'] = st['format']   # multiplier: shown as x1.25 instead of a percentage
            else: row['options'] = st['options']
            rows.append(row)
        launcher_groups.append((int(lc.get('order', 0)), mid, rows))
        if mod.get('host'): shutil.copyfile(os.path.join(d, mod['host']), os.path.join(host, f'hle_mod_{ident(mid).lower()}.c'))
        n_sw = 0
        if mod.get('exefs'):
            if env in switch_env: sys.exit(f'[RED] {mid}: {env} is already the switch of another mod')
            if len(switch_env) >= MAX_SWITCHES: sys.exit(f'[RED] more than {MAX_SWITCHES} mods with exefs patches')
            idx = len(switch_env); switch_env.append(env)
            for bid, rows in exefs_rows(mid, os.path.join(d, mod['exefs']), lambda name: f'mod {mid}: {name}').items():
                expect = {int(k, 0): v.lower() for k, v in mod.get('expect', {}).get(bid, {}).items()}
                for v in expect.values():
                    if not re.fullmatch(r'[0-9a-f]{8}', v): sys.exit(f'[RED] {mid}: expected word {v!r} is not 8 hex digits')
                if expect:
                    missing = sorted(o for o, _, _ in rows if o not in expect)
                    extra = sorted(set(expect) - {o for o, _, _ in rows})
                    if missing or extra: sys.exit(f'[RED] {mid}: "expect" for build {bid} does not match the patched words (no expectation for {", ".join(map(hex, missing)) or "none"}; no patch at {", ".join(map(hex, extra)) or "none"})')
                for off, word, why in rows: switch.setdefault(bid, []).append([off, idx, word, why, expect.get(off)]); n_sw += 1
            print(f'mod {mid}: {n_sw} patched words in the exefs files, switch {env} (byte {idx})')
        romfs = os.path.join(d, mod.get('romfs', 'romfs'))
        if os.path.isdir(romfs) and any(n != '.gitkeep' for _, _, fs in os.walk(romfs) for n in fs):
            shutil.copytree(romfs, os.path.join(a.out, 'romfs', mid), ignore=shutil.ignore_patterns('.gitkeep'))
            romfs_mods.append((env, mid))
        print(f'mod {mid}: {len(nums)} gates, {n_rows} gate rows for builds {", ".join(sorted({b for b in mod.get("obs", {}) if re.fullmatch(r"[0-9a-f]{32}", b)})) or "none yet"}')
        if mod.get('gates') and not n_rows: print(f'[warn] {mid} has no gate rows: it is built in but nothing will call it until mod.json has rows for your main\'s build ID')
    launcher = [r for _, _, rows in sorted(launcher_groups, key=lambda g: g[:2]) for r in rows]
    with open(os.path.join(host, 'hle_mods_gen.h'), 'w', encoding='utf-8') as f:
        f.write('// written by scripts/apply_mods.py; do not edit\n#pragma once\n' + '\n'.join(defs) + '\n')
    pj = os.path.abspath(os.path.join(a.out, 'patches.json'))
    with open(pj, 'w', encoding='utf-8') as f: json.dump({'OBS': obs, 'SWITCH': switch}, f, indent=1)
    if switch_env:
        with open(os.path.join(host, 'hle_modsw_gen.h'), 'w', encoding='utf-8') as f:
            f.write('// written by scripts/apply_mods.py; do not edit\n#pragma once\n#define MODSW_N %d\nstatic const char *const k_modsw_env[MODSW_N] = { %s };\n' % (len(switch_env), ', '.join(f'"{e}"' for e in switch_env)))
    os.makedirs(os.path.join(a.out, 'romfs'), exist_ok=True)
    if romfs_mods:
        with open(os.path.join(host, 'hle_modromfs_gen.h'), 'w', encoding='utf-8') as f:
            f.write('// written by scripts/apply_mods.py; do not edit\n#pragma once\n#define MODROMFS_N %d\nstatic const char *const k_modromfs_env[MODROMFS_N] = { %s };\nstatic const char *const k_modromfs_dir[MODROMFS_N] = { %s };\n'
                    % (len(romfs_mods), ', '.join(f'"{e}"' for e, _ in romfs_mods), ', '.join(f'"{m}"' for _, m in romfs_mods)))
    ls = os.path.abspath(os.path.join(a.out, 'launcher_mods.json'))
    with open(ls, 'w', encoding='utf-8') as f: json.dump({'settings': launcher}, f, indent=1, ensure_ascii=False)
    rf = os.path.abspath(os.path.join(a.out, 'romfs'))
    print(f'DM_MODS_PATCHES={pj}\nDM_MODS_SETTINGS={ls}\nDM_MODS_ROMFS={rf}')
    if os.environ.get('GITHUB_ENV'):
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as f: f.write(f'DM_MODS_PATCHES={pj}\nDM_MODS_SETTINGS={ls}\nDM_MODS_ROMFS={rf}\n')

if __name__ == '__main__': main()
