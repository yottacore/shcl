#!/usr/bin/env bash

##	Purpose:
##		One status line per test, with its test ID, for the pipeline's console:
##			STATUS ID WHERE NAME
##		Source this, set testWhere to the script's name and testCounter to the
##		name of its failure counter, then call:
##			fTest ID NAME...   close the open test and open the next
##			fTestSkip          the open test skipped what it checks
##			fTestSkipBlock     from a skipped block's else branch: the open test
##			                   skipped, and so did every test the block opens
##			fTestEnd           close the open test
##		A test fails when the counter grew while it was open. A new test's ID
##		comes from `cicd/utility/test-ids.py new`.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


testWhere="${testWhere:-?}"
testCounter="${testCounter:-nBad}"
testOpen=""; testName=""; testFrom=0; testSkipped=0

fTestLine(){ printf '%-4s %s %s %s\n' "$1" "$2" "${testWhere}" "$3"; }

fTestEnd(){
	[[ -n "${testOpen}" ]] || return 0
	local status=ok
	if [[ "${!testCounter}" != "${testFrom}" ]]; then status=FAIL
	elif [[ "${testSkipped}" == 1 ]]; then status=skip; fi
	fTestLine "${status}" "${testOpen}" "${testName}"
	testOpen=""
}

fTest(){
	fTestEnd
	testOpen="$1"; shift
	testName="$*"; testFrom="${!testCounter}"; testSkipped=0
}

fTestSkip(){ testSkipped=1; }
##	The block is the `if` whose `else` sits above the caller's line at the
##	caller's indent less one, read out of the calling script, so a test added to
##	the block needs no list kept beside it.
fTestSkipBlock(){
	local src="${BASH_SOURCE[1]}" at="${BASH_LINENO[0]}" id name
	testSkipped=1
	fTestEnd
	while IFS=$'\t' read -r id name; do
		fTestLine skip "${id}" "${name}"
	done < <(awk -v at="${at}" '
		{ line[NR] = $0 }
		NR == at { exit }
		END {
			for (e = at; e > 0 && line[e] !~ /^\t*else([ \t]|$)/; e--) {}
			if (e == 0) exit
			match(line[e], /^\t*/); tabs = RLENGTH
			for (i = e - 1; i > 0; i--) {
				match(line[i], /^\t*/)
				if (RLENGTH == tabs && line[i] ~ /^\t*if /) break
			}
			for (k = i + 1; k < e; k++)
				if (line[k] ~ /^\t+fTest [^ ]+ /) {
					t = line[k]; sub(/^\t+fTest /, "", t)
					id = t; sub(/ .*/, "", id); sub(/^[^ ]+ /, "", t)
					printf "%s\t%s\n", id, t
				}
		}' "${src}")
}


##	History:
##		- 2026-09-27 JC: Created.
##		- 2026-09-28 JC: fTestSkipBlock, so a skipped block names the tests in it.
