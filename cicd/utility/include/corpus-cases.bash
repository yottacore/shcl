#!/usr/bin/env bash

##	Purpose:
##		fCases prints the CLI runs over the conformance corpus that the release
##		checks compare between 2 builds of the CLI. Paths are relative,
##		under c/, so the caller copies project/conformance/* into c/ first.
##		Needs root set to the repo.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

##	One row per CLI run: an id, then the arguments, tab-separated. Every
##	input in the corpus through the subcommands that take a bare file, the
##	schema ones where a case has a schema, and each typed read in reads.tsv.
# shellcheck disable=SC2154  ## root is the caller's
fCases(){
	local dir rel f n=0 q t ty args
	for dir in "${root}"/project/conformance/*/; do
		rel="c/$(basename "${dir}")"
		for f in "${dir}"*.shcl; do
			[[ -e "${f}" ]] || continue
			for t in fmt check paths tokens upgrade; do n=$((n + 1)); printf '%s\t%s\t%s\n' "${n}" "${t}" "${rel}/${f##*/}"; done
		done
		if [[ -f "${dir}schema.shcl" && -f "${dir}input.shcl" ]]; then
			n=$((n + 1)); printf '%s\tcheck\t--schema=%s\t%s\n' "${n}" "${rel}/schema.shcl" "${rel}/input.shcl"
			n=$((n + 1)); printf '%s\tinit\t--schema=%s\n' "${n}" "${rel}/schema.shcl"
		fi
		[[ -f "${dir}reads.tsv" && -f "${dir}input.shcl" ]] || continue
		while IFS= read -r line; do
			q="${line%%$'\t'*}"; ty="${line#*$'\t'}"; ty="${ty%%$'\t'*}"
			case "${ty}" in
				int|float|bool|datetime|string|raw|rawinfo|duration|size) args="get"$'\t'"--${ty}" ;;
				*'[]') args="get"$'\t'"--${ty%[]}"$'\t'"--array" ;;
				duration@*|size@*) args="get"$'\t'"--${ty%@*}"$'\t'"--unit=${ty#*@}" ;;
				count|instances|children|paths) args="${ty}" ;;
				*) continue ;;
			esac
			n=$((n + 1))
			if [[ "${ty}" == paths ]]; then printf '%s\t%s\t%s\n' "${n}" "${args}" "${rel}/input.shcl"
			else printf '%s\t%s\t%s\t%s\n' "${n}" "${args}" "${rel}/input.shcl" "${q}"; fi
		done < <(tail -n +2 "${dir}reads.tsv")
	done
	n=$((n + 1)); printf '%s\texplain\n' "${n}"
	n=$((n + 1)); printf '%s\t--help\n' "${n}"
}

##	History:
##		- 2026-10-20: Moved out of check-cpu-floor.bash, for check-win-release.bash.
