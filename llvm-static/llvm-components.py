#!/usr/bin/env python3
"""Read and trim LLVM's component table for the static LLVM Mesa links.

LLVM's CMake writes the component table llvm-config is compiled with to
<build>/tools/llvm-config/LibraryDependencies.inc. Each entry is

    { "name", "LLVMLib" | nullptr, true, {"dep", "dep", ...} },

Usage:
  llvm-components.py libs <inc> <component>...
      Print the LLVM libraries (LLVMCore, ...) needed to link <component>s,
      dependencies included, one per line.
  llvm-components.py trim <inc> <out> <component>...
      Write a copy of <inc> to <out> in which every component outside that
      closure is marked not installed. llvm-config then lists, and links, only
      the libraries that are shipped: without a libLLVM.so it would otherwise
      report every component and fail on the missing archives (which is what
      meson's `--shared-mode` query, run with no components, would hit).
"""
import re
import sys

ENTRY = re.compile(
    r'\{\s*"(?P<name>[^"]+)"\s*,\s*(?:nullptr|"(?P<lib>[^"]*)")\s*,\s*'
    r'(?P<inst>true|false)\s*,\s*\{(?P<deps>[^}]*)\}\s*\}')


def parse(path):
    with open(path) as f:
        text = f.read()
    comps = {}
    for m in ENTRY.finditer(text):
        comps[m.group('name')] = (m.group('lib'), re.findall(r'"([^"]+)"', m.group('deps')))
    if not comps:
        sys.exit(f'{path}: no components found')
    return text, comps


def closure(comps, roots):
    seen = set()

    def visit(name):
        if name in seen:
            return
        if name not in comps:
            sys.exit(f'unknown LLVM component: {name}')
        seen.add(name)
        for dep in comps[name][1]:
            visit(dep)

    for root in roots:
        visit(root)
    return seen


def main(argv):
    if len(argv) < 3 or argv[1] not in ('libs', 'trim'):
        sys.exit(__doc__)
    text, comps = parse(argv[2])
    if argv[1] == 'libs':
        keep = closure(comps, argv[3:])
        print('\n'.join(sorted(comps[c][0] for c in keep if comps[c][0])))
        return

    out = argv[3]
    keep = closure(comps, argv[4:]) | {'all'}
    # Library-less group components (nativecodegen, all-targets, ...) stay when
    # everything they pull in is shipped.
    changed = True
    while changed:
        changed = False
        for name, (lib, deps) in comps.items():
            if name not in keep and lib is None and all(d in keep for d in deps):
                keep.add(name)
                changed = True

    def mark(m):
        if m.group('name') in keep:
            return m.group(0)
        s, e = m.span('inst')
        o = m.start(0)
        return m.group(0)[:s - o] + 'false' + m.group(0)[e - o:]

    with open(out, 'w') as f:
        f.write(ENTRY.sub(mark, text))
    print(f'{len(keep)} of {len(comps)} components kept')


if __name__ == '__main__':
    main(sys.argv)
