#!/usr/bin/env bash

##	Purpose:
##		The banner's Syntax link names a release tag, and every file written in
##		that format keeps the link for good. Once a commit at or past that
##		release reaches main, the tag has to exist on the remote, or the link is
##		dead in all of them. The pre-push hook runs this for every push to main,
##		and the release recipe runs it again once the push is through.
##		A tree whose version is still below the tag is not a cut, and passes.
##		So does a tree whose banner names no tag.
##	Syntax:
##		check-banner-tag.bash REMOTE REV [TAGREF=SHA ...]
##		TAGREF=SHA is a tag ref the same push sends; all zeros means a delete.
##	Exit: 0 = the tag exists after the push, or none is due; 1 = it does not;
##	      2 = usage, or the remote or tree cannot be read.
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

## The reference binding's constant. The other three are held to the same bytes
## by the corpus.
libRs="$(git -C "${root}" show "${rev}:source/rust/src/lib.rs" 2>/dev/null || true)"
tag="$(sed -n 's|^##    Syntax   https://[^ ]*/blob/\(v[^/ ]*\)/project/spec\.md$|\1|p' <<<"${libRs}" | head -n 1)"
[[ -n "${tag}" ]] || exit 0
cargoVer="$(git -C "${root}" show "${rev}:source/rust/Cargo.toml" 2>/dev/null | sed -n '/^version = "/{s/^version = "\(.*\)"$/\1/p;q;}' || true)"
[[ -n "${cargoVer}" ]] || { fSay "no version in ${rev}'s source/rust/Cargo.toml"; exit 2 ;}

## sort -V puts 3.0.0-beta1 after 3.0.0; with the - mapped to ~ it goes before.
fBelow(){ [[ "$1" != "$2" && "$(printf '%s\n%s\n' "${1/-/\~}" "${2/-/\~}" | sort -V | head -n 1)" == "${1/-/\~}" ]] ;}
if fBelow "${cargoVer}" "${tag#v}"; then exit 0; fi

for pushed in "$@"; do
	[[ "${pushed%%=*}" == "refs/tags/${tag}" ]] || continue
	sha="${pushed#*=}"
	if [[ "${sha}" =~ ^0+$ ]]; then
		fSay "this push deletes ${tag}, which the banner's Syntax link names"; exit 1
	fi
	if ! git -C "${root}" cat-file -e "${sha}^{commit}:project/spec.md" 2>/dev/null; then
		fSay "${tag}, pushed here, has no project/spec.md for the banner's Syntax link to show"; exit 1
	fi
	exit 0
done

remoteTags="$(git -C "${root}" ls-remote --tags "${remote}" 2>/dev/null)" || { fSay "cannot list the tags on ${remote}"; exit 2 ;}
## ls-remote matches a pattern against the end of a ref name, so compare whole names.
if grep -qxF "refs/tags/${tag}" <<<"$(cut -f2 <<<"${remoteTags}")"; then exit 0; fi
fSay "version ${cargoVer} is at or past ${tag}, which the banner's Syntax link names, and ${remote} has no such tag."
fSay "push the tag with main: git push --atomic ${remote} main ${tag} source/go/${tag}"
exit 1


##	History:
##		- 2026-10-01 JC: Created.
