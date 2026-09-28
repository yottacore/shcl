#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'source is valid here, but shellcheck doesn't know the path to it.'
#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes, use double quotes for that.' I know, and I often want an explicit '$'.
#  shellcheck disable=2034  ## 'variable appears unused.' Complains about valid use of variable indirection.
#  shellcheck disable=2086  ## 'Double quote to prevent globbing and word splitting.' (OK for integers.)
#  shellcheck disable=2153  ## 'Possible misspelling.' False hit on vars assigned in the sourced config.bash.
#  shellcheck disable=2154  ## 'referenced but not assigned.' False hit on trap strings that assign the var they use (rc=$?).
#  shellcheck disable=2155  ## 'Declare and assign separately to avoid masking return values.' Cumbersome and unnecessary.
#  shellcheck disable=2317  ## 'Can't reach.' (I.e. an 'exit' is used for debugging - and makes an unusable visual mess.)

##	- Purpose: Local CI/CD pipeline. Generic engine, per-project settings live in config.bash.
##	- Stages (fail-fast, any error aborts before the next stage):
##	   0. remote sync (fast-forward from upstream before anything is built)
##	   1. format (in place locally; check-only under --ci)
##	   2. build (debug - what the tests run against)
##	   3. lint (project lint + shellcheck of the cicd scripts themselves)
##	   4. tests (conformance corpus + fuzz smoke + cross-binding differential check)
##	   5. profiler (flamegraph SVG + hot-spot report; non-gating artifact, local only)
##	   6. release + cross-compile + versioned artifacts + packages (.deb/.rpm/
##	      NSIS setup) + sha256sums (local only)
##	   7. dogfood (install the release builds to fixed local dirs; local only)
##	   8. demo gif for the README (local only; non-gating)
##	   9. backup + publish to git (local only)
##	- Syntax:
##	  cicd/cicd.bash [options]
##	  Options:
##	   --ci                correctness gate only: format check (no rewrite), build,
##	                       lint, tests, cross checks; non-interactive, no
##	                       cross-compiled release artifacts and no publish. This is
##	                       what the GitHub workflow runs - one definition of "passing".
##	   --quick             skip the slow stages: large-document gate, cross-compile,
##	                       profiler, demo gif; tests run at the shorter fuzz depth
##	                       when the config carries TEST_QUICK_CMD
##	   -q, --quiet         unattended (no prompt) and quiet: no preflight block,
##	                       and cargo, ruff and the gif renderer get their own
##	                       quiet flags. Stage headers, results and warnings
##	                       still print; tools with no quiet flag are unchanged
##	   -y, --yes           unattended (no prompt) but not quiet
##	   -m, --message MSG   publish hands-off with this commit message (no editor)
##	   --no-sync           skip the remote sync stage
##	   --no-fmt            skip the formatter stage
##	   --no-lint           skip the lint stage
##	   --no-cross          skip the cross-compile targets and the cross checks
##	                       (native release still builds)
##	   --no-package        skip building installer packages (.deb/.rpm/NSIS setup)
##	   --no-largedoc       skip the large-document gate in the tests stage
##	   --no-profile        skip the profiler stage
##	   --no-dogfood        skip installing the release builds locally
##	   --no-gif            skip the demo gif refresh
##	   --no-publish        skip the git backup + publish stage
##	   -h, --help          show this help
##	- If neither -q/-y nor -m is given, the run prompts once for a commit message
##	  (blank = git editor; Ctrl+C aborts the whole run), then finishes unattended.
##	- A run that passes the tests and the cross checks records the tree it
##	  tested (utility/green-tree.bash), and the pre-push hook lets a commit with
##	  that tree through without running the gate again. --quick, --no-fmt,
##	  --no-lint, --no-cross and a skipped tool each keep a run from recording.
##	- Reuse: copy the cicd/ directory into another project and edit config.bash.

##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

## GIT_DIR and friends, from a hook run in a linked worktree or from the caller,
## would point every gate's scratch repo at this one. The pre-push hook clears
## them too; this covers a direct run.
for gitVar in $(git rev-parse --local-env-vars 2>/dev/null || true); do unset "${gitVar}"; done

## Find the repo root and load project config.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"   ## the git repo root (cicd/..)

## The rustup-routed toolchain must win over any system rust, or the pin in
## rust-toolchain.toml is meaningless and target/ fills with mixed artifacts.
export PATH="${HOME}/.cargo/bin:${PATH}"

## Cap every stage at 50% of cores, since a workstation is usually running
## something else; config command arrays can consume CPU_CAP. A runner that runs
## only this sets CPU_CAP itself. Anything but a plain count is ignored, since
## the value goes into arithmetic.
_cores="$(nproc 2>/dev/null || echo 2)"
if [[ ! "${CPU_CAP:-}" =~ ^[1-9][0-9]*$ ]]; then
	CPU_CAP=$(( _cores / 2 ))
	if (( CPU_CAP < 1 )); then CPU_CAP=1; fi
fi
export CPU_CAP

## Per-stage extras: eval'd strings run after the stage's primary command, so a
## second binding (Go, C, ...) adds its fmt/build/lint/test commands in config
## without touching engine code. All default empty.
FMT_EXTRA=(); FMT_CHECK_EXTRA=(); BUILD_EXTRA=(); LINT_EXTRA=(); TEST_EXTRA=(); TEST_QUICK_CMD=()
PACKAGE_ENABLE=0   ## config opts in; installer packages built off the release artifacts
## -q: "-q" for the eval'd config strings to pass to tools that take one (ruff);
## cargo reads CARGO_TERM_QUIET from the environment instead. Empty otherwise.
QUIET_FLAG=""
fRunExtras(){ local c; for c in "$@"; do fEcho_Clean "extra: ${c}"; eval "${c}"; done; }

## shellcheck source=config.bash
source "${here}/config.bash"
source "${here}/utility/include/gfs-rotate.bash"   ## gfs_rotate() for log/artifact pruning
cd "${root}"
stamp="$(date +%Y%m%d-%H%M%S)"

## Parse options.
assume_yes=0; quiet=0; ci_mode=0; quick=0; cli_message=""; sync_enable=1; gate_partial=0
while (($#)); do case "$1" in
	--ci)                     ci_mode=1; assume_yes=1; shift ;;
	--quick)                  quick=1; shift ;;
	-q|--quiet)               quiet=1; assume_yes=1; QUIET_FLAG="-q"; export CARGO_TERM_QUIET=true; shift ;;
	-y|--yes)                 assume_yes=1; shift ;;
	--no-sync)                sync_enable=0; shift ;;
	--no-fmt)                 FMT_CMD=(); FMT_CHECK_CMD=(); FMT_EXTRA=(); FMT_CHECK_EXTRA=(); gate_partial=1; shift ;;
	--no-lint)                LINT_CMD=(); SHELLCHECK_TARGETS=(); LINT_EXTRA=(); gate_partial=1; shift ;;
	--no-cross)               CROSS_TARGETS=(); CROSS_CHECKS=(); gate_partial=1; shift ;;
	--no-package)             PACKAGE_ENABLE=0; shift ;;
	--no-largedoc)            LARGEDOC_MIB=0; shift ;;
	--no-profile)             PROFILE_ENABLE=0; shift ;;
	--no-dogfood)             DOGFOOD_FIXED_DESTS=(); shift ;;
	--no-gif)                 GIF_ENABLE=0; shift ;;
	--no-publish)             GIT_PUBLISH=(); shift ;;
	--message=*|--msg=*|-m=*) cli_message="${1#*=}"; shift ;;
	-m|--message|--msg)       cli_message="${2-}"; shift; (($#)) && shift ;;
	-h|--help)                sed -n '/^##	- Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##	\{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac; done

## --ci: correctness only, deterministic, side-effect free.
if ((ci_mode)); then
	## A gate that quietly skips what it cannot run is a gate that stops
	## checking when a runner loses a tool. The gates read this and fail on a
	## skip instead; locally a missing tool is still a skip, since a working
	## copy is not required to carry every one.
	export SHCL_GATE_STRICT=1
	sync_enable=0       ## the runner already checked out the exact commit under test
	FMT_CMD=()          ## check-only via FMT_CHECK_CMD; never rewrite in CI
	CROSS_TARGETS=()
	RELEASE_NATIVE_CMD=()
	PACKAGE_ENABLE=0
	PROFILE_ENABLE=0
	DOGFOOD_FIXED_DESTS=()   ## no local install from the read-only gate (and no stale-binary risk)
	GIF_ENABLE=0
	GIT_PUBLISH=()
else
	FMT_CHECK_CMD=()    ## locally the formatter rewrites in place instead
fi
if ((quick)); then
	LARGEDOC_MIB=0     ## minutes of parsing; the fast loop is for the small cases
	CROSS_TARGETS=()
	PACKAGE_ENABLE=0   ## artifact set is partial without cross targets
	PROFILE_ENABLE=0
	GIF_ENABLE=0
	((${#TEST_QUICK_CMD[@]})) && TEST_CMD=("${TEST_QUICK_CMD[@]}")
fi

## A run at least as thorough as the pre-push hook's records the tree it tested
## once the tests and the cross checks pass, and the hook lets a commit with
## that tree through. A gate that skips a missing tool locally notes it in
## SHCL_GATE_SKIPS. Under --ci the same skip is a failure, so a run with
## anything noted there records nothing.
record_green=1
if ((quick || gate_partial)); then record_green=0; fi
export SHCL_GATE_SKIPS="$(mktemp)"
trap 'rm -f "${SHCL_GATE_SKIPS}"' EXIT

## Publish commit message: -m wins, then config, then a default when unattended.
publish_msg=""
if   [[ -n "$cli_message" ]];              then publish_msg="$cli_message"
elif [[ -n "${PUBLISH_AUTO_MESSAGE:-}" ]]; then publish_msg="$PUBLISH_AUTO_MESSAGE"
elif ((assume_yes));                       then publish_msg="${APP_NAME} CI/CD ${stamp}"
fi

## Output helpers: fEcho / fEcho_Clean, blank-collapsing.
declare -i _wasLastEchoBlank=0
fEcho_ResetBlankCounter(){ _wasLastEchoBlank=0; }
fEcho_Clean(){ if [[ -n "${1:-}" ]]; then echo -e "$*"; _wasLastEchoBlank=0; elif [[ "${_wasLastEchoBlank}" == 0 ]] && echo; then _wasLastEchoBlank=1; fi; }
fEcho(){       if [[ -n "$*"     ]]; then fEcho_Clean "[ $* ]"; else fEcho_Clean ""; fi; }
fEcho_Force(){ fEcho_ResetBlankCounter; fEcho "$*"; }
_letterbox="••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••"
fSection(){ fEcho_Clean; fEcho_Clean "${_letterbox}"; fEcho "$*"; }
fDie(){ { fEcho_Force "FAILED: $*"; echo; } >&2; exit 1; }
trap 'rc=$?; printf "\n[ CICD ABORTED (exit %s) at line %s: %s ]\n\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit $rc' ERR

## Current version from the single canonical source.
## No `| head -1`: under pipefail an early-quitting reader kills the writer
## with SIGPIPE, so the quit belongs in sed.
fVersion(){ sed -n '/^version *= *"/{ s/^version *= *"\(.*\)".*/\1/p; q; }' "${root}/${VERSION_MANIFEST}"; }

## The build number a release binary prints after its version: minutes from
## 2000-01-01 UTC to a unix time, rounded, in lower-case Crockford base32.
fBuildNumber(){   ## fBuildNumber EPOCH_SECONDS
	local digits="0123456789abcdefghjkmnpqrstvwxyz" n out=""
	## An empty time, from a git that gave none, or anything else that is not
	## a count of seconds since 2000 would print a build that looks real. The
	## digits test also comes before any arithmetic reads the argument.
	if [[ ! "${1:-}" =~ ^[0-9]{1,15}$ ]] || ((10#$1 < 946684800)); then
		echo "fBuildNumber: not a time since 2000: '${1:-}'" >&2
		return 1
	fi
	n=$(( (10#$1 - 946684800 + 30) / 60 ))
	while :; do
		out="${digits:n % 32:1}${out}"
		n=$((n / 32))
		((n > 0)) || break
	done
	printf '%s\n' "${out}"
}

## (Re)write the sha256sums file over every artifact in the release dir except
## the sums file itself.
fWriteSums(){
	[[ -n "${art_dir:-}" && -d "${art_dir:-/nonexist}" ]] || return 0
	## The subshell must not end on an `&&` list: with no artifacts the test is
	## false, the subshell returns 1, and the ERR trap takes down the run over an
	## empty directory.
	( cd "${art_dir}"
	  files=(); for x in "${EXE_NAME}-${ver}-"*; do [[ "$x" == "$sums" || ! -f "$x" ]] && continue; files+=("$x"); done
	  if ((${#files[@]})); then sha256sum "${files[@]}" > "${sums}"; fi )
}

## True when a running process was started from this file. Linux answers
## through /proc; elsewhere nothing is known to be in use.
fInUse(){   ## fInUse PATH
	local path exe
	path="$(readlink -f -- "$1" 2>/dev/null)" || return 1
	for exe in /proc/[0-9]*/exe; do
		if [[ "$(readlink -- "${exe}" 2>/dev/null || true)" == "${path}" ]]; then return 0; fi
	done
	return 1
}
## First existing+writable dir from the list; empty output when there is none.
fFirstWritableDir(){ local d; for d in "$@"; do [[ -d "$d" && -w "$d" ]] && { echo "$d"; break; }; done; return 0; }

## Install to <dest_dir>/<name> through a temp file in the SAME dir plus a rename,
## so a copy launched by hand never sees a half-written file and a synced dest can't
## propagate a torn one.
fInstallAtomic(){
	local src="$1" dest_dir="$2" name="$3" tmp="$2/.$3.$$.tmp"
	if cp -f "$src" "$tmp" && chmod +x "$tmp" && mv -f "$tmp" "${dest_dir}/${name}"; then
		fEcho "OK: installed ${dest_dir}/${name}"
	else
		rm -f "$tmp"
		fEcho "WARNING: failed to install ${dest_dir}/${name}"
	fi
}

## Preflight: show the plan, then capture the commit message so the rest runs unattended.
if ((! quiet)); then
	fEcho_Clean
	fEcho_Clean "${APP_NAME} $( ((ci_mode)) && echo 'CI gate' || echo 'local CI/CD')"
	fEcho_Clean
	fEcho_Clean "Repo root ......: ${root}"
	fEcho_Clean "Remote sync ....: $( ((sync_enable)) && echo 'fast-forward when behind; abort when diverged' || echo '(skipped)')"
	fEcho_Clean "Format .........: $( ((ci_mode)) && echo "${FMT_CHECK_CMD[*]:-(none configured)}" || echo "${FMT_CMD[*]:-(skipped)}")$( ((${#FMT_EXTRA[@]} + ${#FMT_CHECK_EXTRA[@]})) && echo "  (+ extras)" )"
	fEcho_Clean "Build (debug) ..: ${BUILD_CMD[*]:-(none configured)}$( ((${#BUILD_EXTRA[@]})) && echo "  (+ ${#BUILD_EXTRA[@]} extra)" )"
	fEcho_Clean "Lint ...........: ${LINT_CMD[*]:-(none configured)}$( ((${#LINT_EXTRA[@]})) && echo "  (+ ${#LINT_EXTRA[@]} extra)" )  + shellcheck: ${#SHELLCHECK_TARGETS[@]} file(s)"
	fEcho_Clean "Tests ..........: ${TEST_CMD[*]:-(none configured)}$( ((${#TEST_EXTRA[@]})) && echo "  (+ ${#TEST_EXTRA[@]} extra)" )  + crosscheck: ${#BINDING_CLIS[@]} binding(s)$( ((LARGEDOC_MIB)) && echo "  + large doc: ${LARGEDOC_MIB} MiB" )"
	fEcho_Clean "Profiler .......: $( ((PROFILE_ENABLE)) && echo "${PROFILE_SECS}s run -> flamegraph SVG -> ${PROFILE_OUT_DIR}/" || echo '(skipped)')"
	if ((${#RELEASE_NATIVE_CMD[@]})); then
		fEcho_Clean "Release ........: native + ${#CROSS_TARGETS[@]} cross target(s) -> ${RELEASE_ARTIFACT_DIR}/"
	else
		fEcho_Clean "Release ........: (skipped)"
	fi
	fEcho_Clean "Cross checks ...: $( ((${#CROSS_CHECKS[@]})) && echo "${#CROSS_CHECKS[@]} (no artifact; run whether or not a release is built)" || echo '(skipped)')"
	fEcho_Clean "Packages .......: $( ((PACKAGE_ENABLE)) && echo '.deb/.rpm + NSIS setup (per built binary)' || echo '(skipped)')"
	fEcho_Clean "Dogfood ........: $( if ((${#DOGFOOD_FIXED_DESTS[@]})); then _dfd="$(fFirstWritableDir "${DOGFOOD_FIXED_DESTS[@]}")"; [[ -n "$_dfd" ]] && echo "${_dfd}/${EXE_NAME}" || echo '(no writable dest; will skip)'; else echo '(skipped)'; fi )"
	fEcho_Clean "Demo gif .......: $( ((GIF_ENABLE)) && echo "${GIF_OUT}" || echo '(skipped)')"
	if ((${#GIT_PUBLISH[@]})); then
		fEcho_Clean "Publish (last) .: ${GIT_PUBLISH[*]}$( [[ -n "$publish_msg" ]] && echo " (hands-off: \"${publish_msg}\")" || echo ' (will prompt for message; blank = editor)')"
	else
		fEcho_Clean "Publish (last) .: (skipped)"
	fi
	fEcho_Clean
	fEcho_Clean "Fail-fast: any error aborts before the next stage."
	fEcho_Clean
fi
if ((! assume_yes)) && ((${#GIT_PUBLISH[@]})) && [[ -z "$publish_msg" ]]; then
	read -r -p "Publish commit message (blank = editor; Ctrl+C aborts): " m
	fEcho_ResetBlankCounter
	[[ -n "$m" ]] && publish_msg="$m"
fi

## Tee the whole run to a rotated log so warnings can be reviewed later
## (lint-report.bash reads the newest one). Skipped under --ci (read-only gate).
if ((! ci_mode)) && [[ -n "${LINT_LOG_DIR:-}" ]] && mkdir -p "${root}/${LINT_LOG_DIR}" 2>/dev/null; then
	gfs_rotate "${root}/${LINT_LOG_DIR}" run log >/dev/null 2>&1 || true
	exec > >(tee "${root}/${LINT_LOG_DIR}/run_${stamp}.log") 2>&1
fi

## Warn (non-gating) when a pinned helper tool has drifted from TOOL_PINS, so a
## box update can't silently change results. Format: "name|version|command...".
if declare -p TOOL_PINS &>/dev/null; then
	for pin in "${TOOL_PINS[@]}"; do
		pin_name="${pin%%|*}"; rest="${pin#*|}"; pin_ver="${rest%%|*}"; pin_cmd="${rest#*|}"
		## Scan the first few lines, not just one: some tools (shellcheck) lead
		## with a banner and put the version underneath.
		## Through bash -c: an unquoted expansion hands a quoted argument over with
		## its quotes as literal text, so pwsh echoed its own expression back and
		## the PSScriptAnalyzer pin reported drift on every run.
		have="$(bash -c "${pin_cmd}" 2>/dev/null | head -5 | tr '\n' ' ' || true)"
		if [[ -z "$have" ]]; then
			fEcho "WARNING: pinned tool missing: ${pin_name} (want ${pin_ver}); its stage will skip or fail"
		elif [[ "$have" != *"${pin_ver}"* ]]; then
			fEcho "WARNING: ${pin_name} drifted from pin ${pin_ver}: ${have}"
		fi
	done
fi

## Stage 0: take the remote's work before anything is built, so the pipeline
## validates the tree that will be pushed. The publish stage pulls too, but that
## happens after the tests - a change merged upstream meanwhile would go out
## having never been built here.
if ((sync_enable)); then
	fSection "0/9  Remote sync"
	branch="$(git -C "${root}" symbolic-ref --quiet --short HEAD || true)"
	upstream="$(git -C "${root}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
	if [[ -z "$branch" ]]; then
		fEcho "WARNING: detached HEAD; nothing to sync"
	elif [[ -z "$upstream" ]]; then
		fEcho "WARNING: ${branch} tracks no upstream; nothing to sync"
	elif ! git -C "${root}" fetch --quiet 2>/dev/null; then
		fEcho "WARNING: fetch failed (offline?); continuing against the local tree"
	else
		## Counts either side of the merge base, so "diverged" is distinguishable
		## from "behind" - only the latter can fast-forward.
		read -r ahead behind < <(git -C "${root}" rev-list --left-right --count "HEAD...${upstream}")
		if   ((ahead && behind)); then fDie "${branch} and ${upstream} have diverged (${ahead} local, ${behind} remote); reconcile by hand"
		elif ((behind)); then
			## Stash-wrapped: the working tree is routinely dirty here, and a
			## fast-forward can refuse rather than touch a modified file.
			dirty=0; git -C "${root}" diff --quiet && git -C "${root}" diff --cached --quiet || dirty=1
			((dirty)) && git -C "${root}" stash push --quiet --include-untracked --message "cicd sync ${stamp}"
			ff=0; git -C "${root}" merge --ff-only --quiet "${upstream}" && ff=1
			## A pop that conflicts writes conflict markers into the tree, so it
			## has to stop the run - building those bytes proves nothing. Git
			## keeps the entry on a failed pop, so the work is still recoverable.
			if ((dirty)) && ! git -C "${root}" stash pop --quiet; then
				fDie "the local changes conflict with ${upstream}; they are safe in the stash - resolve, then 'git stash drop'"
			fi
			((ff)) || fDie "fast-forward from ${upstream} failed"
			fEcho "OK: fast-forwarded ${behind} commit(s) from ${upstream}"
		elif ((ahead)); then fEcho "OK: ${ahead} commit(s) ahead of ${upstream}, nothing to take"
		else                 fEcho "OK: level with ${upstream}"
		fi
	fi
fi

## Stage 1: format. In place locally; check-only (fail on diff) under --ci.
fSection "1/9  Format"
if ((ci_mode)); then
	if ((${#FMT_CHECK_CMD[@]})); then
		"${FMT_CHECK_CMD[@]}"
		fRunExtras "${FMT_CHECK_EXTRA[@]}"
		fEcho "OK: format clean"
	else fEcho_Clean "no format check configured"; fi
elif ((${#FMT_CMD[@]})); then
	"${FMT_CMD[@]}"
	fRunExtras "${FMT_EXTRA[@]}"
	fEcho "OK: formatted"
else
	fEcho_Clean "format skipped"
fi
## Taken after the formatter, since locally it rewrites what gets tested.
green_tree=""
if ((record_green)); then green_tree="$("${here}/utility/green-tree.bash" tree "${root}" || true)"; fi

## Stage 2: debug build (fast compile sanity; the tests run against this).
fSection "2/9  Build (debug)"
if ((${#BUILD_CMD[@]})); then
	"${BUILD_CMD[@]}"
	fRunExtras "${BUILD_EXTRA[@]}"
	fEcho "OK: build"
else
	fEcho_Clean "nothing to build yet"
fi

## Stage 3: lint. Project lint first, then shellcheck over the cicd scripts (and
## any other bash config lists), so the pipeline can't rot silently. shellcheck
## is optional locally (warn if missing) but present on GitHub runners.
fSection "3/9  Lint"
if ((${#LINT_CMD[@]})); then
	"${LINT_CMD[@]}"
	fRunExtras "${LINT_EXTRA[@]}"
	fEcho "OK: lint clean"
else
	fEcho_Clean "no project lint configured yet"
fi
if ((${#SHELLCHECK_TARGETS[@]})); then
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck "${SHELLCHECK_TARGETS[@]}"
		fEcho "OK: shellcheck clean (${#SHELLCHECK_TARGETS[@]} file(s))"
	elif ((ci_mode)); then
		fDie "shellcheck required under --ci but not found"
	else
		fEcho "WARNING: shellcheck not installed; skipped"
		echo shellcheck >> "${SHCL_GATE_SKIPS}"
	fi
fi

## Stage 4: tests (conformance corpus + fuzz smoke + anything else config wires in),
## then the cross-binding differential check: every binding CLI must agree with
## every other, byte for byte, on the corpus AND on a freshly fuzz-dumped input set.
## With one binding it is a no-op note; it gets teeth the day a second binding arrives.
## Last comes the large-document gate - the same agreement plus time and memory
## ceilings, at a size no corpus case can reach.
fSection "4/9  Tests"
if ((${#TEST_CMD[@]})); then
	"${TEST_CMD[@]}"
	fRunExtras "${TEST_EXTRA[@]}"
	fEcho "OK: tests passed"
else
	fEcho_Clean "no tests configured yet"
fi
if ((${#BINDING_CLIS[@]})); then
	xcheck_extra=()
	if ((${#BINDING_CLIS[@]} >= 2)) && [[ -n "${XCHECK_GEN:-}" ]]; then
		export XCHECK_DUMP_DIR="${root}/cicd/artifacts/crosscheck"
		rm -rf "${XCHECK_DUMP_DIR}"; mkdir -p "${XCHECK_DUMP_DIR}"
		eval "${XCHECK_GEN}"
		xcheck_extra=(--extra "${XCHECK_DUMP_DIR}")
	fi
	"${here}/utility/crosscheck.bash" --corpus "${root}/project/conformance" "${xcheck_extra[@]}" "${BINDING_CLIS[@]}"
	if ((LARGEDOC_MIB)); then
		"${here}/utility/largedoc.bash" --mib "${LARGEDOC_MIB}" "${BINDING_CLIS[@]}"
	fi
fi
## Stage 5: profiler. Non-gating artifact, not a pass/fail test: an optimized
## build with symbols runs a heavy workload under an in-process sampler (kernel
## perf is locked down on this box) and writes a flamegraph SVG, gfs-rotated like
## the run logs; flame-report.py prints the hot spots into the log. Environmental
## problems skip with a warning; a build or run failure is the app's fault -> die.
fSection "5/9  Profiler"
if ((PROFILE_ENABLE)); then
	fEcho_Clean "building: ${PROFILE_BUILD_CMD[*]}"
	"${PROFILE_BUILD_CMD[@]}" || fDie "profiler build failed (app problem)"
	[[ -f "${PROFILE_BIN}" ]] || fDie "profiler binary missing: ${PROFILE_BIN}"
	## The sampler's attribution against a workload of known shape (config
	## PROFILE_CHECK), before any graph is drawn: a graph that names the wrong
	## code is worse than none.
	if [[ -n "${PROFILE_CHECK:-}" ]]; then
		eval "${PROFILE_CHECK}" || fDie "profiler attribution check failed; its graph would name the wrong code"
	fi
	profile_dir="${root}/${PROFILE_OUT_DIR}"
	mkdir -p "${profile_dir}"
	export PROFILE_WORKLOAD="${profile_dir}/workload.shcl"
	eval "${PROFILE_WORKLOAD_GEN}"
	[[ -s "${PROFILE_WORKLOAD}" ]] || fDie "profiler workload came out empty: ${PROFILE_WORKLOAD}"
	## Born canonical (role "frequent"); the rotation retags the newest as "latest".
	export PROFILE_OUT="${profile_dir}/flame_${stamp}_frequent.svg"
	fEcho_Clean "sampling ${PROFILE_SECS}s: ${PROFILE_RUN}"
	eval "${PROFILE_RUN}" || fDie "profiler run failed (non-zero exit - app problem)"
	[[ -s "${PROFILE_OUT}" ]] || fDie "profiler produced no SVG (app problem): ${PROFILE_OUT}"
	gfs_rotate "${profile_dir}" flame svg
	latest="${profile_dir}/flame_${stamp}_latest.svg"
	[[ -e "$latest" ]] || latest="${PROFILE_OUT}"
	fEcho "OK: flamegraph: ${latest}"
	## Wall-clock per surface (config PROFILE_TIMED): one line each into the log.
	if declare -p PROFILE_TIMED &>/dev/null; then
		for wl in "${PROFILE_TIMED[@]}"; do
			wl_name="${wl%%|*}"; wl_cmd="${wl#*|}"
			t0="$(date +%s.%N)"
			if eval "${wl_cmd}"; then
				t1="$(date +%s.%N)"
				fEcho_Clean "profile timing: ${wl_name} $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2fs", b - a}')"
			else
				fEcho_Clean "profile timing: ${wl_name} FAILED"
			fi
		done
	fi
	fEcho_Clean "open: ${latest}  (in a browser)"
	## Hot-spot summary into the log (non-fatal, no marker - the marker belongs to
	## the per-session --check gate, not the pipeline).
	if command -v python3 >/dev/null 2>&1; then
		fEcho_Clean ""
		## stderr kept: the report's only diagnostics go there, and discarding
		## them left the log saying "unavailable" with no cause - a missing
		## directory, no flamegraphs and an unparseable file all read alike.
		## The exit code is already non-fatal, so keeping it costs nothing.
		python3 "${here}/utility/flame-report.py" --dir "${profile_dir}" || fEcho_Clean "hot spots: (report unavailable - see the reason above)"
	else
		fEcho "WARNING: python3 not found; hot-spot report skipped"
	fi
else
	fEcho_Clean "profiler skipped"
	## The calibration alone, on the config's cheaper build, since the graph's
	## attribution is otherwise unchecked under --ci. It runs offline, and a
	## cache without the sampler's crates is a noted skip rather than a fetch.
	if ((ci_mode)) && [[ -n "${PROFILE_CHECK:-}" ]] && declare -p PROFILE_CHECK_BUILD_CMD &>/dev/null && ((${#PROFILE_CHECK_BUILD_CMD[@]})); then
		if "${PROFILE_CHECK_PROBE_CMD[@]}" >/dev/null 2>&1; then
			fEcho_Clean "building: ${PROFILE_CHECK_BUILD_CMD[*]}"
			"${PROFILE_CHECK_BUILD_CMD[@]}" || fDie "profiler check build failed (app problem)"
			( PROFILE_BIN="${PROFILE_CHECK_BIN}"; eval "${PROFILE_CHECK}" ) \
				|| fDie "profiler attribution check failed; its graph would name the wrong code"
		else
			fEcho_Clean "profiler attribution check skipped: the sampler's crates are not in the local cache"
			echo profiler-check >> "${SHCL_GATE_SKIPS}"
		fi
	fi
fi

## Stage 6: native release + cross targets, collected under versioned names plus
## a sha256 checksums file, ready to attach to a release as plain uploads.
## Naming (stable; download links depend on it): <exe>-<version>-<os-arch>[.exe]
fSection "6/9  Release builds"
built_arts=()   ## <os-arch>|<path> per built binary; stage 7 dogfoods off it too
## Cross-compile checks that produce no artifact: the other bindings' own
## platform branches. Without these the C header's Windows path is never
## compiled here at all, which is exactly how a build-breaking regression in it
## reached dev unnoticed. They are checks, not builds, so they run whenever
## correctness is gated - they sat inside the release branch below for a month,
## which meant --ci, the one run that decides whether a commit reaches main,
## compiled none of them.
for c in "${CROSS_CHECKS[@]}"; do
	c_label="${c%%|*}"; c_cmd="${c#*|}"
	fEcho "cross check: ${c_label}"
	eval "${c_cmd}" || fDie "cross check failed: ${c_label}"
	fEcho "OK: ${c_label}"
done
## The record waits for the cross checks, the last gate a --ci run has. It sat at
## the end of stage 4 once they moved under --ci, so a run that then failed one
## had already let its tree through the hook.
if [[ -n "${green_tree}" ]]; then
	if [[ -s "${SHCL_GATE_SKIPS}" ]]; then
		fEcho_Clean "tree not recorded for the pre-push hook, since this run skipped: $(sort -u "${SHCL_GATE_SKIPS}" | paste -sd ' ')"
	elif "${here}/utility/green-tree.bash" record "${root}" "${green_tree}"; then
		fEcho "OK: tree ${green_tree:0:12} recorded; a push of it skips the pre-push gate"
	fi
fi
if ((${#RELEASE_NATIVE_CMD[@]})); then
	## Stamped from the commit, not the clock, so a rebuild of one commit gives
	## the same bytes. Only these builds carry it: the gate's own builds stay
	## unstamped, the same as the other three CLIs they are compared against.
	SHCL_BUILD="$(fBuildNumber "$(git -C "${root}" log -1 --format=%ct)")" || fDie "no build number from the commit time"
	export SHCL_BUILD
	fEcho "build ${SHCL_BUILD}"
	"${RELEASE_NATIVE_CMD[@]}"
	[[ -f "${RELEASE_NATIVE_BIN}" ]] || fDie "native release binary missing: ${RELEASE_NATIVE_BIN}"
	fEcho "OK: native release: ${RELEASE_NATIVE_BIN} ($(du -h "${RELEASE_NATIVE_BIN}" | cut -f1))"
	built_arts=("${RELEASE_NATIVE_OSARCH:-native}|${RELEASE_NATIVE_BIN}")
	for t in "${CROSS_TARGETS[@]}"; do
		t_label="${t%%|*}"; rest="${t#*|}"; t_osarch="${rest%%|*}"; rest="${rest#*|}"; t_art="${rest%%|*}"; t_cmd="${rest#*|}"
		fEcho "cross: ${t_label}"
		eval "${t_cmd}"
		[[ -f "${t_art}" ]] || fDie "missing artifact for ${t_label}: ${t_art}"
		fEcho "OK: ${t_label}: ${t_art} ($(du -h "${t_art}" | cut -f1))"
		built_arts+=("${t_osarch}|${t_art}")
	done
	unset SHCL_BUILD
	if [[ -n "${RELEASE_ARTIFACT_DIR:-}" ]]; then
		ver="$(fVersion)"
		[[ -n "$ver" ]] || fDie "no version found in ${VERSION_MANIFEST}"
		art_dir="${root}/${RELEASE_ARTIFACT_DIR}"
		rm -rf "${art_dir}"; mkdir -p "${art_dir}"
		sums="${EXE_NAME}-${ver}-sha256sums.txt"
		for pair in "${built_arts[@]}"; do
			p_osarch="${pair%%|*}"; p_src="${pair#*|}"
			p_ext=""; [[ "$p_src" == *.exe ]] && p_ext=".exe"
			cp -f "${p_src}" "${art_dir}/${EXE_NAME}-${ver}-${p_osarch}${p_ext}"
		done
		## Packages and the tarball below record mtimes, uid/gid and build dates;
		## pinning those to the commit's time is what lets two builds of one
		## commit, on any box, give the same bytes (the sums file signs them).
		export SOURCE_DATE_EPOCH="$(git -C "${root}" log -1 --format=%ct)"
		## Installer packages (.deb/.rpm via nfpm, NSIS setup per Windows exe) join
		## the artifact family before the sums are written, so they ship verified too.
		((PACKAGE_ENABLE)) && "${here}/utility/package.bash" "${root}" "${art_dir}" "${ver}"
		## The drop-in sources, wrappers, man page and completions the installer
		## lays down, as one asset in the same family - so they are covered by the
		## signed sums like everything else. The installer used to take them from
		## GitHub's generated source tarball, which carries no signature and no
		## checksum. The modes are set outright: a checkout under umask 077 has no
		## group or other bits, and only the execute bit comes from git.
		( cd "${root}" && tar --sort=name --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
			--mtime="@${SOURCE_DATE_EPOCH}" -cf - \
			source/rust/src/lib.rs source/go/shcl.go source/python/shcl.py \
			source/c/shcl.h source/c/shcl.hpp \
			source/bash/shcl.bash source/powershell/shcl.ps1 \
			source/man/shcl.1 source/completions/shcl.bash source/completions/_shcl \
			| gzip -n -9 > "${art_dir}/${EXE_NAME}-${ver}-dropins.tar.gz" )
		fWriteSums
		fEcho "OK: ${#built_arts[@]} release artifact(s) + ${sums} -> ${RELEASE_ARTIFACT_DIR}/"
		((${#CROSS_TARGETS[@]})) || fEcho_Clean "note: cross targets skipped - artifact set is partial (native only)"
	fi
else
	fEcho_Clean "release builds skipped"
fi

## Stage 7: dogfood - drop the freshly built optimized native binary into the first
## existing+writable fixed dest, under EXE_NAME, so the copy launched by hand stays
## current. The bash wrapper rides along as <EXE_NAME>.bash once it exists, and each
## cross-built binary goes to its own per-os-arch dest where one is configured.
## Skipped when no release binary was built (e.g. --ci) or the dest list is empty.
## No sudo: a non-writable dest is passed over with a warning, never force-installed.
fSection "7/9  Dogfood"
if ((${#DOGFOOD_FIXED_DESTS[@]})) && [[ -f "${RELEASE_NATIVE_BIN:-/nonexist}" ]]; then
	dogfood_dest="$(fFirstWritableDir "${DOGFOOD_FIXED_DESTS[@]}")"
	if [[ -n "$dogfood_dest" ]] && fInUse "${dogfood_dest}/${EXE_NAME}"; then
		fEcho "WARNING: ${dogfood_dest}/${EXE_NAME} is running; dogfood copy skipped"
	elif [[ -n "$dogfood_dest" ]]; then
		fInstallAtomic "${RELEASE_NATIVE_BIN}" "$dogfood_dest" "${EXE_NAME}"
		for wrapper in "${DOGFOOD_WRAPPERS[@]:-}"; do
			[[ -n "$wrapper" && -f "$wrapper" ]] || continue
			ext="${wrapper##*.}"                                       ## .bash / .ps1 -> dest name + dest-list key
			declare -n wrapper_dests="DOGFOOD_WRAPPER_DESTS_${ext}"
			wrapper_dest="$(fFirstWritableDir "${wrapper_dests[@]:-}")"
			unset -n wrapper_dests
			[[ -z "$wrapper_dest" ]] && wrapper_dest="$dogfood_dest"   ## fall back beside the binary
			fInstallAtomic "$wrapper" "$wrapper_dest" "${EXE_NAME}.${ext}"
		done
	else
		fEcho "WARNING: no dogfood dest exists+writable (${DOGFOOD_FIXED_DESTS[*]}); skipping"
	fi
	## The cross builds, each to the dest list named for its os-arch. An os-arch with
	## no list configured is silently not installed - that is the normal case.
	for pair in "${built_arts[@]:1}"; do
		x_osarch="${pair%%|*}"; x_src="${pair#*|}"
		x_key="DOGFOOD_CROSS_DESTS_${x_osarch//-/_}"
		declare -p "$x_key" &>/dev/null || continue
		declare -n x_dests="$x_key"
		x_dest="$(fFirstWritableDir "${x_dests[@]:-}")"
		unset -n x_dests
		[[ -n "$x_dest" ]] || { fEcho "WARNING: no ${x_osarch} dogfood dest exists+writable; skipping"; continue; }
		x_ext=""; [[ "$x_src" == *.exe ]] && x_ext=".exe"
		fInstallAtomic "$x_src" "$x_dest" "${EXE_NAME}${x_ext}"
	done
	## The runner and its launchers, only where they changed, so an ordinary run
	## does not touch the sync tree.
	for runner in "${DOGFOOD_RUNNERS[@]:-}"; do
		[[ -n "$runner" ]] || continue
		IFS='|' read -r -a r_parts <<<"$runner"
		r_src="${root}/${r_parts[0]}"
		[[ -f "$r_src" ]] || { fEcho "WARNING: no dogfood runner at ${r_parts[0]}"; continue; }
		for r_dir in "${r_parts[@]:1}"; do
			[[ -d "$r_dir" && -w "$r_dir" ]] || continue
			cmp -s "$r_src" "${r_dir}/${r_src##*/}" && continue
			fInstallAtomic "$r_src" "$r_dir" "${r_src##*/}"
		done
	done
else
	fEcho_Clean "dogfood skipped"
fi

## Stage 8: demo gif for the README (non-gating: a missing Pillow/font/etc. skips).
## Renders into the rotated private/ store (gfs-kept), then copies the newest onto
## the committed GIF_OUT. If that store is unreachable (no private tree), render
## straight to GIF_OUT and skip rotation.
fSection "8/9  Demo gif"
if ((GIF_ENABLE)); then
	gif_dir="${root}/${GIF_ROTATE_DIR}"
	if mkdir -p "${gif_dir}" 2>/dev/null; then
		## Born canonical (role "frequent"); the rotation retags the newest "latest".
		gif_target="${gif_dir}/demo_${stamp}_frequent.gif"
	else
		fEcho_Clean "gif store unavailable (${GIF_ROTATE_DIR}); rendering committed copy only"
		gif_dir=""; gif_target="${root}/${GIF_OUT}"
	fi
	if "${here}/utility/gen-demo-gif.py" --scenario "${root}/${GIF_SCENARIO}" --out "${gif_target}" --bin "${root}/${RELEASE_NATIVE_BIN}" ${QUIET_FLAG:+--quiet}; then
		if [[ -n "${gif_dir}" ]]; then
			gfs_rotate "${gif_dir}" demo gif
			## Rotation renames the just-rendered file by role (first run -> "first",
			## later -> "latest"); the stamp is unique to this run, so glob it back
			## whatever the suffix, and copy that onto the committed GIF_OUT.
			gif_kept=( "${gif_dir}/demo_${stamp}_"*.gif )
			cp -f "${gif_kept[0]}" "${root}/${GIF_OUT}"
		fi
		fEcho "OK: demo gif -> ${GIF_OUT} ($(du -h "${root}/${GIF_OUT}" | cut -f1))"
	else
		fEcho "WARNING: demo gif skipped (non-fatal)"
	fi
else
	fEcho_Clean "demo gif skipped"
fi

## Stage 9: backup + publish via the standalone publisher.
fSection "9/9  Backup + publish"
if ((${#GIT_PUBLISH[@]})); then
	command -v rar >/dev/null 2>&1 || export GIT_BACKUP_AND_PUBLISH_NOBACKUP=1
	## The publisher's continue-prompt is skipped either way (this run already
	## confirmed); --quiet also quiets its output and makes up a commit message
	## when none is given, so it is passed only when this run is itself quiet.
	## An empty publish_msg can only be an interactive run that left the message
	## blank, and then `git commit` opens the editor as documented.
	publish_flag="--no-prompt"; ((quiet)) && publish_flag="--quiet"
	if [[ -n "$publish_msg" ]]; then
		## Hands-off: the GIT_EDITOR helper fills the message so `git commit` won't
		## open an editor.
		GIT_AUTO_MESSAGE="${publish_msg}" GIT_EDITOR="${here}/utility/git-auto-msg.bash" \
			"${GIT_PUBLISH[@]}" "${publish_flag}"
	else
		"${GIT_PUBLISH[@]}" "${publish_flag}"
	fi
	fEcho "OK: published"
	## An installer fix reaches nobody until it is on main: the README's
	## one-liners fetch the scripts from there as they run, so a fix that stays
	## on dev is the one drift every user meets. Judged after the publish so a
	## dev run that carries one goes red until the docs-only merge to main.
	if [[ "$(git branch --show-current)" == dev ]] && git rev-parse -q --verify origin/main >/dev/null 2>&1; then
		installer_drift="$(git diff --stat origin/main -- install.bash install.ps1 install-dev.bash || true)"
		[[ -z "${installer_drift}" ]] || fDie "the installers differ from origin/main; merge them to main under the docs-only rule:"$'\n'"${installer_drift}"
	fi
else
	fEcho_Clean "publish skipped"
fi

fSection "${APP_NAME} CI/CD: done."
fEcho_Clean


##	History:
##		- 2026-07-11 JC: Created from the sister-project engine, trimmed to what shcl needs pre-code; added --ci gate mode shared with the GitHub workflow.
##		- 2026-07-12 JC: Filled out for the reference parser: debug+release split, cross targets + versioned artifacts + sha256sums, run-log tee with gfs rotation, tool-pin drift warnings, demo gif stage, dev version guard, publish via n8git_backup-and-publish.
##		- 2026-07-12 JC: Dropped the dev version guard; added the profiler stage (flamegraph + flame-report) and the cross-binding crosscheck after tests.
##		- 2026-07-12 JC: Per-stage extras (FMT/BUILD/LINT/TEST_EXTRA eval lists) so additional bindings wire in via config only; first consumer is the Go binding.
##		- 2026-07-13 JC: Dogfood stage (7/9) between release and demo gif: installs the native release binary + bash wrapper (when present) to a fixed local dir; --no-dogfood, off under --ci.
##		- 2026-07-22 JC: Installer packages in stage 6 (utility/package.bash: nfpm .deb/.rpm + NSIS setup), before the sums write; --no-package, off under --ci/--quick.
##		- 2026-08-19 JC: Stage 0 remote sync ahead of the format stage: fast-forwards when only behind (stash-wrapped), stops on a diverged branch, warns and continues when offline or untracked; --no-sync, off under --ci.
##		- 2026-08-26 JC: Dogfood extended to the cross builds via per-os-arch dest lists; the atomic install and dest pick are helpers now.
##		- 2026-09-14 JC: A run that passes the tests stage records its tree for the pre-push hook; local tool skips are noted in SHCL_GATE_SKIPS and hold it back.
##		- 2026-09-19 JC: Clears git's local environment first, so GIT_DIR from a hook run in a linked worktree cannot reach the gates' scratch repos.
##		- 2026-09-21 JC: CPU_CAP set by the caller wins, so a runner with nothing else on it can use every core.
##		- 2026-09-22 JC: The profiler stage runs the config's attribution check before it draws a graph.
##		- 2026-09-23 JC: The record waits for the cross checks, and --no-cross holds it back.
##		- 2026-09-26 JC: --ci runs the profiler's attribution check alone, on the config's cheaper build.
