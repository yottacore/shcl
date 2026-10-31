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
##	   1. format (in place locally; check-only in the run modes below)
##	   2. build (debug - what the tests run against)
##	   3. lint (project lint + shellcheck of the cicd scripts themselves)
##	   4. tests (conformance corpus + fuzz smoke + cross-binding differential check)
##	   5. profiler (flamegraph SVG + hot-spot report; non-gating artifact, local only)
##	   6. release + cross-compile + checks over the release binaries + versioned
##	      artifacts + packages (.deb/.rpm/NSIS setup) + sha256sums (local only)
##	   7. dogfood (install the release builds to fixed local dirs; local only)
##	   8. demo gif for the README (local only; non-gating)
##	   9. backup + publish to git (local only)
##	- Syntax:
##	  cicd/cicd.bash [options]
##	  Options:
##	   With no options a run does every stage and check but the ones taking hours.
##	   --merge-gate, --ci  every check of a run with no flags, strict and hands-off,
##	                       with no format rewrite, sync, dogfood, gif or publish.
##	                       The pre-push hook runs it on a push to main
##	   --backlog-run-full  the same, for the end of a backlog round
##	   --backlog-run-quick, --gate [AREA...]  AREAs: rust go python c cli cicd
##	                       format check, build, lint, tests and cross checks,
##	                       strict, less --quick's cuts, in about 4 minutes,
##	                       recording nothing. AREAs keep only their tests
##	   --quick             the fast loop: leaves out the slow steps, and the ones
##	                       that need another host, that config.bash lists in
##	                       QUICK_SKIP, plus the large-document gate, the slow
##	                       leak checks, packages, profiler and demo gif. Tests
##	                       run at the shorter fuzz depth when the config has
##	                       TEST_QUICK_CMD
##	   --long, --slow      also the leak checks that take hours, and the suites a
##	                       REMOTE_BOXES row names with suites-long. Not with
##	                       --quick
##	   --leakcheck         every leak check config.bash lists, at the end of the
##	                       tests stage, the ones that take hours included
##	   --no-leakcheck      no leak check or sanitizer run. Not with --leakcheck
##	   -q, --quiet         unattended and quiet: no preflight block, and cargo,
##	                       ruff and the gif renderer get their quiet flags
##	   -y, --yes           unattended (no prompt) but not quiet
##	   -m, --message MSG   publish hands-off with this commit message (no editor)
##	   --no-sync           skip the remote sync stage
##	   --no-fmt            skip the formatter stage
##	   --no-lint           skip the lint stage
##	   --no-tests          skip the tests stage (crosscheck and large document
##	                       included) and the gates' profiler calibration
##	   --no-cross          skip the cross targets and checks; native release builds
##	   --no-package        skip building installer packages (.deb/.rpm/NSIS setup)
##	   --no-largedoc       skip the large-document gate in the tests stage
##	   --no-profile        skip the profiler stage
##	   --no-release        skip the release builds, and the packages, dogfood and
##	                       demo gif made from them; cross checks still run
##	   --no-dogfood        skip installing the release builds locally
##	   --no-gif            skip the demo gif refresh
##	   --no-publish        skip the git backup + publish stage
##	   --no-remote         skip the test boxes config.bash lists in REMOTE_BOXES,
##	                       and the GitHub job HOSTED_JOB
##	   --skip TEXT         leave out each step whose command holds TEXT; record nothing
##	   --keep-temp         keep the run's temp folder and containers, and say where
##	   --container[=NAME]  run stages 1-6 in the pinned image from cicd/container/,
##	                       or NAME.Dockerfile there for an extra one, and fail
##	                       when docker can't. See below
##	   --no-container      run stages 1-6 on this box even when docker answers.
##	                       Not with --container
##	   --no-freeze         run stages 2-6 in the checkout, not in a copy. See below
##	   --list              print the steps and test IDs the flags pick; run nothing
##	   -h, --help          show this help
##	- If neither -q/-y nor -m is given, the run prompts once for a commit message
##	  (blank = git editor; Ctrl+C aborts the whole run), then finishes unattended.
##	- A run that passes the tests and the cross checks records the tree it
##	  tested (utility/green-tree.bash), which the pre-push hook then lets through
##	  without the gate. --quick, --no-fmt, --no-lint, --no-tests, --no-cross and
##	  a skipped tool keep a run from recording.
##	- A run with no flags, --long, --merge-gate and --backlog-run-full start the
##	  GitHub job config.bash names in HOSTED_JOB first, for this branch as
##	  pushed, and wait for it last. The macos job takes about 3 minutes. It runs
##	  the commit, not uncommitted edits, and it's a SKIP, with the reason, when
##	  the remote's branch isn't at HEAD or there's no gh. --quick,
##	  --backlog-run-quick, --no-remote and a run that doesn't build
##	  HOSTED_TARGET leave it out. SHCL_GH names a gh to call in place of gitsby's.
##	- Each run works in a temp dir of its own, removed at the end even when it
##	  fails or is stopped. A whole run also sweeps the pipeline's stale leftovers.
##	- When docker (or SHCL_DOCKER) answers on x86_64, stages 1-6 run in the main
##	  image as if --container were given, the pre-push hook's gate included.
##	  Otherwise they run here, with a one-line note saying why. Sync, dogfood,
##	  gif and publish stay on this box. An extra image runs what CTR_ARGS_NAME in
##	  config.bash picks, and nothing runs here after it. The repo is mounted at
##	  its own path, so a run records its tree like any other.
##	- Stages 2-6 run from a copy of the tree taken after formatting, uncommitted
##	  work included, so a merge, checkout or edit during a run can't reach them.
##	  FROZEN_LINKS in config.bash share build dirs. --no-freeze runs in place.
##	- Reuse: copy the cicd/ directory into another project and edit config.bash.

##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

## The whole run is one compound command, which bash reads to its end before any
## of it runs. Otherwise an edit to this file during a run of hours is read at
## the old offset, and the run goes on into the new text (2026102108300000).
{

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

## Low priority for the whole run, since the box is usually running something
## else. Set on this shell, so every child takes it, inside the image too.
renice -n 19 -p $$ > /dev/null 2>&1 || true
if command -v ionice > /dev/null 2>&1; then ionice -c 3 -p $$ > /dev/null 2>&1 || true; fi

## Half the cores, or a quarter when the box is busy or the step is hard, checked
## here and before each step (fCpuStep). A runner that runs only this sets
## CPU_CAP itself, which then holds for every step; anything but a plain count is
## ignored, since the value goes into arithmetic. A run this one starts gets the
## caller's count, or none, through SHCL_CPU_FIXED, not the CPU_CAP of the step.
source "${here}/utility/include/cpu-cap.bash"
if [[ ! -v SHCL_CPU_FIXED ]]; then SHCL_CPU_FIXED="${CPU_CAP:-}"; fi
if [[ ! "${SHCL_CPU_FIXED}" =~ ^[1-9][0-9]*$ ]]; then SHCL_CPU_FIXED=""; fi
export SHCL_CPU_FIXED
fCpuCap

## Per-stage extras: eval'd strings run after the stage's primary command, so a
## second binding (Go, C, ...) adds its fmt/build/lint/test commands in config
## without touching engine code. All default empty.
FMT_EXTRA=(); FMT_CHECK_EXTRA=(); BUILD_EXTRA=(); LINT_EXTRA=(); TEST_EXTRA=(); TEST_QUICK_CMD=()
## The leak checks by length, and the test steps that are leak checks too.
LEAKCHECK_FAST=(); LEAKCHECK_STEPS=(); LEAKCHECK_LONG=(); LEAKCHECK_TESTS=()
FROZEN_LINKS=()     ## build dirs the frozen copy shares with the checkout
RELEASE_CHECKS=()   ## "label|command" over the release binaries, once built
REMOTE_BOXES=()     ## "BOX|SSH_TARGET|os-arch[|suites[=LIST]][|suites-long[=LIST]]" test boxes, after the release builds
## A job of a GitHub workflow, started first and waited for last, when the run
## builds the cross target it tests.
HOSTED_WORKFLOW=""; HOSTED_JOB=""; HOSTED_TARGET=""
QUICK_SKIP=()       ## steps --quick leaves out, by text; see fQuickDrop
PACKAGE_ENABLE=0   ## config opts in; installer packages built off the release artifacts
## -q: "-q" for the eval'd config strings to pass to tools that take one (ruff);
## cargo reads CARGO_TERM_QUIET from the environment instead. Empty otherwise.
QUIET_FLAG=""
## HARD_STEPS: text that marks a step as hard on the machine, matched like
## QUICK_SKIP; it gets a quarter of the cores, busy or not. --hard marks them all.
HARD_STEPS=()
## fCpuStep STEP [hard]: the cap for the step about to run, with a line when
## it changes.
cpu_said=""
fCpuStep(){
	local step="$1" hard="${2:-}" pat said
	if [[ -z "${hard}" ]]; then
		for pat in "${HARD_STEPS[@]}"; do
			if [[ "${step}" == *"${pat}"* ]]; then hard=hard; break; fi
		done
	fi
	fCpuCap "${hard}"
	said="${CPU_CAP}|${cpuWhy}"
	[[ "${said}" == "${cpu_said}" ]] && return 0
	cpu_said="${said}"
	case "${cpuWhy}" in
		busy) fEcho_Clean "jobs: ${CPU_CAP} of ${cpuCount} CPUs (busy, load $((cpuLoad / 100)).$(printf '%02d' $((cpuLoad % 100))))" ;;
		'')   fEcho_Clean "jobs: ${CPU_CAP} of ${cpuCount} CPUs" ;;
		*)    fEcho_Clean "jobs: ${CPU_CAP} of ${cpuCount} CPUs (${cpuWhy})" ;;
	esac
}
fRunExtras(){
	local c hard=""
	if [[ "${1:-}" == --hard ]]; then hard=hard; shift; fi
	for c in "$@"; do fCpuStep "${c}" "${hard}"; fEcho_Clean "extra: ${c}"; eval "${c}"; done
}
fStep(){ fCpuStep "$*"; "$@"; }

## shellcheck source=config.bash
source "${here}/config.bash"
## Set by --container for the run it starts, and for that run only: a gate that
## runs this engine on a stub repo must not take itself for it.
in_container=0
if [[ -n "${SHCL_IN_CONTAINER:-}" ]]; then in_container=1; fi
unset SHCL_IN_CONTAINER SHCL_CTR_IMAGE
## Set for the runs a run starts, on the frozen copy or on the checkout:
## SHCL_RUN_PART=fmt runs the format stage alone, and =build the stages after it.
## SHCL_FROZEN says the tree already is a copy, such as the pre-push hook's.
run_part="${SHCL_RUN_PART:-}"; frozen_given="${SHCL_FROZEN:-}"
unset SHCL_RUN_PART SHCL_FROZEN
## The steps the run that started this one counts, so both number them alike.
step_plan_given="${SHCL_STEP_PLAN:-}"; plan_only="${SHCL_STEP_PLAN_ONLY:-}"
unset SHCL_STEP_PLAN SHCL_STEP_PLAN_ONLY
case "${run_part}" in ''|fmt|build) ;; *) echo "SHCL_RUN_PART=${run_part}: not fmt or build" >&2; exit 2 ;; esac
## A run another run started, which leaves the log, the plan and the sweep to it.
inner_run=0
if ((in_container)) || [[ -n "${run_part}" ]]; then inner_run=1; fi
source "${here}/utility/include/frozen-tree.bash"
source "${here}/utility/include/stop-descendants.bash"
source "${here}/utility/include/gfs-rotate.bash"   ## gfs_rotate() for log/artifact pruning
cd "${root}"
stamp="$(date +%Y%m%d-%H%M%S)"

## Parse options.
assume_yes=0; quiet=0; gate_mode=0; merge_gate=0; backlog_quick=0; run_areas=(); quick=0; cli_message=""; sync_enable=1; gate_partial=0; no_tests=0; leakcheck_flag=0; no_leakcheck=0; long_run=0; keep_temp=0; list_only=0
## --container: which image, and the options the run inside it takes over.
ctr_image=""; ctr_pass=(); no_container=0; no_freeze=0; no_remote=0; skip_texts=()
## Why each step may be off, by step id, for the list in the first section.
declare -A step_why=()
fOff(){   ## fOff STEP REASON
	local w="${step_why[$1]:-}"
	if [[ ", ${w}, " != *", $2, "* ]]; then step_why[$1]="${w:+${w}, }$2"; fi
}
## The run modes, one per run: --gate, --merge-gate (--ci), and the 2 backlog runs.
mode_flag=""
fRunMode(){   ## fRunMode FLAG
	if [[ -n "${mode_flag}" && "${mode_flag}" != "$1" ]]; then echo "${mode_flag} and $1 can't go together (try --help)" >&2; exit 2; fi
	mode_flag="$1"
}
fCtrPick(){
	if [[ -z "$1" ]]; then echo "--container= names no image (try --help)" >&2; exit 2; fi
	if [[ -n "${ctr_image}" && "${ctr_image}" != "$1" ]]; then echo "--container names 2 images, ${ctr_image} and $1 (try --help)" >&2; exit 2; fi
	ctr_image="$1"
}
while (($#)); do case "$1" in
	--merge-gate)             gate_mode=1; merge_gate=1; assume_yes=1; fRunMode "$1"; ctr_pass+=("$1"); shift ;;
	--ci)                     echo "--ci is another name for --merge-gate"; gate_mode=1; merge_gate=1; assume_yes=1; fRunMode --merge-gate; ctr_pass+=(--merge-gate); shift ;;
	## The words after it up to the next option are its areas.
	--backlog-run-quick|--gate)
	                          if [[ "$1" == --gate ]]; then echo "--gate is another name for --backlog-run-quick"; fi
	                          gate_mode=1; backlog_quick=1; assume_yes=1; fRunMode --backlog-run-quick; ctr_pass+=(--backlog-run-quick); shift
	                          while (($#)) && [[ "$1" != -* ]]; do run_areas+=("$1"); ctr_pass+=("$1"); shift; done ;;
	--backlog-run-full)       gate_mode=1; merge_gate=1; assume_yes=1; fRunMode "$1"; ctr_pass+=("$1"); shift ;;
	--quick)                  quick=1; ctr_pass+=("$1"); shift ;;
	--leakcheck)              leakcheck_flag=1; ctr_pass+=("$1"); shift ;;
	--no-leakcheck)           no_leakcheck=1; ctr_pass+=("$1"); shift ;;
	--long|--slow)            long_run=1; ctr_pass+=("$1"); shift ;;
	-q|--quiet)               quiet=1; assume_yes=1; QUIET_FLAG="-q"; export CARGO_TERM_QUIET=true; shift ;;
	-y|--yes)                 assume_yes=1; shift ;;
	--no-sync)                sync_enable=0; fOff sync "$1"; shift ;;
	--no-fmt)                 FMT_CMD=(); FMT_CHECK_CMD=(); FMT_EXTRA=(); FMT_CHECK_EXTRA=(); gate_partial=1; fOff fmt "$1"; ctr_pass+=("$1"); shift ;;
	--no-lint)                LINT_CMD=(); SHELLCHECK_TARGETS=(); LINT_EXTRA=(); gate_partial=1; fOff lint "$1"; ctr_pass+=("$1"); shift ;;
	--no-tests)               TEST_CMD=(); TEST_QUICK_CMD=(); TEST_EXTRA=(); LEAKCHECK_STEPS=(); BINDING_CLIS=(); LARGEDOC_MIB=0; no_tests=1; gate_partial=1; fOff tests "$1"; ctr_pass+=("$1"); shift ;;
	--no-cross)               CROSS_TARGETS=(); CROSS_CHECKS=(); gate_partial=1; for s in release hosted hostedwait; do fOff "${s}" "$1"; done; ctr_pass+=("$1"); shift ;;
	--no-package)             PACKAGE_ENABLE=0; ctr_pass+=("$1"); shift ;;
	--no-largedoc)            LARGEDOC_MIB=0; ctr_pass+=("$1"); shift ;;
	--no-profile)             PROFILE_ENABLE=0; fOff profile "$1"; ctr_pass+=("$1"); shift ;;
	## Dogfood and the gif take the release binary, so a stale one would go out.
	--no-release)             RELEASE_NATIVE_CMD=(); PACKAGE_ENABLE=0; DOGFOOD_FIXED_DESTS=(); GIF_ENABLE=0; for s in release boxes hosted hostedwait dogfood gif; do fOff "${s}" "$1"; done; ctr_pass+=("$1"); shift ;;
	--no-dogfood)             DOGFOOD_FIXED_DESTS=(); fOff dogfood "$1"; shift ;;
	--no-gif)                 GIF_ENABLE=0; fOff gif "$1"; shift ;;
	--no-publish)             GIT_PUBLISH=(); fOff publish "$1"; shift ;;
	--no-remote)              no_remote=1; for s in boxes hosted hostedwait; do fOff "${s}" "$1"; done; shift ;;
	--skip=*)                 skip_texts+=("${1#*=}"); ctr_pass+=("$1"); shift ;;
	--skip)                   skip_texts+=("${2-}"); ctr_pass+=(--skip="${2-}"); shift; (($#)) && shift ;;
	--keep-temp)              keep_temp=1; ctr_pass+=("$1"); shift ;;
	--list)                   list_only=1; shift ;;
	--container)              fCtrPick main; shift ;;
	--container=*)            fCtrPick "${1#*=}"; shift ;;
	--no-container)           no_container=1; shift ;;
	--no-freeze)              no_freeze=1; shift ;;
	--message=*|--msg=*|-m=*) cli_message="${1#*=}"; shift ;;
	-m|--message|--msg)       cli_message="${2-}"; shift; (($#)) && shift ;;
	-h|--help)                sed -n '/^##	- Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##	\{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac; done
## Nothing on the command line resolves last-wins (design.md).
for area in "${run_areas[@]}"; do
	areaKnown=0
	for def in "${BACKLOG_AREAS[@]}"; do if [[ "${def%%|*}" == "${area}" ]]; then areaKnown=1; fi; done
	if ((! areaKnown)); then echo "unknown area: ${area} (try --help)" >&2; exit 2; fi
done
if ((backlog_quick && long_run)); then echo "--backlog-run-quick and --long can't go together (try --help)" >&2; exit 2; fi
## The flag that made the run quick, for the lines that say what it left out.
quick_flag=--quick
if ((backlog_quick)); then quick=1; quick_flag=--backlog-run-quick; fi
if ((leakcheck_flag && no_leakcheck)); then echo "--leakcheck and --no-leakcheck can't go together (try --help)" >&2; exit 2; fi
if ((quick && long_run)); then echo "--quick and --long can't go together (try --help)" >&2; exit 2; fi
if [[ -n "${ctr_image}" ]] && ((no_container)); then echo "--container and --no-container can't go together (try --help)" >&2; exit 2; fi

## The run modes: correctness only, deterministic, side-effect free. --merge-gate
## has every check of a run with no flags: the release and cross builds, their
## checks, the packages, the test boxes and the leak checks.
if ((gate_mode)); then
	## A gate that quietly skips what it cannot run is a gate that stops
	## checking when a runner loses a tool. The gates read this and fail on a
	## skip instead; locally a missing tool is still a skip, since a working
	## copy is not required to have every one.
	export SHCL_GATE_STRICT=1
	sync_enable=0       ## the runner already checked out the exact commit under test
	for s in sync profile dogfood gif publish; do fOff "${s}" "${mode_flag}"; done
	FMT_CMD=()          ## check-only via FMT_CHECK_CMD; never rewrite in CI
	if ((! merge_gate)); then
		CROSS_TARGETS=()
		RELEASE_NATIVE_CMD=()
		PACKAGE_ENABLE=0
		fOff release "${mode_flag}"; fOff boxes "${mode_flag}"
	fi
	PROFILE_ENABLE=0
	## The other hosted job runs the tests and the calibration. A local
	## --no-tests run keeps it, since it still draws a graph. A backlog run's
	## minutes go to the tests; the calibration's profiling build waits for
	## the round's last run.
	if ((no_tests || backlog_quick)); then PROFILE_CHECK=""; fi
	DOGFOOD_FIXED_DESTS=()   ## no local install from the read-only gate (and no stale-binary risk)
	GIF_ENABLE=0
	GIT_PUBLISH=()
else
	FMT_CHECK_CMD=()    ## locally the formatter rewrites in place instead
fi
## The run that froze the tree formatted the checkout before it did.
if [[ "${run_part}" == build ]]; then FMT_CMD=(); FMT_EXTRA=(); fi
freeze=1
if ((no_freeze || inner_run)) || [[ -n "${frozen_given}" ]]; then freeze=0; fi
## --quick: each QUICK_SKIP name is plain text matched against a whole step,
## so it can name a script, a command or a cross target's label. The
## crosscheck is the engine's own step, named by its script.
fQuickSkips(){  ## fQuickSkips STEP -> 0 when a QUICK_SKIP name is in it
	local pat
	for pat in "${QUICK_SKIP[@]}"; do
		if [[ "$1" == *"${pat}"* ]]; then return 0; fi
	done
	return 1
}
fQuickDrop(){   ## fQuickDrop ARRAY_NAME
	local -n steps_q7w="$1"
	local -a kept=()
	local step
	for step in "${steps_q7w[@]}"; do
		if ! fQuickSkips "${step}"; then kept+=("${step}"); fi
	done
	steps_q7w=("${kept[@]}")
}
xcheck_enable=1
if ((quick)); then
	LARGEDOC_MIB=0     ## minutes of parsing; the fast loop is for the small cases
	PACKAGE_ENABLE=0   ## installers, not checks
	PROFILE_ENABLE=0
	GIF_ENABLE=0
	fOff profile "${quick_flag}"; fOff gif "${quick_flag}"
	((${#TEST_QUICK_CMD[@]})) && TEST_CMD=("${TEST_QUICK_CMD[@]}")
	for list in LINT_EXTRA TEST_EXTRA CROSS_CHECKS CROSS_TARGETS RELEASE_CHECKS; do fQuickDrop "${list}"; done
	if fQuickSkips crosscheck.bash; then xcheck_enable=0; fi
fi
## --backlog-run-quick AREA...: the tests stage keeps only the steps of the
## areas named, each matched as text like QUICK_SKIP. The rest of the run is
## the same, since the format check and lint are quick.
if ((${#run_areas[@]})); then
	fAreaHas(){   ## fAreaHas STEP -> 0 when a named area's text is in it
		local area def pat
		local -a pats=()
		for area in "${run_areas[@]}"; do
			for def in "${BACKLOG_AREAS[@]}"; do
				if [[ "${def%%|*}" != "${area}" ]]; then continue; fi
				IFS='|' read -r -a pats <<< "${def#*|}"
				for pat in "${pats[@]}"; do
					if [[ "$1" == *"${pat}"* ]]; then return 0; fi
				done
			done
		done
		return 1
	}
	areaKept=()
	for step in "${TEST_EXTRA[@]}"; do
		if fAreaHas "${step}"; then areaKept+=("${step}"); fi
	done
	TEST_EXTRA=("${areaKept[@]}")
	if ((${#TEST_CMD[@]})) && ! fAreaHas "${TEST_CMD[*]}"; then TEST_CMD=(); fi
	if ! fAreaHas crosscheck.bash; then xcheck_enable=0; fi
elif ((backlog_quick)); then
	## With no areas named, the tests that would keep it from 4 minutes go too.
	areaKept=()
	for step in "${TEST_EXTRA[@]}"; do
		for pat in "${BACKLOG_SKIP[@]}"; do
			if [[ "${step}" == *"${pat}"* ]]; then continue 2; fi
		done
		areaKept+=("${step}")
	done
	TEST_EXTRA=("${areaKept[@]}")
fi
## The leak checks by length: the fast ones in --quick too, the slow ones in
## the default run, and the ones that take hours only under --long or
## --leakcheck, so the default run fits in about an hour (2026102515494614).
leak_long=0
if ((no_leakcheck || no_tests)); then
	LEAKCHECK_STEPS=()
	if ((no_leakcheck)); then
		leakKept=()
		for step in "${TEST_EXTRA[@]}"; do
			for pat in "${LEAKCHECK_TESTS[@]}"; do
				if [[ "${step}" == *"${pat}"* ]]; then continue 2; fi
			done
			leakKept+=("${step}")
		done
		TEST_EXTRA=("${leakKept[@]}")
	fi
elif ((leakcheck_flag || long_run)); then
	LEAKCHECK_STEPS=("${LEAKCHECK_FAST[@]}" "${LEAKCHECK_STEPS[@]}" "${LEAKCHECK_LONG[@]}")
	if ((${#LEAKCHECK_LONG[@]})); then leak_long=1; fi
elif ((gate_mode && ! merge_gate)); then
	LEAKCHECK_STEPS=()
elif ((quick)); then
	LEAKCHECK_STEPS=("${LEAKCHECK_FAST[@]}")
else
	LEAKCHECK_STEPS=("${LEAKCHECK_FAST[@]}" "${LEAKCHECK_STEPS[@]}")
fi

## --skip TEXT: each step that holds TEXT goes, matched like QUICK_SKIP. The
## hosted run leaves out a leak check whose tool it can't install that way. A
## TEXT that matches no step is a typo, or a step another flag took out.
skip_partial=0
for skipText in "${skip_texts[@]}"; do
	if [[ -z "${skipText}" ]]; then echo "--skip names no step (try --help)" >&2; exit 2; fi
	skipHit=0
	for list in LINT_EXTRA TEST_EXTRA CROSS_CHECKS CROSS_TARGETS RELEASE_CHECKS LEAKCHECK_STEPS; do
		declare -n skipList_k4v="${list}"
		skipKept=()
		for step in "${skipList_k4v[@]}"; do
			if [[ "${step}" == *"${skipText}"* ]]; then skipHit=1; else skipKept+=("${step}"); fi
		done
		skipList_k4v=("${skipKept[@]}")
		unset -n skipList_k4v
	done
	if ((xcheck_enable && ${#BINDING_CLIS[@]})) && [[ crosscheck.bash == *"${skipText}"* ]]; then xcheck_enable=0; skipHit=1; fi
	if ((! skipHit)); then echo "--skip ${skipText} matches no step this run takes (try --help)" >&2; exit 2; fi
	skip_partial=1
done

## A run at least as thorough as the pre-push hook's records the tree it tested
## once the tests and the cross checks pass, and the hook lets a commit with
## that tree through. A gate that skips a missing tool locally notes it in
## SHCL_GATE_SKIPS. In a run mode the same skip is a failure, so a run with
## anything noted there records nothing.
record_green=1
if ((quick || gate_partial || skip_partial)); then record_green=0; fi

## The GitHub job, by how long it takes (2026102416250110). The macos job is
## about 3 minutes, more in GitHub's queue, and it runs the pushed commit, so a
## run that tests edits in progress has no use for it. A quick run leaves it out,
## and a run with no flags or a longer one starts it before anything else.
hosted_off=""
fHostedBuilt(){   ## -> 0 when this run builds HOSTED_TARGET
	local t
	((${#RELEASE_NATIVE_CMD[@]})) || return 1
	for t in "${CROSS_TARGETS[@]}"; do
		if [[ "${t}" == *"|${HOSTED_TARGET}|"* ]]; then return 0; fi
	done
	return 1
}
if [[ -n "${HOSTED_JOB}" ]]; then
	if   [[ "${GITHUB_ACTIONS:-}" == true ]]; then hosted_off="already on a GitHub runner"
	elif ((no_remote)); then hosted_off=--no-remote
	## The push the hook gates starts ci.yml, macos job and all.
	elif [[ -n "${frozen_given}" ]]; then hosted_off="the pre-push hook's run"
	elif ((quick)); then hosted_off="${quick_flag}"
	elif ! fHostedBuilt; then hosted_off="no ${HOSTED_TARGET} build this run"
	fi
	if [[ -n "${hosted_off}" ]]; then fOff hosted "${hosted_off}"; fOff hostedwait "${hosted_off}"; fi
fi

## The steps this run takes, by id, in order. A step that's off isn't counted,
## and the first section names it with the flag or the reason. A run another run
## started takes that run's list, so the two number the steps alike, and runs
## only its own part of it.
step_order=(sync hosted fmt build lint tests profile release boxes hostedwait dogfood gif publish)
step_inner=" fmt build lint tests profile release "
step_ids=(); steps_off=(); step_open=""
fStepWanted(){   ## fStepWanted ID -> 0 when this run's settings take the step
	case "$1" in
		sync)    ((sync_enable)) ;;
		fmt)     if ((gate_mode)); then ((${#FMT_CHECK_CMD[@]})); else ((${#FMT_CMD[@]})); fi ;;
		build)   ((${#BUILD_CMD[@]})) ;;
		lint)    ((${#LINT_CMD[@]} + ${#SHELLCHECK_TARGETS[@]})) ;;
		tests)   ((${#TEST_CMD[@]} + ${#TEST_EXTRA[@]} + ${#BINDING_CLIS[@]} + ${#LEAKCHECK_STEPS[@]})) ;;
		profile) ((PROFILE_ENABLE)) || { ((gate_mode)) && [[ -n "${PROFILE_CHECK:-}" ]] && declare -p PROFILE_CHECK_BUILD_CMD &>/dev/null && ((${#PROFILE_CHECK_BUILD_CMD[@]})); } ;;
		release) ((${#CROSS_CHECKS[@]} + ${#RELEASE_NATIVE_CMD[@]})) ;;
		boxes)   ((! no_remote && ! inner_run && ${#REMOTE_BOXES[@]} && ${#RELEASE_NATIVE_CMD[@]})) ;;
		hosted|hostedwait) ((! inner_run)) && [[ -n "${HOSTED_JOB}" && -z "${hosted_off}" ]] ;;
		dogfood) ((${#DOGFOOD_FIXED_DESTS[@]} && ${#RELEASE_NATIVE_CMD[@]})) ;;
		gif)     ((GIF_ENABLE)) ;;
		publish) ((${#GIT_PUBLISH[@]})) ;;
		*)       return 1 ;;
	esac
}
fStepTitle(){   ## fStepTitle ID -> the step's name in its lines
	case "$1" in
		sync)    echo "Remote sync" ;;
		fmt)     if ((gate_mode)); then echo "Format (check only)"; else echo "Format"; fi ;;
		build)   echo "Build (debug)" ;;
		lint)    echo "Lint" ;;
		tests)   echo "Tests" ;;
		profile) echo "Profiler" ;;
		release) echo "Release builds" ;;
		boxes)   echo "Test boxes" ;;
		hosted)  echo "GitHub ${HOSTED_JOB} job: start" ;;
		hostedwait) echo "GitHub ${HOSTED_JOB} job: result" ;;
		dogfood) echo "Dogfood" ;;
		gif)     echo "Demo gif" ;;
		publish) echo "Backup + publish" ;;
	esac
}
## SHCL_STEP_PLAN_ONLY: the steps of stages 1-6 these flags take, one per line,
## and nothing run or made. A run that starts an extra image asks it for the
## flags the run in there gets, since that image's own flags take out more.
if [[ -n "${plan_only}" ]]; then
	for s in "${step_order[@]}"; do
		if [[ "${step_inner}" == *" ${s} "* ]] && fStepWanted "${s}"; then printf '%s\n' "${s}"; fi
	done
	exit 0
fi

## --list: the steps a run with the other flags would take, by stage, with
## the test IDs each one runs under it, and nothing run, made or asked.
## test-ids.py finds the IDs. A step whose label isn't its command carries the
## command after a \x1f, for it to match, and the label alone is printed.
## fBoxListStep ROW: a REMOTE_BOXES row as --list takes it, the box's name and
## the command whose tests it runs. A Windows box's suites are win-runners.bash
## (2026103016433943).
fBoxListStep(){
	local oa w
	IFS='|' read -r _ _ oa w <<< "$1"; w="|${w}|"; ((long_run)) || w="${w//|suites-long/|}"
	if [[ "${oa}" == windows-* && "${w}" == *'|suites'* ]]; then printf '%s\x1fcheck-boxes.bash && win-runners.bash\n' "${1%%|*}"
	else printf '%s\x1fcheck-boxes.bash\n' "${1%%|*}"; fi
}
if ((list_only)); then
	fListStage(){   ## fListStage TITLE STEP... (empty steps dropped)
		local step n=0
		printf '%s\n' "$1"; shift
		for step in "$@"; do
			if [[ -n "${step}" ]]; then printf '\t%s\n' "${step}"; n=$((n + 1)); fi
		done
		if ((n == 0)); then printf '\t(none)\n'; fi
	}
	fListSteps(){
		lsSteps=()
		if ((sync_enable)); then lsSteps=("fast-forward from upstream"); fi
		fListStage "0/9  Remote sync" "${lsSteps[@]}"
		if ((gate_mode)); then fListStage "1/9  Format (check only)" "${FMT_CHECK_CMD[*]}" "${FMT_CHECK_EXTRA[@]}"
		else fListStage "1/9  Format" "${FMT_CMD[*]}" "${FMT_EXTRA[@]}"; fi
		fListStage "2/9  Build (debug)" "${BUILD_CMD[*]}" "${BUILD_EXTRA[@]}"
		lsSteps=(); if ((${#SHELLCHECK_TARGETS[@]})); then lsSteps=("shellcheck over ${#SHELLCHECK_TARGETS[@]} file(s)"); fi
		fListStage "3/9  Lint" "${LINT_CMD[*]}" "${LINT_EXTRA[@]}" "${lsSteps[@]}"
		lsSteps=()
		if ((${#BINDING_CLIS[@]} && xcheck_enable)); then lsSteps+=("crosscheck.bash over ${#BINDING_CLIS[@]} binding(s)"); fi
		if ((LARGEDOC_MIB)); then lsSteps+=("largedoc.bash at ${LARGEDOC_MIB} MiB"); fi
		fListStage "4/9  Tests" "${TEST_CMD[*]}" "${TEST_EXTRA[@]}" "${lsSteps[@]}" "${LEAKCHECK_STEPS[@]}"
		lsSteps=()
		if ((PROFILE_ENABLE)); then lsSteps=("${PROFILE_BUILD_CMD[*]}" "profiler run, ${PROFILE_SECS}s"$'\x1f'"${PROFILE_CHECK:-}")
		elif ((gate_mode)) && [[ -n "${PROFILE_CHECK:-}" ]]; then lsSteps=("profiler attribution check"$'\x1f'"${PROFILE_CHECK}"); fi
		fListStage "5/9  Profiler" "${lsSteps[@]}"
		lsSteps=()
		for c in "${CROSS_CHECKS[@]}"; do lsSteps+=("cross check: ${c%%|*}"$'\x1f'"${c#*|}"); done
		if ((${#RELEASE_NATIVE_CMD[@]})); then
			lsSteps+=("${RELEASE_NATIVE_CMD[*]}")
			for c in "${CROSS_TARGETS[@]}"; do lsSteps+=("cross: ${c%%|*}"); done
			for c in "${RELEASE_CHECKS[@]}"; do lsSteps+=("release check: ${c%%|*}"$'\x1f'"${c#*|}"); done
			if ((PACKAGE_ENABLE)); then lsSteps+=("package.bash"); fi
		fi
		fListStage "6/9  Release builds" "${lsSteps[@]}"
		lsSteps=()
		if ((! no_remote && ${#RELEASE_NATIVE_CMD[@]})); then for c in "${REMOTE_BOXES[@]}"; do lsSteps+=("$(fBoxListStep "${c}")"); done; fi
		fListStage "6/9  Test boxes" "${lsSteps[@]}"
		if [[ -n "${HOSTED_JOB}" ]]; then
			lsSteps=(); if fStepWanted hosted; then lsSteps=("${HOSTED_JOB} job of ${HOSTED_WORKFLOW}, started before stage 1"); fi
			fListStage "6/9  GitHub ${HOSTED_JOB} job" "${lsSteps[@]}"
		fi
		lsSteps=(); if ((${#DOGFOOD_FIXED_DESTS[@]} && ${#RELEASE_NATIVE_CMD[@]})); then lsSteps=("${DOGFOOD_FIXED_DESTS[@]}"); fi
		fListStage "7/9  Dogfood" "${lsSteps[@]}"
		lsSteps=(); if ((GIF_ENABLE)); then lsSteps=("${GIF_OUT}"); fi
		fListStage "8/9  Demo gif" "${lsSteps[@]}"
		fListStage "9/9  Backup + publish" "${GIT_PUBLISH[*]}"
	}
	lsText="$(fListSteps)"
	if ! python3 "${here}/utility/test-ids.py" list <<< "${lsText}" 2>/dev/null; then
		printf '%s\n' "${lsText}" | sed $'s/\x1f.*//'
		echo "(test IDs not listed: utility/test-ids.py could not read them)"
	fi
	exit 0
fi

## Every run gets a temp dir of its own, and TMPDIR points into it, so what a
## gate or a test leaves when it fails or is killed goes with it at the end. A
## stopped run's too, through the trap.
run_tmp_root="${TMPDIR:-/tmp}"
if [[ "${run_tmp_root}" != /* ]]; then run_tmp_root=/tmp; fi
run_tmp_root="${run_tmp_root%/}"
run_tmp="$(mktemp -d "${run_tmp_root}/${APP_NAME}-run.XXXXXX")" || { echo "could not make a temp dir under ${run_tmp_root}" >&2; exit 2; }
echo "$$" > "${run_tmp}/.cicd-run"
export TMPDIR="${run_tmp}"
## What docker makes for this run carries the folder's name, as dev.run.
export SHCL_DEV_RUN="${run_tmp##*/}"
## Only the dir this run made: still at its path, a real dir that's ours, with
## this run's mark in it.
fRmRunTmp(){
	local d="${run_tmp}" mark=""
	run_tmp=""
	if ((keep_temp)); then
		if ((! inner_run)) && [[ -n "${d}" ]]; then
			printf '[ kept this run'\''s temp folder: %s ]\n' "${d}" >&2
			if [[ -n "${ctr_image:-}" ]]; then printf '[ and its containers: docker ps -a --filter label=dev.run=%s ]\n' "${SHCL_DEV_RUN}" >&2; fi
		fi
		return 0
	fi
	[[ -n "${d}" && "${d}" == "${run_tmp_root}/${APP_NAME}-run."* && -d "${d}" && ! -L "${d}" && -O "${d}" ]] || return 0
	mark="$(cat -- "${d}/.cicd-run" 2>/dev/null || true)"
	[[ "${mark}" == "$$" ]] || return 0
	## A test that failed can leave a dir it made read-only. chmod -R passes
	## over links, as rm -rf does.
	if ! rm -rf -- "${d}" 2>/dev/null; then
		chmod -R u+rwX -- "${d}" 2>/dev/null || true
		rm -rf -- "${d}" 2>/dev/null || echo "cleanup: could not remove all of ${d}" >&2
	fi
}
## KB to a size a person reads.
fSize(){ if (($1 >= 1048576)); then printf '%d.%d GB' $(($1 / 1048576)) $(($1 % 1048576 * 10 / 1048576)); else printf '%d MB' $((($1 + 512) / 1024)); fi; }
## The frozen copy, beside the temp dir rather than in it: docker would make a
## mount point for it as root inside the dir mounted at /tmp. A copy git can't
## take down is removed by hand, but only the one this run made.
frozen_root=""
fFrozenGone(){
	local d="${frozen_root}"
	frozen_root=""
	[[ -n "${d}" ]] || return 0
	fFrozenRemove "${root}" "${d}" && return 0
	echo "cleanup: git could not remove the frozen copy at ${d}" >&2
	[[ "${d}" == "${run_tmp_root}/${APP_NAME}-tree."* && -d "${d}" && ! -L "${d}" && -O "${d}" ]] || return 0
	rm -rf -- "${d}" 2>/dev/null || echo "cleanup: could not remove all of ${d}" >&2
}
## A run that stops early. fCleanup has already done it on a whole run.
# shellcheck disable=SC2329  ## runs from the EXIT trap; the whole-run braces hide that
fRunTmpGone(){
	local kb=0 n=""
	## First, or what's still running reads a copy and a temp dir already gone.
	fStopDescendants || true
	if ((! inner_run && ! keep_temp)) && [[ -n "${ctr_image:-}" ]] && declare -F fCtrRunGone >/dev/null; then
		n="$(fCtrRunGone "${SHCL_DEV_RUN}")" || n=""
		if [[ -n "${n}" ]]; then printf '[ cleanup: stopped and removed %s container(s) of this run ]\n' "${n}" >&2; fi
	fi
	fFrozenGone || true
	[[ -n "${run_tmp}" ]] || return 0
	if ((keep_temp)); then fRmRunTmp; return 0; fi
	kb="$(du -sk -- "${run_tmp}" 2>/dev/null | cut -f1)" || kb=0
	fRmRunTmp
	if ((! inner_run)); then printf '[ cleanup: removed this run'\''s temp files, about %s ]\n' "$(fSize "${kb:-0}")" >&2; fi
}
trap 'if declare -F fStepFail >/dev/null; then fStepFail || true; fi; fRunTmpGone || true' EXIT
export SHCL_GATE_SKIPS="$(mktemp)"

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
_letterbox="•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••"
fSection(){ fEcho_Clean; fEcho_Clean "${_letterbox}"; fEcho "$*"; }
## Local time to the hundredth of a second, with no fork.
fStepNow(){   ## fStepNow VAR
	local -n now_r4k="$1"
	local e="${EPOCHREALTIME:-}" t f
	e="${e/,/.}"
	if [[ "${e}" =~ ^([0-9]+)\.([0-9]{2}) ]]; then
		printf -v t '%(%Y%m%d-%H%M%S)T' "${BASH_REMATCH[1]}"; f="${BASH_REMATCH[2]}"
	else
		printf -v t '%(%Y%m%d-%H%M%S)T' -1; f=00
	fi
	now_r4k="${t}.${f}"
}
## fStepLine ID WORD: "[ TIME: Step N of M; WORD Title ]".
fStepLine(){
	local i n=0 now
	for i in "${!step_ids[@]}"; do
		if [[ "${step_ids[i]}" == "$1" ]]; then n=$((i + 1)); break; fi
	done
	fStepNow now
	fEcho "${now}: Step ${n} of ${#step_ids[@]}; $2 $(fStepTitle "$1")"
}
fStepStart(){ fEcho_Clean; fEcho_Clean "${_letterbox}"; fStepLine "$1" Starting; step_open="$1"; }
fStepEnd(){ local id="${step_open}"; step_open=""; fStepLine "${id}" PASS; }
## From the EXIT trap: a step still open when the run stops failed.
# shellcheck disable=SC2329  ## runs from the EXIT trap; the whole-run braces hide that
fStepFail(){ local id="${step_open:-}"; step_open=""; if [[ -n "${id}" ]]; then fStepLine "${id}" FAIL; fEcho_Clean; fi; }
## A step that's open closes on its FAIL line, right under the reason.
fDie(){ fEcho_Force "FAILED: $*" >&2; if [[ -n "${step_open:-}" ]]; then fStepFail; else echo >&2; fi; exit 1; }
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

## Stages 1-6 in the --container image, built first if it's not here. The repo
## and its git dir are mounted at their own paths, so the tree it records and a
## worktree's .git file still mean something. TREE is the checkout or the frozen
## copy, and PART is SHCL_RUN_PART for the run in there.
fRunContainer(){   ## fRunContainer TREE [PART]
	local tree="$1" part="${2:-}"
	local engine="${SHCL_DOCKER:-docker}" ctx="" tag="" link="" real="" step="${2:-stages}"
	local -a mounts=() groups=() env=() inner=() labels=() zone=()
	fSection "Container: ${ctr_image}"
	fCtrLabelArgs labels
	fCtrZoneArgs zone

	## The image is built from a copy of its recipe dir plus the files the
	## config adds, and tagged by their hash, so an edit can't run on an old one.
	ctx="$(mktemp -d)"
	fCtrContext "${ctr_recipe}" "${ctx}" || fDie "could not copy the ${ctr_image} image's build context"
	tag="$(fCtrTag "${ctx}" "${ctr_image}")"
	if "${engine}" image inspect "${tag}" >/dev/null 2>&1; then
		fEcho_Clean "image ${tag}"
	else
		## Quiet, since a first build is minutes of download lines. A failure
		## still prints the step that failed.
		fEcho_Clean "building ${tag}, which takes several minutes the first time"
		fCtrBuild "${tag}" "${ctx}" || fDie "could not build ${tag}"
	fi
	ctr_tag="${tag}"

	local cache="${CTR_CACHE:-${HOME}/.cache/${APP_NAME}-cicd}/${ctr_image}"
	mkdir -p "${cache}" || fDie "could not make the cache dir ${cache}"
	## /tmp too, so big scratch goes where TMPDIR says rather than into the
	## container's layer on the root disk.
	local scratch; scratch="$(mktemp -d)"
	mounts=(-v "${tree}:${tree}" -v "${cache}:/cache" -v "${scratch}:/tmp")
	local gitCommon; gitCommon="$(git -C "${tree}" rev-parse --path-format=absolute --git-common-dir)"
	if [[ "${gitCommon}" != "${tree}/"* ]]; then mounts+=(-v "${gitCommon}:${gitCommon}"); fi
	## Zig's cache, apart from the cache dir so fCtrZigTrim can empty it whole.
	## Made here first, since a volume docker makes for a run has no label.
	if [[ "${ctr_image}" == main ]]; then
		"${engine}" volume create "${labels[@]}" "${CTR_ZIG_VOLUME}" >/dev/null || fDie "could not make the ${CTR_ZIG_VOLUME} volume"
		mounts+=(-v "${CTR_ZIG_VOLUME}:/zig-cache")
	fi
	## An extra image builds into its own copy of these, so it doesn't churn
	## or replace this box's builds. Each copy goes where its path leads, so a
	## gate worktree's target link reaches the copy and not target-gate. Docker
	## makes a missing mount point as root, so a stand-in is made here first and
	## taken away after.
	local -A private=()
	local -a standIns=()
	local priv="" dest="" ctrRc=0
	if [[ "${ctr_image}" != main ]]; then
		for link in "${CTR_PRIVATE[@]}"; do
			private["${link%/}"]=1
			priv="${cache}/private/${link%/}"
			dest="$(readlink -f -- "${tree}/${link%/}")" || fDie "can't resolve ${link} for the ${ctr_image} image's own copy"
			if [[ "${link}" == */ ]]; then
				mkdir -p "${priv}" || fDie "could not make ${priv}"
				if [[ ! -e "${dest}" ]]; then mkdir -p "${dest}" || fDie "could not make ${dest}"; standIns+=("${dest}"); fi
			else
				## Executable, since go build -o into a file that's there keeps its mode.
				if ! { mkdir -p "${priv%/*}" && { [[ -e "${priv}" ]] || : > "${priv}"; } && chmod +x "${priv}"; }; then fDie "could not make ${priv}"; fi
				if [[ ! -e "${dest}" ]]; then : > "${dest}" || fDie "could not make ${dest}"; standIns+=("${dest}"); fi
			fi
			mounts+=(-v "${priv}:${dest}")
		done
	fi
	## Once each, since docker refuses a mount point named twice.
	local -A linked=()
	for link in "${CTR_LINKS[@]}" "${FROZEN_LINKS[@]}"; do
		if [[ -n "${private[${link%/}]:-}" ]]; then continue; fi
		if [[ -L "${tree}/${link}" ]]; then
			real="$(readlink -f -- "${tree}/${link}")"
			if [[ "${real}" != "${tree}/"* && -z "${linked[${real}]:-}" ]]; then linked["${real}"]=1; mkdir -p "${real}"; mounts+=(-v "${real}:${real}"); fi
		fi
	done

	## The caller's uid and groups have no names in the image, and some rows
	## need the second group a runner's user has. So the image's passwd and
	## group files plus the caller's entries, and the caller's groups.
	local etc gid gname; etc="$(mktemp -d)"
	"${engine}" run --rm "${labels[@]}" --name "$(fCtrName "${step}-passwd")" --cpus 1 --cpu-shares 256 "${tag}" cat /etc/passwd > "${etc}/passwd" || fDie "could not read the image's /etc/passwd"
	"${engine}" run --rm "${labels[@]}" --name "$(fCtrName "${step}-group")" --cpus 1 --cpu-shares 256 "${tag}" cat /etc/group > "${etc}/group" || fDie "could not read the image's /etc/group"
	printf '%s:x:%s:%s::/cache/home:/bin/bash\n' "${USER:-builder}" "$(id -u)" "$(id -g)" >> "${etc}/passwd"
	for gid in $(id -G); do
		if grep -q "^[^:]*:[^:]*:${gid}:" "${etc}/group"; then continue; fi
		gname="$(getent group "${gid}" | cut -d: -f1 || true)"
		if [[ -z "${gname}" ]] || grep -q "^${gname}:" "${etc}/group"; then gname="g${gid}"; fi
		printf '%s:x:%s:\n' "${gname}" "${gid}" >> "${etc}/group"
	done
	mounts+=(-v "${etc}/passwd:/etc/passwd:ro" -v "${etc}/group:/etc/group:ro" "${zone[@]}")
	for gid in $(id -G); do
		if [[ "${gid}" != "$(id -g)" ]]; then groups+=(--group-add "${gid}"); fi
	done
	## check-freebsd boots FreeBSD in about 20 s with KVM, 2 minutes without.
	## The caller's kvm group came along above.
	if [[ -r /dev/kvm && -w /dev/kvm ]]; then mounts+=(--device /dev/kvm); fi

	env=(-e SHCL_IN_CONTAINER=1 -e "SHCL_CTR_IMAGE=${ctr_image}" -e "USER=${USER:-builder}" -e "CPU_CAP=${CPU_CAP}" -e "SHCL_CPU_FIXED=${SHCL_CPU_FIXED}")
	if [[ -n "${SHCL_GATE_REF:-}" ]]; then env+=(-e "SHCL_GATE_REF=${SHCL_GATE_REF}"); fi
	if [[ -n "${part}" ]]; then env+=(-e "SHCL_RUN_PART=${part}"); fi
	env+=(-e "SHCL_STEP_PLAN=${step_ids[*]}")
	inner=("$( ((quiet)) && echo -q || echo -y )" --no-sync --no-dogfood --no-gif --no-publish "${ctr_pass[@]}")
	if [[ "${ctr_image}" != main ]]; then
		declare -p "CTR_ARGS_${ctr_image}" &>/dev/null || fDie "config.bash has no CTR_ARGS_${ctr_image}, the stages that image runs"
		local -n ctrArgs_k3v="CTR_ARGS_${ctr_image}"
		inner+=("${ctrArgs_k3v[@]}")
	fi
	fEcho_Clean "runs cicd.bash ${inner[*]}"
	## So a stop can take the container down if its docker client won't go.
	local cidfile="${run_tmp}/ctr.cid"
	stop_cidfiles=("${cidfile}")
	## nice on this side doesn't reach the container, so a CPU quota and a low
	## share; the engine inside renices itself.
	local -a rmArg=(--rm)
	if ((keep_temp)); then rmArg=(); fi
	"${engine}" run "${rmArg[@]}" --init --cidfile "${cidfile}" "${labels[@]}" --name "$(fCtrName "${step}")" --cpus "${CPU_CAP}" --cpu-shares 256 --user "$(id -u):$(id -g)" "${groups[@]}" "${mounts[@]}" "${env[@]}" -w "${tree}" \
		"${tag}" bash "${tree}/cicd/cicd.bash" "${inner[@]}" \
		|| ctrRc=$?
	stop_cidfiles=()
	rm -f -- "${cidfile}"
	## Only a stand-in still empty: anything else was built here meanwhile.
	for dest in "${standIns[@]}"; do
		if [[ -d "${dest}" ]]; then rmdir -- "${dest}" 2>/dev/null || true
		elif [[ -f "${dest}" && ! -s "${dest}" ]]; then rm -f -- "${dest}"; fi
	done
	((ctrRc == 0)) || fDie "the run in the ${ctr_image} image failed; its output is above"
	case "${part}" in
		fmt)   fEcho "OK: stage 1 in the ${ctr_image} image" ;;
		build) fEcho "OK: stages 2-6 in the ${ctr_image} image" ;;
		*)     fEcho "OK: stages 1-6 in the ${ctr_image} image" ;;
	esac
}

## --container: stages 1-6 go to the image. An extra image builds nothing this
## box should install or publish, so nothing runs here after it.
ctr_recipe=""; ctr_note=""; ctr_tag=""
fCtrRecipe(){
	ctr_recipe="${CTR_DIR:-cicd/container}/${ctr_image}.Dockerfile"
	[[ "${ctr_image}" == main ]] && ctr_recipe="${CTR_DIR:-cicd/container}/Dockerfile"
	[[ -f "${root}/${ctr_recipe}" ]] || fDie "--container=${ctr_image}: no recipe at ${ctr_recipe}"
}
if [[ -n "${ctr_image}" ]]; then
	((! in_container)) || fDie "already in the container; --container would start another"
	[[ "${ctr_image}" =~ ^[a-z0-9]+$ ]] || fDie "--container=${ctr_image}: an image name is lower-case letters and digits"
	fCtrRecipe
fi
## With neither flag the main image is used when docker answers, and this box
## when it doesn't (JC, 2026-10-19). The run inside never asks.
if ((! no_container && ! in_container)); then
	source "${here}/utility/include/ctr-image.bash"
	ctr_why="$(fCtrWhyNot)"
	if [[ -n "${ctr_image}" && -n "${ctr_why}" ]]; then fDie "--container can't run: ${ctr_why}"; fi
	if [[ -z "${ctr_image}" ]]; then
		if [[ -n "${ctr_why}" ]]; then ctr_note="stages 1-6 run on this box, since ${ctr_why}"
		else ctr_image=main; fCtrRecipe; fi
	fi
fi
if [[ -n "${ctr_image}" && "${ctr_image}" != main ]]; then
	DOGFOOD_FIXED_DESTS=(); GIF_ENABLE=0; GIT_PUBLISH=()
	for s in dogfood gif publish; do fOff "${s}" "--container=${ctr_image}"; done
fi

## The plan: the list the run that started this one gave, or this run's own.
read -r -a step_ids <<< "${step_plan_given}"
for s in "${step_ids[@]}"; do
	if [[ " ${step_order[*]} " != *" ${s} "* ]]; then step_ids=(); break; fi
done
if ((${#step_ids[@]} == 0)); then
	for s in "${step_order[@]}"; do
		if fStepWanted "${s}"; then step_ids+=("${s}"); else steps_off+=("${s}"); fi
	done
fi
if ((${#step_plan_given} == 0)) && [[ -n "${ctr_image}" && "${ctr_image}" != main ]] && declare -p "CTR_ARGS_${ctr_image}" &>/dev/null; then
	declare -n planArgs_m2x="CTR_ARGS_${ctr_image}"
	ctrSteps="$(SHCL_STEP_PLAN_ONLY=1 SHCL_IN_CONTAINER=1 bash "${here}/cicd.bash" -y --no-sync --no-dogfood --no-gif --no-publish "${ctr_pass[@]}" "${planArgs_m2x[@]}")" \
		|| fDie "could not work out the steps the ${ctr_image} image takes"
	keptIds=" ${step_ids[*]} "; step_ids=(); steps_off=()
	for s in "${step_order[@]}"; do
		if [[ "${step_inner}" == *" ${s} "* ]]; then
			if [[ $'\n'"${ctrSteps}"$'\n' == *$'\n'"${s}"$'\n'* ]]; then step_ids+=("${s}"); continue; fi
			if [[ "${keptIds}" == *" ${s} "* ]]; then fOff "${s}" "--container=${ctr_image}"; fi
		elif [[ "${keptIds}" == *" ${s} "* ]]; then
			step_ids+=("${s}"); continue
		fi
		steps_off+=("${s}")
	done
fi
## fStepOn ID: the step is counted and this run is the one that takes it.
fStepOn(){
	if [[ " ${step_ids[*]} " != *" $1 "* ]]; then return 1; fi
	((! inner_run)) || [[ "${step_inner}" == *" $1 "* ]]
}

## Preflight: show the plan, then capture the commit message so the rest runs unattended.
case "${mode_flag}" in
	--backlog-run-quick) run_title="${APP_NAME} backlog run, quick"; if ((${#run_areas[@]})); then run_title+=": ${run_areas[*]}"; fi ;;
	--backlog-run-full)  run_title="${APP_NAME} backlog run, full" ;;
	--merge-gate)        run_title="${APP_NAME} merge gate" ;;
	*)                   run_title="${APP_NAME} local CI/CD" ;;
esac
if ((quick && ! backlog_quick)); then run_title+=", quick"; fi
## The steps that are off, with the flag or reason for each.
fStepsOff(){
	local id title
	((! inner_run)) || return 0
	fEcho_Clean "Steps ..........: ${#step_ids[@]}"
	for id in "${steps_off[@]}"; do
		## The GitHub job's 2 steps are on or off together, so one line says it.
		if [[ "${id}" == hostedwait ]]; then continue; fi
		title="$(fStepTitle "${id}")"
		fEcho_Clean "Off ............: ${title%: start} (${step_why[${id}]:-not configured})"
	done
	for id in "${skip_texts[@]}"; do fEcho_Clean "Off ............: each step with ${id} (--skip)"; done
}
if ((! quiet)); then
	fSection "${run_title}"
	fEcho_Clean
	fEcho_Clean "Repo root ......: ${root}"
	fEcho_Clean "Remote sync ....: $( ((sync_enable)) && echo 'fast-forward when behind; abort when diverged' || echo '(skipped)')"
	## Under --container the run inside prints its own plan for stages 1-6.
	if [[ -n "${ctr_image}" ]]; then
		fEcho_Clean "Container ......: stages 1-6 in the ${ctr_image} image, from ${ctr_recipe}"
	else
		fEcho_Clean "Format .........: $( ((gate_mode)) && echo "${FMT_CHECK_CMD[*]:-(none configured)}" || echo "${FMT_CMD[*]:-(skipped)}")$( ((${#FMT_EXTRA[@]} + ${#FMT_CHECK_EXTRA[@]})) && echo "  (+ extras)" )"
		fEcho_Clean "Build (debug) ..: ${BUILD_CMD[*]:-(none configured)}$( ((${#BUILD_EXTRA[@]})) && echo "  (+ ${#BUILD_EXTRA[@]} extra)" )"
		fEcho_Clean "Lint ...........: ${LINT_CMD[*]:-(none configured)}$( ((${#LINT_EXTRA[@]})) && echo "  (+ ${#LINT_EXTRA[@]} extra)" )  + shellcheck: ${#SHELLCHECK_TARGETS[@]} file(s)"
		fEcho_Clean "Tests ..........: ${TEST_CMD[*]:-(none configured)}$( ((${#TEST_EXTRA[@]})) && echo "  (+ ${#TEST_EXTRA[@]} extra)" )  + crosscheck: $( ((xcheck_enable)) && echo "${#BINDING_CLIS[@]} binding(s)" || echo "(skipped)" )$( ((LARGEDOC_MIB)) && echo "  + large doc: ${LARGEDOC_MIB} MiB" )"
		fEcho_Clean "Leak checks ....: $( ((${#LEAKCHECK_STEPS[@]})) && echo "${#LEAKCHECK_STEPS[@]}, at the end of the tests$( ((leak_long)) && echo ' (some take hours)')" || echo '(skipped)')"
		fEcho_Clean "Profiler .......: $( ((PROFILE_ENABLE)) && echo "${PROFILE_SECS}s run -> flamegraph SVG -> ${PROFILE_OUT_DIR}/" || echo '(skipped)')"
		if ((${#RELEASE_NATIVE_CMD[@]})); then
			fEcho_Clean "Release ........: native + ${#CROSS_TARGETS[@]} cross target(s) -> ${RELEASE_ARTIFACT_DIR}/$( ((${#RELEASE_CHECKS[@]})) && echo "  + ${#RELEASE_CHECKS[@]} check(s)" )"
		else
			fEcho_Clean "Release ........: (skipped)"
		fi
		fEcho_Clean "Cross checks ...: $( ((${#CROSS_CHECKS[@]})) && echo "${#CROSS_CHECKS[@]} (no artifact; run whether or not a release is built)" || echo '(skipped)')"
		fEcho_Clean "Packages .......: $( ((PACKAGE_ENABLE)) && echo '.deb/.rpm + NSIS setup (per built binary)' || echo '(skipped)')"
		if ((quick)) && ((${#QUICK_SKIP[@]})); then
			_qs="$(printf '%s, ' "${QUICK_SKIP[@]}")"
			fEcho_Clean "Quick skips ....: ${_qs%, }"
		fi
	fi
	_fz='(off)'
	if ((freeze)); then _fz='stages 2-6 run from a copy of the tree taken after the format stage'
	elif [[ "${run_part}" == build ]]; then _fz='(this run is in it)'; fi
	fEcho_Clean "Frozen copy ....: ${_fz}"
	fEcho_Clean "Dogfood ........: $( if ((${#DOGFOOD_FIXED_DESTS[@]})); then _dfd="$(fFirstWritableDir "${DOGFOOD_FIXED_DESTS[@]}")"; [[ -n "$_dfd" ]] && echo "${_dfd}/${EXE_NAME}" || echo '(no writable dest; will skip)'; else echo '(skipped)'; fi )"
	fEcho_Clean "Demo gif .......: $( ((GIF_ENABLE)) && echo "${GIF_OUT}" || echo '(skipped)')"
	if ((${#GIT_PUBLISH[@]})); then
		fEcho_Clean "Publish (last) .: ${GIT_PUBLISH[*]}$( [[ -n "$publish_msg" ]] && echo " (hands-off: \"${publish_msg}\")" || echo ' (will prompt for message; blank = editor)')"
	else
		fEcho_Clean "Publish (last) .: (skipped)"
	fi
	fStepsOff
	fEcho_Clean
	fEcho_Clean "Fail-fast: any error aborts before the next step."
elif ((! inner_run)); then
	fSection "${run_title}"
	fStepsOff
fi
if ((! assume_yes)) && ((${#GIT_PUBLISH[@]})) && [[ -z "$publish_msg" ]]; then
	read -r -p "Publish commit message (blank = editor; Ctrl+C aborts): " m
	fEcho_ResetBlankCounter
	[[ -n "$m" ]] && publish_msg="$m"
fi

## Tee the whole run to a rotated log so warnings can be reviewed later
## (lint-report.bash reads the newest one). Skipped in the run modes (read-only),
## and in the container, where the run outside already logs all of it.
if ((! gate_mode)) && ((! inner_run)) && [[ -n "${LINT_LOG_DIR:-}" ]] && mkdir -p "${root}/${LINT_LOG_DIR}" 2>/dev/null; then
	gfs_rotate "${root}/${LINT_LOG_DIR}" run log >/dev/null 2>&1 || true
	exec > >(tee "${root}/${LINT_LOG_DIR}/run_${stamp}.log") 2>&1
	## It has to outlive the stop, or the cleanup lines are lost.
	stop_keep+=("$!")
fi

## Warn (non-gating) when a pinned helper tool has drifted from TOOL_PINS, so a
## box update can't silently change results. Format: "name|version|command...".
## Under --container this box's tools don't run, and the run inside checks its own.
if [[ -n "${ctr_image}" ]]; then TOOL_PINS=(); fi
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
if fStepOn sync; then
	fStepStart sync
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
			## fast-forward can refuse rather than touch a modified file. An
			## untracked file counts, as in the publisher: one upstream also adds
			## stops the fast-forward (20260923 item 14).
			dirty=0; git -C "${root}" diff --quiet && git -C "${root}" diff --cached --quiet || dirty=1
			[[ -n "$(git -C "${root}" ls-files --others --exclude-standard || true)" ]] && dirty=1
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
	fStepEnd
fi

## The GitHub job starts here and is waited for after the test boxes, so the
## two overlap. GitHub runs what it has, so the remote's branch has to be at
## HEAD. As with a test box, anything short of a finished run that failed is a
## SKIP, and the run goes on; the summary at the end names it again.
## SHCL_GH, for a test, then gitsby, which brings the account the repo's folder
## belongs to, then a plain gh.
fHostedGh(){
	( cd "${root}" || exit 2
	if [[ -n "${SHCL_GH:-}" ]]; then "${SHCL_GH}" "$@"
	elif command -v gitsby >/dev/null 2>&1; then gitsby -q raw gh "$@"
	else gh "$@"; fi )
}
remote_skips=()
hosted_branch=""; hosted_sha=""; hosted_run=""; hosted_since=""; hosted_skip=""
if fStepOn hosted; then
	fStepStart hosted
	hosted_sha="$(git -C "${root}" rev-parse -q --verify HEAD || true)"
	h_branch="$(git -C "${root}" symbolic-ref --quiet --short HEAD || true)"
	h_remote=""; h_remote_sha=""; h_out=""
	if   [[ -z "${hosted_sha}" ]]; then hosted_skip="no commit to run"
	elif [[ ! -f "${root}/.github/workflows/${HOSTED_WORKFLOW}" ]]; then hosted_skip="no .github/workflows/${HOSTED_WORKFLOW}"
	elif [[ -z "${SHCL_GH:-}" ]] && ! command -v gh >/dev/null 2>&1; then hosted_skip="no gh"
	elif [[ -z "${h_branch}" ]]; then hosted_skip="HEAD is detached, so there's no branch to run it on"
	elif ! h_remote="$(git -C "${root}" config "branch.${h_branch}.remote")"; then hosted_skip="${h_branch} tracks no remote"
	elif ! h_remote_sha="$(git -C "${root}" ls-remote "${h_remote}" "refs/heads/${h_branch}" 2>/dev/null)"; then hosted_skip="could not reach ${h_remote}"
	elif [[ "${h_remote_sha%%[[:space:]]*}" != "${hosted_sha}" ]]; then hosted_skip="${h_remote}/${h_branch} isn't at HEAD ${hosted_sha:0:12}, so push first"
	else
		## A minute early, for a clock that runs ahead of GitHub's.
		hosted_since="$(date -u -d "@$((EPOCHSECONDS - 60))" +%Y-%m-%dT%H:%M:%SZ)"
		if h_out="$(fHostedGh workflow run "${HOSTED_WORKFLOW}" --ref "${h_branch}" -f job="${HOSTED_JOB}" 2>&1)"; then
			hosted_branch="${h_branch}"
			## gh prints the run's URL when GitHub gives it one.
			if [[ "${h_out}" =~ /actions/runs/([0-9]+) ]]; then hosted_run="${BASH_REMATCH[1]}"; fi
		else
			printf '%s\n' "${h_out}"
			hosted_skip="gh could not start it, and said why above"
		fi
	fi
	if [[ -n "${hosted_skip}" ]]; then
		remote_skips+=("SKIP GitHub ${HOSTED_JOB} job: ${hosted_skip}")
		printf '%s\n' "${remote_skips[-1]}"
	else
		fEcho_Clean "started: the ${HOSTED_JOB} job of ${HOSTED_WORKFLOW}, on ${h_remote}/${h_branch} at ${hosted_sha:0:12}"
		if [[ -n "$(git -C "${root}" status --porcelain --untracked-files=no || true)" ]]; then
			fEcho_Clean "note: it runs that commit, not the uncommitted edits here"
		fi
	fi
	fStepEnd
fi

## Stage 1: format. In place locally; check-only (fail on diff) in the run modes.
## The run on a frozen copy leaves it to the run that formatted the checkout.
fStageFormat(){
	fStepOn fmt || return 0
	if ((gate_mode)); then
		((${#FMT_CHECK_CMD[@]})) || return 0
		fStepStart fmt
		fStep "${FMT_CHECK_CMD[@]}"
		fRunExtras "${FMT_CHECK_EXTRA[@]}"
		fEcho "OK: format clean"
	elif ((${#FMT_CMD[@]})); then
		fStepStart fmt
		fStep "${FMT_CMD[@]}"
		fRunExtras "${FMT_EXTRA[@]}"
		fEcho "OK: formatted"
	else
		return 0
	fi
	fStepEnd
}

## A detached, locked worktree holding the tree the format stage left, HEAD plus
## what isn't committed, for stages 2-6 (2026102108300000). Any trouble making
## it runs them in the checkout, as before, with a warning.
fFreeze(){
	local head="" tree="" link="" i=0
	local -a changed=()
	if ! head="$(git -C "${root}" rev-parse -q --verify HEAD 2>/dev/null)" || ! tree="$("${here}/utility/green-tree.bash" tree "${root}" 2>/dev/null)"; then
		fEcho "WARNING: no commit to copy; stages 2-6 run in the checkout"
		return 0
	fi
	frozen_root="$(mktemp -d "${run_tmp_root}/${APP_NAME}-tree.XXXXXX")" || fDie "could not make a dir for the frozen copy under ${run_tmp_root}"
	if ! fFrozenAdd "${root}" "${frozen_root}" "${head}" "${tree}"; then
		rmdir -- "${frozen_root}" 2>/dev/null || true
		frozen_root=""
		fEcho "WARNING: could not make a frozen copy; stages 2-6 run in the checkout"
		return 0
	fi
	## An extra image builds into its own copies, and keeps nothing.
	if [[ -z "${ctr_image}" || "${ctr_image}" == main ]]; then
		for link in "${FROZEN_LINKS[@]}"; do
			fFrozenLink "${root}" "${frozen_root}" "${link}" || fDie "could not link ${link} into the frozen copy"
		done
	fi
	mapfile -t changed < <(git -C "${root}" diff --name-status --no-renames "${head}" "${tree}")
	fSection "Frozen copy"
	fEcho_Clean "stages 2-6 run from ${frozen_root}"
	if ((${#changed[@]} == 0)); then
		fEcho_Clean "copied ${head:0:12}, with nothing uncommitted"
	else
		fEcho_Clean "copied ${head:0:12} plus ${#changed[@]} uncommitted file(s):"
		for ((i = 0; i < ${#changed[@]} && i < 20; i++)); do fEcho_Clean "	${changed[i]}"; done
		if ((${#changed[@]} > 20)); then fEcho_Clean "	and $((${#changed[@]} - 20)) more"; fi
	fi
}

## Stages 2-6 on this box, in the frozen copy, by the copy's own engine.
fRunFrozen(){
	local -a inner=("$( ((quiet)) && echo -q || echo -y )" --no-sync --no-container --no-dogfood --no-gif --no-publish "${ctr_pass[@]}")
	local rc=0
	SHCL_STEP_PLAN="${step_ids[*]}" SHCL_RUN_PART=build bash "${frozen_root}/cicd/cicd.bash" "${inner[@]}" || rc=$?
	## A stopped run stays a stopped run.
	if ((rc > 128)); then exit "${rc}"; fi
	((rc == 0)) || fDie "the run in the frozen copy failed; its output is above"
}

## The release builds a run elsewhere left, for dogfood and the gif.
fCollectBuilt(){
	local t rest t_osarch t_art
	built_arts=()
	if ((${#RELEASE_NATIVE_CMD[@]})) && [[ -f "${RELEASE_NATIVE_BIN}" ]]; then
		built_arts=("${RELEASE_NATIVE_OSARCH:-native}|${RELEASE_NATIVE_BIN}")
		for t in "${CROSS_TARGETS[@]}"; do
			rest="${t#*|}"; t_osarch="${rest%%|*}"; rest="${rest#*|}"; t_art="${rest%%|*}"
			if [[ -f "${t_art}" ]]; then built_arts+=("${t_osarch}|${t_art}"); fi
		done
	fi
}

## Stages 1-6 run here, or in the container, which hands back its release
## builds for dogfood and the gif. With a frozen copy, stage 1 runs on the
## checkout first, and 2-6 in the copy, here or in the container.
if [[ -n "${ctr_note}" ]]; then fEcho_Clean "note: ${ctr_note}"; fi
if ((freeze)); then
	if ((${#FMT_CMD[@]})); then
		if [[ -n "${ctr_image}" ]]; then fRunContainer "${root}" fmt; else fStageFormat; fi
	fi
	fFreeze
fi
if [[ -n "${frozen_root}" ]]; then
	if [[ -n "${ctr_image}" ]]; then fRunContainer "${frozen_root}" build; else fRunFrozen; fi
	fCollectBuilt
elif [[ -n "${ctr_image}" ]]; then
	fRunContainer "${root}"
	fCollectBuilt
else
	## Whatever the container needs before a run, such as crates the gate's
	## profiler check reads offline.
	if ((in_container)) && [[ -n "${CTR_PREP:-}" ]]; then eval "${CTR_PREP}"; fi
	fStageFormat
	if [[ "${run_part}" == fmt ]]; then exit 0; fi
	## Taken after the formatter, since locally it rewrites what gets tested.
	green_tree=""
	if ((record_green)); then green_tree="$("${here}/utility/green-tree.bash" tree "${root}" || true)"; fi

	## Stage 2: debug build (fast compile sanity; the tests run against this).
	if fStepOn build; then
		fStepStart build
		fStep "${BUILD_CMD[@]}"
		fRunExtras "${BUILD_EXTRA[@]}"
		fEcho "OK: build"
		fStepEnd
	fi

	## Stage 3: lint. Project lint first, then shellcheck over the cicd scripts (and
	## any other bash config lists), so the pipeline can't rot silently. shellcheck
	## is optional locally (warn if missing) but present on GitHub runners.
	if fStepOn lint; then fStepStart lint; fi
	if ((${#LINT_CMD[@]})); then
		fStep "${LINT_CMD[@]}"
		fRunExtras "${LINT_EXTRA[@]}"
		fEcho "OK: lint clean"
	fi
	if ((${#SHELLCHECK_TARGETS[@]})); then
		if command -v shellcheck >/dev/null 2>&1; then
			shellcheck "${SHELLCHECK_TARGETS[@]}"
			fEcho "OK: shellcheck clean (${#SHELLCHECK_TARGETS[@]} file(s))"
		elif ((gate_mode)); then
			fDie "shellcheck required under ${mode_flag} but not found"
		else
			fEcho "WARNING: shellcheck not installed; skipped"
			echo shellcheck >> "${SHCL_GATE_SKIPS}"
		fi
	fi
	if [[ "${step_open}" == lint ]]; then fStepEnd; fi

	## Stage 4: tests (conformance corpus + fuzz smoke + anything else config wires in),
	## then the cross-binding differential check: every binding CLI must agree with
	## every other, byte for byte, on the corpus AND on a freshly fuzz-dumped input set.
	## With one binding it is a no-op note; it gets teeth the day a second binding arrives.
	## Last comes the large-document gate - the same agreement plus time and memory
	## ceilings, at a size no corpus case can reach.
	if fStepOn tests; then fStepStart tests; fi
	## A backlog run's areas can leave the one or the other.
	if ((${#TEST_CMD[@]} + ${#TEST_EXTRA[@]})); then
		if ((${#TEST_CMD[@]})); then fStep "${TEST_CMD[@]}"; fi
		fRunExtras "${TEST_EXTRA[@]}"
		fEcho "OK: tests passed"
	fi
	if ((${#BINDING_CLIS[@]})) && ((! xcheck_enable)); then
		fEcho_Clean "crosscheck skipped (${quick_flag})"
	elif ((${#BINDING_CLIS[@]})); then
		xcheck_extra=()
		if ((${#BINDING_CLIS[@]} >= 2)) && [[ -n "${XCHECK_GEN:-}" ]]; then
			export XCHECK_DUMP_DIR="${root}/cicd/artifacts/crosscheck"
			rm -rf "${XCHECK_DUMP_DIR}"; mkdir -p "${XCHECK_DUMP_DIR}"
			fCpuStep "${XCHECK_GEN}"; eval "${XCHECK_GEN}"
			xcheck_extra=(--extra "${XCHECK_DUMP_DIR}")
		fi
		fStep "${here}/utility/crosscheck.bash" --corpus "${root}/project/conformance" "${xcheck_extra[@]}" "${BINDING_CLIS[@]}"
		if ((LARGEDOC_MIB)); then
			fStep "${here}/utility/largedoc.bash" --mib "${LARGEDOC_MIB}" "${BINDING_CLIS[@]}"
		fi
	fi
	## Last, since the slowest of them takes hours and the rest should report first.
	if ((${#LEAKCHECK_STEPS[@]})); then
		fRunExtras --hard "${LEAKCHECK_STEPS[@]}"
		fEcho "OK: leak checks passed"
	fi
	if [[ "${step_open}" == tests ]]; then fStepEnd; fi
	## Stage 5: profiler. Non-gating artifact, not a pass/fail test: an optimized
	## build with symbols runs a heavy workload under an in-process sampler (kernel
	## perf is locked down on this box) and writes a flamegraph SVG, gfs-rotated like
	## the run logs; flame-report.py prints the hot spots into the log. Environmental
	## problems skip with a warning; a build or run failure is the app's fault -> die.
	if fStepOn profile; then fStepStart profile; fi
	if ((PROFILE_ENABLE)); then
		fEcho_Clean "building: ${PROFILE_BUILD_CMD[*]}"
		fStep "${PROFILE_BUILD_CMD[@]}" || fDie "profiler build failed (app problem)"
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
		## The calibration alone, on the config's cheaper build, since the graph's
		## attribution is otherwise unchecked under --merge-gate. It runs offline, and a
		## cache without the sampler's crates is a noted skip rather than a fetch.
		if ((gate_mode)) && [[ -n "${PROFILE_CHECK:-}" ]] && declare -p PROFILE_CHECK_BUILD_CMD &>/dev/null && ((${#PROFILE_CHECK_BUILD_CMD[@]})); then
			if "${PROFILE_CHECK_PROBE_CMD[@]}" >/dev/null 2>&1; then
				fEcho_Clean "building: ${PROFILE_CHECK_BUILD_CMD[*]}"
				fStep "${PROFILE_CHECK_BUILD_CMD[@]}" || fDie "profiler check build failed (app problem)"
				( PROFILE_BIN="${PROFILE_CHECK_BIN}"; eval "${PROFILE_CHECK}" ) \
					|| fDie "profiler attribution check failed; its graph would name the wrong code"
			else
				fEcho_Clean "profiler attribution check skipped: the sampler's crates are not in the local cache"
				echo profiler-check >> "${SHCL_GATE_SKIPS}"
			fi
		fi
	fi
	if [[ "${step_open}" == profile ]]; then fStepEnd; fi

	## Stage 6: native release + cross targets, collected under versioned names plus
	## a sha256 checksums file, ready to attach to a release as plain uploads.
	## Naming (stable; download links depend on it): <exe>-<version>-<os-arch>[.exe]
	if fStepOn release; then fStepStart release; fi
	built_arts=()   ## <os-arch>|<path> per built binary; stage 7 dogfoods off it too
	## Cross-compile checks that produce no artifact: the other bindings' own
	## platform branches. Without these the C header's Windows path is never
	## compiled here at all, which is exactly how a build-breaking regression in it
	## reached dev unnoticed. They are checks, not builds, so they run whenever
	## correctness is gated - they sat inside the release branch below for a month,
	## which meant the gate, the one run that decides whether a commit reaches main,
	## compiled none of them.
	for c in "${CROSS_CHECKS[@]}"; do
		c_label="${c%%|*}"; c_cmd="${c#*|}"
		fEcho "cross check: ${c_label}"
		fCpuStep "${c_cmd}"; eval "${c_cmd}" || fDie "cross check failed: ${c_label}"
		fEcho "OK: ${c_label}"
	done
	## The record waits for the cross checks, the last gate before the release. It sat at
	## the end of stage 4 once they moved under the gate, so a run that then failed one
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
		## the same bytes. Only these builds have it: the gate's own builds stay
		## unstamped, the same as the other three CLIs they are compared against.
		SHCL_BUILD="$(fBuildNumber "$(git -C "${root}" log -1 --format=%ct)")" || fDie "no build number from the commit time"
		export SHCL_BUILD
		## A build whose version is already tagged is a dev build, so it shows its
		## date. A release is built from the bump commit, before its tag exists.
		SHCL_BUILD_DATED=""
		if git -C "${root}" rev-parse -q --verify "refs/tags/v$(fVersion)" >/dev/null; then SHCL_BUILD_DATED=1; fi
		export SHCL_BUILD_DATED
		fEcho "build ${SHCL_BUILD}${SHCL_BUILD_DATED:+ (dated)}"
		fStep "${RELEASE_NATIVE_CMD[@]}"
		[[ -f "${RELEASE_NATIVE_BIN}" ]] || fDie "native release binary missing: ${RELEASE_NATIVE_BIN}"
		fEcho "OK: native release: ${RELEASE_NATIVE_BIN} ($(du -h --apparent-size "${RELEASE_NATIVE_BIN}" | cut -f1))"
		built_arts=("${RELEASE_NATIVE_OSARCH:-native}|${RELEASE_NATIVE_BIN}")
		for t in "${CROSS_TARGETS[@]}"; do
			t_label="${t%%|*}"; rest="${t#*|}"; t_osarch="${rest%%|*}"; rest="${rest#*|}"; t_art="${rest%%|*}"; t_cmd="${rest#*|}"
			fEcho "cross: ${t_label}"
			fCpuStep "${t_cmd}"; eval "${t_cmd}"
			[[ -f "${t_art}" ]] || fDie "missing artifact for ${t_label}: ${t_art}"
			fEcho "OK: ${t_label}: ${t_art} ($(du -h --apparent-size "${t_art}" | cut -f1))"
			built_arts+=("${t_osarch}|${t_art}")
		done
		unset SHCL_BUILD SHCL_BUILD_DATED
		## Before anything is collected, so a build that fails one never reaches
		## the artifact dir. built_arts is in scope for the commands.
		for c in "${RELEASE_CHECKS[@]}"; do
			c_label="${c%%|*}"; c_cmd="${c#*|}"
			fEcho "release check: ${c_label}"
			fCpuStep "${c_cmd}"; eval "${c_cmd}" || fDie "release check failed: ${c_label}"
			fEcho "OK: ${c_label}"
		done
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
			((PACKAGE_ENABLE)) && fStep "${here}/utility/package.bash" "${root}" "${art_dir}" "${ver}"
			## The drop-in sources, man page and completions the installer
			## lays down, as one asset in the same family - so they are covered by the
			## signed sums like everything else. The installer used to take them from
			## GitHub's generated source tarball, which has no signature and no
			## checksum. The modes are set outright: a checkout under umask 077 has no
			## group or other bits, and only the execute bit comes from git.
			( cd "${root}" && tar --sort=name --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
				--mtime="@${SOURCE_DATE_EPOCH}" -cf - \
				source/rust/src/lib.rs source/go/shcl.go source/python/shcl.py \
				source/c/shcl.h source/c/shcl.hpp \
				source/man/shcl.1 source/completions/shcl.bash source/completions/_shcl \
				| gzip -n -9 > "${art_dir}/${EXE_NAME}-${ver}-dropins.tar.gz" )
			fWriteSums
			fEcho "OK: ${#built_arts[@]} release artifact(s) + ${sums} -> ${RELEASE_ARTIFACT_DIR}/"
			((${#CROSS_TARGETS[@]})) || fEcho_Clean "note: cross targets skipped - artifact set is partial (native only)"
		fi
	elif [[ "${step_open}" == release ]]; then
		fEcho_Clean "release builds skipped; cross checks only"
	fi
	if [[ "${step_open}" == release ]]; then fStepEnd; fi
fi

## The test boxes, here whichever way stages 1-6 ran, since the host lock and
## the ssh keys are on this box (2026102419263412). A box that isn't there is a
## SKIP, and the run goes on; the summary at the end names it again.
## fBoxRow ROW: a REMOTE_BOXES row as check-boxes.bash takes it, the os-arch
## swapped for its build and its suites words made one: suites for all of them,
## or suites=LIST. suites-long[=LIST] counts only under --long, for a box too
## slow to run them all every run (2026102419263422). A word it doesn't know
## goes on as it is, for check-boxes.bash to refuse.
fBoxRow(){
	local box target osarch rest w n all=0 list="" other=""
	local -a words=() names=()
	IFS='|' read -r box target osarch rest <<< "$1"
	IFS='|' read -ra words <<< "${rest}"
	for w in "${words[@]}"; do
		case "${w}" in suites-long|suites-long=*) if ((long_run)); then w="suites${w#suites-long}"; else continue; fi ;; esac
		case "${w}" in
			suites) all=1 ;;
			suites=?*) IFS=',' read -ra names <<< "${w#suites=}"
				for n in "${names[@]}"; do [[ ",${list}," == *",${n},"* ]] || list+="${list:+,}${n}"; done ;;
			*) other+="|${w}" ;;
		esac
	done
	if ((all)); then list=suites; elif [[ -n "${list}" ]]; then list="suites=${list}"; fi
	printf '%s\n' "${box}|${target}|$(fArtOf "${osarch}")${list:+|${list}}${other}"
}
if fStepOn boxes; then
	fStepStart boxes
	if [[ ! -f "${RELEASE_NATIVE_BIN:-/nonexist}" ]] || ((${#built_arts[@]} == 0)); then
		for r in "${REMOTE_BOXES[@]}"; do
			remote_skips+=("SKIP ${r%%|*}: no release builds this run")
			printf '%s\n' "${remote_skips[-1]}"
		done
	else
		box_rows=()
		for r in "${REMOTE_BOXES[@]}"; do box_rows+=("$(fBoxRow "${r}")"); done
		box_rc=0; fCpuStep check-boxes.bash
		"${here}/utility/check-boxes.bash" "${RELEASE_NATIVE_BIN}" "${box_rows[@]}" 2>&1 | tee "${run_tmp}/boxes.out" || box_rc=$?
		mapfile -t box_skips < <(grep '^SKIP ' "${run_tmp}/boxes.out" || true)
		remote_skips+=("${box_skips[@]}")
		((box_rc == 0)) || fDie "a test box check failed"
		fEcho "OK: test boxes"
	fi
	fStepEnd
fi

## The GitHub job started before stage 1. HOSTED_WAIT_MINS caps the wait, and
## SHCL_HOSTED_POLL sets the seconds between looks, for a test.
if fStepOn hostedwait; then
	fStepStart hostedwait
	h_state=""; h_status=""; h_conclusion=""; h_url=""; h_waited=0; h_poll="${SHCL_HOSTED_POLL:-30}"
	h_cap=$((${HOSTED_WAIT_MINS:-60} * 60))
	[[ "${h_poll}" =~ ^[0-9]{1,4}$ ]] || h_poll=30
	if [[ -n "${hosted_branch}" ]]; then
		## GitHub lists a dispatched run some seconds after it's asked for.
		while [[ -z "${hosted_run}" ]]; do
			hosted_run="$(fHostedGh run list --workflow "${HOSTED_WORKFLOW}" --branch "${hosted_branch}" --event workflow_dispatch --commit "${hosted_sha}" \
				--json databaseId,createdAt --jq "map(select(.createdAt >= \"${hosted_since}\")) | .[0].databaseId // empty" 2>/dev/null)" || hosted_run=""
			[[ -z "${hosted_run}" ]] || break
			if ((h_waited >= 120)); then hosted_skip="GitHub listed no run of it 2 minutes after it was started"; break; fi
			sleep "${h_poll}"; h_waited=$((h_waited + (h_poll > 0 ? h_poll : 10)))
		done
	fi
	h_waited=0
	while [[ -n "${hosted_branch}" && -z "${hosted_skip}" ]]; do
		h_state="$(fHostedGh run view "${hosted_run}" --json status,conclusion,url --jq '.status + "|" + .conclusion + "|" + .url' 2>/dev/null)" || h_state=""
		IFS='|' read -r h_status h_conclusion h_url <<< "${h_state}" || true
		[[ "${h_status}" != completed ]] || break
		if ((h_waited == 0)); then fEcho_Clean "waiting on ${h_url:-run ${hosted_run}}"; fi
		if ((h_waited >= h_cap)); then hosted_skip="still ${h_status:-unknown} after $((h_cap / 60)) minutes: ${h_url:-run ${hosted_run}}"; break; fi
		sleep "${h_poll}"; h_waited=$((h_waited + (h_poll > 0 ? h_poll : 30)))
	done
	## The workflow cancels a run on the branch when a newer one of it starts.
	## GitHub's word for it has the British spelling, which check-docs refuses.
	if [[ -z "${hosted_skip}" && "${h_conclusion}" == cancel* ]]; then hosted_skip="canceled on GitHub: ${h_url}"; fi
	if [[ -n "${hosted_branch}" && -n "${hosted_skip}" ]]; then
		remote_skips+=("SKIP GitHub ${HOSTED_JOB} job: ${hosted_skip}")
		printf '%s\n' "${remote_skips[-1]}"
	elif [[ -n "${hosted_skip}" ]]; then
		fEcho_Clean "not started: ${hosted_skip}"
	else
		[[ "${h_conclusion}" == success ]] || fDie "the ${HOSTED_JOB} job ended ${h_conclusion:-unknown} on GitHub: ${h_url}"
		fEcho "OK: the ${HOSTED_JOB} job on GitHub: ${h_url}"
	fi
	fStepEnd
fi

## Stage 7: dogfood - drop the freshly built optimized native binary into the first
## existing+writable fixed dest, under EXE_NAME, so the copy launched by hand stays
## current. Each cross-built binary goes to its own per-os-arch dest where one is
## configured.
## Skipped when no release binary was built (e.g. --backlog-run-quick) or the dest list is empty.
## No sudo: a non-writable dest is passed over with a warning, never force-installed.
if fStepOn dogfood; then
	fStepStart dogfood
fi
if fStepOn dogfood && [[ -f "${RELEASE_NATIVE_BIN:-/nonexist}" ]]; then
	dogfood_dest="$(fFirstWritableDir "${DOGFOOD_FIXED_DESTS[@]}")"
	if [[ -n "$dogfood_dest" ]] && fInUse "${dogfood_dest}/${EXE_NAME}"; then
		fEcho "WARNING: ${dogfood_dest}/${EXE_NAME} is running; dogfood copy skipped"
	elif [[ -n "$dogfood_dest" ]]; then
		fInstallAtomic "${RELEASE_NATIVE_BIN}" "$dogfood_dest" "${EXE_NAME}"
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
elif fStepOn dogfood; then
	fEcho "WARNING: no release binary at ${RELEASE_NATIVE_BIN}; dogfood skipped"
fi
if [[ "${step_open}" == dogfood ]]; then fStepEnd; fi

## Stage 8: demo gif for the README (non-gating: a missing Pillow/font/etc. skips).
## Renders into the rotated private/ store (gfs-kept), then copies the newest onto
## the committed GIF_OUT. If that store is unreachable (no private tree), render
## straight to GIF_OUT and skip rotation.
if fStepOn gif; then
	fStepStart gif
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
		fEcho "OK: demo gif -> ${GIF_OUT} ($(du -h --apparent-size "${root}/${GIF_OUT}" | cut -f1))"
	else
		fEcho "WARNING: demo gif skipped (non-fatal)"
	fi
	fStepEnd
fi

## Stage 9: backup + publish via the standalone publisher.
if fStepOn publish; then
	fStepStart publish
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
	## An installer fix reaches nobody until it is on main: the install doc's
	## one-liners fetch the scripts from there as they run, so a fix that stays
	## on dev is the one drift every user meets. Judged after the publish so a
	## dev run that has one goes red until the docs-only merge to main.
	if [[ "$(git branch --show-current)" == dev ]] && git rev-parse -q --verify origin/main >/dev/null 2>&1; then
		installer_drift="$(git diff --stat origin/main -- install.bash install.ps1 install-dev.bash || true)"
		[[ -z "${installer_drift}" ]] || fDie "the installers differ from origin/main; merge them to main under the docs-only rule:"$'\n'"${installer_drift}"
	fi
	fStepEnd
fi

## What's gone stale that the pipeline made, then this run's temp dir, in one
## line. The run inside the image leaves it to the run outside, which also
## removes its scratch.
fCleanup(){
	local -a gone=()
	local -i kb=0 sidecars=0 kbTmp=0
	local f stamp size profDir bytes what dfBefore="" dfAfter="" dfLine=""
	if ((inner_run)); then fRmRunTmp; return 0; fi
	fFrozenGone || true
	## A graph the rotation pruned leaves its sample count behind, under the
	## role it was born with.
	profDir="${root}/${PROFILE_OUT_DIR:-}"
	if [[ -n "${PROFILE_OUT_DIR:-}" && -d "${profDir}" ]]; then
		for f in "${profDir}"/flame_*.svg.samples; do
			[[ -f "${f}" && ! -L "${f}" ]] || continue
			stamp="${f##*/flame_}"; stamp="${stamp%%_*}"
			[[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
			if compgen -G "${profDir}/flame_${stamp}_*.svg" >/dev/null; then continue; fi
			size="$(stat -c %s -- "${f}" 2>/dev/null || true)"
			rm -f -- "${f}" || continue
			sidecars+=1
			if [[ "${size}" =~ ^[0-9]{1,15}$ ]]; then kb+=$(((size + 1023) / 1024)); fi
		done
		if ((sidecars)); then gone+=("${sidecars} profiler sample file(s) whose graph is gone"); fi
	fi
	## --keep-temp keeps this run's containers, which the sweep would take.
	if [[ -n "${ctr_image}" ]] && ((! keep_temp)); then
		mkdir -p "${run_tmp}/sweep"
		dfBefore="$(fCtrDf)"
		while IFS=$'\t' read -r bytes what; do
			gone+=("${what}")
			if [[ "${bytes}" =~ ^[0-9]{1,15}$ ]]; then kb+=$((bytes / 1024)); fi
		done < <(fCtrSweep "${run_tmp}/sweep" || true; fCtrZigTrim "${ctr_tag}" || true)
		## A week of build cache stays, for every project on the box.
		"${SHCL_DOCKER:-docker}" builder prune -f --filter until=168h >/dev/null 2>&1 || true
		dfAfter="$(fCtrDf)"
		dfLine="$(paste <(printf '%s\n' "${dfBefore}") <(printf '%s\n' "${dfAfter}") \
			| awk -F'\t' '$1 != "" && $1 == $3 { t = tolower($1); sub(/^local /, "", t); printf "%s%s %s -> %s", (n++ ? ", " : "; docker "), t, $2, $4 }')"
	fi
	if ((keep_temp)); then
		if ((${#gone[@]})); then fEcho_Clean "cleanup: removed $(printf '%s, ' "${gone[@]}" | sed 's/, $//'), about $(fSize "${kb}")"; fi
		fRmRunTmp
		return 0
	fi
	kbTmp="$(du -sk -- "${run_tmp}" 2>/dev/null | cut -f1)" || kbTmp=0
	kb+=kbTmp
	fRmRunTmp
	gone+=("this run's temp files")
	fEcho_Clean "cleanup: removed $(printf '%s, ' "${gone[@]}" | sed 's/, $//'), about $(fSize "${kb}")${dfLine}"
}
fCleanup

## The run that started this one says it's done, after its own steps.
if ((! inner_run)); then
	fSection "${APP_NAME} CI/CD: done."
	for s in "${remote_skips[@]}"; do fEcho_Clean "${s}"; done
	fEcho_Clean
fi
exit 0
}


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
##		- 2026-10-08 JC: The shell wrappers are retired: out of the drop-ins tarball and the dogfood stage.
##		- 2026-10-13 JC: --no-tests, so the hosted gate can run lint and tests as parallel jobs.
##		- 2026-10-13 JC: --container runs stages 1-6 in a pinned image, and --container=NAME in an extra one. --no-release.
##		- 2026-10-16 JC: An extra image's own copies go where their paths lead, files included, with
##		  a stand-in for a missing one. --no-tests drops the calibration only under --ci.
##		- 2026-10-19 JC: --ci is --gate now. --quick runs every step but the ones config's QUICK_SKIP names, cross targets included.
##		- 2026-10-19 JC: --leakcheck, and config's LEAKCHECK_STEPS at the end of the tests stage of a run with no flags.
##		- 2026-10-19 JC: --no-leakcheck, refused beside --leakcheck.
##		- 2026-10-19 JC: Stages 1-6 run in the main image whenever docker answers. --no-container.
##		- 2026-10-19 JC: A temp dir per run, and a cleanup of stale images, containers and profiler sample files at the end.
##		- 2026-10-24 JC: Zig's cache in the main image is a volume of its own, emptied at the end when it's over 2 GB or another Zig filled it.
##		- 2026-10-24 JC: dev.project and dev.run labels and names on what docker makes; a run's containers go on any exit. The tag
##		  before the current one stays, a week of build cache stays, and the cleanup line has docker system df before and after.
##		- 2026-10-24 JC: The CPU cap is checked again before each step: a quarter when the box is busy or the step is hard,
##		  and the run at nice 19 and idle I/O.
##		- 2026-10-25 JC: --long and --slow. The leak checks that take hours are only there and in --leakcheck, --quick keeps
##		  the fast ones, and --no-leakcheck drops the sanitizer runs too. Sizes printed are the files' own.
##		- 2026-10-25 JC: --merge-gate, every check of a run with no flags, for the pre-push hook. --ci is another name for it.
##		- 2026-10-28 JC: --backlog-run-quick with areas, and --backlog-run-full. One run mode per run.
##		- 2026-10-25 JC: --keep-temp keeps the run's temp folder and containers. --list prints the steps and runs nothing.
##		- 2026-10-25 JC: Each step opens with a Starting line and closes with PASS or FAIL, as Step N of M with the time, under a
##		  79-wide rule. Steps that are off aren't counted, and the first section names them with the flag or reason.
##		- 2026-10-28 JC: The run in the image gets this box's zone, so its step lines are in local time too.
##		- 2026-10-28 JC: --skip TEXT leaves out each step that holds TEXT, and the run records nothing. The hosted run skips CodeQL.
##		- 2026-10-29 JC: --gate is another name for --backlog-run-quick, so it records no tree.
##		- 2026-10-30 JC: --list prints the test IDs each step runs under it.
##		- 2026-10-30 JC: A REMOTE_BOXES row's suites-long runs that box's suites only under --long.
##		- 2026-10-30 JC: suites=LIST and suites-long=LIST name some of a box's suites, so vmDebARM64 runs Go every run.
##		- 2026-10-30 JC: A run with no flags, --long and the full run modes start HOSTED_JOB on GitHub first and wait for it last.
