#!/usr/bin/env bash

#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes.' Deliberate: the eval'd command strings expand in the engine, not here.
#  shellcheck disable=2034  ## 'variable appears unused.' Everything here is consumed by cicd.bash.

##	Purpose:
##		- Project-specific CI/CD settings for shcl.
##		- The engine (cicd.bash) stays generic; everything project-specific lives here.
##		- All command arrays run from the repo root; the Rust crate lives in
##		  source/rust (Tier 1 reference + the shcl CLI), so cargo goes through
##		  --manifest-path. Later bindings (Go/C/Python) add their commands here,
##		  not engine code.
##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## Only allow running 'sourced'.
declare -i isSourced_t6wqf=0; [[ "${BASH_SOURCE[0]}" == "${0}" ]] || isSourced_t6wqf=1
((isSourced_t6wqf)) || { echo -e "\nError in $(basename "${BASH_SOURCE[0]}"): This script is meant to be 'sourced' from within another script.\n"; exit 1; }


## Identity
APP_NAME="shcl"
EXE_NAME="shcl"
MANIFEST="source/rust/Cargo.toml"
VERSION_MANIFEST="${MANIFEST}"   ## the single canonical version source (tags + artifact names read it)

## Stage 1: format. FMT_CMD rewrites in place (local runs); FMT_CHECK_CMD fails on
## any diff without touching files (what --ci runs). rustfmt.toml at repo root
## (tabs) is the style source.
FMT_CMD=(cargo fmt --manifest-path "${MANIFEST}")
FMT_CHECK_CMD=(cargo fmt --check --manifest-path "${MANIFEST}")
FMT_EXTRA=('gofmt -w source/go')
FMT_CHECK_EXTRA=('gofmt_diff="$(gofmt -l source/go)"; [[ -z "${gofmt_diff}" ]] || { echo "gofmt: needs formatting: ${gofmt_diff}" >&2; false; }')

## Pinned versions of the external helper tools the pipeline uses; the engine
## warns (non-gating) when an installed tool has drifted from its pin, so a box
## update can't silently change results. Format: "name|version|command...".
## The rustc/clippy toolchain itself is pinned by rust-toolchain.toml at repo root.
TOOL_PINS=(
	"cargo-zigbuild|0.23.0|cargo-zigbuild --version"
	"ruff|0.15.22|ruff --version"
	"mypy|2.3.0|mypy --version"
	## Version of the Cppcheck binary, which is NOT the PyPI wheel's version;
	## the wheel pip installs is CPPCHECK_WHEEL below.
	"cppcheck|2.17.1|cppcheck --version"
	"markdownlint-cli2|0.23.1|markdownlint-cli2 --help"
	## Gating, and its findings move between releases, so CI installs this exact
	## version rather than using whatever the runner image ships.
	"shellcheck|0.11.0|shellcheck --version"
	## Builds the python artifacts so check-wheel.bash can read what is in them.
	## The backend that build stands up is not a tool installed on this box, so
	## it is not pinned here: it is fetched per build, and
	## cicd/packaging/python-build-constraints.txt pins its version.
	## check-wheel.bash reads that version back off the built wheel.
	"build|1.5.0|pyproject-build --version"
	## Supply-chain trio. Findings move as advisory databases update, so pin them
	## the same way and let the drift warning say when a result changed because
	## the tool did.
	"staticcheck|2026.1|staticcheck -version"
	"govulncheck|v1.5.0|govulncheck -version"
	"cargo-deny|0.19.9|cargo deny --version"
	## Gating like shellcheck, and its rule set moves between releases, so the
	## hosted gate installs this exact version rather than whatever the gallery
	## serves that day.
	"PSScriptAnalyzer|1.25.0|pwsh -NoProfile -Command \"(Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1).Version.ToString()\""
	## The Go series ci.yml installs (go-version). One decision with the
	## staticcheck pin: staticcheck has its own type checker and cannot read
	## export data from a Go newer than the release it was cut against, so the
	## two move together.
	"go|1.26|go version"
	## Builds the stub .deb and .rpm the packaging rows in shell-regress read
	## back, and the release packages. A go-installed nfpm says "dev" to
	## --version, so the version comes off the module it was built from.
	"nfpm|2.43.0|go version -m \"\$(command -v nfpm)\""
	## Builds the Windows setup .exe at release. Another version on another box
	## changes its bytes with no warning, as nfpm would. The hosted gate takes
	## the image's apt nsis for the shell-regress rows that compile the setup
	## script and read what it names; it builds no release, so that version
	## never reaches a published file, and check-pins leaves it out.
	"makensis|3.11|makensis -VERSION"
	## Only check-readme needs zig (the Zig example), and only shell-regress
	## needs Pillow (the demo gif's output order). Both fail a skip under --ci.
	"zig|0.16.0|zig version"
	"pillow|11.1.0|python3 -c 'import PIL; print(PIL.__version__)'"
)
## The PyPI wheel that bundles the pinned cppcheck binary has its own version,
## and that is the one pip installs (ci.yml, install-dev.bash). Bump it with
## the binary pin above; check-pins.bash holds ci.yml to both.
CPPCHECK_WHEEL="1.5.1"

## Stage 2: debug build (what the tests exercise). Capped at half the cores -
## cargo via -j, the Go toolchain (and the Go-built lint tools below) via
## GOMAXPROCS, which they all honor.
## The Go and C binding CLIs build here too - crosscheck needs them in stage 4.
## C has no separate fmt/lint stage (no committed zero-dep formatter); the
## strict-warning compile is its quality gate, same spirit as clippy.
BUILD_CMD=(cargo build -j "${CPU_CAP}" --manifest-path "${MANIFEST}")
BUILD_EXTRA=(
	'GOMAXPROCS="${CPU_CAP}" go -C source/go/cmd build -o ../shcl ./shcl'
	'python3 -m py_compile source/python/shcl.py source/python/cmd/shcl/main.py source/python/tests/conformance.py'
	'cc -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c source/c/cmd/shcl/main.c -o source/c/shcl -lm -s'
)

## Stage 3: lint. clippy gates (-D warnings); shellcheck covers the pipeline's own
## scripts so cicd can't rot silently. The extras gate every other binding too:
## go vet, ruff + mypy (Python), cppcheck (C, exhaustive, with a result cache),
## markdownlint over all tracked .md (config in .markdownlint-cli2.jsonc
## at repo root), and PSScriptAnalyzer on every tracked .ps1 but the frozen ones
## in project/legacy/. shfmt is deliberately NOT here - its output fights the
## hand-formatted shell style, so it stays interactive-only.
##
## The last three are the supply-chain half: staticcheck alongside go vet,
## govulncheck against the Go standard library and module graph, and cargo-deny
## over the rust lockfile (config in source/rust/deny.toml). All four libraries
## are dependency-free, so what these actually watch is the toolchain and the
## feature-gated profiler chain - small, and not nothing.
LINT_CMD=(cargo clippy -j "${CPU_CAP}" --manifest-path "${MANIFEST}" --all-targets -- -D warnings)
LINT_EXTRA=(
	## The host clippy never compiles the cfg(windows) code. The target comes with
	## rust-toolchain.toml, and a check needs no mingw linker.
	'cargo clippy -j "${CPU_CAP}" --manifest-path "${MANIFEST}" --target x86_64-pc-windows-gnu --all-targets -- -D warnings'
	'GOMAXPROCS="${CPU_CAP}" go -C source/go vet ./...'
	'GOMAXPROCS="${CPU_CAP}" go -C source/go/cmd vet ./...'
	'( cd source/go && GOMAXPROCS="${CPU_CAP}" staticcheck ./... )'
	'( cd source/go/cmd && GOMAXPROCS="${CPU_CAP}" staticcheck ./... )'
	'( cd source/python && RAYON_NUM_THREADS="${CPU_CAP}" ruff check ${QUIET_FLAG} . )'
	'( cd source/python && MYPYPATH=. mypy )'
	## The comparison tool's rust half stays out of the gate - it is the one thing
	## here with third-party crates, and the gate must not need crates.io. Its
	## python half has no such problem, and neither do the pipeline's own two
	## python utilities: ruff never imports what it checks, so this costs nothing
	## and the files are covered. cicd/utility/ruff.toml extends the project rule
	## set for them.
	'RAYON_NUM_THREADS="${CPU_CAP}" ruff check ${QUIET_FLAG} cicd/utility/flame-report.py cicd/utility/gen-demo-gif.py cicd/utility/check-abnf.py cicd/utility/gen-escapes.py cicd/utility/comparison/pyworker.py cicd/utility/test-ids.py'
	## Exhaustive over every #ifdef mix of the header is about ten minutes, and
	## most runs change no C. The build dir keeps each file's result, keyed on its
	## code, its comments and these options, so an unchanged file replays in well
	## under a second. It sits in the git dir so a pre-push worktree finds it too.
	'cbd="$(git rev-parse --git-common-dir 2>/dev/null || echo cicd/artifacts)/cppcheck-build"; mkdir -p "${cbd}"; cppcheck -j 2 --cppcheck-build-dir="${cbd}" --error-exitcode=1 --enable=warning,portability --inline-suppr --check-level=exhaustive --quiet -Isource/c source/c/cmd/shcl/main.c source/c/tests/conformance.c'
	'markdownlint-cli2'
	'pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path install.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"'
	'pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path utility/dogfood_shcl.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"'
	'pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path cicd/packaging/shclpath.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"'
	'pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path cicd/utility/winpath-regress.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"'
	'pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path cicd/utility/winpath-sandbox.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"'
	'cicd/utility/check-completions.bash'
	'cicd/utility/check-wheel.bash'
	## The README's C example is the first thing a C consumer copies, and it is
	## the one example nothing else here builds.
	'cicd/utility/check-readme.bash'
	## Claims the documents make about themselves, that no linter checks.
	'cicd/utility/check-docs.bash'
	## TOOL_PINS above is copied by hand into ci.yml; this fails the stage when
	## the two disagree, instead of hosted CI going red days later.
	'cicd/utility/check-pins.bash'
	## The C++ veneer has to keep up with the C calls it wraps, or list why not.
	## It fell a whole writer behind before anything checked.
	'cicd/utility/check-veneer.bash'
	## Every test prints its status line with a test ID; a test with none, or
	## two tests sharing one, fails here rather than on the console.
	'python3 cicd/utility/test-ids.py check'
	'GOMAXPROCS="${CPU_CAP}" govulncheck -C source/go ./...'
	'GOMAXPROCS="${CPU_CAP}" govulncheck -C source/go/cmd ./...'
	'RAYON_NUM_THREADS="${CPU_CAP}" cargo deny --manifest-path source/rust/Cargo.toml --all-features check'
)
SHELLCHECK_TARGETS=(
	cicd/cicd.bash
	cicd/config.bash
	cicd/utility/check-banner-tag.bash
	cicd/utility/check-c-compilers.bash
	cicd/utility/check-completions.bash
	cicd/utility/check-docs.bash
	cicd/utility/check-install-dev.bash
	cicd/utility/check-locale.bash
	cicd/utility/check-migrate.bash
	cicd/utility/check-pins.bash
	cicd/utility/check-push-gate.bash
	cicd/utility/check-readme.bash
	cicd/utility/check-veneer.bash
	cicd/utility/check-wheel.bash
	cicd/utility/cli-regress.bash
	cicd/utility/comparison/compare.bash
	cicd/utility/crosscheck.bash
	cicd/utility/largedoc.bash
	cicd/utility/libtest-quiet.bash
	cicd/utility/lint-report.bash
	cicd/utility/perf-gate.bash
	cicd/utility/release-table.bash
	cicd/utility/shell-regress.bash
	cicd/utility/n8git_backup-and-publish
	cicd/utility/package.bash
	cicd/utility/sanitize-c.bash
	cicd/utility/sign-release.bash
	cicd/utility/git-auto-msg.bash
	cicd/utility/green-tree.bash
	cicd/utility/win-runners.bash
	cicd/hooks/pre-push
	cicd/utility/include/gfs-rotate.bash
	cicd/utility/include/largedoc-gen.bash
	cicd/utility/include/test-id.bash
	source/completions/shcl.bash
	install.bash
	install-dev.bash
	utility/dogfood_shcl
)

## Stage 4: tests. cargo test runs the conformance corpus (project/conformance/)
## plus the deterministic fuzz smoke; the env var raises the fuzz iteration count
## well past the quick in-editor default.
##
## 200k, raised from 20k: the two fixpoint defects that sat past the old gate are
## fixed, and both needed this depth to surface at all. Costs about a minute.
## Deeper still is worth a run before a release cut:
##     SHCL_FUZZ_ITERS=1000000 cargo test --manifest-path source/rust/Cargo.toml \
##         --test fuzz_smoke
## RUST_TEST_THREADS caps the harness the way -j caps the compile; the fuzz
## tests are the heavy ones and would otherwise take every core.
## libtest-quiet.bash drops libtest's per-test lines, since each test prints
## its own with its test ID.
TEST_CMD=(cicd/utility/libtest-quiet.bash env SHCL_FUZZ_ITERS=200000 RUST_TEST_THREADS="${CPU_CAP}" cargo test -j "${CPU_CAP}" --manifest-path "${MANIFEST}")
## --quick swaps in this test command: same suites, fuzz at the old 20k gate
## depth - the minute-scale 200k soak is what the fast loop sheds.
TEST_QUICK_CMD=(cicd/utility/libtest-quiet.bash env SHCL_FUZZ_ITERS=20000 RUST_TEST_THREADS="${CPU_CAP}" cargo test -j "${CPU_CAP}" --manifest-path "${MANIFEST}")
## -count=1: the corpus sits outside the Go module, so go's test cache cannot
## see a changed case and answers `ok (cached)` over a broken golden. The
## library is one package, named by directory rather than ./..., since a
## package list hides a passing package's output and with it the per-test
## status lines.
TEST_EXTRA=(
	'GOMAXPROCS="${CPU_CAP}" go -C source/go test -count=1'
	'GOMAXPROCS="${CPU_CAP}" go -C source/go/cmd test -count=1 ./...'
	'python3 source/python/tests/conformance.py'
	'cbin="$(mktemp)"; cc -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c source/c/tests/conformance.c -o "${cbin}" -lm -lpthread && "${cbin}" project/conformance; crc=$?; rm -f "${cbin}"; ((crc==0))'
	'vbin="$(mktemp)"; g++ -std=c++17 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c source/c/tests/veneer_smoke.cpp -o "${vbin}" -lm && "${vbin}"; vrc=$?; rm -f "${vbin}"; ((vrc==0))'
	'obin="$(mktemp)"; cc -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c source/c/tests/oom_hook.c -o "${obin}" -lm && "${obin}"; orc=$?; rm -f "${obin}"; ((orc==0))'
	'rbin="$(mktemp)"; cc -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c source/c/tests/oom_recover.c -o "${rbin}" -lm && "${rbin}"; rrc=$?; rm -f "${rbin}"; ((rrc==0))'
	'mbin="$(mktemp)"; cc -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c source/c/tests/mem_bounds.c -o "${mbin}" -lm && "${mbin}"; mrc=$?; rm -f "${mbin}"; ((mrc==0))'
	## CLI behavior the corpus cannot reach: closed streams, '-' twice on one
	## command line, a carriage return ending an ops line, error-message shape.
	'cicd/utility/cli-regress.bash "${BINDING_CLIS[@]}"'
	## The read and write paths must stay small beside the parse. Two superlinear
	## write regressions reached dev in consecutive rounds with no number to fail
	## on, and the read side was quadratic before the surviving name index.
	'cicd/utility/perf-gate.bash "${BINDING_CLIS[@]}"'
	## The installers, the one-liner's scope hygiene, and the errexit grep trap.
	'cicd/utility/shell-regress.bash'
	## A 2.x file migrated for the current rules reads as the tree 2.x read,
	## judged against a build of the last pre-cut commit.
	'cicd/utility/check-migrate.bash'
	## install-dev's hook setup, through its --hooks-only path on a throwaway
	## clone - the one piece of that script the toolchain installs used to wall
	## off from any gate.
	'cicd/utility/check-install-dev.bash'
	## The pre-push hook's skip for a tree a run already passed. One that fires
	## when it should not sends a commit to dev untested, and nothing after it
	## would say so.
	'cicd/utility/check-push-gate.bash'
	## Every C compiler on the box, not just the default one: the hosted runner's
	## gcc is a different version, and the two disagree about what -Werror
	## rejects. A round went out green here and red there over exactly that.
	'cicd/utility/check-c-compilers.bash'
	## Float handling must not follow the host program's locale, which no corpus
	## case can ask for: the gate builds a comma-decimal locale of its own.
	'cicd/utility/check-locale.bash'
	## The same C programs again under the address and undefined-behavior
	## sanitizers, plus the CLI over the corpus. A read past a buffer that does
	## not change stdout passes every gate above; this one sees it.
	'cicd/utility/sanitize-c.bash'
)

## Stage 4b: cross-binding differential check (crosscheck.bash). Every entry is
## "name|cli-path" (stage 2 has built them by then); the first is the reference.
## Every cicd run requires all bindings to agree byte for byte on the corpus
## plus a fuzz-dumped input set. XCHECK_GEN (eval'd, ${XCHECK_DUMP_DIR} exported
## by the engine) produces that input set; it only runs with two or more bindings.
## It reruns the fuzz tests to dump them, so their passes, already shown by the
## tests stage, are left off the console.
BINDING_CLIS=(
	"rust|source/rust/target/debug/shcl"
	"go|source/go/shcl"
	"python|source/python/cmd/shcl/main.py"
	"c|source/c/shcl"
)
XCHECK_GEN='env SHCL_FUZZ_DUMP="${XCHECK_DUMP_DIR}" SHCL_FUZZ_ITERS=2000 SHCL_FUZZ_DUMP_MAX=500 RUST_TEST_THREADS="${CPU_CAP}" cargo test -j "${CPU_CAP}" --manifest-path '"${MANIFEST}"' --test fuzz_smoke --quiet 2> >(sed -E "/^ok   [0-9A-Za-z]{7} rust /d" >&2)'


## Stage 4c: large document. The corpus cases are a few hundred bytes each and
## the fuzz inputs are smaller, so nothing else here would see a parser going
## quadratic or a buffer that only misbehaves past a few megabytes. One generated
## document goes through every binding in BINDING_CLIS; they must agree on it
## byte for byte, and each stays inside the wall-clock and peak-RSS ceilings
## largedoc.bash sets. Set 0 to skip (--no-largedoc does the same).
##
## 100 MiB is the floor worth testing: the memory multiplier is 40-70x input, so
## this is also the only place the pipeline notices a document costing gigabytes.
## Python is the exception, at 16 MiB, since at 100 it was the gate's critical
## path. That cap is in largedoc.bash's limits table.
LARGEDOC_MIB=100

## Stage 5: profiler. Optimized-with-symbols build (cargo profile "profiling",
## feature-gated pprof sampler - never in a normal build), run over a workload big
## enough to sample meaningfully: the large-document generator at a few MiB. It
## used to be forty copies of the corpus concatenated, which made four lines in
## five merge into an existing node, so the graph measured merging and hint
## formatting rather than parsing. stderr is closed off on every run: a hint
## per unit once put a million lines in the log and a third of the samples in
## the write path.
## Kernel perf is locked down on this box (perf_event_paranoid=3), hence the
## in-process sampler. PROFILE_WORKLOAD_GEN / PROFILE_RUN are eval'd by the engine
## with PROFILE_WORKLOAD / PROFILE_OUT / PROFILE_SECS exported.
## This build is the only thing that compiles the feature-gated sampler block,
## and it is deliberately not in the `--ci` gate: the pprof chain comes from
## crates.io, which the gate must not need - the same reason the comparison
## tool's rust half is out. `--ci` runs only the calibration, below. A full
## local run hard-fails on it, which is where it is caught. The rule that the
## chain never reaches an artifact is enforced separately, on the files
## themselves, by package.bash.
PROFILE_ENABLE=1
PROFILE_SECS=8
PROFILE_BUILD_CMD=(cargo build --profile profiling --features profiling -j "${CPU_CAP}" --manifest-path "${MANIFEST}")
PROFILE_BIN="source/rust/target/profiling/${EXE_NAME}"
PROFILE_OUT_DIR="cicd/artifacts/profiling"   ## relative to repo root; gitignored
PROFILE_WORKLOAD_GEN='source cicd/utility/include/largedoc-gen.bash; largedoc_gen 4 > "${PROFILE_WORKLOAD}"'
## Two inlined loops of known cost ratio, sampled the same way; exit 1 when
## the graph would split them wrong. It prints a status line like every test.
PROFILE_CHECK_ID=EqeDCi1
PROFILE_CHECK='s=ok; SHCL_PROFILE_CHECK=1 "${PROFILE_BIN}" || s=FAIL; printf "%-4s %s profiler attribution-calibration\n" "${s}" "${PROFILE_CHECK_ID}"; [[ "${s}" == ok ]]'
## The calibration is the one pin on the sampler's attribution fix, and --ci
## turns the profiler off, so --ci builds for it alone. No LTO: the loops are
## inlined into one function without it, and the check still fails with the
## fix taken out. Its own target dir, so the full profiling build is left as it
## is. Offline, since the gate must not need crates.io: the probe says whether
## the local cache holds the sampler's crates, and when it does not the check
## is a noted skip.
PROFILE_CHECK_PROBE_CMD=(cargo fetch --offline --manifest-path "${MANIFEST}")
PROFILE_CHECK_BUILD_CMD=(env CARGO_PROFILE_PROFILING_LTO=false CARGO_PROFILE_PROFILING_CODEGEN_UNITS=16
	cargo build --offline --profile profiling --features profiling -j "${CPU_CAP}" --manifest-path "${MANIFEST}"
	--target-dir source/rust/target/profile-check)
PROFILE_CHECK_BIN="source/rust/target/profile-check/profiling/${EXE_NAME}"
PROFILE_RUN='SHCL_PROFILE_OUT="${PROFILE_OUT}" SHCL_PROFILE_SECS="${PROFILE_SECS}" "${PROFILE_BIN}" fmt "${PROFILE_WORKLOAD}" >/dev/null 2>&1'
## Wall-clock per surface, logged after the flamegraph: the graph shows where
## time goes inside fmt, these catch merge/validate/generate/set/read going
## quadratic without moving a sample. "name|command"; nonzero exit = FAILED
## (append `|| [ $? -eq N ]` where a nonzero exit is the expected outcome).
PROFILE_TIMED=(
	'fmt|"${PROFILE_BIN}" fmt "${PROFILE_WORKLOAD}" >/dev/null 2>&1'
	'merge|"${PROFILE_BIN}" fmt --layer="${PROFILE_WORKLOAD}" "${PROFILE_WORKLOAD}" >/dev/null 2>&1'
	'reads|"${PROFILE_BIN}" instances "${PROFILE_WORKLOAD}" service >/dev/null 2>&1 && "${PROFILE_BIN}" count "${PROFILE_WORKLOAD}" service >/dev/null 2>&1'
	'validate|"${PROFILE_BIN}" check --schema=project/conformance/021-schema-valid/schema.shcl "${PROFILE_WORKLOAD}" >/dev/null 2>&1 || [ $? -eq 6 ]'
	'generate|"${PROFILE_BIN}" init --schema=project/conformance/026-init-schema/init-schema.shcl >/dev/null'
	'set|printf "int\tprofile.k\t1\nstring\tprofile.s\tv\nremove\tprofile.k\n" | "${PROFILE_BIN}" set "${PROFILE_WORKLOAD}" >/dev/null 2>&1'
)

## Stage 6: native release + cross targets. One per line:
## "label|os-arch|artifact|command...". os-arch feeds the versioned artifact name
## (<exe>-<version>-<os-arch>[.exe]).
## FreeBSD is x86_64 only: Rust ships no prebuilt std for it on arm64.
## macOS is one universal binary, x86_64 and arm64 in one file, joined by
## cargo-zigbuild. No Apple SDK is needed, since zig has its own libSystem stubs
## and the CLI links nothing else.
## rustc asks xcrun for the SDK anyway and warns when there is none, unless
## SDKROOT names a dir. fMacSdk points it at zig's stubs, the SDK in use. zig
## never reads SDKROOT, so the bytes don't change. Where xcrun exists (the hosted
## macos job) it stays empty, which rustc and cargo-zigbuild treat as unset.
## zig sets the macOS floor from its own default unless the target names one,
## and cargo-zigbuild names none, so a second -target pins it (the last one
## wins). -Wl,-S keeps object paths out of the UUID zig computes, or the bytes
## move with the checkout path. Release strips that debug map anyway.
MACOS_FLOOR="13.0"
macLink="-Clink-arg=-Wl,-S -Clink-arg=-target -Clink-arg="
fMacSdk(){
	[[ -n "${SDKROOT:-}" ]] && { printf '%s' "${SDKROOT}"; return 0; }
	command -v xcrun >/dev/null 2>&1 && return 0
	local zigEnv re='lib_dir"?[[:space:]]*[=:][[:space:]]*"([^"]+)"'
	zigEnv="$(zig env 2>/dev/null || true)"
	[[ "${zigEnv}" =~ ${re} ]] && printf '%s/libc/darwin' "${BASH_REMATCH[1]}"
	return 0
}
RELEASE_NATIVE_CMD=(cargo build --release -j "${CPU_CAP}" --manifest-path "${MANIFEST}")
RELEASE_NATIVE_BIN="source/rust/target/release/${EXE_NAME}"
RELEASE_NATIVE_OSARCH="linux-x86_64"
CROSS_TARGETS=(
	"Windows x86_64 (mingw)|windows-x86_64|source/rust/target/x86_64-pc-windows-gnu/release/${EXE_NAME}.exe|cargo build --release -j \${CPU_CAP} --manifest-path ${MANIFEST} --target x86_64-pc-windows-gnu"
	"Linux ARM64 (zig)|linux-arm64|source/rust/target/aarch64-unknown-linux-gnu/release/${EXE_NAME}|cargo zigbuild --release -j \${CPU_CAP} --manifest-path ${MANIFEST} --target aarch64-unknown-linux-gnu"
	"Windows ARM64 (zig)|windows-arm64|source/rust/target/aarch64-pc-windows-gnullvm/release/${EXE_NAME}.exe|cargo zigbuild --release -j \${CPU_CAP} --manifest-path ${MANIFEST} --target aarch64-pc-windows-gnullvm"
	"FreeBSD x86_64 (zig)|freebsd-x86_64|source/rust/target/x86_64-unknown-freebsd/release/${EXE_NAME}|cargo zigbuild --release -j \${CPU_CAP} --manifest-path ${MANIFEST} --target x86_64-unknown-freebsd"
	"macOS universal (zig)|macos-universal|source/rust/target/universal2-apple-darwin/release/${EXE_NAME}|SDKROOT=\"\$(fMacSdk)\" CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS='${macLink}x86_64-macos.${MACOS_FLOOR}-none' CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS='${macLink}aarch64-macos.${MACOS_FLOOR}-none' cargo zigbuild --release -j \${CPU_CAP} --manifest-path ${MANIFEST} --target universal2-apple-darwin"
)
## Cross-compile checks that ship nothing: they exist so the non-Rust bindings'
## platform branches are compiled somewhere. The C header's Windows path had
## never been built here, which is how a regression in it reached dev. Same
## "label|command" shape as CROSS_TARGETS, minus the artifact. These run under
## --ci as well, since they are checks rather than artifacts; ci.yml has to
## install whatever they need, which today means mingw's gcc.
## No -Wconversion for mingw: its isfinite and isnan macros convert to float in
## the branch they do not take.
CROSS_CHECKS=(
	"C library + CLI for Windows x86_64 (mingw)|wbin=\"\$(mktemp -u)\".exe; x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Werror -Isource/c source/c/cmd/shcl/main.c -o \"\${wbin}\"; wrc=\$?; rm -f \"\${wbin}\"; ((wrc==0))"
	"C library with file I/O compiled out|printf '#define SHCL_NO_FILE_IO\\n#define SHCL_IMPLEMENTATION\\n#include \"shcl.h\"\\n' | cc -x c -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c -c - -o /dev/null"
	## Go's windows publish path lives in its own build-tagged file, so the lint
	## stage's vet and staticcheck - which only ever see the host's GOOS - walk
	## straight past it. These are the only thing that compiles it at all.
	"Go library for Windows (build + vet + staticcheck)|( cd source/go && export GOMAXPROCS=\${CPU_CAP}; GOOS=windows go build ./... && GOOS=windows go vet ./... && GOOS=windows staticcheck ./... )"
)

RELEASE_ARTIFACT_DIR="cicd/artifacts/release"   ## relative to repo root; gitignored

## Stage 6b: installer packages over the artifact dir (utility/package.bash):
## .deb + .rpm via nfpm per Linux binary, an NSIS setup per Windows binary, all
## named into the shcl-<version>-* family so the sha256sums rewrite covers them.
## Config template: cicd/packaging/nfpm.yaml; installer script: packaging/shcl.nsi.
## Off under --ci (no release builds there) and --quick (partial artifact set).
PACKAGE_ENABLE=1

## Stage 7: dogfood. Drop the freshly built native release binary into the first
## existing+writable dir below, under EXE_NAME, so the copy you launch by hand is
## always current (same fixed path the sister project uses). Only runs when a
## release binary got built - --ci builds none, so it no-ops there. Empty the list
## to skip. No sudo: a non-writable dest is passed over, not force-installed.
## Not ~/.local/bin: shcl there is the dogfood runner's link and the installer's,
## and a plain copy over it would stop both (20260924d idea 1).
DOGFOOD_FIXED_DESTS=(
	"${HOME}/synced/0-0/common/exec/util/linux/bin"
)
## Cross-built binaries install too, into a dest keyed by their CROSS_TARGETS
## os-arch label with '-' written as '_'. Same first-existing-and-writable rule; an
## os-arch with no list here just isn't installed. None for either arm64,
## because the synced tree has no arm64 dir to put one in. The macOS dir is where
## dogfood_shcl.ps1 looks on a Mac.
DOGFOOD_CROSS_DESTS_windows_x86_64=(
	"${HOME}/synced/0-0/common/exec/util/mswin/cli/by-self/win64"
)
DOGFOOD_CROSS_DESTS_macos_universal=(
	"${HOME}/synced/0-0/common/exec/util/macos/bin"
)
## The dogfood runner and its launchers, name kept, into every listed dir that
## exists. One per line: "source|dir|dir...". The bash launcher serves Linux and
## macOS alike.
DOGFOOD_RUNNERS=(
	"utility/dogfood_shcl.ps1|${HOME}/synced/0-0/common/exec/util/0_crossplatform"
	"utility/dogfood_shcl|${HOME}/synced/0-0/common/exec/util/linux/bash|${HOME}/synced/0-0/common/exec/util/macos/bash"
	"utility/dogfood_shcl.cmd|${HOME}/synced/0-0/common/exec/util/mswin/cli/by-self/cmd"
)

## Stage 8: demo gif for the README. Rendered from a scripted scenario against the
## fresh native release binary, so the captured output can never go stale.
GIF_ENABLE=1
GIF_SCENARIO="cicd/demo-scenario.toml"
GIF_OUT="assets/demo.gif"
## Every render is kept, gfs-rotated, in the synced (non-repo) private tree; the
## newest is copied onto GIF_OUT above. The ../ leaves the repo root on purpose -
## private/ is a sibling symlink, so rotated gifs never touch the tracked tree.
GIF_ROTATE_DIR="../private/demo/gif"

## Full-run output is tee'd here (gitignored) and gfs-rotated; lint-report.bash
## reports warnings from the newest log at session start.
LINT_LOG_DIR="cicd/artifacts/lint"

## Stage 9: backup + publish via the standalone publisher (versioned RAR backup of
## the whole project dir, then stash/pull/pop, add, commit, push).
GIT_PUBLISH=(cicd/utility/n8git_backup-and-publish)
## Backup excludes only this project has, on top of the publisher's own: the C
## and Go CLI builds, the Python build dir, and the comparison tool's build (none
## ship). The publisher already drops review scratch (crMMDD), gate worktrees,
## extra target-* dirs, and the runbuilds, crosscheck and profiling artifacts.
## One rar pattern per line, no '-x' and no quoting.
export GIT_BACKUP_AND_PUBLISH_RAR_EXCLUDES="*/source/c/shcl
*/source/go/shcl
*/source/python/build
*/comparison/target"
PUBLISH_AUTO_MESSAGE=""


##	History:
##		- 2026-07-11 JC: Created; all build/test stages stubbed pending the reference parser, shellcheck live from day one.
##		- 2026-07-12 JC: Wired the real stages: cargo fmt/clippy/test with the fuzz env, release + three cross targets, artifacts dir, demo gif scenario, n8git publish.
##		- 2026-07-12 JC: Added the profiler settings + binding list for the crosscheck; version guard dropped.
##		- 2026-07-12 JC: Go binding wired in: gofmt/build/vet/test extras + second crosscheck entry.
##		- 2026-07-12 JC: Python binding wired in: py_compile build gate + conformance test extra + third crosscheck entry.
##		- 2026-07-13 JC: Dogfood stage: install the native release binary (+ bash wrapper when it exists) to a fixed local dir.
##		- 2026-07-13 JC: C binding wired in: cc build extra (-Werror) + conformance/veneer test extras + fourth crosscheck entry.
##		- 2026-07-18 JC: Lint stage widened: ruff + mypy, cppcheck, markdownlint, PSScriptAnalyzer, with tool pins.
##		- 2026-07-22 JC: Packaging wired: PACKAGE_ENABLE + package.bash in the shellcheck list.
##		- 2026-08-26 JC: Per-os-arch dogfood dests for the cross builds; windows-x86_64 goes to the synced mswin cli dir.
##		- 2026-09-19 JC: green-tree.bash in the shellcheck list; shell-regress now holds the list to the tracked shell files.
##		- 2026-09-21 JC: cppcheck keeps a result cache in the git dir and checks its two files side by side.
##		- 2026-09-22 JC: PROFILE_CHECK, the sampler's attribution against two loops of known cost.
##		- 2026-09-26 JC: PROFILE_CHECK_*: --ci runs the calibration on a build without LTO.
##		- 2026-10-08 JC: The shell wrappers are retired: out of the lint lists and the dogfood stage.
