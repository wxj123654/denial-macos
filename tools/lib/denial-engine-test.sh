#!/usr/bin/env bash

# Sourced by denial-pc. These functions build experiments without staging any
# engine, SDK, or AOT payload into the checkout's normal development bundle.

engine_test_source_metadata() {
    local source_lock="$1"
    local skia_root="${DENIAL_SKIA_SOURCE_ROOT:-/mnt/exty/denial-skia-fork-3.44.7}"
    if [[ -n "${DENIAL_FLUTTER_SOURCE_ROOT:-}" || -n "${DENIAL_SKIA_SOURCE_ROOT:-}" ]]; then
        [[ -n "${DENIAL_FLUTTER_SOURCE_ROOT:-}" && -n "${DENIAL_SKIA_SOURCE_ROOT:-}" ]] \
            || die 'engine tests require DENIAL_FLUTTER_SOURCE_ROOT and DENIAL_SKIA_SOURCE_ROOT together'
    fi
    [[ "$ENGINE_TEST_SOURCE_ROOT" == /* && "$skia_root" == /* ]] \
        || die 'engine-test source roots must be absolute paths'
    python3 "$SCRIPT_DIR/lib/denial-engine-test-metadata.py" \
        validate-sources "$source_lock" "$ENGINE_TEST_SOURCE_ROOT" "$skia_root"
}

stage_engine_test_candidate() (
    local source_lock="$1"
    local compositor="$2"
    local metadata metadata_after sources_hash build_root output target depot
    local stage='' assembly engine_sha manifest_sha artifact_id final_dir link
    local bindings_sha compositor_sha
    local launcher="$ENGINE_TEST_SOURCE_ROOT/bin/flutter"
    local -a gn_arch=()
    local -a engine_args

    # Verify the existing rollback payload before doing expensive work. None of
    # its files are subsequently passed to install/copy as destinations.
    require_pinned_engine
    require_file "$BUNDLE/data/icudtl.dat"
    require_file "$BUNDLE/lib/libapp.so"
    [[ "$source_lock" == /* ]] || source_lock="$(readlink -f -- "$source_lock")"
    [[ "$source_lock" != "$FLUTTER_SOURCE_LOCK" ]] \
        || die 'use a separate candidate lock; the normal source lock is not an experimental input'
    require_file "$source_lock"
    metadata="$(engine_test_source_metadata "$source_lock")"
    sources_hash="$(printf '%s' "$metadata" | sha256sum | cut -d' ' -f1)"
    [[ -f "$compositor" && -x "$compositor" ]] \
        || die 'cross-version engine tests require a separately built candidate compositor binary'
    compositor_sha="$(file_sha256 "$compositor")"
    local inputs
    inputs="$(mktemp -- "${TMPDIR:-/tmp}/denial-engine-test-inputs.XXXXXX")"
    printf '%s\n' "$metadata" > "$inputs"
    bindings_sha="$(python3 "$SCRIPT_DIR/lib/denial-engine-test-metadata.py" \
        validate-bindings "$ENGINE_TEST_SOURCE_ROOT" "$inputs" "$EMBEDDER_BINDINGS")" \
        || { rm -f -- "$inputs"; die 'generate matching candidate Rust embedder bindings before building the candidate compositor'; }
    bindings_sha="$(jq -er '.' <<<"$bindings_sha")"
    rm -f -- "$inputs"

    mkdir -p -- "$ENGINE_TEST_STORE/build"
    exec 8>"$ENGINE_TEST_STORE/build.lock"
    flock 8
    # Keep cross-version output separate from normal outputs; within an
    # upstream generation GN/Ninja can reuse unchanged dependency objects.
    build_root="$ENGINE_TEST_STORE/build/$(jq -er '.sources.flutter.upstream_revision' <<<"$metadata")/$DENIAL_FLUTTER_PLATFORM"
    target="$(denial_flutter_engine_target release)"
    output="$build_root/out/$target"
    depot="$ENGINE_TEST_SOURCE_ROOT/engine/src/flutter/third_party/depot_tools"
    mkdir -p -- "$build_root"
    if [[ "$DENIAL_FLUTTER_ARCH" != x64 ]]; then
        gn_arch=(--linux "--linux-cpu=$DENIAL_FLUTTER_ARCH")
    fi
    (
        cd -- "$ENGINE_TEST_SOURCE_ROOT/engine/src"
        PATH="$depot/.cipd_bin:$depot:$PATH" \
        DEPOT_TOOLS_UPDATE=0 \
        VPYTHON_VIRTUALENV_ROOT="$ENGINE_TEST_STORE/vpython" \
            ./flutter/tools/gn "${gn_arch[@]}" --runtime-mode=release \
            --enable-fontconfig --out-dir="$build_root" --target-dir="$target"
    )
    require_file "$output/args.gn"
    grep -Fqx 'flutter_runtime_mode = "release"' "$output/args.gn" \
        || die 'candidate build graph is not a release engine'
    grep -Fqx "engine_version = \"$(jq -er '.sources.flutter.revision' <<<"$metadata")\"" "$output/args.gn" \
        || die 'candidate GN graph does not identify the selected Flutter commit'
    grep -Fqx "skia_version = \"$(jq -er '.sources.skia.revision' <<<"$metadata")\"" "$output/args.gn" \
        || die 'candidate GN graph does not identify the selected Skia commit'
    grep -Fqx "dart_version = \"$(jq -er '.dart_revision' <<<"$metadata")\"" "$output/args.gn" \
        || die 'candidate GN graph does not identify the selected Dart commit'
    PATH="$depot/.cipd_bin:$depot:$PATH" DEPOT_TOOLS_UPDATE=0 \
        /usr/bin/ninja -C "$output" -j "$BUILD_JOBS" \
        libflutter_engine.so dart_sdk flutter_patched_sdk/platform_strong.dill \
        gen_snapshot flutter/tools/const_finder:const_finder \
        flutter/tools/font_subset:font_subset impellerc
    require_file "$output/libflutter_engine.so"
    require_file "$output/icudtl.dat"
    require_file "$output/flutter_patched_sdk/platform_strong.dill"
    [[ -x "$output/dart-sdk/bin/dart" && -x "$output/gen_snapshot" \
        && -x "$output/font-subset" && -x "$output/impellerc" ]] \
        || die 'candidate release output is missing a matching SDK/AOT/shader tool'
    [[ -x "$launcher" ]] || die "candidate Flutter launcher is missing: $launcher"

    stage="$(mktemp -d "$ENGINE_TEST_STORE/.candidate.XXXXXX")"
    trap 'if [[ -n "$stage" ]]; then chmod -R u+w -- "$stage"; rm -rf --one-file-system -- "$stage"; fi' EXIT
    mkdir -p -- "$stage/workspace/dart_shell" "$stage/workspace/protocol/generated/dart" "$stage/bundle/lib" "$stage/bundle/data" "$stage/bin" "$stage/abi"
    # Pub may update its lock and generated metadata. Work on a disposable
    # copy, preserving the wire-protocol relative dependency and current edits.
    rsync -aL --exclude=build --exclude=.dart_tool \
        "$ROOT/dart_shell/" "$stage/workspace/dart_shell/"
    rsync -aL "$ROOT/protocol/generated/dart/" "$stage/workspace/protocol/generated/dart/"
    # The committed shell pins the locked stable SDK. A cross-version candidate
    # resolves against its own Flutter tool, only inside this disposable copy.
    python3 - "$stage/workspace/dart_shell/pubspec.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old = "  flutter: 3.44.7\n"
new = "  flutter: \">=3.44.7 <4.0.0\"\n"
if old not in text:
    raise SystemExit("candidate shell pubspec no longer pins Flutter 3.44.7")
p.write_text(text.replace(old, new, 1))
PY
    python3 - "$stage/workspace" > "$stage/SHELL_INPUT_SHA256" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    if path.is_file():
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
    engine_args=(--local-engine-src-path="$build_root" --local-engine="$target" --local-engine-host="$target" --suppress-analytics)
    # The SDK launcher bootstraps its tool with this upstream's official Dart
    # SDK. Assembly explicitly resolves platform/compiler/gen_snapshot/shader
    # tools from the candidate's local-engine output, never the old bundle.
    FLUTTER_PREBUILT_ENGINE_VERSION="$(jq -er '.engine_artifact_revision' <<<"$metadata")" \
        "$launcher" "${engine_args[@]}" --version --machine > "$stage/FLUTTER_VERSION.json"
    jq -e --arg revision "$(jq -er '.sources.flutter.revision' <<<"$metadata")" \
        '.frameworkRevision == $revision' "$stage/FLUTTER_VERSION.json" >/dev/null \
        || die 'candidate Flutter tool reports a different framework commit'
    [[ "$(tr -d '[:space:]' < "$ENGINE_TEST_SOURCE_ROOT/bin/cache/engine.stamp")" \
        == "$(jq -er '.engine_artifact_revision' <<<"$metadata")" ]] \
        || die 'candidate Flutter launcher bootstrapped a different engine artifact'
    [[ "$("$ENGINE_TEST_SOURCE_ROOT/bin/cache/dart-sdk/bin/dart" --version 2>&1)" \
        == "$("$output/dart-sdk/bin/dart" --version 2>&1)" ]] \
        || die 'candidate Flutter-tool Dart SDK and local-engine Dart SDK differ'
    assembly="$stage/assembly"
    (
        cd -- "$stage/workspace/dart_shell"
        export FLUTTER_PREBUILT_ENGINE_VERSION="$(jq -er '.engine_artifact_revision' <<<"$metadata")"
        "$launcher" "${engine_args[@]}" pub get
        "$launcher" "${engine_args[@]}" assemble \
            --resource-pool-size="$BUILD_JOBS" --output="$assembly" \
            -dTargetFile=lib/main.dart -dBuildMode=release \
            -dTargetPlatform="$DENIAL_FLUTTER_PLATFORM" \
            -dDartObfuscation=false -dTrackWidgetCreation=true -dTreeShakeIcons=true \
            "release_bundle_${DENIAL_FLUTTER_PLATFORM}_assets"
    )
    require_file "$assembly/lib/libapp.so"
    rsync -aL "$assembly/flutter_assets/" "$stage/bundle/data/flutter_assets/"
    install -m644 -- "$output/icudtl.dat" "$stage/bundle/data/icudtl.dat"
    install -m755 -- "$assembly/lib/libapp.so" "$stage/bundle/lib/libapp.so"
    install -m644 -- "$output/libflutter_engine.so" "$stage/bundle/lib/libflutter_engine.so"
    # Detect source or lock mutations during the whole build, including pub.
    metadata_after="$(engine_test_source_metadata "$source_lock")"
    [[ "$metadata_after" == "$metadata" ]] || die 'candidate source inputs changed during the build'
    [[ "$(file_sha256 "$EMBEDDER_BINDINGS")" == "$bindings_sha" \
        && "$(file_sha256 "$compositor")" == "$compositor_sha" ]] \
        || die 'candidate compositor or ABI bindings changed during the build'
    install -m755 -- "$compositor" "$stage/bin/deniald"
    install -m644 -- "$EMBEDDER_BINDINGS" "$stage/abi/sys.rs"
    engine_sha="$(file_sha256 "$stage/bundle/lib/libflutter_engine.so")"
    printf '%s  libflutter_engine.so\n' "$engine_sha" > "$stage/libflutter_engine.so.sha256"
    jq -er '.sources.flutter.revision' <<<"$metadata" > "$stage/FLUTTER_REVISION"
    cp -- "$source_lock" "$stage/SOURCE_LOCK.json"
    cp -- "$output/args.gn" "$stage/args.gn"
    python3 "$SCRIPT_DIR/lib/denial-engine-test-metadata.py" \
        bundle-hashes "$stage/bundle" > "$stage/bundle-hashes.json"
    jq --arg source_identity "$sources_hash" \
        --arg shell_input_sha256 "$(< "$stage/SHELL_INPUT_SHA256")" \
        --arg args_sha256 "$(file_sha256 "$stage/args.gn")" \
        --arg architecture "$DENIAL_FLUTTER_PLATFORM" \
        --arg compositor_sha256 "$compositor_sha" \
        --arg embedder_bindings_sha256 "$bindings_sha" \
        --arg source_lock_sha256 "$(file_sha256 "$stage/SOURCE_LOCK.json")" \
        --arg flutter_revision_sha256 "$(file_sha256 "$stage/FLUTTER_REVISION")" \
        --arg flutter_version_sha256 "$(file_sha256 "$stage/FLUTTER_VERSION.json")" \
        --slurpfile bundle_hashes "$stage/bundle-hashes.json" \
        --slurpfile flutter_version "$stage/FLUTTER_VERSION.json" \
        '. + {source_identity: $source_identity, shell_input_sha256: $shell_input_sha256,
          args_sha256: $args_sha256, architecture: $architecture,
          flutter_tool_version: $flutter_version[0], bundle_sha256: $bundle_hashes[0],
          staged_sha256: {"bin/deniald": $compositor_sha256, "abi/sys.rs": $embedder_bindings_sha256,
            "SOURCE_LOCK.json": $source_lock_sha256, "args.gn": $args_sha256,
            "FLUTTER_REVISION": $flutter_revision_sha256, "FLUTTER_VERSION.json": $flutter_version_sha256}}' \
        <<<"$metadata" > "$stage/manifest.json"
    manifest_sha="$(file_sha256 "$stage/manifest.json")"
    artifact_id="$(jq -er '.sources.flutter.revision' <<<"$metadata")-${engine_sha:0:16}-${manifest_sha:0:16}"
    final_dir="$ENGINE_TEST_STORE/$artifact_id"
    rm -rf --one-file-system -- "$stage/workspace" "$stage/assembly"
    rm -f -- "$stage/bundle-hashes.json" "$stage/SHELL_INPUT_SHA256"
    if [[ -e "$final_dir" ]]; then
        cmp -s -- "$stage/manifest.json" "$final_dir/manifest.json" \
            || die "existing candidate manifest is inconsistent: $final_dir"
        python3 "$SCRIPT_DIR/lib/denial-engine-test-metadata.py" \
            verify-bundle "$final_dir/bundle" "$final_dir/manifest.json"
        rm -rf --one-file-system -- "$stage"
        stage=''
    else
        chmod -R a-w -- "$stage"
        mv -- "$stage" "$final_dir"
        stage=''
    fi
    link="$ENGINE_TEST_STORE/.current.$$"
    ln -s -- "$artifact_id" "$link"
    mv -Tf -- "$link" "$ENGINE_TEST_CURRENT"
    printf '\nStaged rebuilt cross-version engine test:\n  Bundle %s\n  Engine %s\n' "$final_dir/bundle" "$engine_sha"
    printf 'Run engine-test-check before engine-test-arm. The normal bundle and source lock were not modified.\n'
)
