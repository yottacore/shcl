#!/usr/bin/env bash

##	Purpose:
##		Check the pre-push hook's skip for a tree a gate already passed, on a
##		throwaway repository with the gate stubbed out. The tree green-tree.bash
##		computes has to be the one a commit of the working copy gets, a recorded
##		tree has to let the hook through without the gate, and a push to main
##		with nothing recorded still has to run it. A skip that fires when it
##		should not is a push that reaches main untested, and nothing downstream
##		would say so. Only main is gated, so every other ref is checked for the
##		gate not running at all. cicd.bash itself runs on a stubbed repository
##		too: what keeps a run from recording, the profiler calibration, the
##		mounts an extra --container image asks for, and when a run goes to the
##		image at all.
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
mkdir -p "${repo}/cicd/hooks" "${repo}/cicd/utility/include" "${repo}/source/rust"
cp "${root}/cicd/hooks/pre-push" "${repo}/cicd/hooks/pre-push"
cp "${root}/cicd/utility/include/frozen-tree.bash" "${repo}/cicd/utility/include/"
cp "${helper}" "${repo}/cicd/utility/green-tree.bash"
cp "${root}/cicd/utility/check-banner-tag.bash" "${repo}/cicd/utility/check-banner-tag.bash"
cp "${root}/cicd/docs-only-paths.txt" "${repo}/cicd/docs-only-paths.txt"
cp "${root}/.gitignore" "${repo}/.gitignore"
cat > "${repo}/cicd/cicd.bash" <<'EOF'
#!/usr/bin/env bash
## --gate) is what the hook looks for in an engine that knows the flag.
## --merge-gate) likewise.
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
## A version below the banner's tag, so a push to main needs no tag until the
## cut commits below.
printf '[package]\nname = "stub"\nversion = "2.0.0"\n' > "${repo}/source/rust/Cargo.toml"
chmod +x "${repo}/cicd/cicd.bash" "${repo}/cicd/hooks/pre-push" "${repo}/cicd/utility/green-tree.bash" "${repo}/cicd/utility/check-banner-tag.bash" "${repo}/x.sh"
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
hookRemote=()  ## the remote git names to the hook; none until the banner tag checks
fPushLines(){  ## fPushLines LINES -> hookRc, hookOut, ran (times the stubbed gate ran)
	: > "${STUB_LOG}"; : > "${STUB_LOG}.head"
	hookRc=0
	hookOut="$(printf '%s' "$1" | bash "${repo}/cicd/hooks/pre-push" ${hookRemote[@]+"${hookRemote[@]}"} 2>&1)" || hookRc=$?
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
[[ "$(cat "${STUB_LOG}.args")" == "--merge-gate" ]] || fail "the hook called the gate as: $(cat "${STUB_LOG}.args")"
fTest EtkuOxf an engine from before --merge-gate is called with --gate
## 2026102515494619: the hook's gate is --merge-gate, every check of a run with
## no flags. An engine without it gets the gate it knew.
sed -i '/^## --merge-gate) /d' "${repo}/cicd/cicd.bash"
git -C "${repo}" commit -q -am gateengine
fPush main "$(git -C "${repo}" rev-parse HEAD)"
((hookRc == 0 && ran == 1)) && [[ "$(cat "${STUB_LOG}.args")" == "--gate --no-largedoc" ]] \
	|| fail "the hook called an engine from before --merge-gate as: $(cat "${STUB_LOG}.args"), exit ${hookRc}"
fTest Et6Ak52 an engine from before --gate is called with --ci
## 2026101816034794: main's tree keeps an engine that knows only --ci until
## the next cut, and a docs-only merge to main gates that tree.
sed -i '/^## --gate) /d' "${repo}/cicd/cicd.bash"
git -C "${repo}" commit -q -am oldengine
fPush main "$(git -C "${repo}" rev-parse HEAD)"
((hookRc == 0 && ran == 1)) && [[ "$(cat "${STUB_LOG}.args")" == "--ci --no-largedoc" ]] \
	|| fail "the hook called an engine from before --gate as: $(cat "${STUB_LOG}.args"), exit ${hookRc}"
git -C "${repo}" reset -q --hard "${sha}"
fTest Etl0lIx a push to main of docs alone skips the gate
## 2026102515494629: judged against the remote's main, by the hook's one list.
## Anything else in the push, the corpus under project/, a remote main the
## clone doesn't have, or a new main runs it.
fDocsPush(){  ## fDocsPush OLD FILE... -> hookRc, ran, for a commit on sha adding FILEs
	local old="$1" f; shift
	git -C "${repo}" reset -q --hard "${sha}"
	for f in "$@"; do
		if [[ "${f}" == */* ]]; then mkdir -p "${repo}/${f%/*}"; fi
		printf 'doc\n' > "${repo}/${f}"; git -C "${repo}" add -- "${f}"
	done
	git -C "${repo}" commit -q -m docs
	fPushLines "$(printf 'refs/heads/x %s refs/heads/main %s' "$(git -C "${repo}" rev-parse HEAD)" "${old}")"$'\n'
}
fDocsPush "${sha}" notes.md project/design_docs/x.md assets/logo.png
((hookRc == 0 && ran == 0)) || fail "a docs-only push to main: exit ${hookRc}, gate ran ${ran} time(s)"
for docsCase in "${sha}|notes.md a.sh" "${sha}|project/conformance/999/input.shcl" "${sha}|project/grammar.abnf" "${zeros}|notes.md" "$(printf '%040d' 1)|notes.md"; do
	read -r -a docsFiles <<< "${docsCase#*|}"
	fDocsPush "${docsCase%%|*}" "${docsFiles[@]}"
	((hookRc == 0 && ran == 1)) || fail "a push to main of ${docsCase#*|} from ${docsCase%%|*}: exit ${hookRc}, gate ran ${ran} time(s)"
done
git -C "${repo}" reset -q --hard "${sha}"
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

## 20261001: the banner's Syntax link names a tag that the cut has to create.
## Once a commit at that version reaches main, the tag has to be on the remote
## or in the same push, recorded tree or not.
bannerTag=v3.0.0-beta1
syntaxUrl="https://github.com/yottacore/shcl/blob/${bannerTag}/project/spec.md"
fBannerCommit(){  ## fBannerCommit VERSION [SPEC [LIBRS]] -> the new commit on branch cut
	## LIBRS is lib.rs's text, "none" for no lib.rs, or "real" for this checkout's.
	local libText="${3:-##    Syntax   ${syntaxUrl}}" libRs="${repo}/source/rust/src/lib.rs"
	mkdir -p "${repo}/source/rust/src" "${repo}/project"
	case "${libText}" in
		none) rm -f "${libRs}" ;;
		real) cp "${root}/source/rust/src/lib.rs" "${libRs}" ;;
		*)    printf '%s\n' "${libText}" > "${libRs}" ;;
	esac
	printf '[package]\nname = "stub"\nversion = "%s"\n' "$1" > "${repo}/source/rust/Cargo.toml"
	if [[ -n "${2:-}" ]]; then printf 'spec\n' > "${repo}/project/spec.md"; else rm -f "${repo}/project/spec.md"; fi
	git -C "${repo}" add --all && git -C "${repo}" commit -q -m "$1" && git -C "${repo}" rev-parse HEAD
}
git -C "${repo}" checkout -q -b cut
before="$(fBannerCommit 2.0.0 spec)"
nospec="$(fBannerCommit 3.0.0-beta1)"
final="$(fBannerCommit 3.0.0 spec)"
git -C "${repo}" reset -q --hard HEAD~1
cut="$(fBannerCommit 3.0.0-beta1 spec)"
git -C "${repo}" tag -a -m cut "${bannerTag}" "${cut}"
git -C "${repo}" tag -a -m nospec nospec "${nospec}"
cutTag="$(git -C "${repo}" rev-parse "refs/tags/${bannerTag}")"
for bare in none have odd; do git init -q --bare "${work}/${bare}.git" || { echo "check-push-gate: git init failed" >&2; exit 2; }; done
git -C "${repo}" push -q --no-verify "${work}/have.git" "refs/tags/${bannerTag}"
git -C "${repo}" push -q --no-verify "${work}/odd.git" "refs/tags/${bannerTag}:refs/tags/x/${bannerTag}"
fTagLine(){ printf 'refs/tags/%s %s refs/tags/%s %s\n' "$1" "$2" "${bannerTag}" "${zeros}" ;}  ## fTagLine LOCALTAG SHA

fTest ErUaPZV a cut pushed to main without the banner tag is refused
hookRemote=("${work}/none.git"); fPush main "${cut}"
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"has no such tag"* ]] \
	|| fail "a cut at the banner's version, pushed to main with no tag anywhere: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest ErUaPbL a cut pushed to main with the banner tag goes through
fPushLines "$(printf 'refs/heads/x %s refs/heads/main %s\n' "${cut}" "${zeros}")"$'\n'"$(fTagLine "${bannerTag}" "${cutTag}")"$'\n'
((hookRc == 0 && ran == 1)) || fail "a cut pushed to main with its tag: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest ErUaPd9 a recorded cut still needs the tag, and a tag on the remote counts
"${helper}" record "${repo}" "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" || fail "record refused the cut"
fPush main "${cut}"
((hookRc == 1 && ran == 0)) || fail "a recorded cut pushed to main with no tag: exit ${hookRc}, gate ran ${ran} time(s)"
hookRemote=("${work}/have.git"); fPush main "${cut}"
((hookRc == 0 && ran == 0)) || fail "a recorded cut whose tag is on the remote: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest ErUaPf2 a tree below the banner version needs no tag
hookRemote=("${work}/none.git"); fPush main "${before}"
((hookRc == 0 && ran == 1)) || fail "a tree at 2.0.0 pushed to main with no tag: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest ErUawc7 the final release after a beta tag still needs that tag
## sort -V alone ranks 3.0.0 below 3.0.0-beta1, which would wave this through.
fPush main "${final}"
((hookRc == 1 && ran == 0)) || fail "a tree at 3.0.0 pushed to main with no ${bannerTag} tag: exit ${hookRc}, gate ran ${ran} time(s)"
fTest ErUaPgt a push that deletes the tag, or sends one with no spec, is refused
hookRemote=("${work}/have.git")
fPushLines "$(printf 'refs/heads/x %s refs/heads/main %s\n(delete) %s refs/tags/%s %s\n' "${cut}" "${zeros}" "${zeros}" "${bannerTag}" "${cutTag}")"$'\n'
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"this push deletes ${bannerTag}"* ]] \
	|| fail "a main push that deletes the banner tag: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
hookRemote=("${work}/none.git")
fPushLines "$(printf 'refs/heads/x %s refs/heads/main %s\n' "${cut}" "${zeros}")"$'\n'"$(fTagLine nospec "$(git -C "${repo}" rev-parse refs/tags/nospec)")"$'\n'
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"has no project/spec.md"* ]] \
	|| fail "a main push sending the banner tag on a tree with no spec: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest ErUaPj3 a tag that only ends in the banner tag name does not count
hookRemote=("${work}/odd.git"); fPush main "${cut}"
((hookRc == 1 && ran == 0)) || fail "a remote holding only refs/tags/x/${bannerTag}: exit ${hookRc}, gate ran ${ran} time(s)"
fTest ErUaPkx a remote that cannot be read refuses the cut
hookRemote=("${work}/missing.git"); fPush main "${cut}"
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"cannot list the tags"* ]] \
	|| fail "an unreadable remote: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"

fTest Erkafqf a cut whose banner Syntax line cannot be read is refused
## 2026100307163910: a Syntax line the pattern no longer matched read as a
## banner naming no tag, and the cut went through with none.
hookRemote=("${work}/none.git")
for libText in "##    Syntax:  ${syntaxUrl}" "##    Syntax   ${syntaxUrl/\/blob\///tree/}" "##    Syntax   ${syntaxUrl} " "## no banner" none; do
	odd="$(fBannerCommit 3.0.0-beta1 spec "${libText}")"
	fPush main "${odd}"
	((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"cannot read the tag"* ]] \
		|| fail "a cut whose lib.rs is '${libText}', pushed to main with no tag: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
done
fTest ErkafuD a tree below the first tagged release needs no tag in its banner
old="$(fBannerCommit 2.0.0 spec '#    Syntax   https://github.com/yottacore/shcl/blob/main/project/spec.md')"
fPush main "${old}"
((hookRc == 0 && ran == 1)) || fail "a 2.x tree whose banner links main: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest Erkafx3 the check reads the banner in the real lib.rs
## Every other case writes a one-line lib.rs, so only this one sees the real
## banner move away from the check's pattern.
real="$(fBannerCommit "${bannerTag#v}" spec real)"
fPush main "${real}"
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"past ${bannerTag}, which the banner's Syntax link names,"* ]] \
	|| fail "a cut with this checkout's lib.rs, pushed to main with no tag: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"

fTest Erkafzp a banner tag on a commit at another version is refused
## 2026100307163918: any commit with a spec passed as the tag, sent in the push
## or already on the remote.
git -C "${repo}" tag -a -m old oldcut "${before}"
fPushLines "$(printf 'refs/heads/x %s refs/heads/main %s\n' "${cut}" "${zeros}")"$'\n'"$(fTagLine oldcut "$(git -C "${repo}" rev-parse refs/tags/oldcut)")"$'\n'
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"at version 2.0.0"* ]] \
	|| fail "a main push sending the banner tag on a 2.0.0 commit: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
git init -q --bare "${work}/stale.git" || { echo "check-push-gate: git init failed" >&2; exit 2; }
git -C "${repo}" push -q --no-verify "${work}/stale.git" "refs/tags/oldcut:refs/tags/${bannerTag}"
hookRemote=("${work}/stale.git"); fPush main "${cut}"
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"at version 2.0.0"* ]] \
	|| fail "a remote whose banner tag is on a 2.0.0 commit: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
fTest Erkag2h a banner tag on the remote that this clone does not have is refused
if ! { git init -q -b dev "${work}/foreign" && printf 'x\n' > "${work}/foreign/x" \
	&& git -C "${work}/foreign" add x && git -C "${work}/foreign" commit -q -m foreign \
	&& git init -q --bare "${work}/foreign.git" \
	&& git -C "${work}/foreign" push -q --no-verify "${work}/foreign.git" "HEAD:refs/tags/${bannerTag}"; }; then
	echo "check-push-gate: cannot build the foreign remote" >&2; exit 2
fi
hookRemote=("${work}/foreign.git"); fPush main "${cut}"
((hookRc == 1 && ran == 0)) && [[ "${hookOut}" == *"not in this clone"* ]] \
	|| fail "a remote whose banner tag this clone cannot read: exit ${hookRc}, gate ran ${ran} time(s): $(tail -c 300 <<<"${hookOut}")"
hookRemote=()
git -C "${repo}" checkout -q dev

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

fTest EqGl8mf only a full --gate run records its tree
## 20260918 item 24: the runs that must not record, through cicd.bash itself.
## A throwaway repository gets the real engine and config with every stage
## stubbed at the end of the config. A --gate run records its tree; a --quick
## run, a run with a stage left out, and a run whose gate noted a skip do not.
## Before this, taking out either hold-back failed nothing.
eng="${work}/eng"
git init -q -b dev "${eng}" || { echo "check-push-gate: git init failed" >&2; exit 2; }
mkdir -p "${eng}/cicd/utility/include" "${eng}/source/rust"
cp "${root}/cicd/cicd.bash" "${root}/cicd/config.bash" "${eng}/cicd/"
cp "${root}/cicd/utility/green-tree.bash" "${eng}/cicd/utility/"
cp "${root}/cicd/utility/include/gfs-rotate.bash" "${root}/cicd/utility/include/ctr-image.bash" "${root}/cicd/utility/include/frozen-tree.bash" \
	"${root}/cicd/utility/include/stop-descendants.bash" "${root}/cicd/utility/include/cpu-cap.bash" "${eng}/cicd/utility/include/"
cp "${root}/.gitignore" "${eng}/.gitignore"
cat > "${eng}/cicd/utility/crosscheck.bash" <<'EOF'
#!/usr/bin/env bash
echo ran > "${STUB_XCHECK}"
EOF
chmod +x "${eng}/cicd/utility/crosscheck.bash"
printf '[package]\nname = "stub"\nversion = "1.0.0"\n' > "${eng}/source/rust/Cargo.toml"
cat >> "${eng}/cicd/config.bash" <<'CFG'
## check-push-gate: every stage stubbed.
FMT_CMD=(true); FMT_CHECK_CMD=(true); FMT_EXTRA=(); FMT_CHECK_EXTRA=()
BUILD_CMD=(true); BUILD_EXTRA=()
LINT_CMD=(true); LINT_EXTRA=(); SHELLCHECK_TARGETS=()
TEST_CMD=(true); TEST_QUICK_CMD=(true)
TEST_EXTRA=('if [[ -n "${STUB_SKIP:-}" ]]; then echo stub >> "${SHCL_GATE_SKIPS}"; fi' 'echo "${GIT_DIR:-unset}" > "${STUB_GITDIR:-/dev/null}"' 'echo slow > "${STUB_SLOW:-/dev/null}"')
## A test that leaves scratch in TMPDIR, a read-only dir in it too, and one
## that stops the run. TERM, as INT is ignored in a run started in the
## background.
TEST_EXTRA+=('if [[ -n "${STUB_TMPDIR:-}" ]]; then echo "${TMPDIR}" > "${STUB_TMPDIR}"; mkdir -p "${TMPDIR}/left/deep" "${TMPDIR}/left/ro"; : > "${TMPDIR}/left/deep/f"; : > "${TMPDIR}/left/ro/f"; chmod 555 "${TMPDIR}/left/ro"; fi' 'if [[ -n "${STUB_STOP:-}" ]]; then kill -TERM $$; fi')
## A test that hangs in a child process, which a stop has to take down.
TEST_EXTRA+=('if [[ -n "${STUB_HANG:-}" ]]; then echo "${TMPDIR}" > "${STUB_HANG}.tmp"; sleep 300 & echo "$!" > "${STUB_HANG}"; wait "$!"; fi')
QUICK_SKIP=(STUB_SLOW crosscheck.bash)
LEAKCHECK_STEPS=('echo leak > "${STUB_LEAK:-/dev/null}"')
LEAKCHECK_FAST=('echo fast > "${STUB_LEAK_FAST:-/dev/null}"'); LEAKCHECK_LONG=('echo long > "${STUB_LEAK_LONG:-/dev/null}"')
LEAKCHECK_TESTS=(STUB_LEAK_TEST); TEST_EXTRA+=('echo t > "${STUB_LEAK_TEST:-/dev/null}"')
CROSS_CHECKS=('stub|[[ -z "${STUB_CROSS_FAIL:-}" ]]')
BINDING_CLIS=(); if [[ -n "${STUB_XCHECK:-}" ]]; then BINDING_CLIS=("stub|true"); fi
LARGEDOC_MIB=0; CROSS_TARGETS=(); PROFILE_ENABLE=0; PACKAGE_ENABLE=0; GIF_ENABLE=0
DOGFOOD_FIXED_DESTS=(); GIT_PUBLISH=(); RELEASE_NATIVE_CMD=()
PROFILE_CHECK_BUILD_CMD=(); CTR_PREP=''
## A release build that leaves a file, with nothing collected or checked.
if [[ -n "${STUB_RELEASE:-}" ]]; then
	RELEASE_NATIVE_CMD=(touch "${STUB_RELEASE}"); RELEASE_NATIVE_BIN="${STUB_RELEASE}"
	RELEASE_CHECKS=(); RELEASE_ARTIFACT_DIR=""; REMOTE_BOXES=(); PACKAGE_ENABLE=0
fi
## The profiler, with a calibration that leaves a file behind when it runs.
if [[ -n "${STUB_PROFILE:-}" ]]; then
	PROFILE_ENABLE=1; PROFILE_BUILD_CMD=(true); PROFILE_BIN=cicd/cicd.bash; PROFILE_TIMED=()
	PROFILE_WORKLOAD_GEN='echo "a: 1" > "${PROFILE_WORKLOAD}"'; PROFILE_RUN='echo svg > "${PROFILE_OUT}"'
	PROFILE_CHECK='echo ran > "${STUB_PROFILE}"'
	PROFILE_CHECK_PROBE_CMD=(true); PROFILE_CHECK_BUILD_CMD=(true); PROFILE_CHECK_BIN=cicd/cicd.bash
fi
CFG
{ git -C "${eng}" add --all && git -C "${eng}" commit -q -m base; } || { echo "check-push-gate: engine repo commit failed" >&2; exit 2; }
engTree="$(git -C "${eng}" rev-parse 'HEAD^{tree}')"
engRecords="${eng}/.git/shcl-green-trees"
## No docker unless a test brings its own, or every run would start the real
## one on a stub repository.
fEngine(){  ## fEngine [VAR=VALUE ...] -- ARGS... -> engRc, engRecorded
	local envs=()
	while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
	rm -f "${engRecords}"
	engRc=0; env -u SHCL_GATE_STRICT -u SHCL_GATE_SKIPS SHCL_DOCKER="${work}/no-docker" "${envs[@]}" bash "${eng}/cicd/cicd.bash" "$@" > "${work}/eng.log" 2>&1 || engRc=$?
	engRecorded=0; if "${eng}/cicd/utility/green-tree.bash" passed "${eng}" "${engTree}"; then engRecorded=1; fi
}
fEngine -- --gate
((engRc == 0 && engRecorded == 1)) || fail "a stubbed --gate run: exit ${engRc}, recorded ${engRecorded}: $(tail -5 "${work}/eng.log")"
fEngine -- --gate --quick
((engRc == 0 && engRecorded == 0)) || fail "a --quick run: exit ${engRc}, recorded ${engRecorded}"
fEngine -- --gate --no-lint
((engRc == 0 && engRecorded == 0)) || fail "a run with lint left out: exit ${engRc}, recorded ${engRecorded}"
fEngine -- --gate --no-fmt
((engRc == 0 && engRecorded == 0)) || fail "a run with the format check left out: exit ${engRc}, recorded ${engRecorded}"
## The hosted lint half. Its tests run in the other job, never here.
rm -f "${work}/eng.notests"
fEngine STUB_GITDIR="${work}/eng.notests" -- --gate --no-tests
((engRc == 0 && engRecorded == 0)) || fail "a run with the tests left out: exit ${engRc}, recorded ${engRecorded}"
[[ ! -e "${work}/eng.notests" ]] || fail "a --no-tests run still ran the tests stage"
fEngine STUB_SKIP=1 -- --gate
((engRecorded == 0)) || fail "a run whose gate noted a skip recorded its tree"
fTest EqjfWm8 a run failing or leaving out the cross checks records nothing
## 20260923 item 1: the cross checks are the last gate, so a run failing one
## records nothing, and a run leaving them out is partial.
fEngine STUB_CROSS_FAIL=1 -- --gate
((engRc != 0 && engRecorded == 0)) || fail "a run failing a cross check: exit ${engRc}, recorded ${engRecorded}"
fEngine -- --gate --no-cross
((engRc == 0 && engRecorded == 0)) || fail "a run with the cross checks left out: exit ${engRc}, recorded ${engRecorded}"
fTest Et6Aueh --quick leaves out what QUICK_SKIP names and nothing else
## 2026101816034794: the fast loop drops the steps config names as slow. A
## bare run and the gate keep them.
fQuick(){  ## fQuick ARGS... -> engRc, slowRan, xcheckRan, otherRan
	rm -f "${work}/eng.slow" "${work}/eng.xcheck" "${work}/eng.other"
	fEngine STUB_SLOW="${work}/eng.slow" STUB_XCHECK="${work}/eng.xcheck" STUB_GITDIR="${work}/eng.other" -- "$@"
	slowRan=0; xcheckRan=0; otherRan=0
	if [[ -e "${work}/eng.slow" ]]; then slowRan=1; fi
	if [[ -e "${work}/eng.xcheck" ]]; then xcheckRan=1; fi
	if [[ -e "${work}/eng.other" ]]; then otherRan=1; fi
}
fQuick --gate --quick
((engRc == 0 && slowRan == 0 && xcheckRan == 0 && otherRan == 1)) || fail "a --quick run: exit ${engRc}, the named step ran ${slowRan}, the crosscheck ${xcheckRan}, another step ${otherRan}"
fQuick -y --no-sync --quick
((engRc == 0 && slowRan == 0 && xcheckRan == 0 && otherRan == 1)) || fail "a local --quick run: exit ${engRc}, the named step ran ${slowRan}, the crosscheck ${xcheckRan}, another step ${otherRan}"
fQuick --gate
((engRc == 0 && slowRan == 1 && xcheckRan == 1)) || fail "a --gate run left out a step QUICK_SKIP names: exit ${engRc}, the named step ran ${slowRan}, the crosscheck ${xcheckRan}"
fQuick -y --no-sync
((engRc == 0 && slowRan == 1 && xcheckRan == 1)) || fail "a run with no flags left out a step QUICK_SKIP names: exit ${engRc}, the named step ran ${slowRan}, the crosscheck ${xcheckRan}"
fTest Et9t3dc --leakcheck adds the leak checks a run with no flags already has
## 2026101707582803: JC, 2026-10-18, a run with no flags does everything.
## --gate and --quick leave the slow leak checks out, --leakcheck adds them
## back, and --no-tests takes them with the rest of the tests.
fLeak(){  ## fLeak ARGS... -> engRc, leakRan
	rm -f "${work}/eng.leak"
	fEngine STUB_LEAK="${work}/eng.leak" -- "$@"
	leakRan=0; if [[ -e "${work}/eng.leak" ]]; then leakRan=1; fi
}
fLeak -y --no-sync
((engRc == 0 && leakRan == 1)) || fail "a run with no flags left the leak checks out: exit ${engRc}, ran ${leakRan}: $(tail -3 "${work}/eng.log")"
fLeak --gate
((engRc == 0 && leakRan == 0)) || fail "a --gate run ran the leak checks: exit ${engRc}, ran ${leakRan}"
fLeak -y --no-sync --quick
((engRc == 0 && leakRan == 0)) || fail "a --quick run ran the leak checks: exit ${engRc}, ran ${leakRan}"
fLeak --gate --leakcheck
((engRc == 0 && leakRan == 1)) || fail "--gate --leakcheck left the leak checks out: exit ${engRc}, ran ${leakRan}"
fLeak -y --no-sync --quick --leakcheck
((engRc == 0 && leakRan == 1)) || fail "--quick --leakcheck left the leak checks out: exit ${engRc}, ran ${leakRan}"
fLeak -y --no-sync --leakcheck --no-tests
((engRc == 0 && leakRan == 0)) || fail "--leakcheck --no-tests ran the leak checks: exit ${engRc}, ran ${leakRan}"
## 2026101920461167: --no-leakcheck drops them from any run.
fLeak -y --no-sync --no-leakcheck
((engRc == 0 && leakRan == 0)) || fail "a run with --no-leakcheck ran the leak checks: exit ${engRc}, ran ${leakRan}"
fLeak --gate --no-leakcheck
((engRc == 0 && leakRan == 0)) || fail "--gate --no-leakcheck ran the leak checks: exit ${engRc}, ran ${leakRan}"
fLeak -y --no-sync --quick --no-leakcheck
((engRc == 0 && leakRan == 0)) || fail "--quick --no-leakcheck ran the leak checks: exit ${engRc}, ran ${leakRan}"
fTest EtD3jdR --leakcheck and --no-leakcheck together are a usage error
## 2026101920461167: nothing on the command line resolves last-wins, so the
## pair is refused before anything runs, in either order.
for leakFirst in --leakcheck --no-leakcheck; do
	leakSecond=--no-leakcheck; if [[ "${leakFirst}" == --no-leakcheck ]]; then leakSecond=--leakcheck; fi
	fLeak -y --no-sync "${leakFirst}" "${leakSecond}"
	if ((engRc != 2 || leakRan != 0)) || ! grep -qF "can't go together" "${work}/eng.log"; then
		fail "cicd.bash took ${leakFirst} ${leakSecond}: exit ${engRc}, ran ${leakRan}: $(tail -2 "${work}/eng.log")"
	fi
done
fTest EtkuOxe the leak checks by length, and --long
## 2026102515494614: the default run fits in about an hour, so what takes hours
## is only in --long, --slow and --leakcheck. --quick keeps the fast ones, and
## --no-leakcheck drops every one, the test steps that are leak checks too.
fLeakLen(){  ## fLeakLen ARGS... -> engRc, leakRun as fast slow long test, 1 or 0 each
	local f
	rm -f "${work}/eng.leak" "${work}/eng.leakfast" "${work}/eng.leaklong" "${work}/eng.leaktest"
	fEngine STUB_LEAK="${work}/eng.leak" STUB_LEAK_FAST="${work}/eng.leakfast" STUB_LEAK_LONG="${work}/eng.leaklong" STUB_LEAK_TEST="${work}/eng.leaktest" -- "$@"
	leakRun=""
	for f in leakfast leak leaklong leaktest; do
		if [[ -e "${work}/eng.${f}" ]]; then leakRun+="1"; else leakRun+="0"; fi
	done
}
for leakCase in '1101|-y --no-sync' '1001|-y --no-sync --quick' '1111|-y --no-sync --long' '1111|-y --no-sync --slow' \
	'1111|-y --no-sync --leakcheck' '1111|-y --no-sync --quick --leakcheck' '0000|-y --no-sync --no-leakcheck' \
	'0000|-y --no-sync --long --no-tests' '0001|--gate' '1111|--gate --long' '1101|--merge-gate' '1101|--ci'; do
	read -r -a leakArgs <<< "${leakCase#*|}"
	fLeakLen "${leakArgs[@]}"
	if ((engRc != 0)) || [[ "${leakRun}" != "${leakCase%%|*}" ]]; then
		fail "cicd.bash ${leakCase#*|} ran the leak checks as ${leakRun} (fast, slow, long, test), not ${leakCase%%|*}: exit ${engRc}: $(tail -2 "${work}/eng.log")"
	fi
done
fLeakLen -y --no-sync --quick --long
if ((engRc != 2)) || [[ "${leakRun}" != 0000 ]] || ! grep -qF "can't go together" "${work}/eng.log"; then
	fail "cicd.bash took --quick --long: exit ${engRc}, ran ${leakRun}: $(tail -2 "${work}/eng.log")"
fi
fTest Et6Aum5 --ci is another name for --merge-gate
## 2026101816034794 made --ci unknown; 2026102515494619 brings it back as
## another name for --merge-gate, which says so in one line.
fEngine -- --ci
if ((engRc != 0)) || ! grep -qxF -- '--ci is another name for --merge-gate' "${work}/eng.log"; then fail "cicd.bash --ci: exit ${engRc}: $(tail -2 "${work}/eng.log")"; fi
fTest EtkuOxg --merge-gate runs every check of a run with no flags
## 2026102515494619: the release builds and the default run's leak checks,
## which --gate leaves out, and the tree is recorded. No dogfood or publish.
rm -f "${work}/eng.release"
fEngine STUB_RELEASE="${work}/eng.release" -- --merge-gate
((engRc == 0 && engRecorded == 1)) && [[ -e "${work}/eng.release" ]] \
	|| fail "a --merge-gate run: exit ${engRc}, recorded ${engRecorded}, release built $([[ -e "${work}/eng.release" ]] && echo 1 || echo 0): $(tail -3 "${work}/eng.log")"
if ! grep -qF 'Off ............: Dogfood (--merge-gate)' "${work}/eng.log" || ! grep -qF 'Off ............: Backup + publish (--merge-gate)' "${work}/eng.log" \
	|| grep -qE 'Starting (Dogfood|Backup)' "${work}/eng.log"; then
	fail "a --merge-gate run dogfooded or published: $(grep -iE 'dogfood|publish' "${work}/eng.log" || true)"
fi
rm -f "${work}/eng.release"
fEngine STUB_RELEASE="${work}/eng.release" -- --gate
[[ ! -e "${work}/eng.release" ]] || fail "a --gate run built the release"
fTest EqL1d4D cicd.bash clears GIT_DIR before its gates
## 20260918b item 2: a direct run with GIT_DIR exported clears it too.
fEngine GIT_DIR="${eng}/.git" STUB_GITDIR="${work}/eng.gitdir" -- --gate
[[ "$(cat "${work}/eng.gitdir" 2>/dev/null || true)" == unset ]] \
	|| fail "cicd.bash passed GIT_DIR on to its gates: $(cat "${work}/eng.gitdir" 2>/dev/null || true)"
fTest EstM5WQ a local --no-tests run still checks the profiler
## 2026101514324714: --no-tests dropped the calibration on a local run too, so
## the flame graph after it was drawn unchecked. Under --gate the calibration
## goes with the tests, which the other hosted job runs.
fCalibrated(){  ## fCalibrated ARGS... -> engRc, calibrated (1 if the calibration ran)
	rm -f "${work}/eng.prof"
	fEngine STUB_PROFILE="${work}/eng.prof" -- "$@"
	calibrated=0; if [[ -e "${work}/eng.prof" ]]; then calibrated=1; fi
}
fCalibrated -y --no-sync --no-tests
((engRc == 0 && calibrated == 1)) || fail "a local --no-tests run drew the flame graph unchecked: exit ${engRc}, calibrated ${calibrated}: $(tail -3 "${work}/eng.log")"
fCalibrated -y --no-sync
((engRc == 0 && calibrated == 1)) || fail "a local run drew the flame graph unchecked: exit ${engRc}, calibrated ${calibrated}"
fCalibrated --gate
((engRc == 0 && calibrated == 1)) || fail "a --gate run skipped the profiler calibration: exit ${engRc}, calibrated ${calibrated}"
fCalibrated --gate --no-tests
((engRc == 0 && calibrated == 0)) || fail "the hosted lint half ran the profiler calibration: exit ${engRc}, calibrated ${calibrated}"
## A docker that answers unless STUB_DOCKER_DOWN is set, and writes down each
## call to STUB_DOCKER_LOG. A run writes down its mounts, or with
## STUB_DOCKER_EXEC runs its command here, once, with its -e settings.
## STUB_DOCKER_IMAGES is a file of the images it has, as REPO:TAG lines,
## oldest first, STUB_DOCKER_DANGLING and STUB_DOCKER_STOPPED are an image and
## a stopped container it has under the dev.project label, STUB_DOCKER_RUNNING
## a container of the asking run until it's stopped, and what it's asked to stop or remove goes in
## STUB_DOCKER_GONE. Each run and build writes its arguments to
## STUB_DOCKER_ARGS. system df gives smaller images once something is gone. With STUB_DOCKER_NOIMAGE it has no image to run, and a
## build makes one. A run given --cidfile writes an ID there, and kill writes
## down what it's asked to kill in STUB_DOCKER_GONE too. With STUB_DOCKER_HANG
## a run writes its PID there and runs until stopped, and with
## STUB_DOCKER_STUBBORN too it passes over a TERM, as a stuck client would.
## A volume create goes in STUB_DOCKER_VOLS. With STUB_DOCKER_ZIG it has Zig's
## cache volume, and a run that mounts it without bash prints that, as
## fCtrZigTrim's would: "KB<TAB>STAMP<TAB>VERSION".
cat > "${work}/fake-docker" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${STUB_DOCKER_LOG:-}" ]]; then echo "${1:-}" >> "${STUB_DOCKER_LOG}"; fi
if [[ -n "${STUB_DOCKER_ARGS:-}" && ( "${1:-}" == run || "${1:-}" == build || "${1:-}${2:-}" == volumecreate ) ]]; then a="$*"; echo "${a//$'\n'/ }" >> "${STUB_DOCKER_ARGS}"; fi
case "${1:-}" in
	info)  exit "${STUB_DOCKER_DOWN:-0}" ;;
	image)
		case "${2:-}" in
			ls)
				if [[ " $* " == *" dangling=true "* ]]; then
					if [[ " $* " == *" label=dev.project=shcl "* && -n "${STUB_DOCKER_DANGLING:-}" ]]; then echo "${STUB_DOCKER_DANGLING}"; fi
				elif [[ -n "${STUB_DOCKER_IMAGES:-}" ]]; then
					if [[ "${3:-}" != -* ]]; then grep "^${3}:" "${STUB_DOCKER_IMAGES}" || true; else cat "${STUB_DOCKER_IMAGES}"; fi
				fi ;;
			inspect)
				if [[ "${3:-}" == --format && "${4:-}" == '{{.Created}}' ]]; then
					for ref in "${@:5}"; do printf '2026-01-01T00:%02d:00Z\n' "$(grep -nxF -- "${ref}" "${STUB_DOCKER_IMAGES:-/dev/null}" | cut -d: -f1)"; done
				elif [[ "${3:-}" == --format ]]; then echo 1048576
				elif [[ -n "${STUB_DOCKER_NOIMAGE:-}" ]]; then exit 1; fi ;;
		esac
		exit 0 ;;
	build) exit 0 ;;
	volume)
		case "${2:-}" in
			create)  echo "$*" >> "${STUB_DOCKER_VOLS:-/dev/null}"; exit 0 ;;
			inspect) [[ -n "${STUB_DOCKER_ZIG:-}" ]]; exit ;;
			rm)      echo "volume rm ${3:-}" >> "${STUB_DOCKER_GONE:-/dev/null}"; exit 0 ;;
		esac
		exit 1 ;;
	rmi|rm|kill|stop) echo "$1 ${*: -1}" >> "${STUB_DOCKER_GONE:-/dev/null}"; exit 0 ;;
	builder) echo "$*" >> "${STUB_DOCKER_PRUNE:-/dev/null}"; exit 0 ;;
	system)
		if [[ -s "${STUB_DOCKER_GONE:-/dev/null}" ]]; then images=1GB; else images=2GB; fi
		printf 'Images\t%s\nContainers\t0B\nLocal Volumes\t119MB\nBuild Cache\t5GB\n' "${images}"
		exit 0 ;;
	ps)
		if [[ " $* " == *" label=dev.project=shcl "* ]]; then
			if [[ " $* " == *" status=exited "* && -n "${STUB_DOCKER_STOPPED:-}" ]]; then echo "${STUB_DOCKER_STOPPED}"; fi
			if [[ " $* " == *" label=dev.run=${SHCL_DEV_RUN:-?} "* && -n "${STUB_DOCKER_RUNNING:-}" ]] \
				&& ! grep -qx "stop ${STUB_DOCKER_RUNNING}" "${STUB_DOCKER_GONE:-/dev/null}" 2>/dev/null; then echo "${STUB_DOCKER_RUNNING}"; fi
		fi
		exit 0 ;;
	run)   ;;
	*)     exit 1 ;;
esac
if [[ " $* " == *":/zig-cache "* && " $* " != *" bash "* ]]; then printf '%b\n' "${STUB_DOCKER_ZIG:-}"; exit 0; fi
## cat /etc/passwd or /etc/group
if [[ " $* " != *" bash "* ]]; then echo "root:x:0:0::/root:/bin/sh"; exit 0; fi
for ((a = 1; a < $#; a++)); do
	if [[ "${!a}" == --cidfile ]]; then b=$((a + 1)); echo c1d0c1d0c1d0 > "${!b}"; fi
done
if [[ -n "${STUB_DOCKER_RUNFAIL:-}" ]]; then exit 1; fi
if [[ -n "${STUB_DOCKER_HANG:-}" ]]; then
	if [[ -n "${STUB_DOCKER_STUBBORN:-}" ]]; then trap '' TERM; fi
	echo "$$" > "${STUB_DOCKER_HANG}"
	while :; do sleep 1 || true; done
fi
if [[ -n "${STUB_DOCKER_EXEC:-}" ]]; then
	echo run >> "${STUB_DOCKER_EXEC}"
	if (($(wc -l < "${STUB_DOCKER_EXEC}") > 1)); then echo "fake-docker: a run started inside a run" >&2; exit 1; fi
	shift; envs=(); dir=.
	while (($#)); do
		case "$1" in
			--rm|--init)           shift ;;
			-e)                    envs+=("$2"); shift 2 ;;
			-w)                    dir="$2"; shift 2 ;;
			-v|--user|--group-add|--label|--name|--network|--device|--cidfile|--cpus|--cpu-shares) shift 2 ;;
			*)                     break ;;
		esac
	done
	shift
	cd "${dir}" && exec env "${envs[@]}" "$@"
fi
: > "${STUB_MOUNTS}"
while (($#)); do
	if [[ "$1" == -v ]]; then
		dst="${2#*:}"; dst="${dst%%:*}"; there=no
		if [[ -e "${dst}" || -L "${dst}" ]]; then there=yes; fi
		printf '%s\t%s\t%s\n' "${2%%:*}" "${dst}" "${there}" >> "${STUB_MOUNTS}"
		shift
	fi
	shift
done
EOF
chmod +x "${work}/fake-docker"
## uname -m as another box would answer it.
realUname="$(command -v uname)"
for arch in x86_64 aarch64; do
	mkdir -p "${work}/${arch}"
	# shellcheck disable=SC2016  ## the stub's own text
	printf '#!/usr/bin/env bash\nif [[ "${1:-}" == -m ]]; then echo %s; else exec %q "$@"; fi\n' "${arch}" "${realUname}" > "${work}/${arch}/uname"
	chmod +x "${work}/${arch}/uname"
done
fCtr(){  ## fCtr [VAR=VALUE ...] -- ARGS... -> fEngine's, docker (its calls), ran (1 if the tests stage ran), noted (note lines)
	local envs=()
	while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
	rm -f "${work}/docker.log" "${work}/docker.exec" "${work}/eng.ran"
	fEngine SHCL_DOCKER="${work}/fake-docker" STUB_DOCKER_LOG="${work}/docker.log" SHCL_CTR_CACHE="${work}/ctrcache" \
		PATH="${work}/x86_64:${PATH}" STUB_GITDIR="${work}/eng.ran" "${envs[@]}" -- "$@"
	docker=""; if [[ -f "${work}/docker.log" ]]; then docker="$(tr '\n' ' ' < "${work}/docker.log")"; docker="${docker% }"; fi
	ran=0; if [[ -e "${work}/eng.ran" ]]; then ran=1; fi
	noted="$(grep -c '^note: stages 1-6 run on this box' "${work}/eng.log" || true)"
}
fTest EtDCDE4 with no docker answering, stages 1-6 run here with a note
## 2026101920461174: no docker, one whose daemon doesn't answer, and a box the
## images can't run on all fall back to a local run, which still records.
fCtr SHCL_DOCKER="${work}/no-docker" -- --gate
if ((engRc != 0 || ran != 1 || noted != 1 || engRecorded != 1)) || ! grep -qF "there's no ${work}/no-docker here" "${work}/eng.log"; then
	fail "a run with no docker: exit ${engRc}, ran ${ran}, ${noted} note(s), recorded ${engRecorded}: $(tail -3 "${work}/eng.log")"
fi
fCtr STUB_DOCKER_DOWN=1 -- --gate
if ((engRc != 0 || ran != 1 || noted != 1 || engRecorded != 1)) || [[ "${docker}" != info ]] || ! grep -qF "fake-docker doesn't answer" "${work}/eng.log"; then
	fail "a run with a docker that doesn't answer: exit ${engRc}, ran ${ran}, ${noted} note(s), recorded ${engRecorded}, docker calls '${docker}': $(tail -3 "${work}/eng.log")"
fi
fCtr PATH="${work}/aarch64:${PATH}" -- -y --no-sync
if ((engRc != 0 || ran != 1 || noted != 1)) || [[ -n "${docker}" ]] || ! grep -qF "x86_64 only" "${work}/eng.log"; then
	fail "a run on aarch64: exit ${engRc}, ran ${ran}, ${noted} note(s), docker calls '${docker}': $(tail -3 "${work}/eng.log")"
fi
fTest EtDCDE5 --no-container runs here and asks no docker
fCtr -- --gate --no-container
((engRc == 0 && ran == 1 && noted == 0 && engRecorded == 1)) && [[ -z "${docker}" ]] \
	|| fail "--no-container: exit ${engRc}, ran ${ran}, ${noted} note(s), recorded ${engRecorded}, docker calls '${docker}': $(tail -3 "${work}/eng.log")"
fTest EtDCDE6 --container with --no-container, or with 2 images, is a usage error
## Nothing on the command line resolves last-wins, so each is refused before
## anything runs.
for ctrArgs in "--container --no-container" "--no-container --container" "--container=alpine --no-container" "--container --container=alpine" "--container="; do
	read -r -a ctrWords <<<"${ctrArgs}"
	fCtr -- -y --no-sync "${ctrWords[@]}"
	if ((engRc != 2 || ran != 0)) || [[ -n "${docker}" ]] || ! grep -qE "can't go together|names 2 images|names no image" "${work}/eng.log"; then
		fail "cicd.bash took ${ctrArgs}: exit ${engRc}, ran ${ran}, docker calls '${docker}': $(tail -2 "${work}/eng.log")"
	fi
done
fTest EstM5os an extra image builds into its own copies and leaves this tree as it was
## 2026101514324713: an alpine run left a root-owned target dir where there had
## been none, built into a gate worktree's target-gate, and swapped this box's C
## CLI for a musl one that won't run here. Docker makes a missing mount point as
## root and follows a link to mount where it leads, so the engine here is a stub
## that writes down the mounts it's asked for, and those are held to that.
## On the checkout's own paths, so --no-freeze.
if [[ "$(uname -m)" == x86_64 ]]; then
	cp -r "${root}/cicd/container" "${eng}/cicd/"
	mapfile -t ctrExtra < <(source "${root}/cicd/config.bash"; printf '%s\n' "${CTR_CONTEXT_EXTRA[@]}")
	for f in "${ctrExtra[@]}"; do cp "${root}/${f}" "${eng}/${f}"; done
	mkdir -p "${eng}/source/c" "${eng}/source/go"
	mapfile -t ctrPrivate < <(source "${root}/cicd/config.bash"; printf '%s\n' "${CTR_PRIVATE[@]}")
	mapfile -t ctrClis < <(source "${root}/cicd/config.bash"; printf '%s\n' "${BINDING_CLIS[@]}")
	fCtrMounts(){  ## fCtrMounts LABEL: an alpine run on eng, its mounts held to the rules
		local label="$1" p host dst there seen="" before=() ctrRc=0
		for p in "${ctrPrivate[@]}"; do before+=("$(if [[ -e "${eng}/${p%/}" || -L "${eng}/${p%/}" ]]; then echo yes; else echo no; fi)"); done
		( cd "${eng}" && env -u SHCL_GATE_STRICT -u SHCL_GATE_SKIPS SHCL_DOCKER="${work}/fake-docker" SHCL_CTR_CACHE="${work}/ctrcache" \
			STUB_MOUNTS="${work}/mounts.tsv" bash "${eng}/cicd/cicd.bash" -y --no-sync --no-freeze --container=alpine ) > "${work}/ctr.log" 2>&1 || ctrRc=$?
		((ctrRc == 0)) || { fail "${label}: the stubbed alpine run failed: $(tail -3 "${work}/ctr.log")"; return 0; }
		while IFS=$'\t' read -r _ dst there; do
			if [[ "${dst}" == "${eng}/"* && "${there}" == no ]]; then fail "${label}: docker would make ${dst#"${eng}/"} as root"; fi
			if [[ "${seen}" == *$'\n'"${dst}"$'\n'* ]]; then fail "${label}: 2 mounts at ${dst}"; fi
			seen+=$'\n'"${dst}"$'\n'
		done < "${work}/mounts.tsv"
		if grep -qF /zig-cache "${work}/mounts.tsv"; then fail "${label}: an extra image, which has no Zig, gets Zig's cache volume"; fi
		for p in "${ctrPrivate[@]}"; do
			host="$(readlink -f -- "${eng}/${p%/}")"
			if ! awk -F'\t' -v d="${host}" -v c="${work}/ctrcache/" '$2 == d && index($1, c) == 1 { f = 1 } END { exit !f }' "${work}/mounts.tsv"; then
				fail "${label}: ${p} isn't the image's own copy where it leads (${host})"
			fi
			if awk -F'\t' -v s="${host}" '$1 == s { f = 1 } END { exit !f }' "${work}/mounts.tsv"; then
				fail "${label}: this box's ${host} is mounted into the run"
			fi
		done
		for p in "${!ctrPrivate[@]}"; do
			if [[ "${before[p]}" == no && ( -e "${eng}/${ctrPrivate[p]%/}" || -L "${eng}/${ctrPrivate[p]%/}" ) ]]; then
				fail "${label}: the run left ${ctrPrivate[p]} behind"
			fi
		done
		return 0
	}
	## The frozen runs above left the checkout's end of each FROZEN_LINKS entry as
	## an empty dir, so they go first, or nothing built here isn't that layout.
	ctrSetUp=1
	for p in "${ctrPrivate[@]}"; do
		if [[ "${p}" == */ && -d "${eng}/${p%/}" && ! -L "${eng}/${p%/}" ]]; then rmdir -- "${eng}/${p%/}" 2>/dev/null || true; fi
		if [[ -e "${eng}/${p%/}" || -L "${eng}/${p%/}" ]]; then fail "can't set up nothing built here: ${p} is in the stub repository"; ctrSetUp=0; fi
	done
	if ((ctrSetUp)); then fCtrMounts "nothing built here"; fi
	## A gate worktree's target dir is a link to the checkout's target-gate.
	if [[ -e "${eng}/source/rust/target" || -L "${eng}/source/rust/target" ]]; then
		fail "can't set up a gate worktree: source/rust/target is in the stub repository"
	else
		mkdir -p "${work}/target-gate"; ln -s "${work}/target-gate" "${eng}/source/rust/target"
		fCtrMounts "a gate worktree"
		## The main image still builds into it, as the pre-push hook's run does.
		( cd "${eng}" && env -u SHCL_GATE_STRICT -u SHCL_GATE_SKIPS SHCL_DOCKER="${work}/fake-docker" SHCL_CTR_CACHE="${work}/ctrcache" \
			STUB_MOUNTS="${work}/mounts.tsv" bash "${eng}/cicd/cicd.bash" -y --no-sync --no-freeze --container ) > "${work}/ctr.log" 2>&1 \
			|| fail "the stubbed run in the main image failed: $(tail -3 "${work}/ctr.log")"
		awk -F'\t' -v d="${work}/target-gate" '$1 == d && $2 == d { f = 1 } END { exit !f }' "${work}/mounts.tsv" \
			|| fail "the main image doesn't build into a gate worktree's target-gate"
		rm -f "${eng}/source/rust/target"
	fi
	## Every CLI the build stage compiles into the tree has its own copy.
	for c in "${ctrClis[@]}"; do
		c="${c#*|}"; [[ "${c}" != *.py ]] || continue
		covered=0
		for p in "${ctrPrivate[@]}"; do
			if [[ "${c}" == "${p%/}" || "${c}" == "${p%/}/"* ]]; then covered=1; fi
		done
		((covered)) || fail "${c} is built into the tree, and CTR_PRIVATE has no copy of it for an extra image"
	done
else
	fTestSkipBlock
fi
fTest EtDCDE7 with docker answering, a run goes to the main image, which records and starts no other
## 2026101920461174: the run inside is told where it is, so it doesn't ask
## docker again. The tree it records is the one on disk, recipes included.
cp -r "${root}/cicd/container" "${eng}/cicd/"
mapfile -t ctrExtra < <(source "${root}/cicd/config.bash"; printf '%s\n' "${CTR_CONTEXT_EXTRA[@]}")
for f in "${ctrExtra[@]}"; do cp "${root}/${f}" "${eng}/${f}"; done
ctrTree="$("${eng}/cicd/utility/green-tree.bash" tree "${eng}")"
fCtr STUB_DOCKER_EXEC="${work}/docker.exec" -- --gate
innerRuns="$(wc -l < "${work}/docker.exec" 2>/dev/null || echo 0)"
ctrRecorded=0; if "${eng}/cicd/utility/green-tree.bash" passed "${eng}" "${ctrTree}"; then ctrRecorded=1; fi
innerArgs="$(sed -n 's/^runs cicd\.bash //p' "${work}/eng.log")"
if ((engRc != 0 || ran != 1 || noted != 0 || innerRuns != 1 || ctrRecorded != 1)) || [[ "${innerArgs}" != *--gate* || "${innerArgs}" == *container* ]]; then
	fail "a run with docker answering: exit ${engRc}, ran ${ran}, ${noted} note(s), ${innerRuns} run(s) in the image, recorded ${ctrRecorded}, inner args '${innerArgs}': $(tail -3 "${work}/eng.log")"
fi
fTest EtDCDE8 --container with a silent docker fails rather than run here
fCtr STUB_DOCKER_DOWN=1 -- -y --no-sync --container
if ((engRc != 1 || ran != 0)) || ! grep -qF "can't run: ${work}/fake-docker doesn't answer" "${work}/eng.log"; then
	fail "--container with docker down: exit ${engRc}, ran ${ran}: $(tail -3 "${work}/eng.log")"
fi
fTest EtDQOIx a run removes its temp dir, failed or stopped too
## 2026101920461153: a gate or test that fails or is killed leaves its scratch
## in TMPDIR. A run points TMPDIR at a dir of its own and removes it on any
## exit. The rest of TMPDIR, which here is work, stays.
: > "${work}/keep.me"
for tmpCase in "whole run|0|" "failed run|1|STUB_CROSS_FAIL=1" "stopped run|143|STUB_STOP=1"; do
	IFS='|' read -r tmpLabel tmpWant tmpEnv <<<"${tmpCase}"
	rm -f "${work}/eng.tmpdir"
	tmpEnvs=(STUB_TMPDIR="${work}/eng.tmpdir"); if [[ -n "${tmpEnv}" ]]; then tmpEnvs+=("${tmpEnv}"); fi
	## Quiet, or this shell says the stopped one was Terminated.
	fEngine "${tmpEnvs[@]}" -- --gate 2>/dev/null
	runTmp="$(cat "${work}/eng.tmpdir" 2>/dev/null || true)"
	if ((engRc != tmpWant)) || [[ "${runTmp}" != "${work}/"?* || -e "${runTmp}" ]] || ! grep -qF "cleanup: removed" "${work}/eng.log"; then
		fail "${tmpLabel}: exit ${engRc}, its TMPDIR '${runTmp}' $([[ -n "${runTmp}" && -e "${runTmp}" ]] && echo 'is still there' || echo 'is gone'): $(tail -3 "${work}/eng.log")"
	fi
done
[[ -e "${work}/keep.me" ]] || fail "a run removed a file in TMPDIR that isn't its own"
fTest Etl0lIy --keep-temp keeps the temp folder and containers of a run, and says where
## 2026102515494634: a whole, failed or stopped run keeps its folder, and the
## run in the image starts its containers without --rm and leaves them.
for tmpCase in "whole run|0|" "failed run|1|STUB_CROSS_FAIL=1" "stopped run|143|STUB_STOP=1"; do
	IFS='|' read -r tmpLabel tmpWant tmpEnv <<<"${tmpCase}"
	rm -f "${work}/eng.tmpdir"
	tmpEnvs=(STUB_TMPDIR="${work}/eng.tmpdir"); if [[ -n "${tmpEnv}" ]]; then tmpEnvs+=("${tmpEnv}"); fi
	fEngine "${tmpEnvs[@]}" -- --gate --keep-temp 2>/dev/null
	## The tests ran in the frozen copy, whose run folder is inside the kept one.
	runTmp="$(cat "${work}/eng.tmpdir" 2>/dev/null || true)"
	keptTmp="$(sed -n "/^\[ kept this run's temp folder: /{s/^\[ kept this run's temp folder: \(.*\) \]\$/\1/p;q;}" "${work}/eng.log" || true)"
	if ((engRc != tmpWant)) || [[ "${keptTmp}" != "${work}/"?* || "${runTmp}" != "${keptTmp}"* || ! -d "${runTmp}/left/deep" ]]; then
		fail "--keep-temp, ${tmpLabel}: exit ${engRc}, kept '${keptTmp}', its TMPDIR '${runTmp}' $([[ -n "${runTmp}" && -d "${runTmp}" ]] && echo 'is there' || echo 'is gone'): $(tail -3 "${work}/eng.log")"
	fi
	if [[ -n "${keptTmp}" && -d "${keptTmp}" ]]; then chmod -R u+rwX -- "${keptTmp}"; fi
done
rm -f "${work}/keep-args.txt"
fCtr STUB_DOCKER_ARGS="${work}/keep-args.txt" STUB_DOCKER_NOIMAGE=1 STUB_DOCKER_ZIG='512\t0.16.0\t0.16.0' STUB_MOUNTS="${work}/keep-lbl.tsv" -- -y --no-sync --keep-temp
keepRm="$(grep -E -- '--name shcl-[^ ]+-(build|fmt) ' "${work}/keep-args.txt" | grep -cF -- ' --rm ' || true)"
keepRuns="$(grep -cE -- '--name shcl-[^ ]+-(build|fmt) ' "${work}/keep-args.txt" || true)"
if ((engRc != 0 || keepRuns < 2 || keepRm != 0)) || ! grep -qF 'and its containers: docker ps -a --filter label=dev.run=shcl-run.' "${work}/eng.log"; then
	fail "--keep-temp in the image: exit ${engRc}, ${keepRuns} step run(s), ${keepRm} with --rm: $(tail -3 "${work}/eng.log")"
fi
fTest Etl3oti --list prints the steps the other flags would run and runs none
## 2026102515494634: the leak checks by length show it, and nothing runs, is
## recorded or is left in TMPDIR.
for listCase in '-y --no-sync --list|echo leak' '-y --no-sync --quick --list|echo fast' '--gate --list|Format (check only)'; do
	read -r -a listArgs <<< "${listCase%%|*}"
	rm -f "${work}/eng.leak" "${work}/eng.leakfast"
	ls -d "${work}"/shcl-run.* > "${work}/list.before" 2>/dev/null || true
	fEngine STUB_LEAK="${work}/eng.leak" STUB_LEAK_FAST="${work}/eng.leakfast" -- "${listArgs[@]}"
	ls -d "${work}"/shcl-run.* > "${work}/list.after" 2>/dev/null || true
	if ((engRc != 0 || engRecorded != 0)) || [[ -e "${work}/eng.leak" || -e "${work}/eng.leakfast" ]] || ! grep -qF -- "${listCase#*|}" "${work}/eng.log" \
		|| ! grep -qx '4/9  Tests' "${work}/eng.log" || ! cmp -s "${work}/list.before" "${work}/list.after"; then
		fail "cicd.bash ${listCase%%|*}: exit ${engRc}, recorded ${engRecorded}: $(tail -3 "${work}/eng.log")"
	fi
done
fTest EtlDIOQ each step opens and closes with a numbered, timed line under a rule
## 2026102416250060: Starting, then PASS or FAIL, as Step N of M, with only
## the steps that run counted, the same numbers in the frozen copy's run, and
## the first section naming each step that's off with its flag or reason.
fStepLines(){  ## fStepLines WANT -> "" when eng.log's step lines are whole, numbered 1 to WANT and in order
	awk -v want="$1" -v rule="$(printf '•%.0s' {1..79})" '
		function bad(m) { if (!err) err = m }
		/^\[ [0-9]{8}-[0-9]{6}\.[0-9]{2}: Step [0-9]+ of [0-9]+; (Starting|PASS|FAIL) / {
			split($0, a, /: Step | of |; /); n = a[2] + 0; m = a[3] + 0; word = a[4]; sub(/ .*/, "", word)
			if (m != want) bad("line " NR " counts " m " steps")
			if (word == "Starting") {
				if (open) bad("line " NR " starts a step inside step " open)
				if (n != done + 1) bad("line " NR " is step " n " after step " done)
				if (prev != rule || prev2 != "") bad("line " NR " has no blank line and 79-wide rule before it")
				open = n
			} else {
				if (n != open) bad("line " NR " closes step " n " while step " open " is open")
				open = 0; done = n
			}
		}
		{ prev2 = prev; prev = $0 }
		END { if (!err && open) err = "step " open " never closed"; if (!err && done != want) err = done " of " want " steps ran"; print err }
	' "${work}/eng.log"
}
fEngine -- -y --no-sync
stepErr="$(fStepLines 5)"
if ((engRc != 0)) || [[ -n "${stepErr}" ]] || ! grep -qxF 'Steps ..........: 5' "${work}/eng.log" \
	|| ! grep -qxF 'Off ............: Remote sync (--no-sync)' "${work}/eng.log" || (($(grep -c '^Off \.' "${work}/eng.log" || true) != 6)) \
	|| ! grep -qE '^\[ [0-9.-]+: Step 5 of 5; PASS Release builds \]$' "${work}/eng.log"; then
	fail "a run with no sync: exit ${engRc}, ${stepErr:-step lines whole}: $(grep -E '^Off|Step [0-9]' "${work}/eng.log" | tail -8 || true)"
fi
fEngine STUB_CROSS_FAIL=1 -- -y --no-sync
stepErr="$(fStepLines 5)"
if ((engRc == 0)) || [[ -n "${stepErr}" ]] \
	|| ! grep -qE '^\[ [0-9.-]+: Step 5 of 5; FAIL Release builds \]$' "${work}/eng.log" || grep -qF 'PASS Release builds' "${work}/eng.log"; then
	fail "a run whose cross check fails: exit ${engRc}, ${stepErr}: $(grep -E 'Step [0-9]' "${work}/eng.log" | tail -3 || true)"
fi
fEngine -- --gate
stepErr="$(fStepLines 5)"
if ((engRc != 0)) || [[ -n "${stepErr}" ]] || ! grep -qE '^\[ [0-9.-]+: Step 1 of 5; Starting Format \(check only\) \]$' "${work}/eng.log" \
	|| ! grep -qxF 'Off ............: Remote sync (--gate)' "${work}/eng.log"; then
	fail "a --gate run: exit ${engRc}, ${stepErr:-step lines whole}: $(grep -E '^Off|Step [0-9]' "${work}/eng.log" | tail -8 || true)"
fi
## An extra image's own flags take out Format, Lint and the cross checks in
## there, so the run here counts only Build and Tests.
if [[ -d "${eng}/cicd/container" ]]; then
	fCtr STUB_DOCKER_EXEC="${work}/docker.exec" -- -y --no-sync --no-freeze --container=alpine
	stepErr="$(fStepLines 2)"
	if ((engRc != 0)) || [[ -n "${stepErr}" ]] || ! grep -qxF 'Off ............: Lint (--container=alpine)' "${work}/eng.log" \
		|| ! grep -qE '^\[ [0-9.-]+: Step 2 of 2; PASS Tests \]$' "${work}/eng.log"; then
		fail "an alpine run: exit ${engRc}, ${stepErr:-step lines whole}: $(grep -E '^Off|Step [0-9]' "${work}/eng.log" | tail -8 || true)"
	fi
fi
fTest EtDQOMF a whole run removes a profiler sample file whose graph is gone
## 2026101920461153: the rotation prunes a graph and leaves the sample count
## beside it. One whose graph is still there stays, whatever its role now.
profDir="${eng}/cicd/artifacts/profiling"
mkdir -p "${profDir}"
printf '9 10\n' > "${profDir}/flame_20200101-000000_frequent.svg.samples"
printf '9 10\n' > "${profDir}/flame_20200102-000000_frequent.svg.samples"
echo svg > "${profDir}/flame_20200102-000000_first.svg"
fEngine STUB_PROFILE="${work}/eng.prof" -- -y --no-sync
if ((engRc != 0)) || [[ -e "${profDir}/flame_20200101-000000_frequent.svg.samples" || ! -e "${profDir}/flame_20200102-000000_frequent.svg.samples" ]]; then
	fail "the profiler's sample files after a run: exit ${engRc}, $(cd "${profDir}" && ls -m): $(tail -3 "${work}/eng.log")"
fi
grep -qF "1 profiler sample file(s) whose graph is gone" "${work}/eng.log" || fail "the cleanup line doesn't count the sample file: $(grep -F cleanup: "${work}/eng.log" || true)"
fTest EtDQOPc a run in the image removes our stale images and containers, and nothing else
## 2026101920461153: a tag of ours the tree's recipe no longer hashes to, every
## tag of a name with no recipe, and a dangling image or stopped container
## with our label. Another project's image, even one named like ours, stays.
## ctr-image.bash on eng, in a shell of its own: "tags" prints the tag each
## recipe hashes to, and "self" runs fCtrRunSelf.
cat > "${work}/ctr-image-on.bash" <<'EOF'
set -euo pipefail
root="$1"; cd "${root}"
CPU_CAP=1
source cicd/config.bash
source cicd/utility/include/ctr-image.bash
## As the gates do: ask first.
if [[ "$2" == self ]]; then
	whyNot="$(fCtrWhyNot)"; [[ -z "${whyNot}" ]] || { echo "no image: ${whyNot}" >&2; exit 2; }
	mkdir -p "$3"; fCtrRunSelf "$3" "" "${root}/cicd/cicd.bash"; exit
fi
for r in cicd/container/*Dockerfile; do
	n="${r##*/}"; n="${n%.Dockerfile}"; if [[ "${n}" == Dockerfile ]]; then n=main; fi
	c="$(mktemp -d)"; fCtrContext "${r}" "${c}"; fCtrTag "${c}" "${n}"
done
EOF
mapfile -t ctrNow < <(bash "${work}/ctr-image-on.bash" "${eng}" tags || true)
((${#ctrNow[@]} >= 2)) || fail "could not work out the images' current tags: ${ctrNow[*]}"
## 2026102416250030: the newest tag but the current one stays, as the one
## before it, so the 111111111111 tags stay. A name with no recipe keeps none.
printf '%s\n' shcl-cicd:000000000000 shcl-cicd-alpine:000000000000 shcl-cicd-gone:000000000000 shcl-cicd:111111111111 \
	shcl-cicd-alpine:111111111111 shcl-cicd-gone:111111111111 "${ctrNow[@]}" shclwrap-c-tools:1 other-cicd:1 shcl-cicd-x:y:1 '<none>:<none>' > "${work}/images.txt"
rm -f "${work}/gone.txt" "${work}/prune.txt"
fCtr STUB_DOCKER_IMAGES="${work}/images.txt" STUB_DOCKER_GONE="${work}/gone.txt" STUB_DOCKER_DANGLING=d0d0 STUB_DOCKER_STOPPED=c0c0 STUB_DOCKER_PRUNE="${work}/prune.txt" -- --gate
sweptGot="$(sort "${work}/gone.txt" 2>/dev/null | paste -sd ' ' || true)"
sweptWant="rm c0c0 rmi d0d0 rmi shcl-cicd-alpine:000000000000 rmi shcl-cicd-gone:000000000000 rmi shcl-cicd-gone:111111111111 rmi shcl-cicd:000000000000"
if ((engRc != 0)) || [[ "${sweptGot}" != "${sweptWant}" ]]; then
	fail "the sweep after a run in the image: exit ${engRc}, removed '${sweptGot}', want '${sweptWant}': $(tail -3 "${work}/eng.log")"
fi
grep -qF "shcl-cicd:000000000000" <(grep -F 'cleanup: removed' "${work}/eng.log") || fail "the cleanup line doesn't name the image it removed"
## After the sweep, a week of build cache stays, and the line has docker's
## sizes from before and after.
[[ "$(cat "${work}/prune.txt" 2>/dev/null)" == "builder prune -f --filter until=168h" ]] || fail "the build cache prune after the sweep: '$(cat "${work}/prune.txt" 2>/dev/null)'"
grep -F 'cleanup: removed' "${work}/eng.log" | grep -qF "; docker images 2GB -> 1GB, containers 0B -> 0B, volumes 119MB -> 119MB, build cache 5GB -> 5GB" \
	|| fail "the cleanup line doesn't compare docker system df before and after: $(grep -F 'cleanup:' "${work}/eng.log" || true)"
fTest EtDQOSv a gate that builds the image removes the tags it replaces
## 2026101920461153: the leak checks build the image when it's missing, and
## that build left the old tag behind. Only the name it built is touched.
rm -f "${work}/gone.txt"
selfOut="$(SHCL_DOCKER="${work}/fake-docker" STUB_DOCKER_NOIMAGE=1 STUB_DOCKER_IMAGES="${work}/images.txt" STUB_DOCKER_GONE="${work}/gone.txt" \
	STUB_MOUNTS="${work}/self.tsv" PATH="${work}/x86_64:${PATH}" bash "${work}/ctr-image-on.bash" "${eng}" self "${work}/self" 2>&1)" || true
selfGot="$(sort "${work}/gone.txt" 2>/dev/null | paste -sd ' ' || true)"
[[ "${selfGot}" == "rmi shcl-cicd:000000000000" ]] || fail "a gate's build of the image removed '${selfGot}', want the oldest main tag only, since the one before stays: ${selfOut}"
fTest Etg0eIJ a run in the main image empties the Zig cache volume over 2 GB or filled by another Zig, and keeps it otherwise
## 2026102416250020: Zig's cache is a labeled volume of the main image's own,
## and it goes whole, never part of it.
for zigCase in "over the cap|2097153\t0.16.0\t0.16.0|volume rm shcl-zig-cache" "another Zig|512\t0.15.2\t0.16.0|volume rm shcl-zig-cache" \
	"at the cap|2097152\t0.16.0\t0.16.0|" "a stamp it can't read|garbage|" "no volume||"; do
	IFS='|' read -r zigLabel zigHas zigWant <<<"${zigCase}"
	rm -f "${work}/gone.txt" "${work}/vols.txt"
	fCtr STUB_DOCKER_GONE="${work}/gone.txt" STUB_DOCKER_VOLS="${work}/vols.txt" STUB_DOCKER_ZIG="${zigHas}" STUB_MOUNTS="${work}/zig.tsv" -- --gate
	awk -F'\t' '$1 == "shcl-zig-cache" && $2 == "/zig-cache" { f = 1 } END { exit !f }' "${work}/zig.tsv" \
		|| fail "Zig's cache volume, ${zigLabel}: the main image doesn't get it at /zig-cache"
	zigGot="$(grep -F volume "${work}/gone.txt" 2>/dev/null || true)"
	if ((engRc != 0)) || [[ "${zigGot}" != "${zigWant}" ]]; then
		fail "Zig's cache volume, ${zigLabel}: exit ${engRc}, removed '${zigGot}', want '${zigWant}': $(tail -3 "${work}/eng.log")"
	fi
	if [[ -n "${zigWant}" ]] && ! grep -F 'cleanup: removed' "${work}/eng.log" | grep -qF "the shcl-zig-cache volume"; then
		fail "Zig's cache volume, ${zigLabel}: the cleanup line doesn't name it"
	fi
	[[ "$(cat "${work}/vols.txt" 2>/dev/null)" =~ ^"volume create --label dev.project=shcl --label dev.run=shcl-run."[A-Za-z0-9]+" shcl-zig-cache"$ ]] \
		|| fail "Zig's cache volume, ${zigLabel}: made as '$(cat "${work}/vols.txt" 2>/dev/null)', want our label on it before the run"
done
fTest EtgFdOY what a run makes in docker carries its labels, and each container its name
## 2026102416250030: dev.project and dev.run, the run folder's name, on each
## container, image and volume, and containers named shcl-RUN-STEP.
rm -f "${work}/args.txt"
fCtr STUB_DOCKER_ARGS="${work}/args.txt" STUB_DOCKER_NOIMAGE=1 STUB_DOCKER_ZIG='512\t0.16.0\t0.16.0' STUB_MOUNTS="${work}/lbl.tsv" -- -y --no-sync
lblRun="$(grep -oE 'dev\.run=[^ ]*' "${work}/args.txt" 2>/dev/null | sed -n '1s/^dev\.run=//p' || true)"
lblBad="$(grep -vF -- "--label dev.project=shcl --label dev.run=${lblRun} " "${work}/args.txt" || true)"
mapfile -t lblNames < <(grep -oE -- '--name [^ ]+' "${work}/args.txt" | cut -d' ' -f2 | LC_ALL=C sort)
lblWant="$(printf "shcl-${lblRun}-%s\n" build build-group build-passwd fmt fmt-group fmt-passwd zig-trim | LC_ALL=C sort | paste -sd' ')"
lblBuilds="$(grep -c '^build ' "${work}/args.txt" || true)"; lblVols="$(grep -c '^volume create ' "${work}/args.txt" || true)"
if ((engRc != 0 || lblBuilds < 1 || lblVols < 1)) || [[ ! "${lblRun}" =~ ^shcl-run\.[A-Za-z0-9]+$ || -n "${lblBad}" ]]; then
	fail "the labels on what a run makes: exit ${engRc}, run '${lblRun}', ${lblBuilds} build(s), ${lblVols} volume(s), without both labels: ${lblBad:-none}: $(tail -2 "${work}/eng.log")"
fi
[[ "$(printf '%s\n' "${lblNames[@]}" | paste -sd' ')" == "${lblWant}" ]] || fail "the containers' names: '${lblNames[*]}', want '${lblWant}'"
fTest EtgShUg every container a run starts has a CPU quota and a low share
## 2026102421025783: nice on the docker client doesn't reach the container.
cpuRuns="$(grep -c '^run ' "${work}/args.txt" || true)"
cpuBad="$(grep '^run ' "${work}/args.txt" | grep -vE -- ' --cpus [1-9][0-9]* --cpu-shares 256 ' || true)"
if ((cpuRuns < 7)) || [[ -n "${cpuBad}" ]]; then
	fail "the CPU limits on a run's containers: ${cpuRuns} run(s), without --cpus and --cpu-shares 256: ${cpuBad:-none}"
fi
## The scripts a gate runs in the image, which this stub doesn't start.
# shellcheck disable=SC2016  ## ctr-image.bash's own text, matched literally
grep -qF '"${tag}" nice -n 19 bash "$@"' "${root}/cicd/utility/include/ctr-image.bash" || fail "fCtrRunSelf no longer runs its script under nice in the image"
fTest EtgFdh7 a run that fails stops and removes its containers by its run label
## 2026102416250030: on any exit, not only a whole run, and only this run's.
rm -f "${work}/gone.txt"
fCtr STUB_DOCKER_RUNFAIL=1 STUB_DOCKER_RUNNING=r1r1 STUB_DOCKER_GONE="${work}/gone.txt" -- --gate
runGot="$(paste -sd' ' "${work}/gone.txt" 2>/dev/null || true)"
if ((engRc != 1)) || [[ "${runGot}" != "stop r1r1 rm r1r1" ]] || ! grep -qF "stopped and removed 1 container(s) of this run" "${work}/eng.log"; then
	fail "a failed run's containers: exit ${engRc}, stopped and removed '${runGot}', want 'stop r1r1 rm r1r1': $(tail -3 "${work}/eng.log")"
fi
## A run started here and stopped by a TERM to its PID alone, once PIDFILE
## names the process it hangs on.
fStopRun(){  ## fStopRun PIDFILE [VAR=VALUE ...] -- ARGS... -> stopRc, stopPid, stopLeft (1 if stopPid outlived the run)
	local pidFile="$1" envs=() ePid i
	shift
	while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
	rm -f "${pidFile}" "${pidFile}.tmp"
	env -u SHCL_GATE_STRICT -u SHCL_GATE_SKIPS SHCL_DOCKER="${work}/no-docker" "${envs[@]}" bash "${eng}/cicd/cicd.bash" "$@" > "${work}/stop.log" 2>&1 &
	ePid=$!
	for ((i = 0; i < 300; i++)); do [[ -s "${pidFile}" ]] && break; sleep 0.2; done
	stopPid="$(cat "${pidFile}" 2>/dev/null || true)"
	kill -TERM "${ePid}" 2>/dev/null || true
	stopRc=0; wait "${ePid}" || stopRc=$?
	stopLeft=0
	if [[ -n "${stopPid}" ]] && kill -0 "${stopPid}" 2>/dev/null; then stopLeft=1; kill -KILL "${stopPid}" 2>/dev/null || true; fi
}
fTest EtNhygG a stopped run takes down the run in the frozen copy and what it started
## 2026101920461153: a TERM to the run's PID ended the run and left its
## children going, over a frozen copy and a temp dir already gone.
fStopRun "${work}/hang.pid" STUB_HANG="${work}/hang.pid" -- --gate --no-container
stopTmp="$(cat "${work}/hang.pid.tmp" 2>/dev/null || true)"
stopTrees="$(git -C "${eng}" worktree list --porcelain | grep -c '^worktree ' || true)"
if ((stopRc != 143 || stopLeft || stopTrees != 1)) || [[ -z "${stopPid}" || -z "${stopTmp}" || -e "${stopTmp}" ]] || ! grep -qF "cleanup: stopped" "${work}/stop.log"; then
	fail "a stopped local run: exit ${stopRc}, its test's child $( ((stopLeft)) && echo 'outlived it' || echo "'${stopPid}' went"), ${stopTrees} worktree(s), the copy's TMPDIR '${stopTmp}': $(tail -3 "${work}/stop.log")"
fi
fTest EtNhz0U a stopped run in the image kills a container whose client will not stop
## 2026101920461153: docker passes a TERM to the container and waits for it.
## A client that doesn't is KILLed after the wait, which would leave the
## container up, so the run kills it by the ID docker wrote down.
rm -f "${work}/gone.txt"
fStopRun "${work}/dhang.pid" SHCL_DOCKER="${work}/fake-docker" STUB_DOCKER_HANG="${work}/dhang.pid" STUB_DOCKER_STUBBORN=1 STUB_DOCKER_GONE="${work}/gone.txt" STUB_DOCKER_RUNNING=r2r2 \
	SHCL_STOP_WAIT=2 SHCL_CTR_CACHE="${work}/ctrcache" PATH="${work}/x86_64:${PATH}" -- --gate
stopKilled="$(grep -c '^kill c1d0c1d0c1d0$' "${work}/gone.txt" 2>/dev/null || true)"
## 2026102416250030: and then what's left of this run, by its label.
grep -qx 'stop r2r2' "${work}/gone.txt" 2>/dev/null || fail "a stopped run in the image didn't stop its containers by its run label: $(paste -sd' ' "${work}/gone.txt" 2>/dev/null || true)"
if ((stopRc != 143 || stopLeft || stopKilled != 1)) || [[ -z "${stopPid}" ]] || ! grep -qF "by KILL after 2 s" "${work}/stop.log"; then
	fail "a stopped run in the image: exit ${stopRc}, the client $( ((stopLeft)) && echo 'outlived it' || echo "'${stopPid}' went"), ${stopKilled:-0} kill(s) of its container: $(tail -3 "${work}/stop.log")"
fi

fTestEnd
(( rc == 0 )) && echo "check-push-gate: OK: the tree matches a commit of the working copy, a recorded tree skips the gate, only a push to main runs it with the full gate, a red gate refuses, the gate builds into target-gate and runs once on main's commit in a multi-ref push, no gate sees a linked worktree's GIT_DIR, the drift check judges the pushed tree as main, a cut needs the banner tag on the remote or in the push, and a partial run records nothing"
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
##		- 2026-10-01 JC: A cut pushed to main needs the banner's tag.
##		- 2026-10-04 JC: A banner the check cannot read, this checkout's own
##		  banner, and a tag on a commit at another version.
##		- 2026-10-16 JC: A local --no-tests run keeps the profiler calibration, and an
##		  extra --container image's mounts leave this tree's builds alone.
##		- 2026-10-19 JC: --gate in place of --ci, and an engine from before it. --quick leaves out what QUICK_SKIP names.
##		- 2026-10-19 JC: --leakcheck, and the leak checks in a run with no flags.
##		- 2026-10-19 JC: --no-leakcheck, and the pair refused.
##		- 2026-10-19 JC: A run goes to the main image when docker answers, and --no-container.
##		- 2026-10-19 JC: A run's own temp dir, and the cleanup of stale images, containers and sample files.
##		- 2026-10-24 JC: Zig's cache volume in the main image, and when a run empties it.
##		- 2026-10-24 JC: The gate worktree half of the extra image check runs every time.
##		- 2026-10-24 JC: The run labels and container names, a failed or stopped run's containers, the tag
##		  before the current one, the build cache prune and the docker sizes on the cleanup line.
##		- 2026-10-25 JC: The leak checks by length, and --long.
##		- 2026-10-25 JC: --merge-gate and --ci, and the hook's call of each engine's gate.
##		- 2026-10-25 JC: A push to main of docs alone, and --keep-temp.
