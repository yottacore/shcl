#!/usr/bin/env bash

##	Purpose:
##		One status line per test, with its test ID, for the pipeline's console:
##			STATUS ID WHERE NAME
##		Source this, set testWhere to the script's name and testCounter to the
##		name of its failure counter, then call:
##			fTest ID NAME...   close the open test and open the next
##			fTestSkip          the open test skipped what it checks
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


##	History:
##		- 2026-09-27 JC: Created.
