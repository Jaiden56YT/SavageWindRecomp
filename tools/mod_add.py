#!/usr/bin/env python3
"""Adds a code mod (an exlaunch module built for the console) to the game files of a source checkout.

Usage: mod_add.py <module (the mod's subsdk9)> <its .elf (with symbols)> [exefs folder (default: extracted/exefs)]
       mod_add.py --remove [exefs folder]

Copies the module into the exefs folder under its own file name and writes its manifest next to it (<name>.mod: the
ELF's symbols, as `nm` prints them), which is what makes tools/layout.py, tools/gen.py and the runtime take it as a
mod (runtime/mods.c). Then: `make gen` and `make` build the game code with it. Functions it hooks that the log names
as "add it to hooks.txt" go in <exefs>/hooks.txt, one `module+offset` per line, before building again.
"""
import os
import shutil
import subprocess
import sys


def main():
    a = sys.argv[1:]
    if a and a[0] == '--remove':
        exefs = a[1] if len(a) > 1 else 'extracted/exefs'
        for n in os.listdir(exefs):
            if n.endswith('.mod'):
                for f in (n, n[:-4]):
                    os.remove(os.path.join(exefs, f))
                    print('removed', os.path.join(exefs, f))
        return
    if len(a) not in (2, 3):
        sys.exit(__doc__)
    nso, elf = a[0], a[1]
    exefs = a[2] if len(a) > 2 else 'extracted/exefs'
    name = os.path.basename(nso)
    if not name.startswith('subsdk') or open(nso, 'rb').read(4) != b'NSO0':
        sys.exit(f'{nso}: not a subsdk module')
    syms = subprocess.run(['nm', '--defined-only', elf], capture_output=True, text=True)
    if syms.returncode:
        sys.exit(f'nm {elf}: {syms.stderr.strip()}')
    lines = [l for l in syms.stdout.splitlines() if len(l.split()) == 3]
    if not any(l.split()[2] == '_ZN3exl4hook4nx644HookEmmb' for l in lines):
        sys.exit(f'{elf}: no exlaunch hook function among its symbols (stripped, or not an exlaunch mod)')
    shutil.copyfile(nso, os.path.join(exefs, name))
    with open(os.path.join(exefs, name + '.mod'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'{os.path.join(exefs, name)}: added, {len(lines)} symbols in {name}.mod')


if __name__ == '__main__':
    main()
