#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## shcl.bash (bash completion)
##
##	Tab completion for the shcl CLI. Installed as
##	<datadir>/bash-completion/completions/shcl, or sourced by hand:
##		source shcl.bash
##
##	The option table below mirrors check_opts() in the CLI, one arm per
##	subcommand. cicd/utility/check-completions.bash diffs the two, so an option
##	added to the CLI without a line here fails the build.
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

## Subcommands. The CLI takes exactly one, and always as the first word.
_shcl_subcommands='get set fmt check init count instances children paths migrate tokens explain help version about donate'

## Type options, valid on `get` only. The table below carries them as the single
## token --<type>, exactly as the CLI's own table does.
_shcl_types='--int --float --bool --datetime --string --raw --rawinfo --duration --size'

## Options that take a value, in either spelling. Mirrors the list asked_for()
## steps over in the CLI; check-completions.bash diffs the two.
_shcl_valopts='--default --on-bad --strictness --schema --unit --layer --set --set-literal --set-default --set-literal-default --remove'

## Options each subcommand accepts. Anything else is a usage error to the CLI,
## so offering it here would be a lie.
_shcl_opts() {
	case "$1" in
		get)             echo '--<type> --array --slots --unit --decimal --default --on-bad --strictness --layer --set --set-literal --set-default --set-literal-default --remove' ;;
		set)             echo '--strictness --layer --set --set-literal --set-default --set-literal-default --remove --write --lossy --no-banner' ;;
		fmt)             echo '--write --lossy --check --strictness --layer --set --set-literal --set-default --set-literal-default --remove' ;;
		check)           echo '--strictness --schema' ;;
		init)            echo '--schema --no-banner' ;;
		migrate)         echo '--write --lossy --from-2x --check' ;;
		tokens|explain)  echo '' ;;
		count|instances|children|paths) echo '--strictness --layer --set --set-literal --set-default --set-literal-default --remove' ;;
		*)               echo '' ;;
	esac
}

## Positional file slot per subcommand: the argument number FILE occupies, or 0
## for the subcommands that take none. Everything after FILE is a PATH, which
## nothing here can enumerate - so it completes to nothing rather than to
## filenames that would always be wrong.
_shcl_fileslot() {
	case "$1" in
		get|set|fmt|check|count|instances|children|paths|migrate|tokens) echo 1 ;;
		*)                                 echo 0 ;;
	esac
}

_shcl() {
	## split: older bash-completion releases hand it back from -s; declared so
	## it never leaks into the shell.
	# shellcheck disable=SC2034
	local cur prev cmd opts i word positional fileslot cword split
	local -a words

	## bash has already cut the line at every character of COMP_WORDBREAKS,
	## which holds `=` and `:`, so `--set url=http://x` arrives as six words.
	## _shcl_words puts them back the way the shell split the line, which is
	## what the CLI sees; bash-completion's -s handles the first `=` only, and
	## the count below then read a value as the FILE.
	_shcl_words

	## Word 1 is the subcommand and nothing else.
	if (( cword == 1 )); then
		mapfile -t COMPREPLY < <(compgen -W "${_shcl_subcommands} -h --help -v -V --version --about --donate" -- "${cur}")
		return
	fi
	cmd="${words[1]}"

	## Value options, either spelling: the next word is the value, whatever it
	## looks like, so complete for the option rather than for the position.
	case "${prev}" in
		--strictness)     mapfile -t COMPREPLY < <(compgen -W 'loose standard strict 1 2 3' -- "${cur}"); return ;;
		--on-bad)         mapfile -t COMPREPLY < <(compgen -W 'error default flag' -- "${cur}"); return ;;
		--unit)           mapfile -t COMPREPLY < <(compgen -W 'ms s m h d B KB MB GB TB KiB MiB GiB TiB' -- "${cur}"); return ;;
		--schema|--layer) _shcl_files "${cur}"; return ;;
	esac
	## The rest take a PATH, or a value nothing here can enumerate.
	[[ " ${_shcl_valopts} " == *" ${prev} "* ]] && return

	if [[ "${cur}" == -* ]]; then
		opts="$(_shcl_opts "${cmd}")"
		[[ "${opts}" == *'--<type>'* ]] && opts="${opts//--<type>/${_shcl_types}}"
		## -w is the only short option; the CLI takes no other.
		[[ "${opts}" == *'--write'* ]] && opts="${opts} -w"
		mapfile -t COMPREPLY < <(compgen -W "${opts} -h --help" -- "${cur}")
		return
	fi

	## help takes a subcommand name, the one positional here that can be listed.
	if [[ "${cmd}" == "help" ]]; then
		mapfile -t COMPREPLY < <(compgen -W "${_shcl_subcommands}" -- "${cur}")
		return
	fi

	## A positional. Count the ones already given, skipping options and the
	## values that follow them in the space form (the =VALUE form is one word).
	## `-` is a FILE (stdin), and everything after `--` is a positional whatever
	## it looks like, so neither is skipped as an option.
	positional=0
	local ended=0
	for (( i = 2; i < cword; i++ )); do
		word="${words[i]}"
		if (( ended )); then
			(( positional++ ))
		elif [[ "${word}" == "--" ]]; then
			ended=1
		elif [[ " ${_shcl_valopts} " == *" ${word} "* ]]; then
			(( i++ ))
		elif [[ "${word}" == "-" || "${word}" != -* ]]; then
			(( positional++ ))
		fi
	done
	fileslot="$(_shcl_fileslot "${cmd}")"
	(( fileslot && positional + 1 == fileslot )) && _shcl_files "${cur}"
}

## Put back what readline cut at a break character, then split the current word
## the way _init_completion -s does. Sets words, cword, cur and prev. The line
## itself says where the shell's own words end: a piece that follows without a
## blank between belongs to the piece before it.
_shcl_words() {
	local w rest="${COMP_LINE:0:${COMP_POINT}}"
	words=()
	for (( i = 0; i <= COMP_CWORD; i++ )); do
		w="${COMP_WORDS[i]}"
		if (( i > 0 && ${#words[@]} )) && [[ -n "${w}" && "${rest}" != [[:space:]]* ]]; then
			words[-1]+="${w}"
		else
			while [[ "${rest}" == [[:space:]]* ]]; do rest="${rest#?}"; done
			words+=("${w}")
		fi
		rest="${rest#"${w}"}"
	done
	cword=$(( ${#words[@]} - 1 ))
	cur="${words[cword]}"
	prev="${words[cword-1]}"
	if [[ "${cur}" == --?*=* ]]; then
		prev="${cur%%=*}"
		cur="${cur#*=}"
	fi
}

## Filename completion. bash-completion's _filedir handles quoting, dirs and
## the compopt dance properly; the compgen fallback is for a hand-sourced copy
## on a box without it.
_shcl_files() {
	if declare -F _filedir >/dev/null; then
		_filedir
		return
	fi
	compopt -o filenames 2>/dev/null
	mapfile -t COMPREPLY < <(compgen -f -- "$1")
}

complete -F _shcl shcl
