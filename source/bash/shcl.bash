#!/usr/bin/env bash
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## shcl.bash
##
##	Shell binding for shcl (Simple Hierarchical Config Language): a convenient
##	front end to the compiled `shcl` binary. Run it as a script, or source it
##	and call the functions - both take the same arguments and hand back the
##	binary's exit code.
##
##	Usage (as a script):
##		shcl.bash get --int  app.shcl  server.port
##		shcl.bash fmt --write app.shcl
##		shcl.bash check app.shcl
##
##	Usage (sourced):
##		source shcl.bash
##		port="$(shcl get --int app.shcl server.port)"      ## the whole CLI
##		port="$(shcl_int app.shcl server.port)"            ## same, typed helper
##		host="$(shcl_get app.shcl server.host)"
##		[[ "$(shcl_bool app.shcl features.debug)" == true ]] && enable_debug
##		hosts=(); while IFS= read -r h; do hosts+=("$h"); done \
##		            < <(shcl_array --string app.shcl cluster.hosts)
##
##	A "$(...)" drops every trailing newline, so a raw block read that way loses
##	its trailing blank lines; read it into a file, or through a loop, when the
##	exact tail matters.
##
##	Functions defined when sourced (each mirrors the CLI and returns its code):
##		shcl                 the whole CLI: get|set|fmt|check|init|count|instances|
##		                     children|paths ...
##		shcl_get             read a string (the default type)
##		shcl_int shcl_float shcl_bool shcl_datetime shcl_raw
##		shcl_duration shcl_size
##		                     read one typed value
##		shcl_array           read an array (pass a --type, else --string)
##		shcl_fmt shcl_check shcl_count shcl_instances shcl_children shcl_paths
##		shcl_migrate shcl_tokens
##		                     the matching subcommands
##
##	Finding the binary (first hit wins):
##		$SHCL_BIN, else a `shcl` beside this file, else one a level up (where
##		the install scripts put it, with this file in scripts/), else `shcl` on
##		PATH, else the repo release/debug build. Set SHCL_BIN to pin an exact
##		one.
##
##	Exit codes (straight from the binary): 0 good, 1 usage error, 2 empty,
##	3 not found, 4 bad type, 5 multiple instances, 6 check failed, strict
##	load failure, a faulty init schema, or --check found a rewrite to make,
##	7 in-place write refused (--lossy overrides) or migrate left something
##	behind, 8 a file or stream could not be read or written.
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

## Strict mode is NOT set globally: it would leak into a shell that sources us,
## and -e is wrong here anyway (a "not found" read is a normal nonzero, not a
## script fault). It is set on the run path only, at the bottom.

## Sourced or run directly? BASH_SOURCE[0]==$0 only when executed as a script.
declare -i _shcl_sourced=0
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || _shcl_sourced=1

## Where this file really lives, resolved once. Follow symlinks by hand (bare
## readlink is POSIX; -f is GNU-only) so a linked-in copy still finds its sibling
## binary and the repo build tree.
_shcl_self="${BASH_SOURCE[0]}"
while [[ -h "${_shcl_self}" ]]; do
	_shcl_link="$(readlink -- "${_shcl_self}")"
	[[ "${_shcl_link}" == /* ]] && _shcl_self="${_shcl_link}" || _shcl_self="$(dirname -- "${_shcl_self}")/${_shcl_link}"
done
_SHCL_DIR="$(cd -- "$(dirname -- "${_shcl_self}")" && pwd)"
unset _shcl_self _shcl_link

## _SHCL_BIN is a private cache, not an interface: an inherited value would pick
## the binary silently, beating every documented lookup step. Clear it at load;
## SHCL_BIN is the supported override.
_SHCL_BIN=""

#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Core
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

## Locate the shcl binary and cache it in _SHCL_BIN. SHCL_BIN, if set, always
## wins; type -P (not command -v) so our own shcl() function can't shadow it.
_shcl_resolve() {
	if [[ -n "${SHCL_BIN:-}" ]]; then
		[[ -f "${SHCL_BIN}" && -x "${SHCL_BIN}" ]] && { _SHCL_BIN="${SHCL_BIN}"; return 0; }
		printf 'shcl.bash: SHCL_BIN is set but not an executable file: %s\n' "${SHCL_BIN}" >&2
		return 1
	fi
	[[ -n "${_SHCL_BIN:-}" && -f "${_SHCL_BIN}" && -x "${_SHCL_BIN}" ]] && return 0
	local candidate
	for candidate in \
		"${_SHCL_DIR}/shcl" \
		"${_SHCL_DIR}/../shcl" \
		"$(type -P shcl 2>/dev/null || true)" \
		"${_SHCL_DIR}/../rust/target/release/shcl" \
		"${_SHCL_DIR}/../rust/target/debug/shcl"
	do
		if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
			_SHCL_BIN="${candidate}"
			return 0
		fi
	done
	printf 'shcl.bash: cannot find a shcl binary (set SHCL_BIN, or put it on PATH)\n' >&2
	return 1
}

## The whole CLI. Everything else is sugar over this.
shcl() {
	_shcl_resolve || return 1
	"${_SHCL_BIN}" "$@"
}

#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Typed sugar (sourced use; the reason to source rather than call the binary)
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

shcl_get()       { shcl get "$@"           ; }
shcl_int()       { shcl get --int "$@"      ; }
shcl_float()     { shcl get --float "$@"    ; }
shcl_bool()      { shcl get --bool "$@"     ; }
shcl_datetime()  { shcl get --datetime "$@" ; }
shcl_duration()  { shcl get --duration "$@" ; }   ## milliseconds; --unit for a bare number
shcl_size()      { shcl get --size "$@"     ; }   ## bytes; --unit, --decimal
shcl_raw()       { shcl get --raw "$@"      ; }
shcl_array()     { shcl get --array "$@"    ; }   ## prefix a --type, else string
shcl_fmt()       { shcl fmt "$@"            ; }
shcl_check()     { shcl check "$@"          ; }
shcl_count()     { shcl count "$@"          ; }
shcl_instances() { shcl instances "$@"      ; }
shcl_children()  { shcl children "$@"       ; }
shcl_paths()     { shcl paths "$@"          ; }
shcl_migrate()   { shcl migrate "$@"        ; }
shcl_tokens()    { shcl tokens "$@"         ; }

#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Run path
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

## When executed (not sourced), be the CLI: forward args, forward the code.
## -uo pipefail but NOT -e, so the binary's nonzero statuses pass through clean.
if (( ! _shcl_sourced )); then
	set -uo pipefail
	shcl "$@"
	exit $?
fi
