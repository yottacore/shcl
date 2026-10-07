#!/usr/bin/env bash

##	Purpose:
##		The generated large document, as one function so the large-document gate
##		and the profiler workload are the same shape. Source this and call:
##			largedoc_gen MIB > file
##		Generated rather than stored: a 100 MiB fixture has no business in a git
##		repo, and the shape matters more than the bytes - repeated instances of
##		one name, nesting, bracket and stacked arrays, quoted values holding the
##		separator, raw blocks, comments, blank lines, non-ASCII, and one array
##		long enough to walk past any fixed element buffer. Nothing in it merges
##		into an earlier line, so a profile of it measures parsing, not merging,
##		and it loads with no diagnostics at all (the large-document gate
##		checks that; a hint per unit once made the profile measure stderr).
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## LC_ALL=C so awk's length() counts bytes.
largedoc_gen(){
	LC_ALL=C awk -v mib="$1" '
	BEGIN {
		target = mib * 1048576
		while (bytes < target) {
			i = n++
			s = "# service group " i "\n" \
			    "service: svc" i "\n" \
			    "\thost: 10." (i%250) "." (int(i/250)%250) "." ((i*7)%250) "\n" \
			    "\tport: " (8000 + i%1000) "\n" \
			    "\tenabled: " (i%2 ? "true" : "false") "\n" \
			    "\tweight: " (i%100) "." (i%97) "\n" \
			    "\tstarted: 2026-0" (1+i%9) "-1" (i%9) "T0" (i%9) ":3" (i%6) "\n" \
			    "\tregion: \"\xe8\xa5\xbf\xe9\x83\xa8, \xe5\x8c\x97\"\n" \
			    "\ttags: [fast, \"eu, west\", cheap" (i%13) "]\n" \
			    "\tlimits:\n\t\tcpu: " (1+i%16) "\n\t\tmem: \"" (i%64) "Gi\"\n" \
			    "\t\tburst:\n"
			for (j = 0; j < 4; j++) s = s "\t\t\t- " ((j*i)%1000) "\n"
			s = s "\tnotes:\n\t\t~~~\n\t\tgenerated entry " i "\n\t\tsecond line\n\t\t~~~\n" \
			      "service: svc" i "-b\n\tport: " (9000 + i%1000) "\n\n"
			printf "%s", s
			bytes += length(s)
		}
		## One array long enough that a fixed per-element buffer has to have grown.
		printf "wide:\n"
		for (j = 0; j < 20000; j++) printf "\t- %d\n", j
	}'
}

## Only allow running 'sourced'.
declare -i isSourced_ldg7c=0; [[ "${BASH_SOURCE[0]}" == "${0}" ]] || isSourced_ldg7c=1
((isSourced_ldg7c)) || { echo -e "\nError in $(basename "${BASH_SOURCE[0]}"): This script is meant to be 'sourced' from within another script.\n"; exit 1; }


##	History:
##		- 2026-08-29 JC: Lifted out of largedoc.bash so the profiler runs the
##		  same document instead of forty concatenated copies of the corpus.
##		- 2026-09-02 JC: The second instance of each service has its own value;
##		  it used to reopen the first, so half the nodes merged and every unit hinted.
##		- 2026-10-07 JC: Arrays in brackets and `- ` items, for the new value syntax.
