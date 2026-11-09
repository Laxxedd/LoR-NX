#!/usr/bin/env python3
import argparse, collections, bisect, json, math, re, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'dm/tools'))

PRESETS = {
    'cpu': ['DM_PROF_CPU=prof_cpu.tsv,100,20,12,10', 'DM_THRCPU=thrcpu.tsv,5', 'DM_NVN_TSV=frames.tsv', 'DM_NVN_TSV_CALLS=0', 'DM_NVN_WAITS=1'],
    'gpu': ['DM_NVN_TSV=frames.tsv', 'DM_NVN_TSV_CALLS=0', 'DM_NVN_GPUPROF=every:300', 'DM_NVN_PASSDUMP=every:600'],
    'mem': ['DM_MEMSTAT=memstat.tsv', 'DM_NVN_TSV=frames.tsv', 'DM_NVN_TSV_CALLS=0'],
}
PRESETS['full'] = sorted(set(sum(PRESETS.values(), [])) - {'DM_NVN_PASSDUMP=every:600'}) + ['DM_NVN_PASSDUMP=every:600']


def pct(xs, p):
    if not xs: return None
    s = sorted(xs)
    return s[min(len(s) - 1, max(0, math.ceil(p / 100 * len(s)) - 1))]


class Symbols:
    def __init__(self, module, script):
        self.main = None
        if not (module and script): return
        import il2cpp_sym, nso
        m = nso.load(Path(module).read_bytes(), module)
        self.starts, self.names = il2cpp_sym.symbols(script, m.text_end)
        fr = il2cpp_sym.functions(m)
        self.fstarts = [s for s, _ in fr]
        self.fends = [e for _, e in fr]
        self.text_end = m.text_end
        self.main = True
        self.cache = {}

    def func(self, token):
        mm = re.fullmatch(r'main\+0x([0-9a-f]+)', token)
        if mm and self.main:
            a = int(mm.group(1), 16)
            if a in self.cache: return self.cache[a]
            r = self.resolve(a)
            self.cache[a] = r
            return r
        if token.startswith('host:'):
            return re.sub(r'[+@]0x[0-9a-f]+$', '', token)
        return token

    def resolve(self, a):
        if a >= self.text_end: return f'main+{a:#x}'
        j = bisect.bisect_right(self.fstarts, a) - 1
        if j < 0 or a >= self.fends[j]: return f'main+{a:#x}'
        i = bisect.bisect_right(self.starts, a) - 1
        if i < 0 or self.starts[i] < self.fstarts[j]: return f'main fn {self.fstarts[j]:#x}'
        return ' | '.join(sorted(self.names[self.starts[i]]))


def read_cpu(path):
    head, groups, stacks = {}, {}, []
    for ln in Path(path).read_text(errors='replace').splitlines():
        if ln.startswith('#'):
            for k, v in re.findall(r'(\w+)=([\d.]+)', ln): head[k] = float(v)
            continue
        c = ln.split('\t')
        if c[0] == 'T' and len(c) >= 6: groups[c[1]] = [int(x) for x in c[2:6]]
        elif c[0] == 'S' and len(c) >= 5: stacks.append((int(c[1]), int(c[2]), c[3], c[4:]))
    return head, groups, stacks


def cpu_report(args, out):
    head, groups, stacks = read_cpu(args.cpu)
    sym = Symbols(args.module, args.script)
    sweeps, late = int(head.get('sweeps', 0)) or 1, int(head.get('late_sweeps', 0))
    hz = head.get('hz', 100)
    out.append(f'## CPU samples\n\n{sweeps} sweeps at {hz:g} Hz over {head.get("elapsed_s", 0):g} s; {late} sweeps ({100 * late / sweeps:.1f}%) while the last present was more than {head.get("late_ms", 0):g} ms old.\n')
    out.append('| thread group | busy (cores) | waiting | busy while late (cores) |\n|---|---|---|---|')
    for g, (run, wait, idle, run_late) in sorted(groups.items(), key=lambda kv: -kv[1][0])[:args.groups]:
        out.append(f'| {g} | {run / sweeps:.2f} | {wait / sweeps:.2f} | {run_late / late:.2f} |' if late else f'| {g} | {run / sweeps:.2f} | {wait / sweeps:.2f} | - |')
    out.append('')
    by_group = collections.defaultdict(list)
    for s in stacks: by_group[s[2]].append(s)
    for g, (run, *_r) in sorted(groups.items(), key=lambda kv: -kv[1][0])[:args.detail]:
        ss = by_group.get(g, [])
        tot = sum(s[0] for s in ss) or 1
        tot_late = sum(s[1] for s in ss)
        self_, incl = collections.Counter(), collections.Counter()
        self_l, incl_l = collections.Counter(), collections.Counter()
        for a, l, _g, fr in ss:
            fn = [sym.func(t) for t in fr]
            self_[fn[0]] += a; self_l[fn[0]] += l
            for f in set(fn): incl[f] += a; incl_l[f] += l
        out.append(f'### {g}\n')
        out.append('| function (self) | % of busy | % of busy while late |\n|---|---|---|')
        for f, n in self_.most_common(args.top):
            out.append(f'| {f} | {100 * n / tot:.1f} | {100 * self_l[f] / tot_late:.1f} |' if tot_late else f'| {f} | {100 * n / tot:.1f} | - |')
        out.append('')
        out.append('| function (on stack) | % of busy | % of busy while late |\n|---|---|---|')
        for f, n in incl.most_common(args.top):
            out.append(f'| {f} | {100 * n / tot:.1f} | {100 * incl_l[f] / tot_late:.1f} |' if tot_late else f'| {f} | {100 * n / tot:.1f} | - |')
        out.append('')
    if not sym.main: out.append('Pass `--module <original main NSO> --script <il2cpp script.json>` to name the `main+0x...` frames.\n')


def frames_report(args, out):
    rows = collections.defaultdict(dict)
    with open(args.frames, errors='replace') as fh:
        for ln in fh:
            c = ln.rstrip('\n').split('\t')
            if len(c) != 3 or not c[1].startswith('@'): continue
            try: rows[int(c[0])][c[1]] = float(c[2])
            except ValueError: pass
    fr = [r for _, r in sorted(rows.items())]
    out.append(f'## Frames ({len(fr)} rows)\n')
    out.append('| metric | p50 | p95 | p99 | max |\n|---|---|---|---|---|')
    for m in ('@frame_ms', '@presented_ms', '@gpu_ms', '@cpu_ms', '@sub_cpu_ms', '@wait_ms', '@draws', '@passes', '@rt_load_mb', '@rt_store_mb', '@upload_ms', '@pso_new'):
        xs = [r[m] for r in fr if m in r and r[m] >= 0]
        if xs: out.append(f'| {m[1:]} | {pct(xs, 50):.2f} | {pct(xs, 95):.2f} | {pct(xs, 99):.2f} | {max(xs):.2f} |')
    ft = [r['@frame_ms'] for r in fr if r.get('@frame_ms', 0) > 0]
    if ft:
        budget = 1000 / args.fps
        out.append(f'\n{sum(1 for x in ft if x > budget * 1.5)} of {len(ft)} frames took more than 1.5 x {budget:.1f} ms.\n')
        gpu = [(r['@gpu_ms'], r['@frame_ms']) for r in fr if r.get('@gpu_ms', -1) >= 0 and r.get('@frame_ms', 0) > 0]
        slow = [g for g, f in gpu if f > budget * 1.2]
        if slow: out.append(f'In frames over {budget * 1.2:.1f} ms the GPU median is {pct(slow, 50):.1f} ms and the frame median {pct([f for g, f in gpu if f > budget * 1.2], 50):.1f} ms: ' + ('GPU bound.' if pct(slow, 50) > budget else 'not GPU bound; look at the CPU sections.') + '\n')


def thr_report(args, out):
    acc = collections.defaultdict(list)
    for ln in Path(args.thrcpu).read_text(errors='replace').splitlines()[1:]:
        c = ln.split('\t')
        if len(c) == 4 and c[1] != '-':
            try: acc[c[2]].append(float(c[3]))
            except ValueError: pass
    out.append('## Thread CPU (mean of intervals where a thread used 0.5% or more; 100 = one core)\n')
    out.append('| thread | mean % | max % |\n|---|---|---|')
    for k, v in sorted(acc.items(), key=lambda kv: -sum(kv[1]) / len(kv[1]))[:args.groups]:
        out.append(f'| {k} | {sum(v) / len(v):.1f} | {max(v):.1f} |')
    out.append('')


def mem_report(args, out):
    best = 0
    for ln in Path(args.memstat).read_text(errors='replace').splitlines():
        c = ln.split('\t')
        if len(c) > 3 and not ln.startswith('#') and c[0] != 'seconds':
            try: best = max(best, float(c[1]))
            except ValueError: pass
    out.append(f'## Memory\n\nPeak phys_footprint {best:.0f} MiB.\n')


def gpu_report(args, out):
    r = subprocess.run([sys.executable, str(REPO / 'dm/tools/gpuprof.py'), args.log], capture_output=True, text=True)
    out.append('## GPU passes (dm/tools/gpuprof.py)\n\n```\n' + '\n'.join((r.stdout or r.stderr).splitlines()[:args.gpu_lines]) + '\n```\n')


def main():
    p = argparse.ArgumentParser(description='Capture presets and one report over the host profiling outputs of a run.')
    sub = p.add_subparsers(dest='cmd', required=True)
    e = sub.add_parser('env', help='print the Documents/env.txt lines of a capture preset')
    e.add_argument('preset', choices=sorted(PRESETS))
    r = sub.add_parser('report', help='summarise the files a run wrote (copied from Documents)')
    r.add_argument('--cpu', help='the DM_PROF_CPU file')
    r.add_argument('--frames', help='the DM_NVN_TSV file')
    r.add_argument('--thrcpu', help='the DM_THRCPU file')
    r.add_argument('--memstat', help='the DM_MEMSTAT file')
    r.add_argument('--log', help='log.txt with [gpuprof] lines')
    r.add_argument('--module', help='the original main NSO, to name main+0x... frames')
    r.add_argument('--script', help="Il2CppDumper's script.json for that NSO")
    r.add_argument('--fps', type=float, default=60)
    r.add_argument('--top', type=int, default=15)
    r.add_argument('--groups', type=int, default=12)
    r.add_argument('--detail', type=int, default=3, help='thread groups listed function by function')
    r.add_argument('--gpu-lines', type=int, default=60)
    r.add_argument('--out', help='write the markdown here instead of stdout')
    a = p.parse_args()
    if a.cmd == 'env':
        print('\n'.join(PRESETS[a.preset]))
        return 0
    out = []
    try:
        if a.frames: frames_report(a, out)
        if a.cpu: cpu_report(a, out)
        if a.thrcpu: thr_report(a, out)
        if a.memstat: mem_report(a, out)
        if a.log: gpu_report(a, out)
    except (OSError, ValueError, ImportError) as ex:
        print(f'error: {ex}', file=sys.stderr)
        return 1
    if not out:
        print('error: give at least one of --cpu --frames --thrcpu --memstat --log', file=sys.stderr)
        return 1
    text = '\n'.join(out)
    if a.out: Path(a.out).write_text(text)
    else: print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
