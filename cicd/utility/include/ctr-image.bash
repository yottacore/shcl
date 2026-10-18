#!/usr/bin/env bash

#  shellcheck disable=2154  ## 'referenced but not assigned.' root and the CTR_ settings come from the script that sources this.

##	Purpose:
##		The --container image's build context and tag, for cicd.bash and for a
##		gate that runs its tools in the image. Source config.bash first, and set
##		root to the repo root.
##			fCtrContext RECIPE DIR  copy the context into DIR: RECIPE (from the
##			                        repo root) as DIR/Dockerfile, the other files
##			                        in its recipe dir, and CTR_CONTEXT_EXTRA
##			fCtrTag DIR NAME        the tag for that context: a hash of its files,
##			                        so an edit to any of them means a new image.
##			                        NAME is main or an extra image's name.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


fCtrContext(){
	local recipe="$1" ctx="$2" f
	cp -p "${root}/${recipe}" "${ctx}/Dockerfile" || return 1
	## The other recipes stay out of the hash.
	while IFS= read -r -d '' f; do
		if [[ "${f}" != *Dockerfile ]]; then cp -p "${f}" "${ctx}/" || return 1; fi
	done < <(find "${root}/${CTR_DIR:-cicd/container}" -maxdepth 1 -type f -print0)
	for f in "${CTR_CONTEXT_EXTRA[@]}"; do cp -p "${root}/${f}" "${ctx}/" || return 1; done
}

fCtrTag(){
	local ctx="$1" name="$2" f
	local -a ctxFiles=()
	mapfile -t ctxFiles < <(cd "${ctx}" && find . -type f | LC_ALL=C sort)
	printf '%s%s:%s\n' "${CTR_IMAGE:-${APP_NAME}-cicd}" "$([[ "${name}" == main ]] || echo "-${name}")" \
		"$(cd "${ctx}" && for f in "${ctxFiles[@]}"; do echo "${f}"; cat "${f}"; done | git hash-object --stdin | cut -c1-12)"
}


##	History:
##		- 2026-10-17 JC: Created, out of cicd.bash, so a gate can find the image.
