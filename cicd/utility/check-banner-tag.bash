#!/usr/bin/env bash

##	Purpose:
##		The banner's Syntax link names a release tag, and every file written in
##		that format keeps the link for good. Once a commit at or past that
##		release reaches main, the tag has to exist on the remote, or the link is
##		dead in all of them. The pre-push hook runs this for every push to main,
##		and the release recipe runs it again once the push is through.
##		A tree whose version is still below the tag is not a cut, and passes.
##		So does a tree below the first release whose banner names a tag. One at
##		or past it whose banner gives no tag here is refused, since a pattern
##		that no longer matches would otherwise wave every cut through.
##		The tag has to point at a commit with a spec, at the tag's own version.
##	Syntax:
##		check-banner-tag.bash REMOTE REV [TAGREF=SHA ...]
##		TAGREF=SHA is a tag ref the same push sends; all zeros means a delete.
##	Exit: 0 = the tag exists after the push, or none is due; 1 = it does not,
##	      or it points at the wrong commit;
##	      2 = usage, or the remote or tree cannot be read.
##	Note: a tag sent in the same push counts as being on the remote. Only an
##	      --atomic push makes that true, and a hook cannot see the flag, so a
##	      plain push the remote takes half of leaves main at the cut with no
##	      tag. The release recipe's run after the push is what catches that.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

(($# >= 2)) || { echo "usage: check-banner-tag.bash REMOTE REV [TAGREF=SHA ...]" >&2; exit 2 ;}
remote="$1"; rev="$2"; shift 2
fSay(){ echo "check-banner-tag: $*" >&2 ;}
## The checkout holding this script, not the caller's directory.
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
## Format 3's banner was the first to name a tag. Every banner since names one.
firstTagged=3.0.0-beta1

fVersionAt(){ git -C "${root}" show "$1:source/rust/Cargo.toml" 2>/dev/null | sed -n '/^version = "/{s/^version = "\(.*\)"$/\1/p;q;}' || true ;}
## sort -V puts 3.0.0-beta1 after 3.0.0; with the - mapped to ~ it goes before.
fBelow(){ [[ "$1" != "$2" && "$(printf '%s\n%s\n' "${1/-/\~}" "${2/-/\~}" | sort -V | head -n 1)" == "${1/-/\~}" ]] ;}

cargoVer="$(fVersionAt "${rev}")"
[[ -n "${cargoVer}" ]] || { fSay "no version in ${rev}'s source/rust/Cargo.toml"; exit 2 ;}
## The reference binding's constant. The other three are held to the same bytes
## by the corpus.
libRs="$(git -C "${root}" show "${rev}:source/rust/src/lib.rs" 2>/dev/null || true)"
tag="$(sed -n 's|^##    Syntax   https://[^ ]*/blob/\(v[^/ ]*\)/project/spec\.md$|\1|p' <<<"${libRs}" | head -n 1)"
if [[ -z "${tag}" ]]; then
	if fBelow "${cargoVer}" "${firstTagged}"; then exit 0; fi
	fSay "cannot read the tag from the banner's Syntax line in ${rev}'s source/rust/src/lib.rs, at version ${cargoVer}."
	fSay "if the banner moved or changed, change the pattern in cicd/utility/check-banner-tag.bash to match it."
	exit 2
fi
if fBelow "${cargoVer}" "${tag#v}"; then exit 0; fi

## fTagCommit COMMIT WHERE: the commit the tag points at has the spec the link
## shows, at the release the tag names.
fTagCommit(){
	local tagVer
	if ! git -C "${root}" cat-file -e "$1^{commit}:project/spec.md" 2>/dev/null; then
		fSay "${tag}, $2, has no project/spec.md for the banner's Syntax link to show"; exit 1
	fi
	tagVer="$(fVersionAt "$1^{commit}")"
	if [[ "${tagVer}" != "${tag#v}" ]]; then
		fSay "${tag}, $2, points at a commit at version ${tagVer:-(none)}, not ${tag#v}"; exit 1
	fi
}

for pushed in "$@"; do
	[[ "${pushed%%=*}" == "refs/tags/${tag}" ]] || continue
	sha="${pushed#*=}"
	if [[ "${sha}" =~ ^0+$ ]]; then
		fSay "this push deletes ${tag}, which the banner's Syntax link names"; exit 1
	fi
	fTagCommit "${sha}" "pushed here"
	exit 0
done

remoteTags="$(git -C "${root}" ls-remote --tags "${remote}" 2>/dev/null)" || { fSay "cannot list the tags on ${remote}"; exit 2 ;}
## ls-remote matches a pattern against the end of a ref name, so compare whole
## names. An annotated tag's commit is on its ^{} line.
remoteSha="$(TAGREF="refs/tags/${tag}" awk '$2 == ENVIRON["TAGREF"] { s = $1 } $2 == ENVIRON["TAGREF"] "^{}" { p = $1 } END { print (p != "" ? p : s) }' <<<"${remoteTags}")"
if [[ -n "${remoteSha}" ]]; then
	if ! git -C "${root}" cat-file -e "${remoteSha}^{commit}" 2>/dev/null; then
		fSay "${tag} on ${remote} points at ${remoteSha:0:12}, which is not in this clone, so its version cannot be checked."
		fSay "fetch it first: git fetch ${remote} tag ${tag}"
		exit 2
	fi
	fTagCommit "${remoteSha}" "on ${remote}"
	exit 0
fi
fSay "version ${cargoVer} is at or past ${tag}, which the banner's Syntax link names, and ${remote} has no such tag."
fSay "push the tag with main: git push --atomic ${remote} main ${tag} source/go/${tag}"
exit 1


##	History:
##		- 2026-10-01 JC: Created.
##		- 2026-10-04 JC: A banner it cannot read at or past the first tagged
##		  release is refused, and the tag has to be at its own version.
