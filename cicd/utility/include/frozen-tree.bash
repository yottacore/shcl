#!/usr/bin/env bash

##	Purpose:
##		A detached worktree that holds one tree for as long as a run needs it, so
##		a merge, a checkout or an edit in the checkout can't reach a build that
##		reads it (2026102108300000). Sourced by cicd.bash and the pre-push hook.
##		It's locked while it exists, so a prune from any other tool passes over
##		it, and it's taken down with `worktree remove`, never a prune, which is
##		global (2026102021300000).
##	Functions:
##		fFrozenAdd REPO DEST REV [TREE]   DEST holds REV, or TREE on top of REV
##		                                  when given (uncommitted work included)
##		fFrozenLink REPO DEST PATH [TO]   DEST/PATH links to TO, or to REPO/PATH,
##		                                  resolved, so a container mount can follow it
##		fFrozenRemove REPO DEST           unlock and remove it
##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## Quiet on success; git's own message on failure.
fFrozenAdd(){
	local repo="$1" dest="$2" rev="$3" tree="${4:-}" out=""
	if [[ -z "${tree}" ]]; then
		out="$(git -C "${repo}" worktree add --detach --lock --reason "frozen run tree" "${dest}" "${rev}" 2>&1)" || { echo "${out}" >&2; return 1; }
		return 0
	fi
	out="$(git -C "${repo}" worktree add --detach --lock --reason "frozen run tree" --no-checkout "${dest}" "${rev}" 2>&1)" || { echo "${out}" >&2; return 1; }
	## The index then holds TREE too, so git status in there shows what was
	## carried over from the checkout as staged.
	out="$(git -C "${dest}" read-tree --reset -u "${tree}" 2>&1)" || { echo "${out}" >&2; fFrozenRemove "${repo}" "${dest}"; return 1; }
}

fFrozenLink(){
	local repo="$1" dest="$2" path="${3%/}" to="${4:-}"
	if [[ -z "${to}" ]]; then
		to="$(readlink -f -- "${repo}/${path}")" || return 1
	fi
	mkdir -p -- "${to}" "$(dirname -- "${dest}/${path}")" || return 1
	## -T: on a path that's already a dir, a plain ln would put the link inside it.
	ln -sT -- "${to}" "${dest}/${path}"
}

fFrozenRemove(){
	local repo="$1" dest="$2"
	git -C "${repo}" worktree unlock "${dest}" >/dev/null 2>&1 || true
	git -C "${repo}" worktree remove --force "${dest}" >/dev/null 2>&1
}


##	History:
##		- 2026-10-21 JC: Created from the pre-push hook's gate worktree, for cicd.bash's frozen copy too.
