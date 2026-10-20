#!/usr/bin/env python3
"""Refuse to publish ROMs, firmware, extracted game data or local machine state.

Audits the files Git would publish (tracked plus untracked-but-not-ignored),
every blob introduced by the commits in --range (a deleted file stays public in
history and pull-request refs), or every file under --tree. With --release (a built app or archive tree) compiled
binaries and build paths are allowed, but ROM/firmware/vector content, SNES
headers and credentials are still refused. Exit 1 lists each violation.
This repository is source-only: users supply their own ROM.
"""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

MAX_BYTES = 512 * 1024
# Exact images that must never be published (hashes only; no content embedded).
DENY_SHA256 = {
    "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9": "Chrono Trigger (USA) ROM",
    "c95f88b299030d5afa55b1031e2b5ef2dff650c4b4e6bb6f8b1359436521278f": "S-SMP IPL ROM image",
    "6de0928369b6c66e8cddc3083c24872b1a987998edb30da2c77b2323fb16ee9b": "SPC700 vectors sample (upstream license unresolved)",
}
DENY_PREFIXES = (
    "input/", "original/", "agentinstructions/", ".agents/",
    "re_workspace/assets/", "re_workspace/refs/", "re_workspace/manifests/",
    "re_workspace/reports/", "re_workspace/.venv/",
)
DENY_PARTS = {".build", "build", ".venv", "__pycache__", ".pytest_cache", ".swiftpm", "DerivedData"}
DENY_NAMES = {".DS_Store", "HANDOFF.md", "AGENT_CONTEXT.md", "AGENT_CONTEXT_V2.md", "skills-lock.json",
              ".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", "id_ecdsa"}
DENY_SUFFIXES = {
    ".sfc", ".smc", ".fig", ".swc", ".spc", ".rom", ".srm", ".ips", ".bps",
    ".dylib", ".so", ".a", ".o", ".zip", ".dmg", ".pkg", ".p12", ".mobileprovision",
    ".tar", ".gz", ".tgz", ".bz2", ".xz", ".zst", ".7z", ".rar", ".img", ".iso", ".pem", ".key",
}
ROM_SUFFIXES = {".sfc", ".smc", ".fig", ".swc", ".spc", ".rom", ".srm"}
DENY_PATHS = {"macos_studio/Tests/ChronoForgeCoreTests/Resources/SPC700/vectors.json"}
SECRET = re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{30,}|"
                    rb"github_pat_[A-Za-z0-9_]{40,}|\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|"
                    rb"\bAKIA[0-9A-Z]{16}\b|\bxox[abprs]-[A-Za-z0-9-]{10,}")
LOCAL_PATH = re.compile(rb"/Users/[A-Za-z0-9._-]+/|/private/tmp/claude-|\.codex/worktrees")


def snes_header(data):
    """True when a LoROM/HiROM internal header checksum pair validates."""
    for base in (0, 512):
        for offset in (0x7FC0, 0xFFC0):
            at = base + offset
            if len(data) < at + 0x20:
                continue
            complement = int.from_bytes(data[at + 0x1C:at + 0x1E], "little")
            checksum = int.from_bytes(data[at + 0x1E:at + 0x20], "little")
            if checksum ^ complement == 0xFFFF and data[at + 0x15] & 0xE0 == 0x20:
                return True
    return False


def published_files(root):
    out = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others",
                                   "--exclude-standard"])
    paths = sorted({p for p in out.decode().split("\0") if p and (root / p).is_file()})
    return [(p, (root / p).read_bytes()) for p in paths]


def history_blobs(root, revisions):
    """(path, content) for every blob reachable from `revisions` (rev-list syntax)."""
    git = ["git", "-C", str(root)]
    listing = subprocess.check_output(git + ["rev-list", "--objects", *revisions.split()], text=True)
    named = [line.split(" ", 1) for line in listing.splitlines() if " " in line]
    if not named:
        return []
    checks = subprocess.run(git + ["cat-file", "--batch-check=%(objecttype)"], check=True, text=True,
                            capture_output=True, input="".join(f"{sha}\n" for sha, _ in named)).stdout.split()
    blobs = [(sha, path) for (sha, path), kind in zip(named, checks) if kind == "blob"]
    return [(path, subprocess.check_output(git + ["cat-file", "blob", sha])) for sha, path in blobs]


def audit(items, release=False):
    problems = []
    for rel, data in items:
        path = PurePosixPath(rel)
        reasons = []
        if release:
            if path.suffix.lower() in ROM_SUFFIXES or path.name == "vectors.json":
                reasons.append(f"ROM or test-vector file {path.name}")
        else:
            if rel.startswith(DENY_PREFIXES) or rel in DENY_PATHS:
                reasons.append("private workspace path")
            if DENY_PARTS & set(path.parts[:-1]) or path.name in DENY_NAMES:
                reasons.append("local build, environment or agent state")
            if path.suffix.lower() in DENY_SUFFIXES:
                reasons.append(f"binary/ROM type {path.suffix}")
            if len(data) > MAX_BYTES:
                reasons.append(f"{len(data)} bytes exceeds {MAX_BYTES}")
        digest = hashlib.sha256(data).hexdigest()
        if digest in DENY_SHA256:
            reasons.append(DENY_SHA256[digest])
        if len(data) >= 0x8000 and snes_header(data):
            reasons.append("contains a valid SNES ROM header")
        if SECRET.search(data):
            reasons.append("credential-like token")
        if not release and LOCAL_PATH.search(data) and rel != "scripts/ci/publication_audit.py":
            reasons.append("local machine path")
        problems += [f"{rel}: {reason}" for reason in reasons]
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path, help="audit every file under this directory instead of Git's view")
    parser.add_argument("--release", action="store_true", help="--tree holds built release contents")
    parser.add_argument("--range", help="audit blobs introduced by these commits, e.g. BASE..HEAD or HEAD")
    args = parser.parse_args()
    if args.release and not args.tree:
        parser.error("--release requires --tree")
    if args.tree and args.range:
        parser.error("use --tree or --range, not both")
    root = Path(__file__).resolve().parents[2]
    if args.tree:
        root = args.tree.resolve()
        items = [(p.relative_to(root).as_posix(), p.read_bytes()) for p in sorted(root.rglob("*")) if p.is_file()]
    elif args.range:
        items = history_blobs(root, args.range)
    else:
        items = published_files(root)
    paths = [rel for rel, _ in items]
    problems = audit(items, release=args.release)
    for problem in problems:
        print(f"::error::{problem}" if os.environ.get("GITHUB_ACTIONS") else f"BLOCKED {problem}")
    print(f"publication audit: {len(paths)} files, {len(problems)} violations")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
