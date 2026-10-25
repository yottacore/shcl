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
##			fCtrBuild TAG DIR       build TAG from the context in DIR, labeled
##			                        as ours, then remove the other tags of its
##			                        name but the one before it
##			fCtrSweep WORK          remove our images and containers a run
##			                        won't use again; see the function. WORK is
##			                        a scratch dir the caller removes
##			fCtrLabelArgs ARRAY     fill ARRAY with the --label pair for what
##			                        this run makes: dev.project, and dev.run,
##			                        SHCL_DEV_RUN, the name of the run's folder
##			fCtrName STEP           a container's name: APP-RUN-STEP
##			fCtrRunGone RUN         stop and remove RUN's containers; prints
##			                        how many there were
##			fCtrDf                  docker system df's sizes, "TYPE<TAB>SIZE"
##			fCtrZigTrim TAG         empty Zig's cache volume when it's over the
##			                        cap or another Zig filled it; see the
##			                        function. TAG is the main image this run used
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

# shellcheck disable=SC2034  ## a nameref, read by the caller
fCtrLabelArgs(){ local -n out_l4b="$1"; out_l4b=(--label "dev.project=${APP_NAME}" --label "dev.run=${SHCL_DEV_RUN:-}"); }
fCtrName(){ printf '%s-%s-%s\n' "${APP_NAME}" "${SHCL_DEV_RUN:-}" "$1"; }

fCtrRunSelf(){
	local engine="${SHCL_DOCKER:-docker}" work="$1" rw="$2" ctx tag rc=0 d
	local -a rwMount=() rwDirs=() labels=()
	shift 2
	## A gate run by hand is a run of its own, named by its scratch dir. Local,
	## so the build below gets it too.
	local SHCL_DEV_RUN="${SHCL_DEV_RUN:-${work##*/}}"
	fCtrLabelArgs labels
	ctx="${work}/ctx"; mkdir -p "${ctx}" "${work}/in"
	fCtrContext "${CTR_DIR:-cicd/container}/Dockerfile" "${ctx}" || { echo "${1##*/}: could not copy the build image's context" >&2; return 2; }
	tag="$(fCtrTag "${ctx}" main)"
	if ! "${engine}" image inspect "${tag}" >/dev/null 2>&1; then
		echo "${1##*/}: building ${tag}, which takes several minutes the first time"
		fCtrBuild "${tag}" "${ctx}" || { echo "${1##*/}: could not build ${tag}" >&2; return 2; }
	fi
	## Docker would make a missing mount point as root, inside a read-only mount.
	IFS=: read -r -a rwDirs <<<"${rw}"
	for d in "${rwDirs[@]}"; do
		mkdir -p "${d}" || return 2
		rwMount+=(-v "${d}:${d}")
	done
	## A caller that sources stop-descendants.bash can then take the container
	## down on a stop, even when its docker client won't go.
	local cidfile="${work}/ctr.cid"
	rm -f -- "${cidfile}"
	if declare -p stop_cidfiles &>/dev/null; then stop_cidfiles=("${cidfile}"); fi
	d="${1##*/}"
	"${engine}" run --rm --init --cidfile "${cidfile}" "${labels[@]}" --name "$(fCtrName "${d%.bash}")" --network none --user "$(id -u):$(id -g)" \
		-v "${root}:${root}:ro" -v "${work}/in:${work}/in" "${rwMount[@]}" -w "${root}" \
		-e SHCL_IN_IMAGE=1 -e "CPU_CAP=${CPU_CAP:-}" -e "TMPDIR=${work}/in" -e "HOME=${work}/in" \
		-e "SHCL_GATE_STRICT=${SHCL_GATE_STRICT:-}" -e "SHCL_CTR_CARGO=${SHCL_CTR_CARGO:-}" \
		"${tag}" bash "$@" || rc=$?
	if declare -p stop_cidfiles &>/dev/null; then stop_cidfiles=(); fi
	rm -f -- "${cidfile}"
	return "${rc}"
}

## The label is what lets fCtrSweep find a dangling image or a stopped
## container of ours, and only ours.
fCtrBuild(){
	local engine="${SHCL_DOCKER:-docker}" tag="$1" ctx="$2" old
	local -a labels=()
	local -A keep=()
	fCtrLabelArgs labels
	"${engine}" build -q "${labels[@]}" -t "${tag}" "${ctx}" >/dev/null || return 1
	keep["${tag}"]=1
	while IFS= read -r old; do keep["${old}"]=1; done < <(fCtrPrev "${tag}")
	while IFS= read -r old; do
		if [[ -z "${old}" || -n "${keep[${old}]:-}" ]]; then continue; fi
		## Not -f, so an image a container still has stays.
		if "${engine}" rmi "${old}" >/dev/null 2>&1; then echo "removed ${old}"; else echo "kept ${old} (in use)"; fi
	done < <("${engine}" image ls "${tag%:*}" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
	return 0
}

## The newest tag of TAG's name but TAG: the one before it, which stays so a
## recipe change can go back without a rebuild. All of them when docker's
## dates don't line up with its tags.
fCtrPrev(){
	local engine="${SHCL_DOCKER:-docker}" tag="$1" ref
	local -a refs=() made=()
	while IFS= read -r ref; do
		if [[ -n "${ref}" && "${ref}" != "${tag}" && "${ref}" != *'<none>' ]]; then refs+=("${ref}"); fi
	done < <("${engine}" image ls "${tag%:*}" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
	((${#refs[@]})) || return 0
	mapfile -t made < <("${engine}" image inspect --format '{{.Created}}' "${refs[@]}" 2>/dev/null || true)
	if ((${#made[@]} != ${#refs[@]})); then printf '%s\n' "${refs[@]}"; return 0; fi
	paste <(printf '%s\n' "${made[@]}") <(printf '%s\n' "${refs[@]}") | LC_ALL=C sort -r | sed -n '1s/^[^\t]*\t//p'
}

## At the end of a run that used the images: a tag of one of our names that
## isn't the one this tree's recipe hashes to or the one before it, every tag
## of a name whose recipe is gone, and a dangling image or a stopped container
## with our label. A name is matched whole, so another project's image is never
## a candidate. Prints "BYTES<TAB>WHAT" for each one removed.
fCtrSweep(){
	local engine="${SHCL_DOCKER:-docker}" work="$1" ours="${CTR_IMAGE:-${APP_NAME}-cicd}" recipe name ctx ref repo bytes id now
	local -A current=()
	local -i n=0
	for recipe in "${root}/${CTR_DIR:-cicd/container}"/*Dockerfile; do
		[[ -f "${recipe}" ]] || continue
		name="${recipe##*/}"; name="${name%.Dockerfile}"
		if [[ "${name}" == Dockerfile ]]; then name=main; fi
		n+=1; ctx="${work}/ctx${n}"
		## A recipe that can't be hashed would make its current tag look stale.
		{ mkdir -p "${ctx}" && fCtrContext "${recipe#"${root}/"}" "${ctx}"; } || return 1
		now="$(fCtrTag "${ctx}" "${name}")"
		current["${now}"]=1
		while IFS= read -r ref; do current["${ref}"]=1; done < <(fCtrPrev "${now}")
	done
	((n)) || return 0
	while IFS= read -r ref; do
		repo="${ref%:*}"
		if [[ "${repo}" != "${ours}" ]] && ! [[ "${repo}" == "${ours}-"* && "${repo#"${ours}-"}" =~ ^[a-z0-9]+$ ]]; then continue; fi
		if [[ -n "${current[${ref}]:-}" ]]; then continue; fi
		bytes="$("${engine}" image inspect --format '{{.Size}}' "${ref}" 2>/dev/null || true)"
		if "${engine}" rmi "${ref}" >/dev/null 2>&1; then printf '%s\t%s\n' "${bytes:-0}" "${ref}"; fi
	done < <("${engine}" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
	while IFS= read -r id; do
		if [[ -n "${id}" ]] && "${engine}" rm "${id}" >/dev/null 2>&1; then printf '0\tcontainer %s\n' "${id}"; fi
	done < <("${engine}" ps -aq --filter "label=dev.project=${APP_NAME}" --filter status=exited --filter status=dead 2>/dev/null || true)
	while IFS= read -r id; do
		[[ -n "${id}" ]] || continue
		bytes="$("${engine}" image inspect --format '{{.Size}}' "${id}" 2>/dev/null || true)"
		if "${engine}" rmi "${id}" >/dev/null 2>&1; then printf '%s\tdangling image %s\n' "${bytes:-0}" "${id}"; fi
	done < <("${engine}" image ls -q --filter dangling=true --filter "label=dev.project=${APP_NAME}" 2>/dev/null || true)
	return 0
}

## Whatever ended RUN, failed and stopped ones too. --rm takes most of them
## as they stop, so the rm is for the rest.
fCtrRunGone(){
	local engine="${SHCL_DOCKER:-docker}" run="$1" i
	local -a ids=() ours=()
	[[ -n "${run}" ]] || return 0
	ours=(--filter "label=dev.project=${APP_NAME}" --filter "label=dev.run=${run}")
	mapfile -t ids < <("${engine}" ps -aq "${ours[@]}" 2>/dev/null || true)
	((${#ids[@]})) || return 0
	"${engine}" stop -t 10 "${ids[@]}" >/dev/null 2>&1 || true
	"${engine}" rm "${ids[@]}" >/dev/null 2>&1 || true
	## A --rm one is still Dead, being removed, for a moment after its stop.
	for ((i = 0; i < 20; i++)); do
		[[ -n "$("${engine}" ps -aq "${ours[@]}" 2>/dev/null || true)" ]] || break
		sleep 0.5
	done
	echo "${#ids[@]}"
}

fCtrDf(){
	local engine="${SHCL_DOCKER:-docker}"
	"${engine}" system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null || true
}

## At the end of a run that used the main image TAG. Zig's cache volume goes
## whole, since its manifests point into the rest of it: when it's over
## CTR_ZIG_CAP_KB, or when the Zig in TAG isn't the one its stamp names. The
## first run to end with a new volume stamps it. Docker won't remove a volume
## another run still has, so that one stays. Prints "BYTES<TAB>WHAT" when it goes.
fCtrZigTrim(){
	local engine="${SHCL_DOCKER:-docker}" tag="$1" vol="${CTR_ZIG_VOLUME:-${APP_NAME}-zig-cache}" cap="${CTR_ZIG_CAP_KB:-}" out="" kb="" stamp="" ver="" why=""
	local -a labels=()
	[[ -n "${tag}" ]] || return 0
	fCtrLabelArgs labels
	[[ "${cap}" =~ ^[0-9]{1,15}$ ]] || cap=2097152
	"${engine}" volume inspect "${vol}" >/dev/null 2>&1 || return 0
	# shellcheck disable=SC2016  ## for the shell in the image
	out="$("${engine}" run --rm "${labels[@]}" --name "$(fCtrName zig-trim)" --network none --user "$(id -u):$(id -g)" -v "${vol}:/zig-cache" "${tag}" \
		sh -c 'v="$(zig version)" || exit 1; f=/zig-cache/zig-version.stamp; s="$(cat "${f}" 2>/dev/null)"
			if [ -z "${s}" ]; then s="${v}"; printf "%s\n" "${v}" > "${f}"; fi
			printf "%s\t%s\t%s\n" "$(du -sk /zig-cache | cut -f1)" "${s}" "${v}"' 2>/dev/null)" || return 0
	IFS=$'\t' read -r kb stamp ver <<<"${out}"
	[[ "${kb}" =~ ^[0-9]{1,15}$ && -n "${ver}" ]] || return 0
	if ((kb > cap)); then why="over $((cap / 1024)) MB"
	elif [[ "${stamp}" != "${ver}" ]]; then why="filled by Zig ${stamp}"
	else return 0; fi
	if "${engine}" volume rm "${vol}" >/dev/null 2>&1; then printf '%s\t%s\n' "$((kb * 1024))" "the ${vol} volume (${why})"; fi
	return 0
}


##	History:
##		- 2026-10-17 JC: Created, out of cicd.bash, so a gate can find the image.
##		- 2026-10-19 JC: fCtrRunSelf, out of analyze-c.bash, for the soak too.
##		- 2026-10-19 JC: fCtrRunSelf takes several writable dirs, and SHCL_CTR_CARGO.
##		- 2026-10-19 JC: fCtrWhyNot, so docker counts only when it answers.
##		- 2026-10-19 JC: fCtrBuild, so a gate's build drops the old tags too, and fCtrSweep.
##		- 2026-10-24 JC: fCtrZigTrim, for the main image's Zig cache volume.
##		- 2026-10-24 JC: dev.project and dev.run labels, container names, fCtrRunGone and fCtrDf.
##		  The tag before the current one stays.
