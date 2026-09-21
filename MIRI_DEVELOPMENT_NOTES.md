## Building and Running Miri from a Source Checkout

These are the pain points I hit when cloning `github.com/rust-lang/rust` at `0aeaa5eb22180fdf12a8489e63c4daa18da6f236` on macOS Sequoia (arm64), together with the fixes that made the toolchain usable for both in-tree tests and external crates.

### Repository & Config Setup

1. Clone with partial history to save space:
   ```bash
   git clone --filter=blob:none https://github.com/rust-lang/rust.git
   cd rust
   git checkout 0aeaa5eb22180fdf12a8489e63c4daa18da6f236
   ```

2. Check out only the submodules we truly need:
   ```bash
   git submodule update --init --filter=blob:none \
     library/backtrace library/stdarch src/llvm-project
   ```
   (later we also needed `src/tools/cargo`).

3. `config.toml` tweaks that kept the build reliable on this host (`rust/config.toml`):
   ```toml
   change-id = 133853

   [llvm]
   download-ci-llvm = false       # CI artifact was 404'ing
   targets = "AArch64;ARM;RISCV;X86"

   [build]
   extended = true
   submodules = false             # opt into submodules manually
   python = "python3"
   tools = ["cargo", "clippy", "rustdoc", "rustfmt", "miri", "cargo-miri"]

   [rust]
   debug-assertions = true
   incremental = true
   debuginfo-level = 1
   debuginfo-level-std = 1
   debuginfo-level-tools = 1

   [dist]
   compression-formats = ["xz"]
   ```

### Toolchain Prereqs

* Install `pkgconf` and `libffi` via Homebrew. `pkg-config` must see the keg-only libffi:
  ```bash
  brew install pkgconf libffi
  export PKG_CONFIG_PATH=/opt/homebrew/opt/libffi/lib/pkgconfig:$PKG_CONFIG_PATH
  ```
* The stock `libffi-sys` build currently fails on Apple clang 17 (`invalid CFI advance_loc`). Instead of forcing a rebuild, enable the `system` feature so Miri uses Homebrew’s libffi. In `src/tools/miri/Cargo.toml`:
  ```toml
  [target.'cfg(unix)'.dependencies]
  libc = "0.2"
  libffi = { version = "3.2.0", features = ["system"] }
  libloading = "0.8"
  ```

After that, `./x check` succeeds (plan for a ~20 GB checkout plus cache).

### Stage 0 vs. Stage 1 tooling

* `./x check` automatically builds stage0 Cargo/Clippy/etc. Those binaries are tied to the beta snapshot (`1.84.0-beta.1` here). They **cannot** parse `edition2024` manifests, which many local crates now use.
* Fix: build the tree’s Cargo (`./x build cargo`). That:
  * requires initializing `src/tools/cargo`.
  * leaves you with `build/aarch64-apple-darwin/stage1-tools-bin/cargo`, matching your stage1 rustc.

### Stage1 std in the sysroot

Bootstrap’s stage1 sysroot (`build/<triple>/stage1/lib/rustlib/<triple>/lib`) only holds LLVM tools by default. When `cargo-miri` builds host crates (build scripts, proc-macros) with your stage1 compiler (1.85.0-dev), it hits `E0463`/`E0514` unless that directory contains the matching `libstd`, `libcore`, etc.

Steps:
1. Build std: `./x build library/std --stage 1`.
2. Copy the artifacts from `build/<triple>/stage1-std/<triple>/release{,/deps}` into `build/<triple>/stage1/lib/rustlib/<triple>/lib`.
   The helper script described below now does this automatically if it notices that `libstd*.rlib` is missing.

### Running `./x miri …` in-tree

* `./x miri library/core --test-args <pattern>` is a good smoke test; it compiles stage1 std, Miri, cargo-miri, and the Miri sysroot once, then reuses caches on subsequent runs.
* Be aware `./x miri library/core` without filters can look idle in `htop`—it’s waiting for tests. Pass `--test-args` to keep turnaround low.

### Running external crates under the built Miri

Requirements:
* Stage1 rustc/rustdoc
* Stage1 cargo (see above)
* Stage1 std copied into the host sysroot
* Miri sysroot created by any `./x miri …` invocation
* `MIRI_SYSROOT`, `MIRI_HOST_SYSROOT`, `MIRI_LIB_SRC`, `RUSTC`, `RUSTDOC`, `DYLD_LIBRARY_PATH`, etc., exported

To make this repeatable we added `run-test-crate-miri.sh` (documented in-line). Highlights:

* Validates that all the stage0/1 binaries and sysroots exist, then populates `build/<triple>/stage1/lib/rustlib/<triple>/lib` if needed.
* Adds stage1 Cargo + stage0 tools to `PATH`.
* Exports the relevant env vars so `cargo-miri` uses the correct compiler and sysroots.
* Accepts:
  * `help` (usage)
  * `--crate /path/to/cargo/project`
  * `--miri-arg <flag>` (repeatable; appended to `MIRIFLAGS`)
  * `--` to pass the remainder to the binary (e.g. `-- --foo`).

Example:
```bash
./run-test-crate-miri.sh \
    --crate /path/to/some/crate \
    --miri-arg -Zmiri-disable-isolation \
    -- --bin-flag
```

You must run it from the repo root (or adjust `REPO_ROOT`), and if the crate lives outside the sandbox you’ll need to allow writes.

### Common Failure Modes

| Symptom | Fix |
| --- | --- |
| `curl: (56) The requested URL returned error: 404 … download-ci-llvm` | Set `[llvm] download-ci-llvm = false` and initialize `src/llvm-project`. |
| `libffi-sys` build fails with “invalid CFI advance_loc expression” | Install Homebrew `libffi` and set `libffi = { features = ["system"] }` in Miri. |
| `cargo` errors about `edition2024` | Build a stage1 Cargo (`./x build cargo`) and ensure the script’s `PATH` prefers `build/<triple>/stage1-tools-bin`. |
| `libstd` missing when running `cargo miri` on external crates | Build std (`./x build library/std --stage 1`) and copy `stage1-std/<triple>/release{,/deps}/*.rlib/.dylib/.rmeta` into `build/<triple>/stage1/lib/rustlib/<triple>/lib` (script now does this automatically). |
| `miri` cannot load `librustc_driver` | Ensure `DYLD_LIBRARY_PATH` covers both `build/<triple>/stage1/lib` and `build/<triple>/stage0/lib`. The script exports this before invoking `cargo miri`. |
| `Operation not permitted (os error 1)` when running script | Occurs if the crate lives outside the sandbox; rerun with elevated permissions (the CLI harness handles approval). |

With those adjustments, `./x check`, `./x miri library/core --test-args …`, and invoking `cargo miri` on third-party projects work reliably. Refer to `run-test-crate-miri.sh` for the exact environment setup.

## 2026-05-01 Nightly Update and Static Index Logging

This section documents the later update to line up with `0.15.2-nightly-2026-05-01`. The checkout used for that work was:

```text
f53b654a8882fd5fc036c4ca7a4ff41ce32497a6
2026-04-30 07:30:46 +0000
Auto merge of #155018 - nnethercote:simplify-HashStable, r=fee1-dead
```

That is the commit reported by the matching `nightly-2026-05-01` rustup compiler:

```text
rustc 1.97.0-nightly (f53b654a8 2026-04-30)
```

### Source Changes

The static-index logging support is split between rustc's interpreter hook and Miri's implementation:

* `compiler/rustc_const_eval/src/interpret/machine.rs`
  * Added a default no-op `Machine::before_location` hook.
  * The hook receives the active `DefId` and MIR `Location`.
  * Keeping the default no-op matters because the hook is now called by the generic interpreter, not only by Miri.

* `compiler/rustc_const_eval/src/interpret/step.rs`
  * Calls `M::before_location(self, self.frame().instance.def_id(), loc)?` before evaluating each MIR statement or terminator.
  * This is the single point where the execution stream is observed.

* `src/tools/miri/src/bin/miri.rs`
  * Added the CLI flag:
    ```bash
    -Zmiri-static-index-logfile=<path>
    ```
  * The flag is consumed by Miri and stored in config rather than forwarded to rustc.

* `src/tools/miri/src/eval.rs`
  * Added `MiriConfig::static_index_logging: Option<PathBuf>`.

* `src/tools/miri/src/machine.rs`
  * Added `StaticIndexLoggingConfig`, currently holding a buffered output writer.
  * Added `MiriMachine::static_index_logging`.
  * Opens the configured logfile with an 8 MiB `BufWriter`.
  * Writes two header lines before any location entries:
    ```text
    <tcx.sess.cfg_version>
    1.97.0-nightly (f53b654a8 2026-04-30)
    ```
  * The second line is intentionally pinned to the compiler version corresponding to `0.15.2-nightly-2026-05-01`; this keeps logs comparable even though the local stage1 compiler reports `1.97.0-dev`.
  * Implements `Machine::before_location` for Miri and writes one line per executed location:
    ```text
    <def_id.index> <def_id.krate.index> <basic_block.index> <statement_index>
    ```
  * The current code uses `File::create(path).unwrap()`, so the parent directory must already exist. For example, create `log-dump/` before passing `-Zmiri-static-index-logfile=log-dump/logs-miri.txt`.

* `src/tools/miri/Cargo.toml`
  * Changed the Unix `libffi` dependency to:
    ```toml
    libffi = { version = "5.1.0", features = ["system"], optional = true }
    ```
  * This avoids rebuilding bundled libffi on macOS and uses the Homebrew/system libffi instead.

### Build Commands That Were Needed

The commands that made this checkout usable were:

```bash
./x check --stage 1 src/tools/miri
./x build --stage 1 src/tools/miri src/tools/miri/cargo-miri
./x build --stage 1 library/std
./x build --stage 1 library/proc_macro
```

`library/proc_macro` is easy to miss. Without it, external crates that depend on proc macros can fail while compiling dependencies such as `proc-macro2`:

```text
error[E0463]: can't find crate for `proc_macro`
```

### `run-miri.sh`

The current helper script is `run-miri.sh`. It replaced the older `run-test-crate-miri.sh` flow described above.

Example:

```bash
./run-miri.sh \
    --crate ../../test-rust-nightly2/test-crate/ \
    --miri-arg -Zmiri-static-index-logfile=log-dump/logs-miri.txt
```

Important behavior in the script:

* Uses the local stage1 `rustc` and local stage1 `miri`.
* Puts `stage1-tools-bin` first in `PATH` so the locally built `cargo-miri` is used.
* Chooses a Cargo frontend in this order:
  * `$CARGO`, if the environment provides one.
  * `rustup which --toolchain nightly-2026-05-01 cargo`, if installed.
  * `build/<host>/stage1-tools-bin/cargo` as a fallback.
* The rustup Cargo path is intentional: some bootstrap-built Cargo binaries in this checkout are too old for `cargo-miri setup`'s unstable target-spec flow.
* Exports:
  * `RUSTC` pointing at `build/<host>/stage1/bin/rustc`
  * `RUSTDOC` when available
  * `MIRI_SYSROOT`
  * `MIRI_HOST_SYSROOT`
  * `MIRI_LIB_SRC`
  * `MIRI`
  * `DYLD_LIBRARY_PATH` covering both stage1 and stage0 lib directories
* Runs `cargo miri setup --target "$HOST_TRIPLE"` before executing the target crate.
* Accepts repeated `--miri-arg` values and appends them to `MIRIFLAGS`.

### Stage1 Sysroot Trap

The most time-consuming failure was caused by stale or incorrectly copied stage1 sysroot artifacts.

Do not copy the top-level files from:

```text
build/<host>/stage1-std/<host>/dist/libstd.rlib
build/<host>/stage1-std/<host>/dist/libstd.dylib
```

Those files are metadata stubs. If they land in:

```text
build/<host>/stage1/lib/rustlib/<host>/lib
```

then host builds fail with errors like:

```text
error: only metadata stub found for `rlib` dependency `std`
error: only metadata stub found for `dylib` dependency `std`
```

The sysroot lib directory should instead contain the hash-qualified artifacts from:

```text
build/<host>/stage1-std/<host>/dist/deps
```

For example:

```text
libstd-<hash>.rlib
libstd-<hash>.rmeta
libstd-<hash>.dylib
libproc_macro-<hash>.rlib
libproc_macro-<hash>.rmeta
```

`run-miri.sh` now refreshes the host sysroot by:

1. Deleting existing `*.rlib`, `*.rmeta`, and `*.dylib` files from `build/<host>/stage1/lib/rustlib/<host>/lib`.
2. Checking that `libproc_macro-*.rmeta` exists in `stage1-std/<host>/dist/deps`.
3. Copying only `*.rlib`, `*.rmeta`, and `*.dylib` from `stage1-std/<host>/dist/deps`.

This avoids mixing old stage artifacts with the current compiler and avoids the unversioned `libstd` stubs.

### Verification

The successful end-to-end command was:

```bash
./run-miri.sh --crate ../../test-rust-nightly2/test-crate/ --miri-arg -Zmiri-static-index-logfile=log-dump/logs-miri.txt
```

It exited with status 0 and printed:

```text
LOG::test-crate/src/main.rs:773:779
LOG::test-crate/src/main.rs:785:791
```

The generated logfile began with:

```text
1.97.0-dev
1.97.0-nightly (f53b654a8 2026-04-30)
187 1 0 0
187 1 0 1
```

Additional checks run after the script changes:

```bash
bash -n run-miri.sh
git diff --check
```

Both passed.
