#!/usr/bin/env bash
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## install.bash
##
##	Release installer for shcl (Simple Hierarchical Config Language) on Linux,
##	macOS, and FreeBSD.
##	It downloads the latest release from GitHub, checks the sha256sums file
##	against the release signing key before it trusts any checksum in it, and
##	lays out the binary and the drop-in source files. Running it again updates
##	an existing install in place, and removes the retired shell wrappers that an
##	older install put in scripts/.
##
##	It needs curl or wget, and openssl for the signature check.
##
##	Usage (one-liner):
##		bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
##		bash <(wget -qO- https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
##	With options:
##		bash <(curl -fsSL .../install.bash) --target=system --yes
##	`curl ... | bash -s -- OPTIONS` works too.
##
##	Options (both --opt=VALUE and --opt VALUE work):
##		--release <stable|dev>   stable (default): newest full release, or the
##		                         newest pre-release while there is no full one.
##		                         dev: newest release including pre-releases.
##		--target <user|system>   user (default): ~/.local/share/shcl plus a symlink
##		                         at ~/.local/bin/shcl. No sudo.
##		                         system: /opt/shcl plus a symlink at
##		                         /usr/local/bin/shcl (sudo if not root).
##		--yes | -y               skip the confirmation prompt.
##		--version                print this installer's version and exit.
##		--uninstall              remove what an install of the same --target
##		                         laid down (binary, symlinks, code/, man/,
##		                         completions/, and an older install's
##		                         scripts/), and nothing else.
##
##	Layout under the install dir:
##		shcl         the CLI binary
##		code/        drop-in single-file bindings (lib.rs, shcl.go, shcl.py,
##		             shcl.h, shcl.hpp)
##		man/         the man page, symlinked into the target's man1 dir
##		completions/ bash and zsh completions. Enable them by hand, as the note
##		             at the end of the install says. The .deb and .rpm do it
##		             for you.
##
##	There aren't any prebuilt binaries for NetBSD or OpenBSD yet. Build from
##	source, or use a drop-in file as described in
##	https://github.com/yottacore/shcl/blob/main/project/install.md#diy-install
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

set -euo pipefail

installer_version="1.5.0"
REPO="yottacore/shcl"
release="stable"
target="user"
assume_yes=0
uninstall=0

## Release signing key. The sha256sums file is signed offline with the matching
## private key, so an attacker who replaces a release asset would also have to
## forge this signature. The key is baked in rather than fetched, because a key
## downloaded over the same channel as the artifact proves nothing. Rotating it
## means publishing a new installer, so treat that as a breaking change.
readonly SIGNING_KEY='-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAk5W58wTiFTlHUCsIuHES
qexain6AC8WwFmCDsjfliOIDa2vPhkSVOqMsSbYH/OL94pHZ+Bs0agNXrl99ANol
zwQ4rvu6gAsc4GCb0Krbbq2B+jKqTM8xeN7tFLWKd5E08IOF2HA4ugQSlK+rC6ez
bBqP1MuJFFxqxDhEtGef9v/nuhX2kWq3v0uN6Y0umbghuNAR7gmoSOwbb8uYfVOA
H1OAWV2To2wyIe6WWt4BPmFJBpEI53k4rmoDVdjmJFoj2vETHmEh2QfTPA5541jP
LeuO8p8V6+Aa8i32EtVeT1+ozwHidku/CZZOAdxYZ7yXAZdG3eOOxcHVfmXVwqRx
PR+lA3E/KcRcN9oeeveXS35jwH0h3hSh6sJOr1q0qMtM7bB4Lxt47wXHTJ0VPneG
5xbmO5pUS3LMcZwnXXavYjh2kYS52ZLhi1JbPFgPyYUiIv76IUbwtpEXbONi12g7
fioZ6cStZAekJs33Wkee6NmSY54AozxTkcNUJTgs81eMa/gRL8l3jud8AWqL5vyk
qpG1PTN70vSgrHD4wNMp2QX29Iv+A6+FO4B1oxjrnokg212rwqX004Ep0csu/JjO
l9XHvwp0Iucfi8zCg7ozDcU3dsDnUJ8A3PtJ47jEt1n37/oiM6pWDXVVBjz4DI9i
ACmdUphTcGhYvn91ORZVxt0CAwEAAQ==
-----END PUBLIC KEY-----'

fDie() { printf 'install.bash: %s\n\n' "$*" >&2; exit 1; }

## The usage text is a heredoc rather than a sed slice of "$0", because under a
## `curl | bash -s -- --help` pipe $0 is "bash", and sed would read the wrong
## file, or a stray one named "bash" in the cwd.
fUsage() {
	cat <<EOF
install.bash ${installer_version} - release installer for shcl on Linux, macOS, and FreeBSD

It downloads the latest release from GitHub, checks the sha256sums file against
the release signing key before it trusts any checksum in it, and lays out the
binary and the drop-in source files. Running it again updates an existing install
in place, and removes the shell wrappers that an older install put in scripts/.

It needs curl or wget, and openssl for the signature check.

Usage (one-liner):
  bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
  bash <(wget -qO- https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)

With options:
  bash <(curl -fsSL .../install.bash) --target=system --yes

Options (both --opt=VALUE and --opt VALUE work):
  --release <stable|dev>   stable (default): newest full release, or the
                           newest pre-release while there is no full one.
                           dev: newest release including pre-releases.
  --target <user|system>   user (default): ~/.local/share/shcl plus a symlink
                           at ~/.local/bin/shcl. No sudo.
                           system: /opt/shcl plus a symlink at
                           /usr/local/bin/shcl (sudo if not root).
  --yes, -y                skip the confirmation prompt.
  --version                print this installer's version and exit.
  --uninstall              remove what an install of the same --target laid
                           down (binary, symlinks, code/, man/, completions/,
                           and an older install's scripts/), and nothing else.

Layout under the install dir:
  shcl          the CLI binary
  code/         drop-in single-file bindings (lib.rs, shcl.go, shcl.py,
                shcl.h, shcl.hpp)
  man/          the man page, symlinked into the target's man1 dir
  completions/  bash and zsh completions. Enable them by hand, as the note at
                the end of the install says. The .deb and .rpm do it for you.

EOF
}

## Every run opens with a blank line and ends with one, errors included.
echo

## Value options accept --opt=VALUE and --opt VALUE, like the shcl CLI.
while (( $# )); do
	case "$1" in
		--release=*) release="${1#*=}" ;;
		--release)   (( $# >= 2 )) || fDie "missing value for --release (try --release=VALUE)"; shift; release="$1" ;;
		--target=*)  target="${1#*=}" ;;
		--target)    (( $# >= 2 )) || fDie "missing value for --target (try --target=VALUE)"; shift; target="$1" ;;
		-y|--yes)    assume_yes=1 ;;
		--uninstall) uninstall=1 ;;
		-h|--help)   fUsage; exit 0 ;;
		--version)   printf 'install.bash %s\n\n' "${installer_version}"; exit 0 ;;
		*) fDie "unknown option: $1" ;;
	esac
	shift
done
case "${release}" in dev|development) release="dev" ;; stable) ;; *) fDie "--release must be dev or stable" ;; esac
case "${target}" in user|system) ;; *) fDie "--target must be user or system" ;; esac

## There are prebuilt binaries for Linux on x86_64 and arm64, macOS on both, and
## FreeBSD on x86_64 only. Rust doesn't have a prebuilt std for FreeBSD on arm64.
os="$(uname -s)"
case "${os}" in
	Linux)   osname="linux" ;;
	Darwin)  osname="macos" ;;
	FreeBSD) osname="freebsd" ;;
	*) fDie "no prebuilt ${os} binaries yet - build from source or use a drop-in file, as described in https://github.com/yottacore/shcl/blob/main/project/install.md#diy-install" ;;
esac
case "$(uname -m)" in
	x86_64|amd64)  arch="x86_64" ;;
	aarch64|arm64) arch="arm64" ;;
	*) fDie "no prebuilt binary for $(uname -m)" ;;
esac
[[ "${osname}-${arch}" == freebsd-arm64 ]] && fDie "no prebuilt FreeBSD arm64 binary - build from source: cargo install shcl"
## macOS has one binary for both, so a shell running under Rosetta gets the
## same file as a native one.
[[ "${osname}" == macos ]] && arch="universal"

## Use curl or wget, whichever is present. https is pinned through redirects and
## TLS is floored at 1.2, so a bounced download can't silently downgrade.
## GITHUB_TOKEN goes to the API calls alone. Every release download redirects
## to another host, and wget sends a --header on to it, so fFetch doesn't send
## one.
if command -v curl >/dev/null; then
	fFetch() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$2" "$1"; }
	fFetchApi() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} -o "$2" "$1"; }
	fApiStatus() { curl -fsS -o /dev/null -w '%{http_code}' --proto '=https' --tlsv1.2 ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "$1" 2>/dev/null || true; }
elif command -v wget >/dev/null; then
	## wget's --https-only applies to recursive downloads only, so a redirect to
	## plain http went through. wget's own record of each response names every
	## hop, and a Location header with plain http refuses the file.
	fWget() { local hops rc=0; { hops="$(wget -q --https-only --secure-protocol=TLSv1_2 --server-response "$@" 2>&1 >&3 3>&-)" || rc=$?; } 3>&1; if grep -qiE '^[[:space:]]*Location:[[:space:]]*http:' <<< "${hops}"; then echo "refused a redirect to plain http" >&2; return 1; fi; return "${rc}"; }
	fFetch() { fWget -O "$2" "$1" || { rm -f -- "$2"; return 1; }; }
	fFetchApi() { fWget ${GITHUB_TOKEN:+--header="Authorization: Bearer ${GITHUB_TOKEN}"} -O "$2" "$1" || { rm -f -- "$2"; return 1; }; }
	fApiStatus() { wget -q --https-only --secure-protocol=TLSv1_2 ${GITHUB_TOKEN:+--header="Authorization: Bearer ${GITHUB_TOKEN}"} --server-response -O /dev/null "$1" 2>&1 | awk '/^  HTTP/ { code = $2 } END { print code }'; }
else
	fDie "need curl or wget"
fi
## openssl is required, the same as curl or wget. Without it the release
## signature can't be checked, and an unverified install isn't offered. On a
## box without openssl, verify by hand and use the DIY path.
command -v openssl >/dev/null || fDie "need openssl to verify the release signature - for a manual install, see https://github.com/yottacore/shcl/blob/main/project/install.md#diy-install"
## openssl does the checksums too. FreeBSD before 14 doesn't have sha256sum.
fSha256(){ openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

## The man dir is the one man already reads for that target, so `man shcl` works
## without a MANPATH edit, in the same way the binary symlink works on PATH.
if [[ "${target}" == "system" ]]; then
	dest="/opt/shcl"
	link="/usr/local/bin/shcl"
	manlink="/usr/local/share/man/man1/shcl.1"
	asroot=""
	## Check that sudo is here before planning to use it. Choosing it blind fails
	## at the first write, after both downloads and the confirmation.
	if [[ "$(id -u)" != 0 ]]; then
		command -v sudo >/dev/null || fDie "a system install needs root, so run as root, install sudo, or use --target=user"
		asroot="sudo"
	fi
else
	dest="${HOME}/.local/share/shcl"
	link="${HOME}/.local/bin/shcl"
	manlink="${HOME}/.local/share/man/man1/shcl.1"
	asroot=""
fi

## Removes the files the install writes, by name, then each payload directory if
## that emptied it. It never uses a recursive delete or a glob, because a glob
## took whatever else someone had put in code/ or scripts/. scripts/ is from an
## install before the wrappers were retired. The staging name goes too, since an
## interrupted install leaves it behind. Everything runs in one privileged
## shell, because a system tree that only root can list is also one that only
## root can empty.
fRemoveLaidDown(){   ## fRemoveLaidDown DEST
	local dest="$1"
	# shellcheck disable=SC2016  ## the positional parameters are the inner shell's
	${asroot} sh -c '
		cd -- "$1" 2>/dev/null || exit 0
		shift
		rm -f "$@" 2>/dev/null
		rmdir code scripts man completions 2>/dev/null
		exit 0
	' sh "${dest}" .shcl.new \
		code/lib.rs code/shcl.go code/shcl.py code/shcl.h code/shcl.hpp \
		scripts/shcl.bash scripts/shcl.ps1 \
		man/shcl.1 \
		completions/shcl.bash completions/_shcl
}

## The uninstall reverses what the install lays down, and nothing else. It
## removes the symlinks, the binary, and the payload files, then each directory
## if it's empty. It never deletes recursively, since the user may have pointed
## a path elsewhere.
if (( uninstall )); then
	## When there's nothing of an install at this target, say so rather than
	## "removed". The usual case is a system install from before user became
	## the default.
	ours=0
	[[ -e "${dest}" ]] && ours=1
	[[ -L "${link}" && "$(readlink -- "${link}")" == "${dest}/"* ]] && ours=1
	[[ -L "${manlink}" && "$(readlink -- "${manlink}")" == "${dest}/"* ]] && ours=1
	if (( ! ours )); then
		printf 'nothing to remove: no shcl install under %s\n' "${dest}"
		if [[ "${target}" == user && -e /opt/shcl ]]; then
			echo "a system install is in /opt/shcl; --target=system removes that one"
		fi
		echo
		exit 0
	fi
	printf 'removing shcl: %s, %s and %s\n' "${dest}" "${link}" "${manlink}"
	if (( ! assume_yes )); then
		reply=""
		if ! read -r -p "Proceed? [y/N] " reply 2>/dev/null </dev/tty; then
			fDie "no terminal to confirm on - pass --yes"
		fi
		case "${reply}" in y|Y|yes|Yes|YES) ;; *) printf 'aborted\n\n'; exit 1 ;; esac
	fi
	## Only remove our own links. A bin/shcl or man1/shcl.1 that isn't a symlink
	## into dest was put there by hand or by a package, and removing it would
	## break that install.
	[[ -L "${link}" && "$(readlink -- "${link}")" == "${dest}/"* ]] && ${asroot} rm -f "${link}"
	[[ -L "${manlink}" && "$(readlink -- "${manlink}")" == "${dest}/"* ]] && ${asroot} rm -f "${manlink}"
	${asroot} rm -f "${dest}/shcl"
	fRemoveLaidDown "${dest}"
	## Only an empty dir goes, and the output says so when it doesn't. The dir
	## can have files that this installer never put there, such as a package's
	## or someone's own, and "removed" was wrong for them. install.ps1 says the
	## same.
	if [[ -d "${dest}" ]]; then
		if ${asroot} rmdir "${dest}" 2>/dev/null; then
			echo "removed"
		else
			echo "removed what this installer laid down"
			printf "left %s in place, since it has files this installer didn't put there\n" "${dest}"
		fi
	else
		echo "removed"
	fi
	echo
	exit 0
fi

## Never install over a real file. A bin/shcl that isn't a symlink is a
## hand-placed install from the DIY route, and replacing it would throw that
## work away. It's checked before any download, so the refusal costs nothing.
## fLinkOwner says what's at the bin path: nothing, our own link, a real file,
## or a link somewhere else. A link to a cargo-built or hand-built copy is as
## much a working install as a real file, and both used to be replaced without
## a word. The uninstall already declines to remove a link that isn't ours.
fLinkOwner(){   ## fLinkOwner LINK DEST
	local link="$1" dest="$2" tgt
	if [[ -L "${link}" ]]; then
		tgt="$(readlink -- "${link}")"
		if [[ "${tgt}" == "${dest}/"* ]]; then printf 'ours\n'; else printf 'elsewhere %s\n' "${tgt}"; fi
	elif [[ -e "${link}" ]]; then
		printf 'file\n'
	else
		printf 'free\n'
	fi
}
owner="$(fLinkOwner "${link}" "${dest}")"
case "${owner}" in
	free|ours) ;;
	file) fDie "${link} exists and isn't a symlink - move it aside first, then re-run" ;;
	*)    fDie "${link} is a symlink to ${owner#elsewhere } - move it aside first, then re-run" ;;
esac

## Picks the tag out of a /releases listing. The highest version wins, never the
## newest by date. GitHub's /releases/latest is ordered by date, so a patch
## back-ported to an older line after a newer release was published would be
## handed out as "stable". The list endpoint has the same problem, which is why
## both channels sort here.
## A draft doesn't have any published assets, so neither channel can install
## one, and stable also drops pre-releases. tag_name, draft, and prerelease come
## in that order within one release object, so the flags that follow a tag
## belong to it. sort -V with the first '-' mapped to '~' ranks a pre-release
## below its own final, so v2.0.0-rc1 < v2.0.0, and the '~' is mapped back
## afterwards.
## The fields are read in the order the API emits them, so a whole release on
## one line has to be split first. A compact response used to yield no tag at
## all, and the run said no release was published.
## Only vX.Y.Z tags count, with an optional -suffix, as in install.ps1. A tag
## such as `vnext` sorts above every version under sort -V, and `v2.0.0x`
## would have passed an unanchored match. Stable falls back to the newest
## pre-release when there isn't any full release, so a first beta still
## installs by default.
fPickTag(){
	local channel="$1" json="$2" tags pick
	tags="$(awk '
		{ buf = buf $0 "\n" }
		END {
			gsub(/"(tag_name|draft|prerelease)":/, "\n&", buf)
			n = split(buf, line, "\n")
			for (i = 1; i <= n; i++) {
				s = line[i]
				if (s ~ /^"tag_name":/)               { t = s; sub(/^"tag_name": *"/, "", t); sub(/".*/, "", t); if (t !~ /^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/) t = "" }
				else if (s ~ /^"draft": *true/)       { t = "" }
				else if (s ~ /^"prerelease": *true/)  { if (t != "") print "pre " t; t = "" }
				else if (s ~ /^"prerelease": *false/) { if (t != "") print "full " t; t = "" }
			}
		}
	' "${json}")"
	[[ "${channel}" == stable ]] && pick="$(grep '^full ' <<<"${tags}" || true)"
	[[ -n "${pick:-}" ]] || pick="${tags}"
	cut -d' ' -f2 <<<"${pick}" | sed 's/-/~/' | sort -V | tail -n1 | sed 's/~/-/'
}

api="https://api.github.com/repos/${REPO}/releases?per_page=100"
## fRmTmp removes the one folder this script made, and nothing else. It's the
## shared safe removal guard cut down to that, in Bash 3.2 and without GNU
## realpath or rm. `..` is refused as a whole path part only, since a TMPDIR
## named `sp..x` is a name.
tmp="$(mktemp -d)" || fDie "couldn't make a temp folder"
tmp="$(CDPATH='' cd -P -- "${tmp}" && pwd -P)" || fDie "couldn't make a temp folder"
tmpParent="${tmp%/*}"
fRmTmp(){
	local p="${1:-}" oneFs=''
	case "${p}" in
		''|..|../*|*/..|*/../*|*//*|*"
"*) printf 'safe-rm: refused, bad path: "%s"\n' "${p}" >&2; return 1 ;;
	esac
	if [[ -z "${tmpParent}" || "${p}" != "${tmpParent}"/?* || "${p#"${tmpParent}"/}" == */* ]]; then
		printf 'safe-rm: refused, not the folder this made: %s\n' "${p}" >&2; return 1
	fi
	if [[ -L "${p}" || ! -d "${p}" ]]; then printf 'safe-rm: refused, a link or not there: %s\n' "${p}" >&2; return 1; fi
	if [[ "$(CDPATH='' cd -P -- "${p}" 2>/dev/null && pwd -P)" != "${p}" ]]; then
		printf 'safe-rm: refused, goes through a link: %s\n' "${p}" >&2; return 1
	fi
	if rm --version >/dev/null 2>&1; then oneFs=--one-file-system; else case "$(uname -s)" in Darwin|*BSD) oneFs=-x ;; esac; fi
	rm -rf ${oneFs} -- "${p}"
}
trap 'fRmTmp "${tmp}"' EXIT
## A 403 from an unauthenticated request is the API's rate limit, and it's
## common behind a shared address. "none published yet, or network down" sent
## people looking in the wrong place. GITHUB_TOKEN is used when it's set.
fApiFailure(){   ## fApiFailure STATUS RELEASE
	case "$1" in
		403|429) printf "GitHub's API refused the request because of its rate limit. Wait, or set GITHUB_TOKEN to a token with public read access and re-run\n" ;;
		401)     printf 'GitHub rejected the credentials in GITHUB_TOKEN - unset it, or replace it with one that has public read access\n' ;;
		*)       printf "can't fetch the %s release (none published yet, or network down)\n" "$2" ;;
	esac
}
fFetchApi "${api}" "${tmp}/rel.json" || fDie "$(fApiFailure "$(fApiStatus "${api}")" "${release}")"
## Every grep below may match nothing when there's no release, no such asset,
## or a release cut before the drop-in payload existed. Under pipefail that's a
## failed substitution, which would end the script here instead of at the check
## that reports it, so each one swallows its own status.
tag="$(fPickTag "${release}" "${tmp}/rel.json")"
[[ -n "${tag}" && "${tag}" != null ]] || fDie "no ${release} release found"
version="${tag#v}"
channel="${release}"
[[ "${release}" == stable && "${tag}" == *-* ]] && channel="stable, but no full release yet, so the newest pre-release"

## Prints the version the installed binary reports, or nothing when it doesn't
## run. The binary itself is asked, so an install from before this check counts
## too.
fInstalledVersion(){   ## fInstalledVersion BIN
	local out
	out="$("$1" --version 2>/dev/null </dev/null | head -n1 || true)"
	[[ "${out}" =~ ^shcl\ v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
	return 0
}
## Is A older than B? It uses the same order that fPickTag ranks tags in.
fIsOlder(){   ## fIsOlder A B
	[[ "$1" != "$2" ]] || return 1
	[[ "$(printf '%s\n%s\n' "$1" "$2" | sed 's/-/~/' | sort -V | head -n1 | sed 's/~/-/')" == "$1" ]]
}

## State the plan. Abort is the default when there's no tty to confirm on.
## A plain run after `--release dev` goes back to the stable release, and the
## plan used to show that as an ordinary update.
existing="new install"
installed=""
older=0
if [[ -e "${dest}/shcl" ]]; then
	existing="updates the existing install"
	installed="$(fInstalledVersion "${dest}/shcl")"
	if [[ -n "${installed}" ]] && fIsOlder "${version}" "${installed}"; then
		older=1
		existing="replaces the newer ${installed} with an older release"
	fi
fi
printf 'shcl %s (%s, %s-%s) -> %s (%s)\n' "${version}" "${channel}" "${osname}" "${arch}" "${dest}" "${existing}"
printf '  from     https://github.com/%s/releases/tag/%s\n' "${REPO}" "${tag}"
printf '  binary   %s/shcl (symlink %s)\n' "${dest}" "${link}"
printf '  drop-ins %s/code/\n' "${dest}"
[[ -d "${dest}/scripts" ]] && printf '  removes  the retired wrappers in %s/scripts/\n' "${dest}"
printf '  man page %s (symlink %s)\n' "${dest}/man/shcl.1" "${manlink}"
printf '  compl.   %s/completions/ (enable by hand, as the note at the end says)\n' "${dest}"
[[ -n "${asroot}" ]] && printf '  uses sudo for %s and %s\n' "${dest}" "${link}"
(( older )) && [[ "${release}" == stable ]] && printf '  note     to keep %s, re-run with --release dev\n' "${installed}"
if (( ! assume_yes )); then
	## Ask on the terminal, and treat "can't ask" as an abort. Testing /dev/tty
	## for readability isn't the same check, because it passes in plenty of
	## unattended runs where the read then dies on a raw shell error.
	reply=""
	if ! read -r -p "Proceed? [y/N] " reply 2>/dev/null </dev/tty; then
		fDie "no terminal to confirm on - pass --yes"
	fi
	case "${reply}" in y|Y|yes|Yes|YES) ;; *) printf 'aborted\n\n'; exit 1 ;; esac
fi

## Nothing is downloaded until the destinations are known to be writable. A
## read-only HOME used to get through both downloads and then fail on a raw
## mkdir error, twice. A sudo install writes as root, so this only checks a
## non-sudo install.
fNearestExisting(){   ## fNearestExisting PATH
	local p="$1"
	while [[ -n "${p}" && "${p}" != "/" && "${p}" != "." && ! -e "${p}" ]]; do
		p="$(dirname -- "${p}")"
	done
	printf '%s\n' "${p}"
}
if [[ -z "${asroot}" ]]; then
	for want in "${dest}" "$(dirname -- "${link}")" "$(dirname -- "${manlink}")"; do
		near="$(fNearestExisting "${want}")"
		[[ -d "${near}" && -w "${near}" ]] || fDie "can't write ${want}: ${near} isn't writable"
	done
fi

## Download and verify the binary. The signed sums come first, since they list
## every asset, so a release from before a platform got its binary is reported
## as that instead of as a failed download.
echo
asset="shcl-${version}-${osname}-${arch}"
base="https://github.com/${REPO}/releases/download/${tag}"
fFetch "${base}/shcl-${version}-sha256sums.txt" "${tmp}/sums" || fDie "download failed: sha256sums"
fFetch "${base}/shcl-${version}-sha256sums.txt.sig" "${tmp}/sums.sig" || fDie "download failed: sha256sums signature"

## Check the signature before trusting anything the sums file says, because a
## checksum read out of an unverified file proves nothing.
printf '%s\n' "${SIGNING_KEY}" > "${tmp}/signing.pub"
openssl dgst -sha256 -verify "${tmp}/signing.pub" -signature "${tmp}/sums.sig" "${tmp}/sums" >/dev/null 2>&1 \
	|| fDie "signature check failed on sha256sums - refusing to install"

want="$(grep " ${asset}\$" "${tmp}/sums" | cut -d' ' -f1 || true)"
[[ -n "${want}" ]] || fDie "release ${tag} doesn't have a ${osname}-${arch} binary - pick a newer release, or build from source: cargo install shcl"
echo "downloading ${asset}..."
fFetch "${base}/${asset}" "${tmp}/shcl" || fDie "download failed: ${asset}"
got="$(fSha256 "${tmp}/shcl")"
[[ -n "${want}" && "${got}" == "${want}" ]] || fDie "sha256 mismatch on ${asset}"

## Drop-in code files come from a release asset that's listed in the same
## signed sums file as the binary. They used to come from GitHub's generated
## source tarball, which doesn't have a signature or a checksum, so the one
## payload we made executable was the one nothing had verified. A release from
## before the asset existed installs the binary and says what was skipped.
chmod 755 "${tmp}/shcl"

## Run the verified binary where it is before anything is written. On an older
## glibc or on musl, the failure would otherwise show up as a raw loader error
## after the install, with the broken install left in place. Each build has its
## own floor. The x86_64 binary is linked against glibc 2.34 and needs
## libgcc_s, and the arm64 one is linked against 2.30 without libgcc_s. Exit
## 126 means the temp dir refuses to execute anything, as on a noexec mount,
## which isn't the binary's fault.
case "${osname}-${arch}" in
	linux-x86_64)  needs="glibc 2.34 or newer (Ubuntu 22.04, Debian 12, RHEL 9, or later) plus libgcc_s.so.1, and doesn't run on musl" ;;
	linux-*)       needs="glibc 2.30 or newer (Ubuntu 20.04, Debian 11, RHEL 9, or later), and doesn't run on musl" ;;
	macos-*)       needs="macOS 13 or newer" ;;
	freebsd-*)     needs="FreeBSD 14 or newer" ;;
esac
smoke_status=0
"${tmp}/shcl" --version >/dev/null 2>"${tmp}/smoke.err" || smoke_status=$?
if [[ "${smoke_status}" != 0 ]]; then
	if [[ "${smoke_status}" == 126 ]]; then
		fDie "can't execute from ${tmp} (noexec mount?) - set TMPDIR to a directory that allows execution and re-run"
	fi
	head -n1 "${tmp}/smoke.err" >&2
	fDie "the prebuilt ${osname}-${arch} binary doesn't run here, since it needs ${needs}. Install from source instead: cargo install shcl"
fi

dropins="shcl-${version}-dropins.tar.gz"
want_src="$(grep " ${dropins}\$" "${tmp}/sums" | cut -d' ' -f1 || true)"
have_dropins=0
have_docs=0
if [[ -n "${want_src}" ]]; then
	echo "downloading ${dropins}..."
	fFetch "${base}/${dropins}" "${tmp}/dropins.tgz" || fDie "download failed: ${dropins}"
	got_src="$(fSha256 "${tmp}/dropins.tgz")"
	[[ "${got_src}" == "${want_src}" ]] || fDie "sha256 mismatch on ${dropins}"
	mkdir -p "${tmp}/x" "${tmp}/code" "${tmp}/man" "${tmp}/completions"
	tar -xzf "${tmp}/dropins.tgz" -C "${tmp}/x"
	cp "${tmp}/x/source/rust/src/lib.rs" "${tmp}/x/source/go/shcl.go" "${tmp}/x/source/python/shcl.py" \
	   "${tmp}/x/source/c/shcl.h" "${tmp}/x/source/c/shcl.hpp" "${tmp}/code/"
	## A payload from before the man page and completions existed is still
	## valid, so install what it has and say what it didn't include.
	if [[ -f "${tmp}/x/source/man/shcl.1" ]]; then
		cp "${tmp}/x/source/man/shcl.1" "${tmp}/man/"
		cp "${tmp}/x/source/completions/shcl.bash" "${tmp}/x/source/completions/_shcl" "${tmp}/completions/"
		have_docs=1
	fi
	have_dropins=1
fi

## A system install has to be readable and runnable by every user, so the modes
## can't come from whoever happened to run the script. sudo keeps the caller's
## umask unless sudoers overrides it, and 077 left /opt/shcl, the launcher, and
## the man page readable by root only. `a+rX` gives the modes that the .deb and
## .rpm set, which are 755 for directories and the binary and 644 for data. It
## also repairs a tree that an earlier run wrote too tightly. A user install
## keeps the caller's umask, since it's one user's copy.
fWidenModes(){
	local run="${1}"; shift
	${run} chmod -R a+rX "$@"
}

## Prints the shallowest directory that `mkdir -p DIR` will have to create, or
## nothing when DIR exists. The bin and man1 directories are usually there
## already on a system. When they aren't, they're ours to widen too, and a
## system directory that was already there is left alone.
fTopMissing(){
	local dir="${1}" top=""
	while [[ "${dir}" != "/" && "${dir}" != "." && ! -d "${dir}" ]]; do top="${dir}"; dir="$(dirname "${dir}")"; done
	printf '%s' "${top}"
}

## Lay the payload in ${tmp} down under ${dest} and link it. The binary goes
## in through a hidden temp file and an mv in the same dir, so a running copy
## only ever sees the complete old or new file. It's a function so that the
## same steps can run on a staged payload without the downloads in front.
fLayDown(){
	local desttop linkdir mandir manowner
	man_note=""
	desttop="$(fTopMissing "${dest}")"
	linkdir="$(fTopMissing "$(dirname "${link}")")"
	${asroot} mkdir -p "${dest}" "$(dirname "${link}")"
	${asroot} cp "${tmp}/shcl" "${dest}/.shcl.new"
	${asroot} mv -f "${dest}/.shcl.new" "${dest}/shcl"
	if (( have_dropins )); then
		${asroot} mkdir -p "${dest}/code"
		${asroot} cp "${tmp}"/code/* "${dest}/code/"
	fi
	## When the install was another version, the files this release doesn't
	## include are removed by name. A newer release's drop-ins, man page, and
	## completions left beside an older binary describe the wrong format. On
	## the same version they can only have been put there by hand, so they stay.
	dropped=""
	if [[ "${installed:-}" != "${version:-}" ]]; then
		if (( ! have_dropins )) && [[ -d "${dest}/code" ]]; then
			${asroot} rm -f "${dest}/code/lib.rs" "${dest}/code/shcl.go" "${dest}/code/shcl.py" "${dest}/code/shcl.h" "${dest}/code/shcl.hpp"
			${asroot} rmdir "${dest}/code" 2>/dev/null || true
			dropped="the drop-ins"
		fi
		if (( ! have_docs )) && [[ -d "${dest}/man" || -d "${dest}/completions" ]]; then
			[[ "$(fLinkOwner "${manlink}" "${dest}")" == ours ]] && ${asroot} rm -f "${manlink}"
			${asroot} rm -f "${dest}/man/shcl.1" "${dest}/completions/shcl.bash" "${dest}/completions/_shcl"
			${asroot} rmdir "${dest}/man" "${dest}/completions" 2>/dev/null || true
			dropped="${dropped:+${dropped}, }the man page and completions"
		fi
	fi
	## The shell wrappers are retired to project/legacy/, so an update removes
	## the copies an older install left, and scripts/ once that empties it.
	${asroot} rm -f "${dest}/scripts/shcl.bash" "${dest}/scripts/shcl.ps1"
	${asroot} rmdir "${dest}/scripts" 2>/dev/null || true
	mandir=""
	if (( have_docs )); then
		mandir="$(fTopMissing "$(dirname "${manlink}")")"
		${asroot} mkdir -p "${dest}/man" "${dest}/completions" "$(dirname "${manlink}")"
		${asroot} cp "${tmp}"/man/* "${dest}/man/"
		${asroot} cp "${tmp}"/completions/* "${dest}/completions/"
		## The same rule as the bin link. A real man1/shcl.1 came from a
		## package, and a link to another copy, such as stow or a hand-built
		## install, is someone else's too. That link used to be repointed here,
		## and then the uninstall took it for ours and deleted it. Now it's left
		## alone, and the receipt says so.
		manowner="$(fLinkOwner "${manlink}" "${dest}")"
		case "${manowner}" in
			free|ours) ${asroot} ln -sfn "${dest}/man/shcl.1" "${manlink}" ;;
			file)      man_note="${manlink} isn't a symlink" ;;
			*)         man_note="${manlink} links to ${manowner#elsewhere }" ;;
		esac
	fi
	${asroot} ln -sfn "${dest}/shcl" "${link}"
	if [[ "${target}" == "system" ]]; then
		fWidenModes "${asroot}" "${desttop:-${dest}}" ${linkdir:+"${linkdir}"} ${mandir:+"${mandir}"}
	fi
}

## Is DIR on the PATH? It compares by element and ignores a trailing slash on
## either side, because the shell resolves `bin/` fine and a plain string
## compare didn't.
fOnPath(){
	local dir="${1%/}" elem
	while IFS= read -r -d: elem || [[ -n "${elem}" ]]; do
		[[ "${elem%/}" == "${dir}" ]] && return 0
	done <<<"${PATH}:"
	return 1
}

fLayDown

echo
if (( older )); then
	printf 'installed shcl %s -> %s (older than the %s it replaced)\n' "${version}" "${link}" "${installed}"
else
	printf 'installed shcl %s -> %s\n' "${version}" "${link}"
fi
[[ -n "${dropped}" ]] && printf "note: removed %s the %s install had, since this release doesn't include them\n" "${dropped}" "${installed:-earlier}"
if [[ -n "${man_note}" ]]; then
	printf "note: %s, so it was left alone and this install's man page isn't linked there\n" "${man_note}"
fi
(( have_dropins )) || printf "note: this release doesn't have a signed drop-in payload, so %s/code was skipped - take the files from the repo if you want them\n" "${dest}"
## Completions are laid down but not turned on. No one directory works for
## everyone. The bash autoload dir depends on the bash-completion version, zsh
## wants a dir on $fpath, and writing into the distro's own /usr/share would
## collide with the .deb and .rpm, which do put them in place. So print the
## lines to paste, the same way the PATH note does.
if (( have_docs )); then
	# The completion paths are for the user to paste, not for us to expand here.
	# shellcheck disable=SC2016
	printf 'completions are in %s/completions. To enable them:\n  bash: echo '\''source "%s/completions/shcl.bash"'\'' >> ~/.bashrc\n  zsh:  ln -s "%s/completions/_shcl" ~/.zfunc/_shcl   (with ~/.zfunc on your $fpath)\n' \
		"${dest}" "${dest}" "${dest}"
elif (( have_dropins )); then
	printf "note: this release doesn't include a man page or completions, which were added after it was cut\n"
fi
## Under the one-liner $0 is a /dev/fd path, or "bash" when piped, so the hint
## names the one-liner unless this is a file on disk.
rerun="bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)"
[[ -f "$0" ]] && rerun="$0"
printf 'to remove it again: %s --uninstall --target=%s\n' "${rerun}" "${target}"
## For both targets, an install that nobody can run by name looks fine to the
## version check below, so say something when the symlink dir is off the PATH.
## The man page is lost too, since man derives its search dirs from the bin
## dirs on PATH.
linkdir="$(dirname "${link}")"
if ! fOnPath "${linkdir}"; then
	# The PATH expansion is for the user to paste, not for us to expand here.
	# shellcheck disable=SC2016
	printf 'note: %s isn'\''t on your PATH, so neither shcl nor "man shcl" will be found. Add it with:\n  export PATH="%s:$PATH"\nPut that line in your shell profile to make it stick.\n' "${linkdir}" "${linkdir}"
fi
## Also say what `shcl` resolves to. The receipt below runs the link we just
## wrote, so another copy earlier on PATH used to go unseen here, and the next
## `shcl` the user typed was someone else's.
fShadowedBy(){   ## fShadowedBy LINK
	local link="$1" onpath
	onpath="$(command -v shcl 2>/dev/null || true)"
	[[ -z "${onpath}" || "${onpath}" -ef "${link}" ]] && return 1
	printf '%s\n' "${onpath}"
}
if shadow="$(fShadowedBy "${link}")"; then
	printf 'note: the shcl on your PATH is %s, which comes before the copy just installed\n' "${shadow}"
fi
"${link}" --version 2>/dev/null || "${dest}/shcl" --version
echo
