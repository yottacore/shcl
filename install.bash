#!/usr/bin/env bash
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## install.bash
##
##	Release installer for shcl (Simple Hierarchical Config Language) on Linux.
##	Downloads the latest release from GitHub, checks the sha256sums file against
##	the release signing key before trusting a checksum out of it, and lays out
##	the binary plus the drop-in source files and shell wrappers. Idempotent:
##	re-running updates an existing install in place.
##
##	Needs curl or wget, plus openssl for the signature check.
##
##	Usage (one-liner):
##		bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
##		bash <(wget -qO- https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
##	With options:
##		bash <(curl -fsSL .../install.bash) --target=system --yes
##	The piped form, `curl ... | bash -s -- OPTIONS`, works too.
##
##	Options (both --opt=VALUE and --opt VALUE work):
##		--release <stable|dev>   stable (default) = newest full release, or the
##		                         newest pre-release while there is no full one;
##		                         dev = newest release including pre-releases.
##		--target <user|system>   user (default): ~/.local/share/shcl + a symlink
##		                         at ~/.local/bin/shcl. No sudo.
##		                         system: /opt/shcl + a symlink at
##		                         /usr/local/bin/shcl (sudo if not root).
##		--yes | -y               skip the confirmation prompt.
##		--version                print this installer's version and exit.
##		--uninstall              remove what an install of the same --target
##		                         laid down (binary, symlinks, code/, scripts/,
##		                         man/, completions/), and nothing else.
##
##	Layout under the install dir:
##		shcl         the CLI binary
##		code/        drop-in single-file bindings (lib.rs, shcl.go, shcl.py,
##		             shcl.h, shcl.hpp)
##		scripts/     shell wrappers (shcl.bash, shcl.ps1)
##		man/         the man page, symlinked into the target's man1 dir
##		completions/ bash and zsh completions, enabled by hand (see the note the
##		             install prints - the .deb/.rpm put these in place for you)
##
##	macOS and the BSDs have no prebuilt binaries yet - build from source or use
##	a drop-in file (see README.md).
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

set -euo pipefail

installer_version="1.1.2"
REPO="yottacore/shcl"
release="stable"
target="user"
assume_yes=0
uninstall=0

## Release signing key. The sha256sums file is signed offline with the matching
## private key, so replacing a release asset is not enough - an attacker would
## have to forge this signature too. Baked in rather than fetched, because a key
## downloaded over the same channel as the artifact proves nothing. Rotating it
## means publishing a new installer; treat that as a breaking change.
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

## Usage text lives here, not in a sed slice of "$0": under a
## `curl | bash -s -- --help` pipe, $0 is just "bash" and sed reads the wrong
## file (or a stray one named "bash" in the cwd).
fUsage() {
	cat <<EOF
install.bash ${installer_version} - release installer for shcl on Linux

Downloads the latest release from GitHub, checks the sha256sums file against the
release signing key before trusting a checksum out of it, and lays out the binary
plus the drop-in source files and shell wrappers. Idempotent: re-running updates
an existing install in place.

Needs curl or wget, plus openssl for the signature check.

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
                           down (binary, symlinks, code/, scripts/, man/,
                           completions/), and nothing else.

Layout under the install dir:
  shcl          the CLI binary
  code/         drop-in single-file bindings (lib.rs, shcl.go, shcl.py,
                shcl.h, shcl.hpp)
  scripts/      shell wrappers (shcl.bash, shcl.ps1)
  man/          the man page, symlinked into the target's man1 dir
  completions/  bash and zsh completions, enabled by hand (see the note the
                install prints - the .deb/.rpm put these in place for you)

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

## Platform gate: prebuilt binaries exist for Linux x86_64/arm64 only.
os="$(uname -s)"
[[ "${os}" == "Linux" ]] || fDie "no prebuilt ${os} binaries yet - build from source or use a drop-in file (see README.md)"
case "$(uname -m)" in
	x86_64|amd64)  arch="x86_64" ;;
	aarch64|arm64) arch="arm64" ;;
	*) fDie "no prebuilt binary for $(uname -m)" ;;
esac

## curl or wget, whichever is present. https is pinned through redirects and
## TLS floored at 1.2, so a bounced download can't silently downgrade.
## GITHUB_TOKEN goes to the API calls alone. Every release download redirects
## to another host, and wget sends a --header on to it, so fetch sends none.
if command -v curl >/dev/null; then
	fFetch() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$2" "$1"; }
	fFetchApi() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} -o "$2" "$1"; }
	fApiStatus() { curl -fsS -o /dev/null -w '%{http_code}' --proto '=https' --tlsv1.2 ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "$1" 2>/dev/null || true; }
elif command -v wget >/dev/null; then
	## wget's --https-only covers recursive downloads only, so a redirect to
	## plain http went through. Its own record of each response names every hop,
	## and a plain-http Location refuses the file.
	fWget() { local hops rc=0; { hops="$(wget -q --https-only --secure-protocol=TLSv1_2 --server-response "$@" 2>&1 >&3 3>&-)" || rc=$?; } 3>&1; if grep -qiE '^[[:space:]]*Location:[[:space:]]*http:' <<< "${hops}"; then echo "refused a redirect to plain http" >&2; return 1; fi; return "${rc}"; }
	fFetch() { fWget -O "$2" "$1" || { rm -f -- "$2"; return 1; }; }
	fFetchApi() { fWget ${GITHUB_TOKEN:+--header="Authorization: Bearer ${GITHUB_TOKEN}"} -O "$2" "$1" || { rm -f -- "$2"; return 1; }; }
	fApiStatus() { wget -q --https-only --secure-protocol=TLSv1_2 ${GITHUB_TOKEN:+--header="Authorization: Bearer ${GITHUB_TOKEN}"} --server-response -O /dev/null "$1" 2>&1 | awk '/^  HTTP/ { code = $2 } END { print code }'; }
else
	fDie "need curl or wget"
fi
## openssl is a hard requirement, same class as curl/wget: without it the
## release signature cannot be checked, and installing unverified is not on
## offer. Verify by hand and use the DIY path if the box genuinely lacks it.
command -v openssl >/dev/null || fDie "need openssl to verify the release signature (see README.md for a manual install)"

## Destinations.
## The man dir is the one man already reads for that target, so `man shcl` works
## without a MANPATH edit - the same trick the binary symlink plays on PATH.
if [[ "${target}" == "system" ]]; then
	dest="/opt/shcl"
	link="/usr/local/bin/shcl"
	manlink="/usr/local/share/man/man1/shcl.1"
	asroot=""
	## Check sudo is actually here before planning to use it: choosing it blind
	## fails at the first write, after both downloads and the confirmation.
	if [[ "$(id -u)" != 0 ]]; then
		command -v sudo >/dev/null || fDie "a system install needs root: run as root, install sudo, or use --target=user"
		asroot="sudo"
	fi
else
	dest="${HOME}/.local/share/shcl"
	link="${HOME}/.local/bin/shcl"
	manlink="${HOME}/.local/share/man/man1/shcl.1"
	asroot=""
fi

## The files the install writes, by name, then each payload directory if that
## emptied it - never a recursive delete, and never a glob. A glob took whatever
## else someone had put in code/ or scripts/. The staging name goes too, since
## an interrupted install leaves it behind. Everything runs in one privileged
## shell, because a system tree only root can list is also one only root can
## empty.
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

## Uninstall: the reverse of what the install lays down, and nothing else - the
## symlinks, the binary, and the payload files, then each directory if it is
## empty. Never a recursive delete of a path the user may have pointed elsewhere.
if (( uninstall )); then
	## Nothing of an install at this target: say so, rather than "removed". A
	## system install from before user became the default is the usual case.
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
	## Only ours: a bin/shcl or man1/shcl.1 that is not a symlink into dest was
	## put there by hand or by a package, and removing it would break that install.
	[[ -L "${link}" && "$(readlink -- "${link}")" == "${dest}/"* ]] && ${asroot} rm -f "${link}"
	[[ -L "${manlink}" && "$(readlink -- "${manlink}")" == "${dest}/"* ]] && ${asroot} rm -f "${manlink}"
	${asroot} rm -f "${dest}/shcl"
	fRemoveLaidDown "${dest}"
	## Only an empty dir goes, and say so when it does not: the dir can hold
	## files this installer never put there (a package's, or someone's own), and
	## reporting "removed" over the top of them was a lie. Matches what the
	## PowerShell installer already said.
	if [[ -d "${dest}" ]]; then
		if ${asroot} rmdir "${dest}" 2>/dev/null; then
			echo "removed"
		else
			echo "removed what this installer laid down"
			printf 'left %s in place: it holds files this installer did not put there\n' "${dest}"
		fi
	else
		echo "removed"
	fi
	echo
	exit 0
fi

## Never over a real file: a bin/shcl that is not a symlink is a hand-placed
## install (the DIY route), and replacing it would throw that work away. Checked
## before any download so the refusal costs nothing.
## What is at the bin path: nothing, our own link, a real file, or a link
## somewhere else. A real file is a hand-placed install (the DIY route) and a
## link to a cargo-built or hand-built copy is as much a working install as
## that; either used to be replaced with nothing said. The uninstall already
## declines to remove a link that is not ours.
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
	file) fDie "${link} exists and is not a symlink - move it aside first, then re-run" ;;
	*)    fDie "${link} is a symlink to ${owner#elsewhere } - move it aside first, then re-run" ;;
esac

## Pick the tag out of a /releases listing: highest version wins, never newest
## by date. GitHub's /releases/latest is date-ordered, so a patch back-ported to
## an older line after a newer one shipped would be handed out as "stable" - the
## same hazard the list endpoint has, and the reason both channels sort here.
## A draft has no published assets, so neither channel can install one; stable
## drops pre-releases on top of that. tag_name, draft and prerelease arrive in
## that order within one release object, so the flags that follow a tag belong
## to it. sort -V with the first '-' mapped to '~' ranks a pre-release below its
## own final (v2.0.0-rc1 < v2.0.0); mapped back afterwards.
## The three fields are read in the order the API emits them, so a whole release
## on one line has to be split first: a compact response used to yield no tag at
## all, and the run said no release was published.
## Only vX.Y.Z tags count, as in install.ps1. A tag such as `vnext` sorts above
## every version under sort -V. Stable falls back to the newest pre-release when
## there is no full release at all, so a first beta still installs by default.
fPickTag(){
	local channel="$1" json="$2" tags pick
	tags="$(awk '
		{ buf = buf $0 "\n" }
		END {
			gsub(/"(tag_name|draft|prerelease)":/, "\n&", buf)
			n = split(buf, line, "\n")
			for (i = 1; i <= n; i++) {
				s = line[i]
				if (s ~ /^"tag_name":/)               { t = s; sub(/^"tag_name": *"/, "", t); sub(/".*/, "", t); if (t !~ /^v[0-9]+\.[0-9]+\.[0-9]+/) t = "" }
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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
## A 403 from an unauthenticated request is the API's rate limit, and behind a
## shared address it is common - "none published yet, or network down" sent
## people looking in the wrong place. GITHUB_TOKEN is used when it is set.
fApiFailure(){   ## fApiFailure STATUS RELEASE
	case "$1" in
		403|429) printf "GitHub's API refused the request (rate limit). Wait, or set GITHUB_TOKEN to a token with public read access and re-run\n" ;;
		401)     printf 'GitHub rejected the credentials in GITHUB_TOKEN - unset it, or replace it with one that has public read access\n' ;;
		*)       printf 'cannot fetch the %s release (none published yet, or network down)\n' "$2" ;;
	esac
}
fFetchApi "${api}" "${tmp}/rel.json" || fDie "$(fApiFailure "$(fApiStatus "${api}")" "${release}")"
## Every grep below may legitimately match nothing (no release, no such asset,
## a release cut before the drop-in payload existed). Under pipefail that is a
## failed substitution, which would end the script here instead of at the check
## that reports it - so each one swallows its own status.
tag="$(fPickTag "${release}" "${tmp}/rel.json")"
[[ -n "${tag}" && "${tag}" != null ]] || fDie "no ${release} release found"
version="${tag#v}"
channel="${release}"
[[ "${release}" == stable && "${tag}" == *-* ]] && channel="stable, but no full release yet, so the newest pre-release"

## State the plan; abort is the default when there is no tty to confirm on.
existing="new install"
[[ -e "${dest}/shcl" ]] && existing="updates the existing install"
printf 'shcl %s (%s, linux-%s) -> %s (%s)\n' "${version}" "${channel}" "${arch}" "${dest}" "${existing}"
printf '  from     https://github.com/%s/releases/tag/%s\n' "${REPO}" "${tag}"
printf '  binary   %s/shcl (symlink %s)\n' "${dest}" "${link}"
printf '  drop-ins %s/code/, wrappers %s/scripts/\n' "${dest}" "${dest}"
printf '  man page %s (symlink %s)\n' "${dest}/man/shcl.1" "${manlink}"
printf '  compl.   %s/completions/ (enable by hand - see the note at the end)\n' "${dest}"
[[ -n "${asroot}" ]] && printf '  uses sudo for %s and %s\n' "${dest}" "${link}"
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

## Nothing is downloaded before the destinations are known to be writable: a
## read-only HOME used to get through both downloads and then fail on a raw
## mkdir error, twice. A sudo install writes as root, so the question is only
## about what this shell can reach.
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
		[[ -d "${near}" && -w "${near}" ]] || fDie "cannot write ${want}: ${near} is not writable"
	done
fi

## Download and verify the binary.
echo
asset="shcl-${version}-linux-${arch}"
base="https://github.com/${REPO}/releases/download/${tag}"
echo "downloading ${asset}..."
fFetch "${base}/${asset}" "${tmp}/shcl" || fDie "download failed: ${asset}"
fFetch "${base}/shcl-${version}-sha256sums.txt" "${tmp}/sums" || fDie "download failed: sha256sums"
fFetch "${base}/shcl-${version}-sha256sums.txt.sig" "${tmp}/sums.sig" || fDie "download failed: sha256sums signature"

## Check the signature before trusting anything the sums file says. Order is the
## whole point: a checksum read out of an unverified file proves nothing.
printf '%s\n' "${SIGNING_KEY}" > "${tmp}/signing.pub"
openssl dgst -sha256 -verify "${tmp}/signing.pub" -signature "${tmp}/sums.sig" "${tmp}/sums" >/dev/null 2>&1 \
	|| fDie "signature check failed on sha256sums - refusing to install"

want="$(grep " ${asset}\$" "${tmp}/sums" | cut -d' ' -f1 || true)"
got="$(sha256sum "${tmp}/shcl" | cut -d' ' -f1)"
[[ -n "${want}" && "${got}" == "${want}" ]] || fDie "sha256 mismatch on ${asset}"

## Drop-in code files and wrappers come from a release asset covered by the same
## signed sums file as the binary. They used to come from GitHub's generated
## source tarball, which has neither a signature nor a checksum - so the one
## payload we made executable was the one nothing had verified. Releases before
## the asset existed simply install the binary and say what was skipped.
chmod 755 "${tmp}/shcl"

## Run the verified binary where it sits before anything is written: on an
## older glibc (or musl) the failure would otherwise surface as a raw loader
## error after the install, with the broken install left in place. The floor
## differs per build: the x86_64 binary is linked against glibc 2.34 and needs
## libgcc_s, the arm64 one against 2.30 with no libgcc_s. Exit 126 is the temp
## dir refusing to execute at all (a noexec mount), which is not the binary's
## fault.
case "${arch}" in
	x86_64) needs="glibc 2.34 or newer (Ubuntu 22.04, Debian 12, RHEL 9, or later) plus libgcc_s.so.1" ;;
	*)      needs="glibc 2.30 or newer (Ubuntu 20.04, Debian 11, RHEL 9, or later)" ;;
esac
smoke_status=0
"${tmp}/shcl" --version >/dev/null 2>"${tmp}/smoke.err" || smoke_status=$?
if [[ "${smoke_status}" != 0 ]]; then
	if [[ "${smoke_status}" == 126 ]]; then
		fDie "cannot execute from ${tmp} (noexec mount?) - set TMPDIR to a directory that allows execution and re-run"
	fi
	head -n1 "${tmp}/smoke.err" >&2
	fDie "the prebuilt linux-${arch} binary does not run here: it needs ${needs} and does not run on musl. Install from source instead: cargo install shcl"
fi

dropins="shcl-${version}-dropins.tar.gz"
want_src="$(grep " ${dropins}\$" "${tmp}/sums" | cut -d' ' -f1 || true)"
have_dropins=0
have_docs=0
if [[ -n "${want_src}" ]]; then
	echo "downloading ${dropins}..."
	fFetch "${base}/${dropins}" "${tmp}/dropins.tgz" || fDie "download failed: ${dropins}"
	got_src="$(sha256sum "${tmp}/dropins.tgz" | cut -d' ' -f1)"
	[[ "${got_src}" == "${want_src}" ]] || fDie "sha256 mismatch on ${dropins}"
	mkdir -p "${tmp}/x" "${tmp}/code" "${tmp}/scripts" "${tmp}/man" "${tmp}/completions"
	tar -xzf "${tmp}/dropins.tgz" -C "${tmp}/x"
	cp "${tmp}/x/source/rust/src/lib.rs" "${tmp}/x/source/go/shcl.go" "${tmp}/x/source/python/shcl.py" \
	   "${tmp}/x/source/c/shcl.h" "${tmp}/x/source/c/shcl.hpp" "${tmp}/code/"
	cp "${tmp}/x/source/bash/shcl.bash" "${tmp}/x/source/powershell/shcl.ps1" "${tmp}/scripts/"
	## A payload from before the man page and completions existed is still a
	## valid payload - install what it has and say what it did not include.
	if [[ -f "${tmp}/x/source/man/shcl.1" ]]; then
		cp "${tmp}/x/source/man/shcl.1" "${tmp}/man/"
		cp "${tmp}/x/source/completions/shcl.bash" "${tmp}/x/source/completions/_shcl" "${tmp}/completions/"
		have_docs=1
	fi
	chmod 755 "${tmp}/scripts/shcl.bash"
	have_dropins=1
fi

## A system install has to be readable and runnable by every user, and the modes
## cannot come from whoever happened to run the script: sudo keeps the caller's
## umask unless sudoers overrides it, and 077 left /opt/shcl, the launcher and
## the man page root-only. `a+rX` gives what the .deb and .rpm set - directories
## and the binary 755, data 644 - and repairs a tree an earlier run wrote too
## tightly. A user install keeps the caller's umask: it is one user's copy.
fWidenModes(){
	local run="${1}"; shift
	${run} chmod -R a+rX "$@"
}

## The shallowest directory `mkdir -p DIR` will have to create, or nothing
## when DIR exists. The bin and man1 directories are usually there already
## on a system; when they are not, they are ours to widen too, and a system
## directory that was already there is left alone.
fTopMissing(){
	local dir="${1}" top=""
	while [[ "${dir}" != "/" && "${dir}" != "." && ! -d "${dir}" ]]; do top="${dir}"; dir="$(dirname "${dir}")"; done
	printf '%s' "${top}"
}

## Lay the payload in ${tmp} down under ${dest} and link it. The binary goes
## in via a hidden temp + mv in the same dir, so a running copy only ever sees
## the complete old or new file. A function so the same steps run on a staged
## payload without the downloads in front of them.
fLayDown(){
	local desttop linkdir mandir manowner
	man_note=""
	desttop="$(fTopMissing "${dest}")"
	linkdir="$(fTopMissing "$(dirname "${link}")")"
	${asroot} mkdir -p "${dest}" "$(dirname "${link}")"
	${asroot} cp "${tmp}/shcl" "${dest}/.shcl.new"
	${asroot} mv -f "${dest}/.shcl.new" "${dest}/shcl"
	if (( have_dropins )); then
		${asroot} mkdir -p "${dest}/code" "${dest}/scripts"
		${asroot} cp "${tmp}"/code/* "${dest}/code/"
		${asroot} cp "${tmp}"/scripts/* "${dest}/scripts/"
	fi
	mandir=""
	if (( have_docs )); then
		mandir="$(fTopMissing "$(dirname "${manlink}")")"
		${asroot} mkdir -p "${dest}/man" "${dest}/completions" "$(dirname "${manlink}")"
		${asroot} cp "${tmp}"/man/* "${dest}/man/"
		${asroot} cp "${tmp}"/completions/* "${dest}/completions/"
		## The bin link's rule: a real man1/shcl.1 came from a package, and a
		## link to another copy (stow, a hand-built install) is as much someone
		## else's. That link used to be repointed here, after which the
		## uninstall took it for ours and deleted it. Left alone, and said so.
		manowner="$(fLinkOwner "${manlink}" "${dest}")"
		case "${manowner}" in
			free|ours) ${asroot} ln -sfn "${dest}/man/shcl.1" "${manlink}" ;;
			file)      man_note="${manlink} is not a symlink" ;;
			*)         man_note="${manlink} links to ${manowner#elsewhere }" ;;
		esac
	fi
	${asroot} ln -sfn "${dest}/shcl" "${link}"
	if [[ "${target}" == "system" ]]; then
		fWidenModes "${asroot}" "${desttop:-${dest}}" ${linkdir:+"${linkdir}"} ${mandir:+"${mandir}"}
	fi
}

## Is DIR on the PATH? By element, with a trailing slash ignored on either
## side: the shell resolves `bin/` fine, and a plain string compare did not.
fOnPath(){
	local dir="${1%/}" elem
	while IFS= read -r -d: elem || [[ -n "${elem}" ]]; do
		[[ "${elem%/}" == "${dir}" ]] && return 0
	done <<<"${PATH}:"
	return 1
}

fLayDown

echo
printf 'installed shcl %s -> %s\n' "${version}" "${link}"
if [[ -n "${man_note}" ]]; then
	printf 'note: %s - left alone, and this install'\''s man page not linked there\n' "${man_note}"
fi
(( have_dropins )) || printf 'note: this release ships no signed drop-in payload, so %s/code and %s/scripts were skipped - take them from the repo if you want them\n' "${dest}" "${dest}"
## Completions are laid down but not wired in. There is no one directory that
## works: the bash autoload dir varies by bash-completion version, zsh wants a
## dir on $fpath, and writing into the distro's own /usr/share would collide
## with the .deb/.rpm - which do put these in place properly. So: print the
## lines to paste, the same way the PATH note does.
if (( have_docs )); then
	# The completion paths are for the user to paste, not for us to expand here.
	# shellcheck disable=SC2016
	printf 'completions are at %s/completions - to enable them:\n  bash: echo '\''source "%s/completions/shcl.bash"'\'' >> ~/.bashrc\n  zsh:  ln -s "%s/completions/_shcl" ~/.zfunc/_shcl   (with ~/.zfunc on your $fpath)\n' \
		"${dest}" "${dest}" "${dest}"
elif (( have_dropins )); then
	printf 'note: this release ships no man page or completions - they arrived after it was cut\n'
fi
## Under the one-liner $0 is a /dev/fd path (or "bash" when piped), so the hint
## names the one-liner unless this really is a file on disk.
rerun="bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)"
[[ -f "$0" ]] && rerun="$0"
printf 'to remove it again: %s --uninstall --target=%s\n' "${rerun}" "${target}"
## Both targets: an install nobody can invoke by name looks fine to the version
## check below, so say something when the symlink dir is off the PATH. It costs
## the man page too - man derives its search dirs from the bin dirs on PATH.
linkdir="$(dirname "${link}")"
if ! fOnPath "${linkdir}"; then
	# The PATH expansion is for the user to paste, not for us to expand here.
	# shellcheck disable=SC2016
	printf 'note: %s is not on your PATH, so neither shcl nor "man shcl" will be found - add it with:\n  export PATH="%s:$PATH"\n(put that line in your shell profile to make it stick)\n' "${linkdir}" "${linkdir}"
fi
## And what `shcl` actually resolves to: the receipt below runs the link we just
## wrote, so another copy earlier on PATH used to be invisible here and the next
## `shcl` the user typed was someone else's.
fShadowedBy(){   ## fShadowedBy LINK
	local link="$1" onpath
	onpath="$(command -v shcl 2>/dev/null || true)"
	[[ -z "${onpath}" || "${onpath}" -ef "${link}" ]] && return 1
	printf '%s\n' "${onpath}"
}
if shadow="$(fShadowedBy "${link}")"; then
	printf 'note: shcl on your PATH is %s, not the copy just installed - it comes first on PATH\n' "${shadow}"
fi
"${link}" --version 2>/dev/null || "${dest}/shcl" --version
echo
