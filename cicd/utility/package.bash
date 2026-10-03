#!/usr/bin/env bash

##	Purpose:
##		Build installable packages from the versioned release artifacts:
##		.deb + .rpm via nfpm (x86_64 and arm64, whichever binaries exist) and an
##		NSIS setup .exe per Windows binary. Payload mirrors install.bash: binary,
##		code/ drop-ins (lib.rs, shcl.go, shcl.py, shcl.h, shcl.hpp), scripts/
##		wrappers (shcl.bash, shcl.ps1), and for the Linux packages only the man/
##		page and completions/ for bash and zsh. Packages go beside the raw
##		binaries in the artifact dir, named into the same shcl-<version>-* family
##		so the engine's sha256sums rewrite picks them up. Two builds of one
##		commit give the same bytes (mtimes and build metadata are pinned to the
##		commit time through SOURCE_DATE_EPOCH).
##	Syntax:
##		package.bash ROOT ART_DIR VERSION
##	Exit: 0 = all buildable packages built (a missing tool warns and skips its
##	formats), nonzero = a package build failed.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

root="${1:?usage: package.bash ROOT ART_DIR VERSION}"
artDir="${2:?usage: package.bash ROOT ART_DIR VERSION}"
ver="${3:?usage: package.bash ROOT ART_DIR VERSION}"
meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fEcho(){ echo "[ $* ]"; }
fWarn(){ fEcho "WARNING: $*"; }
fDie(){ echo "package: $*" >&2; exit 1; }

##	NSIS wants four dot-separated integers where the project version can have a
##	prerelease tail. Same rule the Rust build script uses for the executable's
##	own version field: the digit-only pieces in order, padded to four.
fVersionQuad(){
	local -a parts=() quad=()
	local piece
	IFS='.+-' read -r -a parts <<<"${1}"
	for piece in "${parts[@]}"; do
		[[ "${piece}" =~ ^[0-9]+$ ]] && quad+=("${piece}")
	done
	while ((${#quad[@]} < 4)); do quad+=("0"); done
	printf '%s.%s.%s.%s\n' "${quad[0]}" "${quad[1]}" "${quad[2]}" "${quad[3]}"
}

## Stage the shared payload (same file set install.bash pulls from a tag).
payload="$(mktemp -d)"
trap 'rm -rf "${payload}"' EXIT
mkdir -p "${payload}/code" "${payload}/scripts"
chmod 755 "${payload}" "${payload}/code" "${payload}/scripts"   ## tree type copies dir modes into the package
cp "${root}/source/rust/src/lib.rs" "${root}/source/go/shcl.go" "${root}/source/python/shcl.py" \
   "${root}/source/c/shcl.h" "${root}/source/c/shcl.hpp" "${payload}/code/"
cp "${root}/source/bash/shcl.bash" "${root}/source/powershell/shcl.ps1" "${payload}/scripts/"
chmod 644 "${payload}"/code/* "${payload}/scripts/shcl.ps1"
chmod 755 "${payload}/scripts/shcl.bash"

## Every package records the mtime of what it holds, so a payload staged a
## minute later gives different bytes for the same commit. Pin the staged tree
## and the binaries to the commit's time; nfpm reads the same value for the
## package's own build date. The engine exports it for the drop-ins tarball too.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${root}" log -1 --format=%ct)}"
fPinMtime(){ touch -d "@${SOURCE_DATE_EPOCH}" "$@"; }
find "${payload}" -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +

##	The profiler is a feature-gated dependency chain under a license `deny.toml`
##	allows on exactly the basis that it never ships. Nothing enforced that
##	beyond the release command not including the flag, so it is checked against
##	the file rather than the command: every binary in the artifact directory,
##	and the source payload beside them, must have no trace of the three crates.
##	The names are assembled so this test does not match itself.
fCheckNoProfiler(){
	local f hit
	for f in "${artDir}"/shcl-* "${payload}"/code/*; do
		[[ -f "${f}" ]] || continue
		case "${f}" in *.sha256|*sha256sums*) continue ;; esac
		hit="$(LC_ALL=C grep -l -a -e "ppr""of" -e "inf""erno" -e "quick""-xml" "${f}" || true)"
		[[ -z "${hit}" ]] || fDie "$(basename "${f}"): has the profiler dependency, which must never ship"
	done
}
fCheckNoProfiler

built=0

## What the packages require for libgcc_s when the binary links it. rpm's
## generator names the soname rather than a package, since the package name
## differs by distro: Fedora and RHEL call it libgcc, openSUSE libgcc_s1, and
## a plain `libgcc` refused to install on openSUSE. Both provide the soname.
debGccDep='libgcc-s1'
rpmGccDep='libgcc_s.so.1()(64bit)'

##	The deb's Depends and the rpm's Requires against the binary they contain:
##	the glibc floor, libgcc when linked, and the Debian doc files.
fCheckDeps(){
	local stem="$1" glibc="$2" needGcc="$3" deps
	deps="$(dpkg-deb -f "${stem}.deb" Depends)"
	[[ "${deps}" == *"libc6 (>= ${glibc})"* ]] || fDie "$(basename "${stem}").deb: Depends ${deps@Q} lacks libc6 (>= ${glibc})"
	if [[ -n "${needGcc}" && "${deps}" != *"${debGccDep}"* ]]; then fDie "$(basename "${stem}").deb: Depends ${deps@Q} lacks ${debGccDep}"; fi
	## Into a variable first: grep -q quitting early would kill the tar behind
	## dpkg-deb with SIGPIPE and fail the pipeline for the wrong reason.
	local listing; listing="$(dpkg-deb -c "${stem}.deb")"
	grep -q ' ./usr/share/doc/shcl/copyright$' <<<"${listing}" || fDie "$(basename "${stem}").deb: no copyright file"
	grep -q ' ./usr/share/doc/shcl/changelog.gz$' <<<"${listing}" || fDie "$(basename "${stem}").deb: no changelog"
	if ! command -v rpm >/dev/null 2>&1 && [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		## Under the gate a skipped read-back is a failure: the check exists to
		## catch a package that declares nothing, and it cannot do that silently.
		fDie "rpm is missing and the gate requires it to read the package back"
	fi
	grep -q ' ./usr/share/shcl/$' <<<"${listing}" || fDie "$(basename "${stem}").deb: does not own /usr/share/shcl"
	## Debian's zsh looks in vendor-completions and never in site-functions.
	grep -q ' ./usr/share/zsh/vendor-completions/_shcl$' <<<"${listing}" || fDie "$(basename "${stem}").deb: zsh completion is not where Debian's zsh looks"
	if command -v rpm >/dev/null 2>&1; then
		deps="$(rpm -qp --requires "${stem}.rpm" 2>/dev/null)"
		[[ "${deps}" == *"glibc >= ${glibc}"* ]] || fDie "$(basename "${stem}").rpm: Requires ${deps@Q} lacks glibc >= ${glibc}"
		if [[ -n "${needGcc}" ]] && ! grep -qxF "${rpmGccDep}" <<<"${deps}"; then fDie "$(basename "${stem}").rpm: Requires ${deps@Q} lacks ${rpmGccDep}"; fi
		## And that name has to be one rpm's own generator gives the binary,
		## which is what every rpm distro provides; a package name is one
		## distro's. STEM is the binary the package contains.
		if [[ -n "${needGcc}" ]]; then
			local elfdeps=/usr/lib/rpm/elfdeps gen
			if [[ -x "${elfdeps}" ]]; then
				gen="$("${elfdeps}" --requires "${stem}" </dev/null)"
				grep -qxF "${rpmGccDep}" <<<"${gen}" || fDie "$(basename "${stem}").rpm: requires ${rpmGccDep}, which rpm does not generate for the binary"
			elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
				fDie "rpm's elfdeps is missing and the gate requires it to check the libgcc requirement"
			fi
		fi
		## rpm owns only what is listed, so the payload's own parent has to be
		## listed too or removing the package leaves the directory behind.
		local files; files="$(rpm -qlp "${stem}.rpm" 2>/dev/null)"
		grep -qx '/usr/share/shcl' <<<"${files}" || fDie "$(basename "${stem}").rpm: does not own /usr/share/shcl"
		grep -qx '/usr/share/doc/shcl' <<<"${files}" || fDie "$(basename "${stem}").rpm: does not own /usr/share/doc/shcl"
		grep -qx '/usr/share/zsh/site-functions/_shcl' <<<"${files}" || fDie "$(basename "${stem}").rpm: no zsh completion in site-functions"
	fi
}

## Linux: .deb + .rpm per arch with a binary present. nfpm arch names are
## GOARCH-style; the artifact names use the uname-style spelling. The config
## template is sed-rendered per build (nfpm won't expand env vars in src paths).
if command -v nfpm >/dev/null 2>&1; then
	## The man page and the shell completions have a home only on Linux, so they
	## join the payload here and never reach the Windows setup. Both package
	## formats want the man page compressed; -n keeps the timestamp and the
	## original name out of the gzip header, so the same source gives the same
	## bytes on every build.
	mkdir -p "${payload}/man" "${payload}/completions" "${payload}/doc"
	gzip -9 -n -c "${root}/source/man/shcl.1" > "${payload}/man/shcl.1.gz"
	cp "${root}/source/completions/shcl.bash" "${root}/source/completions/_shcl" "${payload}/completions/"
	cp "${root}/license.md" "${payload}/doc/copyright"
	gzip -9 -n -c "${root}/changelog.md" > "${payload}/doc/changelog.gz"
	chmod 644 "${payload}/man/shcl.1.gz" "${payload}"/completions/* "${payload}"/doc/*
	fPinMtime "${payload}/man" "${payload}/man/shcl.1.gz" "${payload}/completions" "${payload}"/completions/* "${payload}/doc" "${payload}"/doc/*
	for pair in "x86_64|amd64" "arm64|arm64"; do
		osarch="${pair%%|*}"; goarch="${pair#*|}"
		bin="${artDir}/shcl-${ver}-linux-${osarch}"
		[[ -f "${bin}" ]] || continue
		fPinMtime "${bin}"
		## The dependencies come off the binary: its newest GLIBC_ symbol
		## version is the glibc floor, and libgcc is needed only when the
		## dynamic section says so (the arm64 build links it statically).
		glibc="$(objdump -T "${bin}" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -uV | tail -1)"
		[[ -n "${glibc}" ]] || fDie "no GLIBC_ symbol version in ${bin}"
		debGcc=""; rpmGcc=""
		## Into a variable first, for the same reason as the deb listing above:
		## a grep -q that quits early kills the writer with SIGPIPE under
		## pipefail, and the probe then reads as "no libgcc".
		needed="$(readelf -d "${bin}" || true)"
		if grep -q 'NEEDED.*libgcc_s' <<<"${needed}"; then debGcc=$'\n      - '"${debGccDep}"; rpmGcc=$'\n      - '"${rpmGccDep}"; fi
		sed -e "s|\${SHCL_VERSION}|${ver}|g" -e "s|\${SHCL_ARCH}|${goarch}|g" \
		    -e "s|\${SHCL_BIN}|${bin}|g" -e "s|\${SHCL_PAYLOAD}|${payload}|g" \
		    -e "s|\${SHCL_GLIBC}|${glibc}|g" -e "s|\${SHCL_DEB_LIBGCC}|${debGcc//$'\n'/\\n}|g" -e "s|\${SHCL_RPM_LIBGCC}|${rpmGcc//$'\n'/\\n}|g" \
		    "${meDir}/../packaging/nfpm.yaml" > "${payload}/nfpm.yaml"
		for fmt in deb rpm; do
			out="${artDir}/shcl-${ver}-linux-${osarch}.${fmt}"
			nfpm package -f "${payload}/nfpm.yaml" -p "${fmt}" -t "${out}" >/dev/null
			fEcho "OK: package: $(basename "${out}") ($(du -h --apparent-size "${out}" | cut -f1))"
			built=$((built + 1))
		done
		## What went in has to match what the binary needs, or the package
		## installs where the binary cannot run.
		fCheckDeps "${artDir}/shcl-${ver}-linux-${osarch}" "${glibc}" "${debGcc:+1}"
	done
else
	fWarn "nfpm not installed; .deb/.rpm skipped"
fi

## The setup's uninstaller removes the payload by name, one NSIS Delete line
## per file, so a file someone else keeps in code\ or scripts\ stays, as it
## does with both script installers.
fUninstallList(){
	local f rel
	for f in "$1"/code/* "$1"/scripts/*; do
		rel="${f#"$1"/}"
		# shellcheck disable=SC2016  ## $INSTDIR is NSIS's, not the shell's
		printf 'Delete "$INSTDIR\\%s"\n' "${rel//\//\\}"
	done
}

## Windows: an NSIS setup per built .exe. The x86 installer stub runs fine on
## ARM64 Windows (emulated), so one .nsi covers both.
if command -v makensis >/dev/null 2>&1; then
	## Beside the payload rather than in it; nfpm packs only the subdirectories.
	fUninstallList "${payload}" > "${payload}/uninstall.nsh"
	## Same icon the executables use. Absent is not an error - the setup just
	## falls back to the NSIS default.
	icoArg=""; [[ -f "${root}/assets/shcl.ico" ]] && icoArg="${root}/assets/shcl.ico"
	## Packed verbatim into the setup; its mtime rides into the archive too.
	fPinMtime "${meDir}/../packaging/shclpath.ps1"
	for osarch in x86_64 arm64; do
		exe="${artDir}/shcl-${ver}-windows-${osarch}.exe"
		[[ -f "${exe}" ]] || continue
		fPinMtime "${exe}"
		out="${artDir}/shcl-${ver}-windows-${osarch}-setup.exe"
		makensis -V2 -DVERSION="${ver}" -DVERQUAD="$(fVersionQuad "${ver}")" \
			-DSRCEXE="${exe}" -DPAYLOAD="${payload}" -DOUTFILE="${out}" -DUNINSTLIST="${payload}/uninstall.nsh" \
			${icoArg:+-DICON="${icoArg}"} "${meDir}/../packaging/shcl.nsi" >/dev/null
		fEcho "OK: package: $(basename "${out}") ($(du -h --apparent-size "${out}" | cut -f1))"
		built=$((built + 1))
	done
else
	fWarn "makensis not installed; NSIS setup skipped"
fi

((built)) || fWarn "no packages built (no matching binaries in ${artDir})"


##	History:
##		- 2026-07-22: Created: nfpm deb/rpm + NSIS setup over the release artifact dir.
##		- 2026-09-08: The profiler dependency is checked against the artifacts,
##		  not against the release command not including its flag.
##		- 2026-08-29: Reproducible output: mtimes pinned to the commit time; man page
##		  and completions staged for the Linux packages only.
##		- 2026-09-02: Dependencies read off the binary, Debian copyright and changelog
##		  files, and a check of both against every package built.
