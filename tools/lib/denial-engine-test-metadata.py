#!/usr/bin/env python3
"""Validate isolated engine inputs and immutable bundle contents without running UI."""

import argparse
import ast
import hashlib
import json
import re
import subprocess
from pathlib import Path


def fail(message):
    raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], text=True, stderr=subprocess.PIPE
    ).strip()


def clean_revision(root, revision):
    if git(root, "rev-parse", "--show-toplevel") != str(root.resolve()):
        fail(f"not a source repository root: {root}")
    if git(root, "rev-parse", "HEAD") != revision:
        fail(f"source HEAD does not match candidate lock: {root}")
    if git(root, "status", "--porcelain=v1", "--ignore-submodules=all"):
        fail(f"source checkout is dirty: {root}")


def deps_assignment(text, name):
    """Read literal DEPS dictionaries; never execute a checkout's Python code."""
    tree = ast.parse(text)
    assignments = [
        node.value
        for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == name for target in node.targets)
    ]
    if len(assignments) != 1 or not isinstance(assignments[0], ast.Dict):
        fail(f"expected a single literal {name} dictionary in DEPS")
    return {ast.literal_eval(key): value for key, value in zip(assignments[0].keys, assignments[0].values)}


def deps_value(node, variables):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return deps_value(node.left, variables) + deps_value(node.right, variables)
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "Var"
        and len(node.args) == 1
        and not node.keywords
    ):
        return deps_value(variables[ast.literal_eval(node.args[0])], variables)
    fail("unsupported expression in the locked DEPS dependency")


def validate_sources(lock_path, flutter, skia):
    lock = read_json(lock_path)
    if set(lock) != {"schema_version", "flutter", "skia", "depot_tools"} or lock["schema_version"] != 1:
        fail("unsupported candidate source-lock schema")
    repositories = {
        "flutter": "https://github.com/wxj123654/flutter.git",
        "skia": "https://github.com/wxj123654/skia.git",
        "depot_tools": "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
    }
    for name, repository in repositories.items():
        fields = {"repository", "revision"} if name == "depot_tools" else {"repository", "branch", "revision", "upstream_revision"}
        entry = lock[name]
        if not isinstance(entry, dict) or set(entry) != fields or entry["repository"] != repository:
            fail(f"invalid {name} source-lock entry")
        for field in fields & {"revision", "upstream_revision"}:
            if not isinstance(entry[field], str) or not re.fullmatch("[0-9a-f]{40}", entry[field]):
                fail(f"invalid {name}.{field}")
        if "branch" in fields and (not isinstance(entry["branch"], str) or not entry["branch"]):
            fail(f"invalid {name}.branch")

    clean_revision(flutter, lock["flutter"]["revision"])
    clean_revision(skia, lock["skia"]["revision"])
    nested_skia = flutter / "engine/src/flutter/third_party/skia"
    if not nested_skia.is_symlink() or nested_skia.resolve() != skia.resolve():
        fail("Flutter's nested Skia must symlink to the selected paired root")
    for name, root in (("flutter", flutter), ("skia", skia)):
        git(root, "merge-base", "--is-ancestor", lock[name]["upstream_revision"], lock[name]["revision"])

    deps = (flutter / "DEPS").read_text()
    variables = deps_assignment(deps, "vars")
    dependencies = deps_assignment(deps, "deps")
    skia_revision = deps_value(variables["skia_revision"], variables)
    if skia_revision != lock["skia"]["revision"]:
        fail("Flutter DEPS Skia revision differs from the candidate lock")
    upstream_deps = git(flutter, "show", f'{lock["flutter"]["upstream_revision"]}:DEPS')
    upstream_vars = deps_assignment(upstream_deps, "vars")
    if deps_value(upstream_vars["skia_revision"], upstream_vars) != lock["skia"]["upstream_revision"]:
        fail("Skia upstream base differs from the selected upstream Flutter DEPS")
    depot_entry = deps_value(dependencies["engine/src/flutter/third_party/depot_tools"], variables)
    if depot_entry != repositories["depot_tools"] + "@" + lock["depot_tools"]["revision"]:
        fail("Flutter DEPS depot_tools differs from the candidate lock")
    depot = flutter / "engine/src/flutter/third_party/depot_tools"
    clean_revision(depot, lock["depot_tools"]["revision"])
    dart_revision = deps_value(variables["dart_revision"], variables)
    if dart_revision != deps_value(upstream_vars["dart_revision"], upstream_vars):
        fail("Dart revision differs from the selected upstream engine artifact")
    clean_revision(flutter / "engine/src/flutter/third_party/dart", dart_revision)
    engine_revision = (flutter / "bin/internal/engine.version").read_text().strip()
    upstream_engine = git(flutter, "show", f'{lock["flutter"]["upstream_revision"]}:bin/internal/engine.version')
    if not re.fullmatch("[0-9a-f]{40}", engine_revision) or engine_revision != upstream_engine:
        fail("engine.version differs from the exact upstream Flutter artifact revision")
    return {
        "schema_version": 1,
        "source_lock_sha256": sha256(lock_path),
        "sources": lock,
        "engine_artifact_revision": engine_revision,
        "dart_revision": dart_revision,
        "deps_sha256": sha256(flutter / "DEPS"),
    }


def bundle_hashes(bundle):
    result = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            fail(f"immutable bundle contains a symlink: {path}")
        if path.is_file():
            result[path.relative_to(bundle).as_posix()] = sha256(path)
        elif not path.is_dir():
            fail(f"immutable bundle contains a special file: {path}")
    for required in ("lib/libflutter_engine.so", "lib/libapp.so", "data/icudtl.dat"):
        if required not in result:
            fail(f"immutable bundle is missing {required}")
    if not any(name.startswith("data/flutter_assets/") for name in result):
        fail("immutable bundle has no Flutter assets")
    return result


def legacy_compatible(flutter, upstream_revision):
    current_engine = (flutter / "bin/internal/engine.version").read_text().strip()
    upstream_engine = git(flutter, "show", f"{upstream_revision}:bin/internal/engine.version")
    current_vars = deps_assignment((flutter / "DEPS").read_text(), "vars")
    upstream_vars = deps_assignment(git(flutter, "show", f"{upstream_revision}:DEPS"), "vars")
    if (
        not re.fullmatch("[0-9a-f]{40}", current_engine)
        or current_engine != upstream_engine
        or deps_value(current_vars["dart_revision"], current_vars)
        != deps_value(upstream_vars["dart_revision"], upstream_vars)
    ):
        fail("cross-version engine tests require --source-lock and rebuilt AOT assets")


def validate_bindings(flutter, inputs, bindings):
    text = bindings.read_text()
    revision = inputs["sources"]["flutter"]["revision"]
    upstream = inputs["sources"]["flutter"]["upstream_revision"]
    artifact = inputs["engine_artifact_revision"]
    # Denial extends embedder.h in the fork. The candidate compositor is bound
    # to that exact header, not the public upstream copy.
    header = subprocess.check_output([
        "git", "-C", str(flutter), "show",
        f"{revision}:engine/src/flutter/shell/platform/embedder/embedder.h",
    ], stderr=subprocess.PIPE)
    header_sha = hashlib.sha256(header).hexdigest()
    for line in (
        f"// Flutter engine revision: {artifact}",
        f"// Flutter source revision: {upstream}",
        f"// Source embedder.h SHA-256: {header_sha}",
    ):
        if line not in text.splitlines():
            fail("candidate compositor bindings do not match the exact upstream embedder header")
    return sha256(bindings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-sources")
    validate.add_argument("lock", type=Path)
    validate.add_argument("flutter", type=Path)
    validate.add_argument("skia", type=Path)
    legacy = commands.add_parser("legacy-compatible")
    legacy.add_argument("flutter", type=Path)
    legacy.add_argument("upstream_revision")
    bindings = commands.add_parser("validate-bindings")
    bindings.add_argument("flutter", type=Path)
    bindings.add_argument("inputs", type=Path)
    bindings.add_argument("bindings", type=Path)
    for name in ("bundle-hashes", "verify-bundle"):
        command = commands.add_parser(name)
        command.add_argument("bundle", type=Path)
        if name == "verify-bundle":
            command.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "validate-sources":
            output = validate_sources(args.lock, args.flutter, args.skia)
        elif args.command == "legacy-compatible":
            legacy_compatible(args.flutter, args.upstream_revision)
            return
        elif args.command == "validate-bindings":
            output = validate_bindings(args.flutter, read_json(args.inputs), args.bindings)
        else:
            output = bundle_hashes(args.bundle)
            if args.command == "verify-bundle":
                manifest = read_json(args.manifest)
                if manifest.get("schema_version") != 1 or output != manifest.get("bundle_sha256"):
                    fail("isolated bundle contents differ from the candidate manifest")
                staged = manifest.get("staged_sha256")
                if not isinstance(staged, dict) or "bin/deniald" not in staged or "abi/sys.rs" not in staged:
                    fail("candidate manifest does not identify its compositor and ABI bindings")
                for name, expected in staged.items():
                    relative = Path(name)
                    if relative.is_absolute() or ".." in relative.parts:
                        fail("candidate manifest path escapes the artifact")
                    path = args.bundle.parent / relative
                    if path.is_symlink() or not path.is_file() or sha256(path) != expected:
                        fail(f"staged candidate file differs from its manifest: {name}")
                return
        print(json.dumps(output, sort_keys=True, indent=2))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"denial-engine-test: {error}\n")


if __name__ == "__main__":
    main()
