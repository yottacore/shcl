#!/usr/bin/env bash

##	Purpose:
##		Run install-dev.bash against a throwaway clone and check what it leaves
##		behind. --hooks-only covers the tail. The stocktaking and the plan in
##		front of it run too, against a fixture config with every tool they would
##		install stubbed on PATH, so no install and no fetch happens here. Both
##		halves run the shipped script, not a copy of its logic.
##	Syntax:
##		check-install-dev.bash
##	Exit: 0 = all checks pass, 1 = a check failed (named), 2 = cannot set up.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=check-install-dev; testCounter=nFail

## With GIT_DIR set, the clone and `git init` below act on the real repository.
for gitVar in $(git rev-parse --local-env-vars 2>/dev/null || true); do unset "${gitVar}"; done

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/install-dev.bash"
[[ -r "${script}" ]] || { echo "check-install-dev: cannot read ${script}" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
## --no-hardlinks: /tmp is routinely a different filesystem from the repo.
git clone -q --no-hardlinks --local "${root}" "${work}/clone" || { echo "check-install-dev: local clone failed" >&2; exit 2; }

rc=0; declare -i nFail=0
fail() { echo "check-install-dev: FAIL: $*" >&2; rc=1; nFail+=1; }

fTest EoeB8tE --hooks-only by --dir sets the hooks path and keepalive
## From a neutral cwd, pointed at the clone by --dir: sets both configs.
( cd "${work}" && bash "${script}" --hooks-only --dir clone >/dev/null )
[[ "$(git -C "${work}/clone" config core.hooksPath)" == "cicd/hooks" ]] || fail "hooksPath not set"
[[ "$(git -C "${work}/clone" config core.sshCommand)" == *ServerAliveInterval* ]] || fail "ssh keepalive not set"

fTest EoeB8tF a second --hooks-only run changes nothing
## Idempotent: a second run changes nothing and still exits 0.
before="$(git -C "${work}/clone" config --list --local)"
( cd "${work}" && bash "${script}" --hooks-only --dir clone >/dev/null ) || fail "second run failed"
[[ "$(git -C "${work}/clone" config --list --local)" == "${before}" ]] || fail "second run changed the config"

fTest EoeB8tG a configured sshCommand survives
## A chosen sshCommand survives: the keepalive is only for the unconfigured.
git -C "${work}/clone" config core.sshCommand "ssh -i /keep/this"
( cd "${work}/clone" && bash "${script}" --hooks-only >/dev/null )
[[ "$(git -C "${work}/clone" config core.sshCommand)" == "ssh -i /keep/this" ]] || fail "a configured sshCommand was overwritten"

fTest EoeB8tH a run inside the clone finds it with no --dir
## Run inside the clone with no --dir: the in-clone detection finds it.
## `--unset` exits 5 when the key is not there, which under errexit would end
## the run here and take every check below it with it.
git -C "${work}/clone" config --unset core.hooksPath || true
( cd "${work}/clone" && bash "${script}" --hooks-only >/dev/null )
[[ "$(git -C "${work}/clone" config core.hooksPath)" == "cicd/hooks" ]] || fail "in-clone run did not set hooksPath"

fTest Er20EK0 --hooks-only sets the hooks in a worktree
## 20260830 item 43: in a worktree .git is a file, and the hooks were skipped
## there. The key is shared with the main checkout, so it comes off first.
git -C "${work}/clone" worktree add -q --detach "${work}/wt"
git -C "${work}/clone" config --unset core.hooksPath || true
if ( cd "${work}" && bash "${script}" --hooks-only --dir wt >/dev/null 2>&1 ); then
	[[ "$(git -C "${work}/wt" config core.hooksPath || true)" == "cicd/hooks" ]] || fail "a worktree did not get the hooks"
else
	fail "--hooks-only refused a worktree"
fi

fTest Ep10fNQ --hooks-only refuses a repository that is not a clone
## Not a clone: refused, and nothing written. The fixture is a repository that
## is not an shcl clone, since that is what the guard is for - a bare directory
## fails inside git config whether the guard is there or not, and the config
## is read back because the exit status alone proved nothing either way.
git init -q "${work}/other"
if ( cd "${work}" && bash "${script}" --hooks-only --dir other >/dev/null 2>&1 ); then
	fail "--hooks-only accepted a repository that is not an shcl clone"
fi
[[ -z "$(git -C "${work}/other" config --local core.hooksPath || true)" ]] || fail "a refused run set hooksPath on a foreign repository"
[[ -z "$(git -C "${work}/other" config --local core.sshCommand || true)" ]] || fail "a refused run set sshCommand on a foreign repository"

fTest Ep10fNR --hooks-only refuses a tree that is not a repository
## An shcl-shaped tree that is not a repository: refused too.
mkdir -p "${work}/tree/cicd"
cp "${root}/cicd/cicd.bash" "${work}/tree/cicd/"
if ( cd "${work}" && bash "${script}" --hooks-only --dir tree >/dev/null 2>&1 ); then
	fail "--hooks-only accepted a tree that is not a repository"
fi

fTest Eq5i0NM the default path refuses a foreign repository up front
## The default path, not --hooks-only, pointed at a repository that is not
## shcl: refused before anything is fetched, with its branch and config as
## they were. The refusal comes ahead of the network, so this runs offline.
git -C "${work}/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "${work}/other" branch -q dev
other_branch="$(git -C "${work}/other" branch --show-current)"
## The message is read too: without the guard the run can still fail later,
## on the network, for a reason that has nothing to do with this.
if ( cd "${work}" && bash "${script}" --yes --dir other >"${work}/out" 2>&1 </dev/null ); then
	fail "the default path accepted a repository that is not an shcl clone"
fi
grep -qF "is not an shcl clone" "${work}/out" || fail "the default path did not refuse a foreign repository up front"
[[ "$(git -C "${work}/other" branch --show-current)" == "${other_branch}" ]] || fail "a refused run switched a foreign repository's branch"
[[ -z "$(git -C "${work}/other" config --local core.hooksPath || true)" ]] || fail "the default path set hooksPath on a foreign repository"

fTest Eq5i0NN the default path refuses a non-empty directory
## A non-empty directory that is no repository at all is refused the same way.
mkdir -p "${work}/stuff" && : >"${work}/stuff/keep"
if ( cd "${work}" && bash "${script}" --yes --dir stuff >"${work}/out" 2>&1 </dev/null ); then
	fail "the default path accepted a non-empty directory that is not a clone"
fi
grep -qF "is not an shcl clone" "${work}/out" || fail "the default path did not refuse a non-empty directory up front"

fTest EqRTWFd the plan is built off the pins in the config
## 20260920 idea 6: everything between the option parse and the hook setup ran
## in no gate - reading the pins, deciding what is already at its pin, and
## building the plan. Run the default path inside the throwaway clone against a
## fixture config, with every tool it would install stubbed on PATH, so nothing
## is installed and nothing is fetched.
## A scratch HOME too: the script puts ~/.cargo/bin and the go bin dir in front
## of PATH, which would reach past the stubs to the real tools, and an install
## that got through would end up in the real home.
mkdir -p "${work}/home"
stub="${work}/stub"; mkdir -p "${stub}"
# shellcheck disable=SC2016  ## the stub's own text, expanded when the stub runs
fStub(){ printf '#!/bin/sh\necho "STUB $(basename "$0") $*" >> "%s/stub.log"\n%s\n' "${work}" "$2" > "${stub}/$1"; chmod +x "${stub}/$1"; }
fStub pipx            'exit 0'
fStub npm             'exit 0'
fStub pwsh            'exit 0'
fStub ruff            'echo "ruff 9.9.9"'
fStub mypy            'echo "mypy 0.0.1"'
fStub cppcheck        'exit 1'
fStub pyproject-build 'echo 9.9.9'
fStub markdownlint-cli2 'echo 9.9.9'
fStub staticcheck     'echo 9.9.9'
fStub govulncheck     'echo 9.9.9'
fStub cargo           'echo 9.9.9'
# shellcheck disable=SC2016  ## same, and ${work} is spliced in on purpose
fStub go              'if [ "$1" = env ]; then echo "'"${work}"'/gopath"; else echo 9.9.9; fi'

## One pin at the fixture version, one drifted, one missing, and a cppcheck
## wheel version that is not the binary's - which is the pair the plan has to
## keep straight.
cat > "${work}/pins.bash" <<'CFGEOF'
TOOL_PINS=(
	"ruff|9.9.9|ruff --version"
	"mypy|9.9.9|mypy --version"
	"cppcheck|9.9.9|cppcheck --version"
	"build|9.9.9|pyproject-build --version"
	"markdownlint-cli2|9.9.9|markdownlint-cli2 --help"
	"staticcheck|9.9.9|staticcheck -version"
	"govulncheck|9.9.9|govulncheck -version"
	"cargo-deny|9.9.9|cargo deny --version"
)
CPPCHECK_WHEEL="7.7.7"
CFGEOF
cp "${work}/pins.bash" "${work}/clone/cicd/config.bash"

( cd "${work}/clone" && HOME="${work}/home" PATH="${stub}:${PATH}" bash "${script}" --yes >"${work}/plan" 2>&1 </dev/null ) \
	|| fail "the default path failed inside a clone with every install stubbed: $(tail -n 3 "${work}/plan")"
grep -qF 'cppcheck 9.9.9 (pipx cppcheck==7.7.7, user-space)' "${work}/plan" \
	|| fail "the plan does not name both cppcheck versions: $(grep -i cppcheck "${work}/plan" | tr '\n' ' ')"
grep -qF 'mypy 9.9.9 (pipx, user-space)' "${work}/plan" || fail "the plan leaves out a tool whose version drifted off its pin"
grep -qF 'ruff 9.9.9' "${work}/plan" && fail "the plan offers to install a tool already at its pin"
grep -qF 'STUB pipx install --force cppcheck==7.7.7' "${work}/stub.log" \
	|| fail "the cppcheck install did not ask for the wheel version"
grep -qF 'STUB pipx install --force ruff' "${work}/stub.log" && fail "a tool already at its pin was installed anyway"

fTest Er20EK1 the default path sets the hooks in a worktree
## The default path ends on the same hooks setup, behind its own .git test.
cp "${work}/pins.bash" "${work}/wt/cicd/config.bash"
git -C "${work}/clone" config --unset core.hooksPath || true
( cd "${work}/wt" && HOME="${work}/home" PATH="${stub}:${PATH}" bash "${script}" --yes >"${work}/wt.out" 2>&1 </dev/null ) \
	|| fail "the default path failed in a worktree: $(tail -n 3 "${work}/wt.out")"
[[ "$(git -C "${work}/wt" config core.hooksPath || true)" == "cicd/hooks" ]] || fail "the default path in a worktree did not set the hooks"

fTest EqzwPFA with no terminal the refusal comes first
## 20260829 item 20: with no terminal, the prompt's own open of /dev/tty
## failed out loud before the message saying so. setsid leaves no terminal.
ttyRc=0
( cd "${work}/clone" && HOME="${work}/home" PATH="${stub}:${PATH}" setsid -w bash "${script}" >/dev/null 2>"${work}/tty.err" </dev/null ) || ttyRc=$?
[[ "${ttyRc}" != 0 && "$(head -n1 "${work}/tty.err")" == "install-dev.bash: no terminal to confirm on - pass --yes" ]] \
	|| fail "with no terminal the refusal is not the first thing said (exit ${ttyRc}): $(head -n1 "${work}/tty.err")"

fTest EqzwPFB a fresh clone by a relative --dir gets the hooks
## 20260822 item 1: the script changed into a fresh clone and then looked for
## it by the relative --dir it was given, so the hooks were skipped at exit 0.
## The default path from an empty directory, with git's clone taken from this
## checkout and the pins fetch answered with the fixture config, so nothing
## leaves the box.
net="${work}/netstub"; mkdir -p "${net}" "${work}/empty"
realGit="$(command -v git)"
# shellcheck disable=SC2016  ## the stub's own text
printf '#!/bin/sh
if [ "$1" = clone ]; then exec "%s" clone -q --no-hardlinks "%s" "$3"; fi
exec "%s" "$@"
' "${realGit}" "${root}" "${realGit}" > "${net}/git"
# shellcheck disable=SC2016  ## the stub's own text
printf '#!/bin/sh
while [ $# -gt 1 ]; do [ "$1" = -o ] && cp "%s" "$2"; shift; done
' "${work}/pins.bash" > "${net}/curl"
chmod +x "${net}/git" "${net}/curl"
( cd "${work}/empty" && HOME="${work}/home" PATH="${net}:${stub}:${PATH}" bash "${script}" --yes --dir fresh >"${work}/fresh.out" 2>&1 </dev/null ) \
	|| fail "the default path failed on a fresh clone: $(tail -n 3 "${work}/fresh.out")"
[[ "$(git -C "${work}/empty/fresh" config --local core.hooksPath || true)" == "cicd/hooks" ]] \
	|| fail "a fresh clone by a relative --dir did not get the hooks: $(tail -n 3 "${work}/fresh.out")"

fTest EqRTWFe a config with no CPPCHECK_WHEEL is refused
## The wheel version is read out of the config, not carried in the script: with
## the line gone the run refuses rather than installing whatever pipx has.
grep -v '^CPPCHECK_WHEEL=' "${work}/clone/cicd/config.bash" > "${work}/cfg.nowheel"
cp "${work}/cfg.nowheel" "${work}/clone/cicd/config.bash"
if ( cd "${work}/clone" && HOME="${work}/home" PATH="${stub}:${PATH}" bash "${script}" --yes >"${work}/plan2" 2>&1 </dev/null ); then
	fail "the plan was built with no CPPCHECK_WHEEL in the config"
fi
grep -qF "no CPPCHECK_WHEEL" "${work}/plan2" || fail "a missing CPPCHECK_WHEEL is not named: $(tail -n 2 "${work}/plan2")"

fTestEnd
(( rc == 0 )) && echo "check-install-dev: OK: --hooks-only sets the hooks path and keepalive, idempotently, and refuses a non-clone; the default path refuses one too, builds its plan off the config's pins, says first that it has no terminal, and hooks up a fresh clone and a worktree"
exit "${rc}"


##	History:
##		- 2026-09-01 JC: Created.
##		- 2026-09-19 JC: Clears git's local environment first.
##		- 2026-09-20 JC: The pin reader, the at-pin test and the plan, against a
##		                 fixture config with stubbed tools.
##		- 2026-09-26 JC: A prompt with no terminal, and a fresh clone by a
##		                 relative --dir, with git and curl stubbed.
##		- 2026-09-26 JC: A worktree, where .git is a file, on both paths.
