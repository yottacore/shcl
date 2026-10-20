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
##			fCtrRunSelf WORK RW SCRIPT [ARG...]
##			                        run SCRIPT in the main image, built first if
##			                        it isn't here, with no network, as the
##			                        caller's uid. The repo goes in read only at its
##			                        own path; WORK, a scratch dir, and RW, a dir,
##			                        several joined by ':', or empty, are all it
##			                        writes, each at its own path.
##			                        SHCL_IN_IMAGE=1 tells the script where it is,
##			                        and SHCL_CTR_CARGO, when set, goes in as is.
##			                        Returns the script's exit, or 2.
##			fCtrWhyNot              nothing when the images can run here, else
##			                        why not: they're x86_64 only, and docker (or
##			                        SHCL_DOCKER) counts once its daemon answers.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## An installed docker with no daemon behind it is no docker at all. The
## timeout is for a DOCKER_HOST that never replies.
fCtrWhyNot(){
	local engine="${SHCL_DOCKER:-docker}"
	local -a limit=()
	if [[ "$(uname -m)" != x86_64 ]]; then echo "the build images are x86_64 only"; return 0; fi
	if ! command -v "${engine}" >/dev/null 2>&1; then echo "there's no ${engine} here (SHCL_DOCKER names another)"; return 0; fi
	if command -v timeout >/dev/null 2>&1; then limit=(timeout 30); fi
	if ! "${limit[@]}" "${engine}" info >/dev/null 2>&1; then echo "${engine} doesn't answer"; fi
	return 0
}

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

fCtrRunSelf(){
	local engine="${SHCL_DOCKER:-docker}" work="$1" rw="$2" ctx tag rc=0 d
	local -a rwMount=() rwDirs=()
	shift 2
	ctx="${work}/ctx"; mkdir -p "${ctx}" "${work}/in"
	fCtrContext "${CTR_DIR:-cicd/container}/Dockerfile" "${ctx}" || { echo "${1##*/}: could not copy the build image's context" >&2; return 2; }
	tag="$(fCtrTag "${ctx}" main)"
	if ! "${engine}" image inspect "${tag}" >/dev/null 2>&1; then
		echo "${1##*/}: building ${tag}, which takes several minutes the first time"
		"${engine}" build -q -t "${tag}" "${ctx}" >/dev/null || { echo "${1##*/}: could not build ${tag}" >&2; return 2; }
	fi
	## Docker would make a missing mount point as root, inside a read-only mount.
	IFS=: read -r -a rwDirs <<<"${rw}"
	for d in "${rwDirs[@]}"; do
		mkdir -p "${d}" || return 2
		rwMount+=(-v "${d}:${d}")
	done
	"${engine}" run --rm --init --network none --user "$(id -u):$(id -g)" \
		-v "${root}:${root}:ro" -v "${work}/in:${work}/in" "${rwMount[@]}" -w "${root}" \
		-e SHCL_IN_IMAGE=1 -e "CPU_CAP=${CPU_CAP:-}" -e "TMPDIR=${work}/in" -e "HOME=${work}/in" \
		-e "SHCL_GATE_STRICT=${SHCL_GATE_STRICT:-}" -e "SHCL_CTR_CARGO=${SHCL_CTR_CARGO:-}" \
		"${tag}" bash "$@" || rc=$?
	return "${rc}"
}


##	History:
##		- 2026-10-17 JC: Created, out of cicd.bash, so a gate can find the image.
##		- 2026-10-19 JC: fCtrRunSelf, out of analyze-c.bash, for the soak too.
##		- 2026-10-19 JC: fCtrRunSelf takes several writable dirs, and SHCL_CTR_CARGO.
##		- 2026-10-19 JC: fCtrWhyNot, so docker counts only when it answers.
