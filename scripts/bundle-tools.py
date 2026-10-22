#!/usr/bin/env python3
"""Copies Homebrew's ffmpeg, ffprobe and cwebp plus every non-system dylib they need into
<dest>/ (executables) and <dest>/lib/ (libraries), rewrites load commands to @loader_path,
and ad-hoc signs everything so the tools run on a Mac without Homebrew.
cwebp is taken from build/deps/bin (scripts/build-deps.sh) when present. The build fails if any
embedded Mach-O targets a macOS newer than MAX_MINOS (the app's LSMinimumSystemVersion).

Usage: bundle-tools.py [--ffmpeg-dir DIR] <dest-dir> [tool ...]
  --ffmpeg-dir DIR   take ffmpeg/ffprobe from DIR/bin (e.g. build/ffmpeg-lgpl from scripts/build-ffmpeg.sh)
                     instead of Homebrew, and embed DIR/licenses as licenses/ffmpeg
"""
import os
import re
import shutil
import subprocess
import sys

TOOLS = ["ffmpeg", "ffprobe", "cwebp"]
SEARCH_BIN = ["/opt/homebrew/bin", "/usr/local/bin"]
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
DEPS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "deps")
MAX_MINOS = (14, 0)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def load_commands(path):
    """Returns (install_id, [dependency refs], [rpaths]) from otool -l."""
    out = run("otool", "-l", path)
    deps, rpaths, ident = [], [], None
    cmd = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            cmd = line.split()[1]
        elif line.startswith("name ") and cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB"):
            deps.append(re.sub(r" \(offset \d+\)$", "", line[5:]))
        elif line.startswith("name ") and cmd == "LC_ID_DYLIB":
            ident = re.sub(r" \(offset \d+\)$", "", line[5:])
        elif line.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(re.sub(r" \(offset \d+\)$", "", line[5:]))
    return ident, deps, rpaths


def resolve(ref, loader, rpaths):
    """Resolves a load-command reference to a real file path, or None for system libraries."""
    if ref.startswith(SYSTEM_PREFIXES):
        return None
    loader_dir = os.path.dirname(loader)
    candidates = []
    if ref.startswith("@rpath/"):
        tail = ref[len("@rpath/"):]
        for rp in rpaths:
            rp = rp.replace("@loader_path", loader_dir).replace("@executable_path", loader_dir)
            candidates.append(os.path.join(rp, tail))
        candidates.append(os.path.join(loader_dir, tail))
        candidates.append(os.path.join(loader_dir, "..", "lib", tail))
    elif ref.startswith("@loader_path/") or ref.startswith("@executable_path/"):
        candidates.append(os.path.join(loader_dir, ref.split("/", 1)[1]))
    else:
        candidates.append(ref)
    for c in candidates:
        if os.path.exists(c):
            return os.path.realpath(c)
    raise SystemExit(f"Cannot resolve {ref} (needed by {loader})")


def main():
    argv = sys.argv[1:]
    ffmpeg_dir = None
    if argv[:1] == ["--ffmpeg-dir"]:
        if len(argv) < 2:
            raise SystemExit(__doc__)
        ffmpeg_dir = os.path.abspath(argv[1])
        argv = argv[2:]
        if not os.path.isfile(os.path.join(ffmpeg_dir, "bin", "ffmpeg")):
            raise SystemExit(f"{ffmpeg_dir}/bin/ffmpeg not found; run scripts/build-ffmpeg.sh first")
    if not argv:
        raise SystemExit(__doc__)
    dest = os.path.abspath(argv[0])
    tools = argv[1:] or TOOLS
    libdir = os.path.join(dest, "lib")
    os.makedirs(libdir, exist_ok=True)

    copied = {}  # real source path -> destination path
    queue = []
    for tool in tools:
        search = [os.path.join(ffmpeg_dir, "bin")] if ffmpeg_dir and tool in ("ffmpeg", "ffprobe") else SEARCH_BIN
        if tool == "cwebp":
            search = [os.path.join(DEPS, "bin")] + search
        src = next((os.path.join(d, tool) for d in search if os.path.exists(os.path.join(d, tool))), None)
        if not src:
            raise SystemExit(f"{tool} not found; install it with Homebrew first")
        real = os.path.realpath(src)
        target = os.path.join(dest, tool)
        copied[real] = target
        queue.append(real)

    # Breadth-first walk of the dependency graph, keyed by real path (avoids self-reference loops).
    plan = {}  # real path -> list of (ref, dependency real path)
    while queue:
        real = queue.pop()
        if real in plan:
            continue
        _, deps, rpaths = load_commands(real)
        edges = []
        for ref in deps:
            dep = resolve(ref, real, rpaths)
            if dep is None:
                continue
            edges.append((ref, dep))
            if dep not in copied:
                name = os.path.basename(ref)
                copied[dep] = os.path.join(libdir, name)
            queue.append(dep)
        plan[real] = edges

    for src, dst in copied.items():
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755)

    for src, edges in plan.items():
        dst = copied[src]
        in_lib = os.path.dirname(dst) == libdir
        args = ["install_name_tool"]
        if in_lib:
            args += ["-id", "@loader_path/" + os.path.basename(dst)]
        for ref, dep in edges:
            new = ("@loader_path/" if in_lib else "@loader_path/lib/") + os.path.basename(copied[dep])
            if ref != new:
                args += ["-change", ref, new]
        _, _, rpaths = load_commands(dst)
        for rp in set(rpaths):
            args += ["-delete_rpath", rp]
        if len(args) > 1:
            subprocess.run(args + [dst], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "-s", "-", dst], check=True, capture_output=True)

    # Sanity check: nothing may still point outside the bundle.
    for dst in copied.values():
        _, deps, rpaths = load_commands(dst)
        bad = [d for d in deps + rpaths if not d.startswith(("@loader_path/",) + SYSTEM_PREFIXES)]
        if bad:
            raise SystemExit(f"{dst} still references {bad}")
    too_new = [f"{os.path.relpath(p, dest)} (minos {m})" for p in copied.values() for m in minos(p)
               if tuple(int(x) for x in m.split(".")[:2]) > MAX_MINOS]
    if too_new:
        raise SystemExit("Embedded binaries require a newer macOS than %d.%d: %s"
                         % (MAX_MINOS + (", ".join(too_new),)))

    copy_licenses(dest, copied.keys())
    if ffmpeg_dir:
        out = os.path.join(dest, "licenses", "ffmpeg")
        shutil.rmtree(out, ignore_errors=True)
        shutil.copytree(os.path.join(ffmpeg_dir, "licenses"), out)
    if os.path.isdir(os.path.join(DEPS, "licenses")):
        shutil.copytree(os.path.join(DEPS, "licenses"), os.path.join(dest, "licenses"), dirs_exist_ok=True)
    total = sum(os.path.getsize(p) for p in copied.values())
    print(f"Bundled {len(tools)} tools + {len(copied) - len(tools)} libraries ({total / 1048576:.1f} MB) into {dest}")


def minos(path):
    """Minimum macOS versions (LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX) of a Mach-O file."""
    out, cmd, found = run("otool", "-l", path), None, []
    for line in out.splitlines():
        parts = line.split()
        if parts[:1] == ["cmd"]:
            cmd = parts[1]
        elif (cmd == "LC_BUILD_VERSION" and parts[:1] == ["minos"]) or (cmd == "LC_VERSION_MIN_MACOSX" and parts[:1] == ["version"]):
            found.append(parts[1])
    return found


def copy_licenses(dest, sources):
    """Copies LICENSE/COPYING files of every Homebrew formula involved into <dest>/licenses/<formula>/."""
    cellar_re = re.compile(r"^(.*/Cellar/([^/]+)/[^/]+)/")
    lic_root = os.path.join(dest, "licenses")
    for src in sources:
        m = cellar_re.match(src)
        if not m:
            continue
        prefix, formula = m.group(1), m.group(2)
        out = os.path.join(lic_root, formula)
        if os.path.isdir(out):
            continue
        files = [f for f in os.listdir(prefix) if re.match(r"(?i)^(license|licence|copying|notice|authors)", f)]
        if files:
            os.makedirs(out, exist_ok=True)
            for f in files:
                p = os.path.join(prefix, f)
                if os.path.isfile(p):
                    shutil.copy2(p, out)


if __name__ == "__main__":
    main()
