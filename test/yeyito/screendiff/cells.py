#!/usr/bin/env python3
"""cells.py A B: compare two shot.sh captures cell by cell (character, colors,
bold/italic/underline). Prints each differing row; trailing blank cells with
the same background are ignored."""
import re, sys
SGR = re.compile(r'\x1b\[([0-9;:]*)m')
def parse(path):
    rows = []
    for line in open(path, encoding='utf-8', errors='replace').read().split('\n'):
        st = {}; cells = []; i = 0
        while i < len(line):
            m = SGR.match(line, i)
            if m:
                ps = [p for p in m.group(1).replace(':', ';').split(';')] or ['0']
                j = 0
                while j < len(ps):
                    p = int(ps[j] or 0)
                    if p == 0: st = {}
                    elif p in (38, 48) and j + 1 < len(ps) and ps[j+1] == '2':
                        st['fg' if p == 38 else 'bg'] = '#%02x%02x%02x' % tuple(int(x) for x in ps[j+2:j+5]); j += 4
                    elif p in (38, 48) and j + 1 < len(ps) and ps[j+1] == '5':
                        st['fg' if p == 38 else 'bg'] = 'c%s' % ps[j+2]; j += 2
                    elif p == 39: st.pop('fg', None)
                    elif p == 49: st.pop('bg', None)
                    elif 30 <= p <= 37 or 90 <= p <= 97: st['fg'] = 'a%d' % p
                    elif 40 <= p <= 47 or 100 <= p <= 107: st['bg'] = 'a%d' % p
                    elif p in (1, 3, 4, 7, 9): st['a%d' % p] = 1
                    elif p in (22, 23, 24, 27, 29): st.pop('a%d' % (p - 20), None)
                    j += 1
                i = m.end(); continue
            cells.append((line[i], tuple(sorted(st.items())))); i += 1
        rows.append(cells)
    return rows
a, b = parse(sys.argv[1]), parse(sys.argv[2])
show = len(sys.argv) > 3
diffs = 0
for r in range(max(len(a), len(b))):
    ra = a[r] if r < len(a) else []; rb = b[r] if r < len(b) else []
    ta = ''.join(c for c, _ in ra).rstrip(); tb = ''.join(c for c, _ in rb).rstrip()
    cols = [c for c in range(max(len(ra), len(rb))) if (ra[c] if c < len(ra) else (' ', ())) != (rb[c] if c < len(rb) else (' ', ()))]
    cols = [c for c in cols if not ((ra[c][0] if c < len(ra) else ' ') == ' ' == (rb[c][0] if c < len(rb) else ' ') and dict(ra[c][1] if c < len(ra) else ()).get('bg') == dict(rb[c][1] if c < len(rb) else ()).get('bg'))]
    if not cols: continue
    diffs += 1
    print(f'row {r+1}: cols {cols[0]+1}-{cols[-1]+1}')
    if ta != tb:
        print(f'  old: {ta!r}\n  new: {tb!r}')
    else:
        print(f'  text: {ta!r}')
    for c in cols[:6] if show else cols[:3]:
        ca = ra[c] if c < len(ra) else (' ', ()); cb = rb[c] if c < len(rb) else (' ', ())
        print(f'    col {c+1}: old {ca[0]!r} {dict(ca[1])}  new {cb[0]!r} {dict(cb[1])}')
print(f'{diffs} differing rows')
