#!/usr/bin/env bash

##	Purpose:
##		Check the pre-push hook's skip for a tree a gate already passed, on a
##		throwaway repository with the gate stubbed out. The tree green-tree.bash
##		computes has to be the one a commit of the working copy gets, a recorded
##		tree has to let the hook through without the gate, and a push to main
##		with nothing recorded still has to run it. A skip that fires when it
##		should not is a push that reaches main untested, and nothing downstream
##		would say so. Only main is gated, so every other ref is checked for the
##		gate not running at all.
##	Syntax:
##		check-push-gate.bash
##	Exit: 0 = all checks pass, 1 = a check failed (named), 2 = cannot set up.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=check-push-gate; testCounter=nFail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="${root}/cicd/utility/green-tree.bash"
for f in "${helper}" "${root}/cicd/hooks/pre-push" "${root}/.gitignore"; do
	[[ -r "${f}" ]] || { echo "check-push-gate: cannot read ${f}" >&2; exit 2; }
done

## No global or system config reaches the throwaway repository: identity rules,
## a hooks path or commit signing there would change what is being checked.
unset GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE SHCL_SKIP_HOOK SHCL_GATE_RERUN STUB_RC
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.invalid
export GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.invalid

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
## The hook's worktrees and the helper's scratch index go in here too.
export TMPDIR="${work}"

rc=0; declare -i nFail=0
fail() { echo "check-push-gate: FAIL: $*" >&2; rc=1; nFail+=1; }
repo="${work}/repo"
zeros=0000000000000000000000000000000000000000

git init -q -b dev "${repo}" || { echo "check-push-gate: git init failed" >&2; exit 2; }
mkdir -p "${repo}/cicd/hooks" "${repo}/cicd/utility" "${repo}/source/rust"
cp "${root}/cicd/hooks/pre-push" "${repo}/cicd/hooks/pre-push"
cp "${helper}" "${repo}/cicd/utility/green-tree.bash"
cp "${root}/.gitignore" "${repo}/.gitignore"
cat > "${repo}/cicd/cicd.bash" <<'EOF'
#!/usr/bin/env bash
echo "ran ${SHCL_GATE_REF:-}" >> "${STUB_LOG}"
echo "$*" > "${STUB_LOG}.args"
echo "${GIT_DIR:-unset}" > "${STUB_LOG}.gitdir"
here="$(cd "$(dirname "$0")/.." && pwd)"
readlink "${here}/source/rust/target" > "${STUB_LOG}.target" || echo none > "${STUB_LOG}.target"
git -C "${here}" rev-parse HEAD >> "${STUB_LOG}.head"
exit "${STUB_RC:-0}"
EOF
printf 'one\n' > "${repo}/a.txt"
printf 'gone\n' > "${repo}/c.txt"
printf '#!/bin/sh\n' > "${repo}/x.sh"
: > "${repo}/source/rust/.keep"
chmod +x "${repo}/cicd/cicd.bash" "${repo}/cicd/hooks/pre-push" "${repo}/cicd/utility/green-tree.bash" "${repo}/x.sh"
{ git -C "${repo}" add --all && git -C "${repo}" commit -q -m base; } || { echo "check-push-gate: first commit failed" >&2; exit 2; }
helper="${repo}/cicd/utility/green-tree.bash"

fTest EpsjpdQ the tree matches a commit of the working copy
## Every kind of change a commit of the working copy picks up: an edit, a new
## file, a deletion, a mode, and an ignored file that must stay out. a.txt is
## staged and then edited again, so the index and the disk disagree.
printf 'two\n' > "${repo}/a.txt"
git -C "${repo}" add a.txt
printf 'three\n' > "${repo}/a.txt"
printf 'new\n' > "${repo}/b.txt"
rm "${repo}/c.txt"
chmod -x "${repo}/x.sh"
mkdir -p "${repo}/cicd/artifacts" && printf 'junk\n' > "${repo}/cicd/artifacts/junk"
staged="$(git -C "${repo}" diff --cached --name-only)"
tree="$("${helper}" tree "${repo}")" || fail "tree exited non-zero on a dirty working copy"
[[ "$(git -C "${repo}" diff --cached --name-only)" == "${staged}" ]] || fail "tree changed the real index"
git -C "${repo}" add --all && git -C "${repo}" commit -q -m work
head="$(git -C "${repo}" rev-parse 'HEAD^{tree}')"
[[ "${tree}" == "${head}" ]] || fail "tree gave ${tree}, and a commit of the same working copy got ${head}"

fTest EpsjpdR a target link in a worktree leaves the tree, and records reach it
## The hook gates inside a worktree with a target link of its own added. The
## tree there has to be the commit's, or the run it starts can never record.
git -C "${repo}" worktree add -q --detach "${work}/wt" HEAD
ln -s "${repo}/source/rust/target-gate" "${work}/wt/source/rust/target"
[[ "$("${helper}" tree "${work}/wt" || true)" == "${head}" ]] || fail "the target link the hook adds to its worktree changes the tree"

if "${helper}" passed "${repo}" "${head}"; then fail "a tree nothing recorded passed"; fi
"${helper}" record "${repo}" "${head}" || fail "record refused the tree the working copy holds"
"${helper}" passed "${repo}" "${head}" || fail "a recorded tree did not pass"
"${helper}" passed "${work}/wt" "${head}" || fail "a worktree does not see its clone's recorded trees"
git -C "${repo}" worktree remove --force "${work}/wt"

fTest EpsjpdS a tree that moved mid-run is not recorded
## Files that change between the start of a run and its end: nothing recorded.
printf 'four\n' > "${repo}/a.txt"
moved="$("${helper}" tree "${repo}")"
printf 'five\n' > "${repo}/a.txt"
if "${helper}" record "${repo}" "${moved}" 2>/dev/null; then fail "recorded a tree the working copy no longer holds"; fi
if "${helper}" passed "${repo}" "${moved}"; then fail "a tree refused at record time passed anyway"; fi
git -C "${repo}" checkout -q -- a.txt

fTest EpsjpdT passed refuses what is not a tree hash
## Not a tree hash, so it never reaches the pattern: '.*' would match any line.
prc=0; "${helper}" passed "${repo}" '.*' 2>/dev/null || prc=$?
((prc == 2)) || fail "passed took '.*' as a tree (exit ${prc})"

export STUB_LOG="${work}/stub.log"
fPushLines(){  ## fPushLines LINES -> hookRc, hookOut, ran (times the stubbed gate ran)
	: > "${STUB_LOG}"; : > "${STUB_LOG}.head"
	hookRc=0
	hookOut="$(printf '%s' "$1" | bash "${repo}/cicd/hooks/pre-push" 2>&1)" || hookRc=$?
	ran="$(wc -l < "${STUB_LOG}")"
}
fPush(){ fPushLines "$(printf 'refs/heads/x %s refs/heads/%s %s' "$2" "$1" "${zeros}")"$'\n' ;}  ## fPush BRANCH SHA

printf 'six\n' > "${repo}/d.txt"
git -C "${repo}" add d.txt && git -C "${repo}" commit -q -m six
sha="$(git -C "${repo}" rev-parse HEAD)"

fTest Eq31fgG a push to main runs the gate
fPush main "${sha}"
((hookRc == 0 && ran == 1)) || fail "a commit nothing recorded, pushed to main: exit ${hookRc}, gate ran ${ran} time(s)"
fTest EqGjDtg the hook tells the gate it stands in for main
## 20260918 item 6: the installer drift check judges the tree as main only
## when the gate is told that is what it stands in for.
grep -qx 'ran main' "${STUB_LOG}" || fail "the hook did not tell the gate it stands in for main: $(cat "${STUB_LOG}")"
fTest EqGl8me the hook calls the full gate
## 20260918 item 24: the stub ran whatever it was asked to, so the hook could
## have called a quick or partial gate and passed here all the same.
[[ "$(cat "${STUB_LOG}.args")" == "--ci --no-largedoc" ]] || fail "the hook called the gate as: $(cat "${STUB_LOG}.args")"
fTest EqzwPFC the gate builds into target-gate
## 20260830 item 5: the gate's worktree got the checkout's own target dir, so
## its build baked the worktree's path into the checkout's test binaries.
[[ "$(cat "${STUB_LOG}.target")" == */source/rust/target-gate ]] \
	|| fail "the hook linked the gate's target dir to $(cat "${STUB_LOG}.target"), not the checkout's target-gate"
fTest EpsjpdU a red gate refuses the push
export STUB_RC=1; fPush main "${sha}"; unset STUB_RC
((hookRc == 1)) || fail "a red gate did not refuse the push (exit ${hookRc})"
fTest EpsjpdV a feature or dev push runs no gate
fPush feature "${sha}"
((hookRc == 0 && ran == 0)) || fail "a feature branch push: exit ${hookRc}, gate ran ${ran} time(s)"
fPush dev "${sha}"
((hookRc == 0 && ran == 0)) || fail "a commit nothing recorded, pushed to dev: exit ${hookRc}, gate ran ${ran} time(s)"
fTest EqzwPFD a multi-ref push gates the main commit once
## 20260830 item 6: only the last ref of a multi-ref push was gated. Main
## first and a feature ref after it: the gate runs once, on main's commit.
fPushLines "$(printf 'refs/heads/x %s refs/heads/main %s\nrefs/heads/y %s refs/heads/feature %s\n' "${sha}" "${zeros}" "$(git -C "${repo}" rev-parse HEAD~1)" "${zeros}")"$'\n'
((hookRc == 0 && ran == 1)) && [[ "$(cat "${STUB_LOG}.head")" == "${sha}" ]] \
	|| fail "a push of main and a feature ref: exit ${hookRc}, gate ran ${ran} time(s), on $(tr '\n' ' ' < "${STUB_LOG}.head")"

fTest EpsjpdW a recorded tree skips the gate unless asked to rerun
"${helper}" record "${repo}" "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" || fail "record refused a clean checkout"
fPush main "${sha}"
((hookRc == 0 && ran == 0)) || fail "a recorded tree, pushed to main: exit ${hookRc}, gate ran ${ran} time(s)"
[[ "${hookOut}" == *"not running it again"* ]] || fail "the hook let a recorded tree through without saying so: ${hookOut}"
export SHCL_GATE_RERUN=1; fPush main "${sha}"; unset SHCL_GATE_RERUN
((hookRc == 0 && ran == 1)) || fail "SHCL_GATE_RERUN=1 on a recorded tree: exit ${hookRc}, gate ran ${ran} time(s)"

fTest Er839pf a recorded tree whose installers differ from dev is gated on main
## 20260926 item 13: a run that recorded the tree may have compared the
## installers for another ref. Pushed to main, a tree that differs from dev's
## installers runs the gate, recorded or not.
printf 'dev copy\n' > "${repo}/install.bash"
git -C "${repo}" add install.bash && git -C "${repo}" commit -q -m devinstall
git -C "${repo}" update-ref refs/remotes/origin/dev "$(git -C "${repo}" rev-parse HEAD)"
printf 'main copy\n' > "${repo}/install.bash"
git -C "${repo}" commit -q -am mainonly
drift="$(git -C "${repo}" rev-parse HEAD)"
"${helper}" record "${repo}" "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" || fail "record refused the drifted tree"
fPush main "${drift}"
((hookRc == 0 && ran == 1)) || fail "a recorded tree whose installer differs from dev, pushed to main: exit ${hookRc}, gate ran ${ran} time(s)"
git -C "${repo}" reset -q --hard "${sha}"
git -C "${repo}" update-ref -d refs/remotes/origin/dev
fPush main "${sha}"
((hookRc == 0 && ran == 0)) || fail "a recorded tree with no origin/dev, pushed to main: exit ${hookRc}, gate ran ${ran} time(s)"

fTest EpsjpdX a missing helper reads as not passed
## A checkout from before the helper existed has none, which reads as not passed.
mv "${helper}" "${helper}.off"
fPush main "${sha}"
mv "${helper}.off" "${helper}"
((hookRc == 0 && ran == 1)) || fail "with the helper missing: exit ${hookRc}, gate ran ${ran} time(s)"

fTest EpsjpdY a merge of a branch that passed skips the gate
## A --no-ff merge of a branch that passed, onto a branch that has not moved
## since, has the branch's tree.
git -C "${repo}" checkout -q -b topic
printf 'seven\n' > "${repo}/d.txt"
git -C "${repo}" commit -q -am seven
"${helper}" record "${repo}" "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" || fail "record refused the topic branch"
git -C "${repo}" checkout -q dev
git -C "${repo}" merge -q --no-ff -m "Merge topic" topic
fPush main "$(git -C "${repo}" rev-parse HEAD)"
((hookRc == 0 && ran == 0)) || fail "a merge of a branch that passed: exit ${hookRc}, gate ran ${ran} time(s)"

fTest EpsjpdZ a new tree after a recorded merge is gated on main only
## One more commit: a tree nobody ran, so main gates it and dev does not.
printf 'eight\n' > "${repo}/d.txt"
git -C "${repo}" commit -q -am eight
fPush main "$(git -C "${repo}" rev-parse HEAD)"
((hookRc == 0 && ran == 1)) || fail "a new tree after a recorded merge: exit ${hookRc}, gate ran ${ran} time(s)"
fPush dev "$(git -C "${repo}" rev-parse HEAD)"
((hookRc == 0 && ran == 0)) || fail "a new tree pushed to dev: exit ${hookRc}, gate ran ${ran} time(s)"

fTest Eq2y5mC a merge nobody ran is gated on main only
## A merge nobody ran, the everyday case: dev takes it, main gates it.
git -C "${repo}" checkout -q -b topic2
printf 'nine\n' > "${repo}/d.txt"
git -C "${repo}" commit -q -am nine
git -C "${repo}" checkout -q dev
git -C "${repo}" merge -q --no-ff -m "Merge topic2" topic2
merged="$(git -C "${repo}" rev-parse HEAD)"
fPush dev "${merged}"
((hookRc == 0 && ran == 0)) || fail "a merge pushed to dev: exit ${hookRc}, gate ran ${ran} time(s)"
fPush main "${merged}"
((hookRc == 0 && ran == 1)) || fail "a merge pushed to main: exit ${hookRc}, gate ran ${ran} time(s)"

fTest EqL1d4C GIT_DIR from a linked worktree does not reach the gate
## 20260918b item 2: a push from a linked worktree hands the hook GIT_DIR, and
## passed on to the gate it pointed every scratch repo the gate built at this
## one. This push goes through real git, since that is what sets it.
git init -q --bare "${work}/remote.git" || { echo "check-push-gate: git init failed" >&2; exit 2; }
git -C "${repo}" config core.hooksPath cicd/hooks
git -C "${repo}" worktree add -q -b linked "${work}/linked" HEAD
printf 'ten\n' > "${work}/linked/d.txt"
git -C "${work}/linked" commit -q -am ten
: > "${STUB_LOG}"; rm -f "${STUB_LOG}.gitdir"
linkedRc=0; git -C "${work}/linked" push -q "${work}/remote.git" HEAD:main > "${work}/linked.out" 2>&1 || linkedRc=$?
ran="$(wc -l < "${STUB_LOG}")"
((linkedRc == 0 && ran == 1)) || fail "a push to main from a linked worktree: exit ${linkedRc}, gate ran ${ran} time(s): $(tail -c 300 "${work}/linked.out")"
[[ "$(cat "${STUB_LOG}.gitdir" 2>/dev/null || true)" == unset ]] \
	|| fail "the hook passed GIT_DIR on to the gate from a linked worktree: $(cat "${STUB_LOG}.gitdir" 2>/dev/null || true)"
git -C "${repo}" config --unset core.hooksPath
git -C "${repo}" worktree remove --force "${work}/linked"

fTest EqGjDth the installer drift check judges the pushed tree as main
## 20260918 item 6: the installer drift check, on a clone of this repository
## with the refs as they stand between a dev push that changes an installer and
## the main push that follows it. The hook runs before git moves origin/main,
## so judged by the refs, the main push that ends the drift was refused.
clone="${work}/clone"
if git clone -q --shared --no-checkout "${root}" "${clone}" 2>/dev/null && git -C "${clone}" checkout -q --detach "$(git -C "${root}" rev-parse HEAD)" 2>/dev/null; then
	base="$(git -C "${clone}" rev-parse HEAD)"
	printf '# drift\n' >> "${clone}/install.bash"
	git -C "${clone}" commit -q -am drift
	moved="$(git -C "${clone}" rev-parse HEAD)"
	git -C "${clone}" update-ref refs/remotes/origin/main "${base}"
	git -C "${clone}" update-ref refs/remotes/origin/dev "${moved}"
	## The check under test is this checkout's, not the commit's, and so is
	## what it sources. The clone has no build, so its help checks skip; that
	## skip is the clone's, and neither fails nor gets noted in the run's own
	## skip list.
	fDocsCopy(){
		cp "${root}/cicd/utility/check-docs.bash" "${clone}/cicd/utility/check-docs.bash"
		mkdir -p "${clone}/cicd/utility/include"
		cp "${root}/cicd/utility/include/test-id.bash" "${clone}/cicd/utility/include/test-id.bash"
	}
	fDocsCopy
	fDocs(){ docsRc=0; docsOut="$(env -u SHCL_GATE_STRICT "$@" SHCL_GATE_SKIPS=/dev/null bash "${clone}/cicd/utility/check-docs.bash" 2>&1)" || docsRc=$? ;}
	fDocs -u SHCL_GATE_REF
	((docsRc == 1)) && [[ "${docsOut}" == *"installer on dev and not on main"*install.bash* ]] \
		|| fail "a run outside the hook did not see dev ahead of main: exit ${docsRc}"
	fDocs SHCL_GATE_REF=main
	((docsRc == 0)) || fail "the main push that brings the installers level was refused: exit ${docsRc}: $(tail -c 300 <<<"${docsOut}")"
	git -C "${clone}" checkout -q --detach "${base}"
	fDocsCopy
	fDocs SHCL_GATE_REF=main
	((docsRc == 1)) && [[ "${docsOut}" == *"between this push to main and dev"*install.bash* ]] \
		|| fail "a main push that leaves the installers behind dev went through: exit ${docsRc}: $(tail -c 300 <<<"${docsOut}")"
else
	fail "cannot clone ${root} for the installer drift check"
fi

fTest EqGl8mf only a full --ci run records its tree
## 20260918 item 24: the runs that must not record, through cicd.bash itself.
## A throwaway repository gets the real engine and config with every stage
## stubbed at the end of the config. A --ci run records its tree; a --quick
## run, a run with a stage left out, and a run whose gate noted a skip do not.
## Before this, taking out either hold-back failed nothing.
eng="${work}/eng"
git init -q -b dev "${eng}" || { echo "check-push-gate: git init failed" >&2; exit 2; }
mkdir -p "${eng}/cicd/utility/include" "${eng}/source/rust"
cp "${root}/cicd/cicd.bash" "${root}/cicd/config.bash" "${eng}/cicd/"
cp "${root}/cicd/utility/green-tree.bash" "${eng}/cicd/utility/"
cp "${root}/cicd/utility/include/gfs-rotate.bash" "${eng}/cicd/utility/include/"
cp "${root}/.gitignore" "${eng}/.gitignore"
printf '[package]\nname = "stub"\nversion = "1.0.0"\n' > "${eng}/source/rust/Cargo.toml"
cat >> "${eng}/cicd/config.bash" <<'CFG'
## check-push-gate: every stage stubbed.
FMT_CMD=(true); FMT_CHECK_CMD=(true); FMT_EXTRA=(); FMT_CHECK_EXTRA=()
BUILD_CMD=(true); BUILD_EXTRA=()
LINT_CMD=(true); LINT_EXTRA=(); SHELLCHECK_TARGETS=()
TEST_CMD=(true); TEST_QUICK_CMD=(true)
TEST_EXTRA=('if [[ -n "${STUB_SKIP:-}" ]]; then echo stub >> "${SHCL_GATE_SKIPS}"; fi' 'echo "${GIT_DIR:-unset}" > "${STUB_GITDIR:-/dev/null}"')
CROSS_CHECKS=('stub|[[ -z "${STUB_CROSS_FAIL:-}" ]]')
BINDING_CLIS=(); LARGEDOC_MIB=0; CROSS_TARGETS=(); PROFILE_ENABLE=0; PACKAGE_ENABLE=0; GIF_ENABLE=0
DOGFOOD_FIXED_DESTS=(); GIT_PUBLISH=(); RELEASE_NATIVE_CMD=()
PROFILE_CHECK_BUILD_CMD=()
CFG
{ git -C "${eng}" add --all && git -C "${eng}" commit -q -m base; } || { echo "check-push-gate: engine repo commit failed" >&2; exit 2; }
engTree="$(git -C "${eng}" rev-parse 'HEAD^{tree}')"
engRecords="${eng}/.git/shcl-green-trees"
fEngine(){  ## fEngine [VAR=VALUE ...] -- ARGS... -> engRc, engRecorded
	local envs=()
	while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
	rm -f "${engRecords}"
	engRc=0; env -u SHCL_GATE_STRICT -u SHCL_GATE_SKIPS "${envs[@]}" bash "${eng}/cicd/cicd.bash" "$@" > "${work}/eng.log" 2>&1 || engRc=$?
	engRecorded=0; if "${eng}/cicd/utility/green-tree.bash" passed "${eng}" "${engTree}"; then engRecorded=1; fi
}
fEngine -- --ci
((engRc == 0 && engRecorded == 1)) || fail "a stubbed --ci run: exit ${engRc}, recorded ${engRecorded}: $(tail -5 "${work}/eng.log")"
fEngine -- --ci --quick
((engRc == 0 && engRecorded == 0)) || fail "a --quick run: exit ${engRc}, recorded ${engRecorded}"
fEngine -- --ci --no-lint
((engRc == 0 && engRecorded == 0)) || fail "a run with lint left out: exit ${engRc}, recorded ${engRecorded}"
fEngine -- --ci --no-fmt
((engRc == 0 && engRecorded == 0)) || fail "a run with the format check left out: exit ${engRc}, recorded ${engRecorded}"
fEngine STUB_SKIP=1 -- --ci
((engRecorded == 0)) || fail "a run whose gate noted a skip recorded its tree"
fTest EqjfWm8 a run failing or leaving out the cross checks records nothing
## 20260923 item 1: the cross checks are the last gate, so a run failing one
## records nothing, and a run leaving them out is partial.
fEngine STUB_CROSS_FAIL=1 -- --ci
((engRc != 0 && engRecorded == 0)) || fail "a run failing a cross check: exit ${engRc}, recorded ${engRecorded}"
fEngine -- --ci --no-cross
((engRc == 0 && engRecorded == 0)) || fail "a run with the cross checks left out: exit ${engRc}, recorded ${engRecorded}"
fTest EqL1d4D cicd.bash clears GIT_DIR before its gates
## 20260918b item 2: a direct run with GIT_DIR exported clears it too.
fEngine GIT_DIR="${eng}/.git" STUB_GITDIR="${work}/eng.gitdir" -- --ci
[[ "$(cat "${work}/eng.gitdir" 2>/dev/null || true)" == unset ]] \
	|| fail "cicd.bash passed GIT_DIR on to its gates: $(cat "${work}/eng.gitdir" 2>/dev/null || true)"

fTestEnd
(( rc == 0 )) && echo "check-push-gate: OK: the tree matches a commit of the working copy, a recorded tree skips the gate, only a push to main runs it with the full gate, a red gate refuses, the gate builds into target-gate and runs once on main's commit in a multi-ref push, no gate sees a linked worktree's GIT_DIR, the drift check judges the pushed tree as main, and a partial run records nothing"
exit "${rc}"


##	History:
##		- 2026-09-14 JC: Created.
##		- 2026-09-16 JC: Only a push to main is gated.
##		- 2026-09-18 JC: The gate is told it stands in for main, and the
##		  installer drift check is run on a clone with the refs set as they
##		  are between the dev push and the main push.
##		- 2026-09-18 JC: The hook's gate flags are checked, and the engine's
##		  record hold-backs run for real on a stubbed repository.
##		- 2026-09-19 JC: A push from a linked worktree, and a direct run with
##		  GIT_DIR exported, must not hand GIT_DIR to the gate.
##		- 2026-09-26 JC: The gate's target link, and a push naming main and a
##		  feature ref.
