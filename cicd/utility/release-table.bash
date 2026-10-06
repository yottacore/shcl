#!/usr/bin/env bash

##	Purpose:
##		Write the markdown downloads table for a release's notes: target OS in
##		rows, CPU architecture in columns, an empty cell where there is no
##		build. Packages for a pair share its cell. Anything that is not for one
##		platform (sums, signature, drop-in sources) goes in a line under it.
##		Reads only; it never edits a release.
##	Syntax:
##		release-table.bash TAG [--repo OWNER/NAME] [--dir DIR | --names FILE]
##		  TAG           the release tag, such as v3.0.0-beta1
##		  --repo        the GitHub repo the links point at (default yottacore/shcl)
##		  --dir DIR     take the asset names from a local artifact dir, such as
##		                cicd/artifacts/release, before anything is uploaded
##		  --names FILE  one asset name per line; - for stdin
##		  With neither, the names come from the published release, through gh.
##	Exit: 0 table written, 1 nothing to tabulate or a name clash, 2 usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

set -Eeuo pipefail

fDie(){ printf 'release-table.bash: %s\n' "$1" >&2; exit "${2:-1}"; }

fUsage(){
	cat <<'EOF'

##	Purpose:
##		Write the markdown downloads table for a release's notes: target OS in
##		rows, CPU architecture in columns, an empty cell where there is no
##		build. Packages for a pair share its cell. Anything that is not for one
##		platform (sums, signature, drop-in sources) goes in a line under it.
##		Reads only; it never edits a release.
##	Syntax:
##		release-table.bash TAG [--repo OWNER/NAME] [--dir DIR | --names FILE]
##		  TAG           the release tag, such as v3.0.0-beta1
##		  --repo        the GitHub repo the links point at (default yottacore/shcl)
##		  --dir DIR     take the asset names from a local artifact dir, such as
##		                cicd/artifacts/release, before anything is uploaded
##		  --names FILE  one asset name per line; - for stdin
##		  With neither, the names come from the published release, through gh.
##	Exit: 0 table written, 1 nothing to tabulate or a name clash, 2 usage.

EOF
}

tag=""; repo="yottacore/shcl"; dir=""; namesFile=""
while (( $# )); do
	case "$1" in
		--repo=*)  repo="${1#*=}" ;;
		--repo)    (( $# >= 2 )) || fDie "missing value for --repo" 2; shift; repo="$1" ;;
		--dir=*)   dir="${1#*=}" ;;
		--dir)     (( $# >= 2 )) || fDie "missing value for --dir" 2; shift; dir="$1" ;;
		--names=*) namesFile="${1#*=}" ;;
		--names)   (( $# >= 2 )) || fDie "missing value for --names" 2; shift; namesFile="$1" ;;
		-h|--help) fUsage; exit 0 ;;
		-?*)       fDie "unknown option: $1" 2 ;;
		*)         [[ -z "${tag}" ]] || fDie "one tag only: $1" 2; tag="$1" ;;
	esac
	shift
done
[[ -n "${tag}" ]] || fDie "need a TAG (try --help)" 2
[[ -z "${dir}" || -z "${namesFile}" ]] || fDie "--dir and --names do not mix" 2
[[ "${repo}" == */* ]] || fDie "--repo wants OWNER/NAME: ${repo}" 2

## GitHub turns any character outside [A-Za-z0-9._-] in an uploaded name into
## a dot, so a local name and a link built from it would 404 otherwise.
fUploadName(){ local n="$1"; printf '%s' "${n//[^A-Za-z0-9._-]/.}" ;}

names=()
if [[ -n "${dir}" ]]; then
	[[ -d "${dir}" ]] || fDie "no such dir: ${dir}" 2
	for f in "${dir}"/*; do
		if [[ -f "${f}" ]]; then names+=("${f##*/}"); fi
	done
elif [[ -n "${namesFile}" ]]; then
	[[ "${namesFile}" == "-" || -r "${namesFile}" ]] || fDie "cannot read ${namesFile}" 2
	if [[ "${namesFile}" == "-" ]]; then mapfile -t names; else mapfile -t names < "${namesFile}"; fi
else
	command -v gh >/dev/null || fDie "need gh, or pass --dir or --names" 2
	ghNames="$(gh release view "${tag}" --repo "${repo}" --json assets -q '.assets[].name')" \
		|| fDie "gh could not read release ${tag} on ${repo}"
	mapfile -t names <<<"${ghNames}"
fi

ver="$(fUploadName "${tag#v}")"
prefix="shcl-${ver}-"
base="https://github.com/${repo}/releases/download/${tag}"
platRe='^([a-z0-9]+)-([a-z0-9_]+)(.*)$'

## Cells link by reference, so the padded table stays readable as text. A
## cell's label is the name past the version; the other files keep theirs.
declare -A seen=() cells=() osSeen=() archSeen=()
rows=(); others=(); refs=()
for raw in "${names[@]}"; do
	raw="${raw%$'\r'}"
	[[ -n "${raw//[[:space:]]/}" ]] || continue
	name="$(fUploadName "${raw}")"
	[[ -z "${seen[${name}]:-}" ]] || fDie "two assets upload as ${name}: ${seen[${name}]} and ${raw}"
	seen["${name}"]="${raw}"
	rest="${name#"${prefix}"}"
	os=""; arch=""; kind=""
	if [[ "${name}" == "${prefix}"* && "${rest}" =~ ${platRe} ]]; then
		os="${BASH_REMATCH[1]}"; arch="${BASH_REMATCH[2]}"; kind="${BASH_REMATCH[3]}"
	fi
	case "${os}" in linux|windows|macos|darwin|freebsd|netbsd|openbsd|android) ;; *) os="" ;; esac
	## Rank orders the links inside one cell.
	case "${kind}" in
		""|.exe)    rank=1; label="binary" ;;
		-setup.exe) rank=2; label="installer" ;;
		.deb|.rpm|.apk|.pkg|.dmg|.msi|.zip|.tar.gz|.tar.xz) rank=3; label="${kind}" ;;
		*)          os="" ;;
	esac
	if [[ -z "${os}" ]]; then others+=("${name}"); continue; fi
	osSeen["${os}"]=1
	refs+=("[${rest}]: ${base}/${name}")
	## One universal macOS build serves both columns.
	if [[ "${arch}" == "universal" ]]; then archList=(x86_64 arm64); else archList=("${arch}"); fi
	for a in "${archList[@]}"; do
		archSeen["${a}"]=1
		rows+=("${os}|${a}|${rank}|${label}|${rest}")
	done
done
(( ${#rows[@]} )) || fDie "no platform downloads among ${#names[@]} asset name(s) for ${tag}"

mapfile -t rows < <(printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3n -k4,4)
for r in "${rows[@]}"; do
	IFS='|' read -r os a _ label ref <<<"${r}"
	key="${os}|${a}"
	cells["${key}"]="${cells[${key}]:+${cells[${key}]}, }[${label}][${ref}]"
done

## Known names first in this order, then anything new, sorted.
fOrder(){
	local k; local -a known=() out=() extra=()
	while [[ "$1" != "--" ]]; do known+=("$1"); shift; done; shift
	for k in "${known[@]}"; do if [[ " $* " == *" ${k} "* ]]; then out+=("${k}"); fi; done
	for k in "$@"; do if [[ " ${known[*]} " != *" ${k} "* ]]; then extra+=("${k}"); fi; done
	if (( ${#extra[@]} )); then mapfile -t extra < <(printf '%s\n' "${extra[@]}" | LC_ALL=C sort); out+=("${extra[@]}"); fi
	printf '%s\n' "${out[@]}"
}
mapfile -t osList < <(fOrder linux windows macos darwin freebsd netbsd openbsd android -- "${!osSeen[@]}")
mapfile -t archCols < <(fOrder x86_64 arm64 -- "${!archSeen[@]}")

declare -A osName=([linux]=Linux [windows]=Windows [macos]=macOS [darwin]=macOS [freebsd]=FreeBSD
	[netbsd]=NetBSD [openbsd]=OpenBSD [android]=Android)

## Grid of display text, header first, then the widths that pad it.
declare -a grid=() widths=()
nCols=$(( ${#archCols[@]} + 1 ))
grid+=("OS" "${archCols[@]}")
for os in "${osList[@]}"; do
	grid+=("${osName[${os}]:-${os}}")
	for a in "${archCols[@]}"; do grid+=("${cells[${os}|${a}]:-}"); done
done
for ((c = 0; c < nCols; c++)); do widths[c]=4; done
for ((i = 0; i < ${#grid[@]}; i++)); do
	c=$(( i % nCols ))
	if (( ${#grid[i]} > widths[c] )); then widths[c]=${#grid[i]}; fi
done

## Leading pipe, no trailing one, and the last column unpadded. An empty last
## cell still ends the row on a bare pipe; GitHub reads that as empty.
fRow(){
	local line="" cellText c
	for ((c = 0; c < nCols; c++)); do
		if (( c == nCols - 1 )); then line+="| $1"; else printf -v cellText '| %-*s ' "${widths[c]}" "$1"; line+="${cellText}"; fi
		shift
	done
	printf '%s\n' "${line%"${line##*[! ]}"}"
}
nRows=$(( ${#grid[@]} / nCols ))
fRow "${grid[@]:0:nCols}"
seps=(); for ((c = 0; c < nCols; c++)); do seps+=(":---"); done
fRow "${seps[@]}"
for ((r = 1; r < nRows; r++)); do fRow "${grid[@]:r*nCols:nCols}"; done
if (( ${#others[@]} )); then
	joined="$(printf '[%s], ' "${others[@]}")"
	printf '\nOther files: %s\n' "${joined%, }"
	for n in "${others[@]}"; do refs+=("[${n}]: ${base}/${n}"); done
fi
printf '\n'
printf '%s\n' "${refs[@]}"

##	History:
##		- 2026-10-05 JC: Written, for the downloads table in a release's notes.
