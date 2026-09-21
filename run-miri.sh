#!/usr/bin/env bash

# This file was written by Codex.
# Run a binary crate under the locally built Miri.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./run-miri.sh --crate PATH [--miri-arg FLAG]... [-- <binary args>]
  ./run-miri.sh --help

Options:
  --repo-root DIR  Path to the rust-lang/rust checkout. Defaults to this script's directory.
  --crate PATH     Path to the Cargo project you want to run under Miri. Required.
  --miri-arg FLAG  Extra flag passed to Miri (e.g. --miri-arg -Zmiri-disable-isolation).
                   Can be repeated.
  --               Everything after `--` is forwarded to the binary run under Miri.

Examples:
  ./run-miri.sh --repo-root /path/to/rust --crate /path/to/crate
  ./run-miri.sh --crate /path/to/crate --miri-arg -Zmiri-static-index-logfile=/full/path/to/logfile.txt -- --bin-flags
EOF
}

if [[ "${1-}" == "--help" ]]; then
    usage
    exit 0
fi

REPO_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$REPO_ROOT_DEFAULT"
HOST_TRIPLE="${HOST_TRIPLE:-aarch64-apple-darwin}"

CRATE_DIR=""
declare -a MIRI_USER_ARGS=()
declare -a BIN_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --crate)
            shift || { echo "error: --crate requires a path" >&2; exit 1; }
            CRATE_DIR="$1"
            ;;
        --crate=*)
            CRATE_DIR="${1#*=}"
            ;;
        --repo-root)
            shift || { echo "error: --repo-root requires a path" >&2; exit 1; }
            REPO_ROOT="$1"
            ;;
        --repo-root=*)
            REPO_ROOT="${1#*=}"
            ;;
        --miri-arg)
            shift || { echo "error: --miri-arg requires a flag" >&2; exit 1; }
            MIRI_USER_ARGS+=("$1")
            ;;
        --miri-arg=*)
            MIRI_USER_ARGS+=("${1#*=}")
            ;;
        --)
            shift
            BIN_ARGS=("$@")
            break
        ;;
        --help)
            usage
            exit 0
        ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 1
    esac
    shift
done

# Paths to the different tool stages and sysroots produced by `./x`.
stage0_bin="$REPO_ROOT/build/$HOST_TRIPLE/stage0/bin"
stage1_bin="$REPO_ROOT/build/$HOST_TRIPLE/stage1/bin"
stage1_tools_bin="$REPO_ROOT/build/$HOST_TRIPLE/stage1-tools-bin"
miri_host_sysroot="$REPO_ROOT/build/$HOST_TRIPLE/stage1"
miri_lib_dir="$REPO_ROOT/build/$HOST_TRIPLE/stage1/lib"
miri_stage0_lib_dir="$REPO_ROOT/build/$HOST_TRIPLE/stage0/lib"
miri_sysroot="$REPO_ROOT/build/$HOST_TRIPLE/miri-sysroot"
stage1_miri="$stage1_tools_bin/miri"

require_file() {
    local path="$1"
    local what="$2"
    if [[ ! -e "$path" ]]; then
        echo "error: expected $what at $path; run './x check' / './x miri ...' first." >&2
        exit 1
    fi
}

require_file "$stage0_bin/cargo" "stage0 cargo"
require_file "$stage1_bin/rustc" "stage1 rustc"
require_file "$stage1_tools_bin/cargo-miri" "cargo-miri tool"
require_file "$miri_lib_dir" "stage1 lib dir"
require_file "$miri_stage0_lib_dir" "stage0 lib dir"
require_file "$miri_host_sysroot/lib/rustlib" "host sysroot"
require_file "$stage1_miri" "miri driver"

resolve_cargo_for_miri() {
    if [[ -n "${CARGO:-}" ]]; then
        printf '%s\n' "$CARGO"
        return
    fi
    if command -v rustup >/dev/null 2>&1; then
        if cargo_path="$(rustup which --toolchain nightly-2026-05-01 cargo 2>/dev/null)"; then
            printf '%s\n' "$cargo_path"
            return
        fi
    fi
    printf '%s\n' "$stage1_tools_bin/cargo"
}

resolve_stage1_std_dir() {
    local candidate
    for candidate in \
        "$REPO_ROOT/build/$HOST_TRIPLE/stage1-std/$HOST_TRIPLE/dist" \
        "$REPO_ROOT/build/$HOST_TRIPLE/stage1-std/$HOST_TRIPLE/release" \
        "$REPO_ROOT/build/$HOST_TRIPLE/stage1-std/release"
    do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    printf '%s\n' "$REPO_ROOT/build/$HOST_TRIPLE/stage1-std/$HOST_TRIPLE/dist"
}

# Stage1 sysroot can retain library artifacts from an older compiler after a checkout update.
refresh_stage1_sysroot() {
    local sysroot_lib="$miri_host_sysroot/lib/rustlib/$HOST_TRIPLE/lib"
    local stage1_std_dir
    local -a proc_macro_rmeta
    stage1_std_dir="$(resolve_stage1_std_dir)"
    mkdir -p "$sysroot_lib"
    require_file "$stage1_std_dir" "stage1 library build output (run './x build --stage 1 library/std library/proc_macro')"
    find "$sysroot_lib" -maxdepth 1 -type f \( -name '*.rlib' -o -name '*.rmeta' -o -name '*.dylib' \) -delete
    shopt -s nullglob
    proc_macro_rmeta=("$stage1_std_dir"/deps/libproc_macro-*.rmeta)
    if ((${#proc_macro_rmeta[@]} == 0)); then
        echo "error: expected stage1 proc_macro artifacts in $stage1_std_dir/deps; run './x build --stage 1 library/proc_macro'." >&2
        exit 1
    fi
    # The top-level dist/libstd.{rlib,dylib} files are metadata stubs. Rustc expects
    # the full, hash-qualified artifacts from dist/deps in a sysroot lib dir.
    if [[ -d "$stage1_std_dir/deps" ]]; then
        for ext in rlib rmeta dylib; do
            cp "$stage1_std_dir/deps"/*."$ext" "$sysroot_lib"/ 2>/dev/null || true
        done
    fi
    shopt -u nullglob
}

refresh_stage1_sysroot

cargo_for_miri="$(resolve_cargo_for_miri)"
require_file "$cargo_for_miri" "Cargo frontend for cargo-miri"

# Keep the locally built cargo-miri and miri first, while using a Cargo frontend new enough for
# cargo-miri setup's unstable flags.
export CARGO="$cargo_for_miri"
export PATH="$stage1_tools_bin:$(dirname "$cargo_for_miri"):$stage0_bin:$PATH"
# Tells cargo/miri to compile everything with the stage1 compiler we just built.
export RUSTC="$stage1_bin/rustc"
if [[ -x "$stage1_bin/rustdoc" ]]; then
    # Doctests go through rustdoc, so route them through stage1 when that binary was built.
    export RUSTDOC="$stage1_bin/rustdoc"
fi
# Points cargo-miri/rustc at the sysroot prepared by `./x miri …` (contains Miri-built std).
export MIRI_SYSROOT="$miri_sysroot"
# Keeps spans/backtraces pointing at the local source tree instead of the rustup rust-src.
export MIRI_LIB_SRC="$REPO_ROOT/library"
# Needed so `cargo-miri` can build host artifacts (proc-macros/build scripts) with a matching std.
export MIRI_HOST_SYSROOT="$miri_host_sysroot"
# Force the driver to be the stage1 `miri` binary (the cargo-miri wrapper expects to exec "miri").
export MIRI="$stage1_miri"
# Without this, `miri` fails to load `librustc_driver` at runtime.
export DYLD_LIBRARY_PATH="$miri_lib_dir:$miri_stage0_lib_dir:${DYLD_LIBRARY_PATH:-}"

"$CARGO" miri setup --target "$HOST_TRIPLE"
require_file "$miri_sysroot" "Miri sysroot"

if ((${#MIRI_USER_ARGS[@]})); then
    user_flags="${MIRI_USER_ARGS[*]}"
    if [[ -n "${MIRIFLAGS:-}" ]]; then
        export MIRIFLAGS="${MIRIFLAGS} ${user_flags}"
    else
        export MIRIFLAGS="${user_flags}"
    fi
fi

if [[ -z "$CRATE_DIR" ]]; then
    echo "error: --crate PATH is required" >&2
    usage >&2
    exit 1
fi

if [[ ! -d "$CRATE_DIR" ]]; then
    echo "error: crate directory '$CRATE_DIR' does not exist" >&2
    exit 1
fi
CRATE_DIR="$(cd "$CRATE_DIR" && pwd)"
MANIFEST="$CRATE_DIR/Cargo.toml"
require_file "$MANIFEST" "Cargo manifest for target crate"

cd "$CRATE_DIR"
cargo_cmd=("$CARGO" miri run)
if ((${#BIN_ARGS[@]})); then
    cargo_cmd+=("--")
    cargo_cmd+=("${BIN_ARGS[@]}")
fi
exec "${cargo_cmd[@]}"
