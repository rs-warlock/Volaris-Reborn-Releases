#!/usr/bin/env python3
"""Merges the arm64 and x64 Vanguard.app builds into one universal app: every native file becomes one fat binary
(lipo), every other file must be the same in both builds. A file that differs is reported; lib/modules (the Java class
image) is compared entry by entry, so the report says exactly which classes differ between the two CPU builds.

    merge_universal.py <arm64 Vanguard.app> <x64 Vanguard.app> <out Vanguard.app> <report.json> <jimage tool>

Exit 0 = merged with nothing unexplained; exit 2 = merged, but a file differs that is not on the known list
(the report names it; the universal app is still written so it can be tested); exit 1 = the builds do not match.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ARM, X64, OUT, REPORT, JIMAGE = sys.argv[1:6]
THIN = b'\xcf\xfa\xed\xfe'          # 64-bit little-endian Mach-O (both CPUs)
FAT = b'\xca\xfe\xba\xbe'
HOME = 'Contents/runtime/Contents/Home/'
# Text that names the CPU it was built for and that nothing reads while the game runs.
KNOWN_DIFFERENT = {HOME + 'release',
                   # signature manifests: the merged app is signed again afterwards
                   'Contents/_CodeSignature/CodeResources', 'Contents/runtime/Contents/_CodeSignature/CodeResources'}
MODULES = HOME + 'lib/modules'


def archs(path):
    r = subprocess.run(['lipo', '-archs', path], capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else []


def magic(path):
    with open(path, 'rb') as f:
        return f.read(4)


def tree(root):
    """rel path -> ('link', target) | ('file', None) | ('dir', None), symlinks not followed"""
    out = {}
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            full = os.path.join(base, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if os.path.islink(full):
                out[rel] = ('link', os.readlink(full))
            elif os.path.isdir(full):
                out[rel] = ('dir', None)
            else:
                out[rel] = ('file', None)
    return out


def same_bytes(a, b):
    if os.path.getsize(a) != os.path.getsize(b):
        return False
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        while True:
            x, y = fa.read(1 << 20), fb.read(1 << 20)
            if x != y:
                return False
            if not x:
                return True


def module_entries_differing(a, b):
    """Extract both class images with the JDK's jimage tool and list the entries whose bytes differ."""
    with tempfile.TemporaryDirectory() as t:
        ea, eb = os.path.join(t, 'a'), os.path.join(t, 'b')
        for img, d in ((a, ea), (b, eb)):
            subprocess.run([JIMAGE, 'extract', '--dir', d, img], check=True)
        ta, tb = tree(ea), tree(eb)
        only_a = sorted(k for k, v in ta.items() if v[0] == 'file' and k not in tb)
        only_b = sorted(k for k, v in tb.items() if v[0] == 'file' and k not in ta)
        differ = sorted(k for k, v in ta.items() if v[0] == 'file' and k in tb
                        and not same_bytes(os.path.join(ea, k), os.path.join(eb, k)))
        return {'entries': sum(1 for v in ta.values() if v[0] == 'file'),
                'differ': differ, 'only_arm64': only_a, 'only_x64': only_b}


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    subprocess.run(['ditto', ARM, OUT], check=True)
    ta, tx = tree(ARM), tree(X64)
    report = {'lipo': [], 'identical': 0, 'differ_known': [], 'differ_unknown': [], 'modules': None,
              'only_arm64': sorted(set(ta) - set(tx)), 'only_x64': sorted(set(tx) - set(ta)), 'kind_mismatch': []}
    for rel, (kind, target) in sorted(ta.items()):
        if rel not in tx:
            continue
        if tx[rel][0] != kind or (kind == 'link' and tx[rel][1] != target):
            report['kind_mismatch'].append(rel)
            continue
        if kind != 'file':
            continue
        a, b, o = os.path.join(ARM, rel), os.path.join(X64, rel), os.path.join(OUT, rel)
        ma, mb = magic(a), magic(b)
        if ma in (THIN, FAT) and mb in (THIN, FAT) and archs(a) and archs(b):
            aa, ab = archs(a), archs(b)
            if aa == ab:
                # already the same (a fat file both builds ship, or a data file that happens to look like Mach-O)
                if same_bytes(a, b):
                    report['identical'] += 1
                else:
                    report['differ_unknown'].append(rel + ' (same archs ' + ','.join(aa) + ', different bytes)')
                continue
            if 'arm64' not in aa or 'x86_64' not in ab:
                report['differ_unknown'].append(f'{rel} (archs {aa} / {ab})')
                continue
            mode = os.stat(a).st_mode
            tmp = o + '.lipo'
            subprocess.run(['lipo', '-create', a, b, '-output', tmp], check=True)
            os.replace(tmp, o)
            os.chmod(o, mode & 0o7777)
            report['lipo'].append(rel)
        elif same_bytes(a, b):
            report['identical'] += 1
        elif rel in KNOWN_DIFFERENT:
            report['differ_known'].append(rel)
        elif rel == MODULES:
            report['modules'] = module_entries_differing(a, b)
        else:
            report['differ_unknown'].append(rel)
    m = report['modules']
    report['modules_identical'] = m is None
    # Every module descriptor names the CPU it was linked for (ModuleTarget "macos-aarch64" / "macos-amd64"), and the
    # jdk.jpackage tool carries its own native launcher. The JVM reads neither while it runs a program (the 10-25 run
    # played on an Intel Mac with the arm64 descriptors), so the universal app keeps arm64's class image. Anything
    # else that differs is reported as unknown.
    if m is not None:
        def target_only(k):
            return (k.endswith('/module-info.class') or k.startswith('java.base/jdk/internal/module/SystemModules$')
                    or k == 'jdk.jpackage/jdk/jpackage/internal/resources/jpackageapplauncher')
        other = [k for k in m['differ'] if not target_only(k)] + m['only_arm64'] + m['only_x64']
        report['modules_target_only'] = not other
        if other:
            report['differ_unknown'].append(MODULES + ': ' + ', '.join(other[:40]))
    with open(REPORT, 'w') as f:
        json.dump(report, f, indent=2)
    print(f"lipo: {len(report['lipo'])} native files, identical: {report['identical']}, "
          f"known differences: {report['differ_known']}, unknown: {report['differ_unknown']}")
    if m is not None:
        print(f"lib/modules: {len(m['differ'])} of {m['entries']} entries differ, "
              f"{len(m['only_arm64'])} only in arm64, {len(m['only_x64'])} only in x64")
        for k in (m['differ'] + m['only_arm64'] + m['only_x64'])[:80]:
            print('   ', k)
    if report['only_arm64'] or report['only_x64'] or report['kind_mismatch']:
        print('the two builds do not have the same files:', report['only_arm64'][:20], report['only_x64'][:20],
              report['kind_mismatch'][:20])
        return 1
    if report['differ_unknown']:
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
