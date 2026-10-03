#!/usr/bin/env bash
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## install-dev.bash
##
##	Dev-environment setup for shcl on Linux and macOS (on Windows, use WSL -
##	the dev pipeline is bash). Clones the repo if needed, installs what it can
##	without sudo (rustup, and the optional linters via pipx/npm/pwsh), and
##	prints the exact install hint for anything that needs the system package
##	manager. States the plan first, with an option to abort.
##
##	Usage (one-liner):
##		bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install-dev.bash)
##	With options:
##		bash <(curl -fsSL .../install-dev.bash) --yes
##
##	Options:
##		--dir <path>   where to clone (default ./shcl; skipped when run inside
##		               an existing shcl clone).
##		--yes | -y     skip the confirmation prompt.
##		--hooks-only   skip the toolchain and just point git at the tracked
##		               hooks (for a box that already has the tools).
##		--version      print this installer's version and exit.
##
##	What a full dev box needs (see contributing.md "How to develop"):
##		gating:   rustup (rustfmt+clippy ride along), go, python3, gcc+g++,
##		          shellcheck, ruff, mypy, cppcheck, build, markdownlint-cli2,
##		          staticcheck, govulncheck, cargo-deny (all at the pinned versions),
##		          PSScriptAnalyzer (only if pwsh is present)
##		the gate: cicd/cicd.bash --ci
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

set -euo pipefail

installer_version="1.1.1"
REPO_URL="https://github.com/yottacore/shcl"
clone_dir="./shcl"
assume_yes=0
hooks_only=0
dir_given=0

fDie() { printf 'install-dev.bash: %s\n\n' "$*" >&2; exit 1; }
fHave() { command -v "$1" >/dev/null 2>&1; }

## Usage text lives here, not in a sed slice of "$0": under a
## `curl | bash -s -- --help` pipe, $0 is just "bash" and sed reads the wrong
## file (or a stray one named "bash" in the cwd).
fUsage() {
	cat <<EOF
install-dev.bash ${installer_version} - dev-environment setup for shcl

Linux and macOS; on Windows use WSL, since the dev pipeline is bash. Clones the
repo if needed, installs what it can without sudo (rustup, and the optional
linters via pipx/npm/pwsh), and prints the exact install hint for anything that
needs the system package manager. States the plan first, with an option to abort.

Usage (one-liner):
  bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install-dev.bash)

With options:
  bash <(curl -fsSL .../install-dev.bash) --yes

Options:
  --dir <path>   where to clone (default ./shcl; skipped when run inside an
                 existing shcl clone).
  --yes, -y      skip the confirmation prompt.
  --hooks-only   skip the toolchain and just point git at the tracked hooks
                 (for a box that already has the tools). Needs an existing
                 clone: run it inside one, or name one with --dir.
  --version      print this installer's version and exit.

What a full dev box needs (see contributing.md, "How to develop"):
  gating:    rustup (rustfmt and clippy ride along), go, python3, gcc and g++,
             shellcheck, ruff, mypy, cppcheck, build, markdownlint-cli2,
             staticcheck, govulncheck, cargo-deny (all at the pinned versions),
             PSScriptAnalyzer (only if pwsh is present)
  the gate:  cicd/cicd.bash --ci

EOF
}

## Every run opens with a blank line and ends with one, errors included.
echo

while (( $# )); do
	case "$1" in
		--dir=*) clone_dir="${1#*=}"; dir_given=1 ;;
		--dir)   (( $# >= 2 )) || fDie "missing value for --dir (try --dir=VALUE)"; shift; clone_dir="$1"; dir_given=1 ;;
		--hooks-only) hooks_only=1 ;;
		-y|--yes) assume_yes=1 ;;
		-h|--help) fUsage; exit 0 ;;
		--version) printf 'install-dev.bash %s\n\n' "${installer_version}"; exit 0 ;;
		*) fDie "unknown option: $1" ;;
	esac
	shift
done

case "$(uname -s)" in Linux|Darwin) ;; *) fDie "Linux/macOS only (on Windows, run this under WSL)" ;; esac
fHave git || fDie "git is required first"

## curl or wget, whichever is present, the same way install.bash does it; only
## the rustup step needs one. https is pinned through redirects and TLS floored
## at 1.2, so a bounced download can't silently downgrade.
if fHave curl; then
	fFetch() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$2" "$1"; }
elif fHave wget; then
	## wget's --https-only covers recursive downloads only, so a redirect to
	## plain http went through. Its own record of each response names every hop,
	## and a plain-http Location refuses the file.
	fWget() { local hops rc=0; { hops="$(wget -q --https-only --secure-protocol=TLSv1_2 --server-response "$@" 2>&1 >&3 3>&-)" || rc=$?; } 3>&1; if grep -qiE '^[[:space:]]*Location:[[:space:]]*http:' <<< "${hops}"; then echo "refused a redirect to plain http" >&2; return 1; fi; return "${rc}"; }
	fFetch() { fWget -O "$2" "$1" || { rm -f -- "$2"; return 1; }; }
fi

## Point git at the tracked hooks rather than copying them in, so an update to
## the hook arrives with a pull instead of needing a reinstall. -e, not -d: in
## a worktree .git is a file.
fSetupHooks() {
	git -C "${clone_dir}" config core.hooksPath cicd/hooks
	echo "git hooks: core.hooksPath -> cicd/hooks (pre-push gates main)"
	## The gate runs for minutes while git already holds the ssh session open;
	## without keepalives GitHub drops it and the push dies of SIGPIPE after a
	## green gate. Only set when nothing is configured, so a chosen key stays.
	if ! git -C "${clone_dir}" config core.sshCommand >/dev/null; then
		git -C "${clone_dir}" config core.sshCommand "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=30"
		echo "git ssh: keepalives on, so the pre-push gate cannot outlive the connection"
	fi
}

## Already inside a clone? Then set up here instead of cloning again. Known by
## shape, not by remote URL, so a fork's clone counts too. An explicit --dir
## wins under --hooks-only, which exists to be pointed at a clone.
fIsShcl(){   ## fIsShcl DIR
	[[ -e "$1/.git" && -f "$1/cicd/cicd.bash" ]] && grep -q '^name = "shcl"' "$1/source/rust/Cargo.toml" 2>/dev/null
}
in_clone=0
if (( ! (hooks_only && dir_given) )) \
	&& top="$(git rev-parse --show-toplevel 2>/dev/null)" && fIsShcl "${top}"; then
	in_clone=1; clone_dir="${top}"
fi

## Hooks only: no clone, no stocktaking, no installs.
if (( hooks_only )); then
	if (( ! in_clone )); then
		fIsShcl "${clone_dir}" || fDie "--hooks-only needs an existing clone (run inside one, or name one with --dir)"
	fi
	fSetupHooks
	echo
	exit 0
fi

## An existing --dir is used only if it is already a clone of this project.
## Anything else there gets refused before the plan, since git config and the
## dev checkout below would land on someone else's repository.
if (( ! in_clone )) && [[ -e "${clone_dir}" ]]; then
	if fIsShcl "${clone_dir}"; then
		in_clone=1; clone_dir="$(cd "${clone_dir}" && pwd)"
	elif [[ -n "$(ls -A "${clone_dir}" 2>/dev/null)" || ! -d "${clone_dir}" ]]; then
		fDie "${clone_dir} already exists and is not an shcl clone - pick another --dir"
	fi
fi

## Tool versions come from TOOL_PINS in cicd/config.bash, so a dev box gets what
## the gate expects rather than whatever is newest today (the pipeline warns on
## every run otherwise). Outside a clone the file is fetched from main: there is
## nothing else to read it from before the clone exists.
if (( in_clone )); then
	pins_file="${clone_dir}/cicd/config.bash"
else
	fHave curl || fHave wget || fDie "need curl or wget"
	pins_file="$(mktemp)"
	trap 'rm -f "${pins_file}"' EXIT
	fFetch "https://raw.githubusercontent.com/yottacore/shcl/main/cicd/config.bash" "${pins_file}" || fDie "cannot fetch cicd/config.bash for the tool pins"
fi
## "name|version|command" out of TOOL_PINS -> pin_ver, pin_cmd.
fPin() {
	local line
	line="$(awk -v name="$1" '/^TOOL_PINS=\(/ { inpins=1; next } inpins && /^\)/ { exit } inpins && index($0, "\"" name "|") { sub(/^[ \t]*"/, ""); sub(/"[ \t]*$/, ""); print; exit }' "${pins_file}")"
	[[ -n "${line}" ]] || fDie "no TOOL_PINS entry for $1 in cicd/config.bash"
	pin_ver="${line#*|}"; pin_cmd="${pin_ver#*|}"; pin_ver="${pin_ver%%|*}"
}
## The cppcheck pin names the binary; the PyPI wheel that contains it has its own
## version, kept beside TOOL_PINS as CPPCHECK_WHEEL so nothing here can drift.
fCppcheckWheel() {
	cppcheck_wheel="$(sed -n 's/^CPPCHECK_WHEEL="\([^"]*\)".*/\1/p' "${pins_file}")"
	[[ -n "${cppcheck_wheel}" ]] || fDie "no CPPCHECK_WHEEL in cicd/config.bash"
}
## Installed at the pinned version? The same test the pipeline's drift warning
## makes; missing and drifted both count as "install".
fAtPin() {
	fPin "$1"
	# shellcheck disable=SC2086
	[[ "$(${pin_cmd} 2>/dev/null | head -5 | tr '\n' ' ')" == *"${pin_ver}"* ]]
}

## Take stock: what gets installed (no sudo), what only gets a hint. The cargo
## and go bin dirs join PATH for the checks below, since that is where the
## installs land whether or not the user's profile knows it yet.
orig_path="${PATH}"
[[ -d "${HOME}/.cargo/bin" ]] && PATH="${HOME}/.cargo/bin:${PATH}"
gobin=""
fHave go && gobin="$(go env GOPATH)/bin" && PATH="${gobin}:${PATH}"
pkg_hint="your package manager"
if fHave apt-get; then pkg_hint="sudo apt-get install"
elif fHave dnf; then pkg_hint="sudo dnf install"
elif fHave pacman; then pkg_hint="sudo pacman -S"
elif fHave brew; then pkg_hint="brew install"
fi
todo=() hints=()
need_rustup=0
if ! fHave cargo && [[ ! -x "${HOME}/.cargo/bin/cargo" ]]; then
	if fHave curl || fHave wget; then need_rustup=1; todo+=("rustup (official installer, user-space)")
	else hints+=("curl/wget   - ${pkg_hint} curl  (then re-run for rustup)")
	fi
fi
fHave go         || hints+=("go          - ${pkg_hint} golang (or https://go.dev/dl)")
fHave python3    || hints+=("python3     - ${pkg_hint} python3")
fHave cc         || hints+=("gcc/g++     - ${pkg_hint} build-essential (or gcc gcc-c++)")
fHave shellcheck || hints+=("shellcheck  - ${pkg_hint} shellcheck")
if fHave pipx; then
	for t in ruff mypy build; do fAtPin "$t" || todo+=("${t} ${pin_ver} (pipx, user-space)"); done
	## Both versions, because they are different numbers for one tool: the pin
	## is the binary's version and the install asks pipx for the wheel's. The
	## plan used to name the binary's and the install two blocks down fetched
	## the other, so the two lines disagreed about what was about to happen.
	fAtPin cppcheck || { fCppcheckWheel; todo+=("cppcheck ${pin_ver} (pipx cppcheck==${cppcheck_wheel}, user-space)"); }
else
	hints+=("pipx        - ${pkg_hint} pipx  (then re-run for ruff/mypy/cppcheck/build)")
fi
if fHave npm; then
	fAtPin markdownlint-cli2 || todo+=("markdownlint-cli2 ${pin_ver} (npm -g --prefix ~/.local)")
else
	hints+=("npm         - ${pkg_hint} npm  (then re-run for markdownlint-cli2)")
fi
## The supply-chain trio the gate runs. The Go pair ride the go hint when go is
## missing; cargo-deny builds through cargo, which may itself arrive this run.
if fHave go; then
	for t in staticcheck govulncheck; do fAtPin "$t" || todo+=("${t} ${pin_ver} (go install, user-space)"); done
fi
if (( need_rustup )) || fHave cargo || [[ -x "${HOME}/.cargo/bin/cargo" ]]; then
	fAtPin cargo-deny || todo+=("cargo-deny ${pin_ver} (cargo install, user-space - builds from source, takes a while)")
fi
if fHave pwsh; then
	pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 1 }" >/dev/null 2>&1 \
		|| todo+=("PSScriptAnalyzer (pwsh Install-Module, user-scope)")
fi

## The plan.
if (( in_clone )); then
	printf 'using the existing clone at %s\n' "${clone_dir}"
else
	printf 'will clone %s -> %s\n' "${REPO_URL}" "${clone_dir}"
fi
if (( ${#todo[@]} )); then
	echo "will install (no sudo):"
	printf '  %s\n' "${todo[@]}"
fi
if (( ${#hints[@]} )); then
	echo "missing - install these yourself (needs the system package manager):"
	printf '  %s\n' "${hints[@]}"
fi
if (( ! ${#todo[@]} && ! ${#hints[@]} )) && (( in_clone )); then
	echo "everything is already in place"
fi
if (( ! assume_yes )); then
	## Ask on the terminal, and treat "cannot ask" as the abort it is. Testing
	## /dev/tty for readability was not the same question: it passes in plenty of
	## unattended contexts where the read then dies on a raw shell error.
	reply=""
	if ! read -r -p "Proceed? [y/N] " reply 2>/dev/null </dev/tty; then
		fDie "no terminal to confirm on - pass --yes"
	fi
	case "${reply}" in y|Y|yes|Yes|YES) ;; *) printf 'aborted\n\n'; exit 1 ;; esac
fi

## Clone. Resolve the dir to an absolute path afterwards - later steps refer to
## it from inside the clone, where a relative --dir no longer points here.
## contributing.md says to branch from dev, so a fresh clone starts there rather
## than on the release branch. Anything already checked out or edited is left
## alone - this is a convenience for a first clone, not a policy.
fStartOnDev(){   ## fStartOnDev DIR
	local dir="$1"
	git -C "${dir}" show-ref --verify --quiet refs/remotes/origin/dev || return 0
	[[ "$(git -C "${dir}" branch --show-current)" == "main" ]] || return 0
	git -C "${dir}" diff --quiet && git -C "${dir}" diff --cached --quiet || return 0
	git -C "${dir}" checkout -q dev
}
if (( ! in_clone )); then
	echo
	git clone "${REPO_URL}" "${clone_dir}"
	cd "${clone_dir}"
	clone_dir="$(pwd)"
	fStartOnDev "${clone_dir}"
fi

## Install the user-space pieces.
echo
if (( need_rustup )); then
	echo "installing rustup..."
	## To a file first, so a download that fails or that a redirect took to
	## plain http runs nothing.
	rustup_sh="$(mktemp)"
	fFetch https://sh.rustup.rs "${rustup_sh}" || { rm -f -- "${rustup_sh}"; fDie "cannot fetch the rustup installer"; }
	sh "${rustup_sh}" -y --no-modify-path || { rm -f -- "${rustup_sh}"; fDie "the rustup installer failed"; }
	rm -f -- "${rustup_sh}"
	PATH="${HOME}/.cargo/bin:${PATH}"
fi
if fHave pipx; then
	for t in ruff mypy build; do fAtPin "$t" || pipx install --force "${t}==${pin_ver}"; done
	fAtPin cppcheck || { fCppcheckWheel; pipx install --force "cppcheck==${cppcheck_wheel}"; }
fi
if fHave npm; then
	fAtPin markdownlint-cli2 || npm install -g --prefix "${HOME}/.local" "markdownlint-cli2@${pin_ver}"
fi
if fHave go; then
	fAtPin staticcheck || go install "honnef.co/go/tools/cmd/staticcheck@${pin_ver}"
	fAtPin govulncheck || go install "golang.org/x/vuln/cmd/govulncheck@${pin_ver}"
fi
if fHave cargo; then
	fAtPin cargo-deny || cargo install cargo-deny --version "${pin_ver}" --locked
fi
if fHave pwsh; then
	pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force }"
fi

[[ -e "${clone_dir}/.git" ]] && fSetupHooks

echo
echo "done. The gate is:  cicd/cicd.bash --ci"
echo "(rust-toolchain.toml pins the toolchain; the first cargo run fetches it.)"
(( ${#hints[@]} )) && echo "note: the hinted packages above are still missing."
## By element, with a trailing slash ignored on either side: the shell
## resolves `bin/` fine, and a plain string compare did not.
fOnPath(){
	local dir="${1%/}" elem
	while IFS= read -r -d: elem || [[ -n "${elem}" ]]; do
		[[ "${elem%/}" == "${dir}" ]] && return 0
	done <<<"${orig_path}:"
	return 1
}
for bindir in "${HOME}/.cargo/bin" "${gobin}"; do
	[[ -n "${bindir}" && -d "${bindir}" ]] && ! fOnPath "${bindir}" && echo "note: ${bindir} is not on your PATH - the tools installed there need it to be."
done
echo
exit 0
