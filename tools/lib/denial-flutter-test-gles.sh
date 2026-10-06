#!/usr/bin/env bash

# Prepare a separate Flutter local-engine host whose tester always selects the
# headless GLES backend. Never replace the normal flutter_tester or engine.
denial_prepare_flutter_gles_test_host() {
    local output="$1" shaders="$2" shader_include="$3"
    local framework_shaders="${4:-}"
    local host="${output}_gles_test" compiled="${output}_gles_test/runtime-shaders"
    local entry name source temporary input_dir
    local -a shader_dirs=("$shaders")
    if [[ -n "$framework_shaders" ]]; then
        shader_dirs+=("$framework_shaders/material/shaders")
    fi

    [[ -x "$output/flutter_tester_opengles" && -x "$output/impellerc" ]] \
        || { printf 'denial-flutter-test: GLES tester/compiler missing\n' >&2; return 1; }
    mkdir -p -- "$host" "$compiled"
    for entry in "$output"/*; do
        name="${entry##*/}"
        [[ "$name" != flutter_tester ]] || continue
        if [[ ! -e "$host/$name" && ! -L "$host/$name" ]]; then
            ln -s -- "$entry" "$host/$name"
        fi
    done
    # Flutter's tester target normally compiles only SkSL/Vulkan stages. The
    # wrapper installs exact lock-matched GLES stages after that asset build.
    for input_dir in "${shader_dirs[@]}"; do
        for source in "$input_dir"/*.frag; do
            [[ -f "$source" ]] || continue
            name="${source##*/}"
            temporary="$compiled/.${name}.tmp"
            "$output/impellerc" --sksl --runtime-stage-gles --runtime-stage-gles3 \
                --runtime-stage-vulkan --iplr --input="$source" --input-type=frag \
                --sl="$temporary" --spirv="$compiled/$name.spirv" \
                --include="$shader_include" --include="$input_dir" || return 1
            mv -f -- "$temporary" "$compiled/$name"
        done
    done
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'output=%q\ncompiled=%q\n' "$output" "$compiled"
        cat <<'SH'
for arg in "$@"; do
    case "$arg" in
        --flutter-assets-dir=*)
            assets="${arg#*=}/shaders"
            mkdir -p -- "$assets"
            for shader in "$compiled"/*.frag; do
                [[ -f "$shader" ]] || continue
                # Parallel test workers share assets. Replace atomically, not
                # with a truncating copy while another worker may load them.
                temporary="$(mktemp "$assets/.gles-shader.XXXXXX")"
                cp -- "$shader" "$temporary"
                mv -f -- "$temporary" "$assets/${shader##*/}"
            done
            ;;
    esac
done
export DENIAL_FLUTTER_TEST_BACKEND=opengles
unset DISPLAY WAYLAND_DISPLAY
printf 'Denial Flutter test backend: OpenGLES (headless ANGLE/SwiftShader)\n' >&2
exec "$output/flutter_tester_opengles" --impeller-backend=opengles "$@"
SH
    } > "$host/flutter_tester"
    chmod +x -- "$host/flutter_tester"
    printf '%s\n' "${host##*/}"
}
