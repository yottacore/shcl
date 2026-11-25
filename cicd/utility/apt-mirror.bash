#!/usr/bin/env bash

##	Purpose:
##		The hosted Ubuntu runners send apt to a mirror list, with the cloud's own
##		mirror first and archive.ubuntu.com behind it. apt moves down that list
##		only when a fetch fails, never when it's slow, and on some runs the
##		first mirror gave 110 kB/s, so the tool install took 40 minutes where
##		it usually takes 2 (2026112314544545). This times a ranged fetch from
##		the first mirror, and when that's under the floor and the next one is
##		faster, takes the first out of the list. It prints what it measured
##		either way, so a slow install's log says which mirror it used.
##	Syntax:
##		apt-mirror.bash [MIRRORS]
##		  MIRRORS  apt's mirror list (default /etc/apt/apt-mirrors.txt)
##		APT_MIN_BPS is the floor in bytes a second (default 2000000), and
##		APT_PROBE_SECONDS how long each probe may take (default 15).
##		APT_CODENAME overrides the release named in /etc/os-release.
##	Exit: 0 = the list was left as it was, or the slow mirror was taken out;
##	      2 = usage, or the list has to change and can't be written.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

(($# <= 1)) || { echo "usage: apt-mirror.bash [MIRRORS]" >&2; exit 2 ;}
mirrors="${1:-/etc/apt/apt-mirrors.txt}"
minBps="${APT_MIN_BPS:-2000000}"
probeSecs="${APT_PROBE_SECONDS:-15}"
fSay(){ echo "apt-mirror: $*" ;}
[[ "${minBps}" =~ ^[0-9]+$ && "${probeSecs}" =~ ^[0-9]+$ ]] || { echo "apt-mirror: APT_MIN_BPS and APT_PROBE_SECONDS take whole numbers" >&2; exit 2 ;}

[[ -f "${mirrors}" ]] || { fSay "no ${mirrors}, so apt's sources are left as they are"; exit 0 ;}
codename="${APT_CODENAME:-}"
if [[ -z "${codename}" && -r /etc/os-release ]]; then
	codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"' | head -n 1)"
fi
[[ -n "${codename}" ]] || { fSay "no release codename to probe with, so ${mirrors} is left as it is"; exit 0 ;}
arch="$(dpkg --print-architecture 2>/dev/null || true)"; arch="${arch:-amd64}"

urls=()
while read -r url _; do
	[[ -z "${url}" || "${url}" == \#* ]] && continue
	urls+=("${url}")
done < "${mirrors}"
((${#urls[@]} >= 2)) || { fSay "${mirrors} lists ${#urls[@]} mirror(s), so there is none to move to"; exit 0 ;}

## fProbe URL: bytes a second for the first 4 MiB of the release's Contents
## file, which every Ubuntu mirror carries and which takes ranges. A fetch that
## fails or times out still reports what it got, so a dead mirror reads as 0.
fProbe(){
	local bps
	bps="$(curl -sS -o /dev/null -r 0-4194303 --max-time "${probeSecs}" -w '%{speed_download}' "${1%/}/dists/${codename}/Contents-${arch}.gz" 2>/dev/null || true)"
	bps="${bps%%.*}"
	[[ "${bps}" =~ ^[0-9]+$ ]] || bps=0
	echo "${bps}"
}

first="${urls[0]}"; next="${urls[1]}"
firstBps="$(fProbe "${first}")"
if ((firstBps >= minBps)); then
	fSay "${first} at $((firstBps / 1000)) kB/s, so apt keeps it first"
	exit 0
fi
nextBps="$(fProbe "${next}")"
if ((nextBps <= firstBps)); then
	fSay "${first} at $((firstBps / 1000)) kB/s, under the $((minBps / 1000)) kB/s floor, and ${next} no faster at $((nextBps / 1000)) kB/s, so apt keeps the list as it is"
	exit 0
fi
[[ -w "${mirrors}" ]] || { echo "apt-mirror: ${first} is slow, and ${mirrors} can't be written to take it out" >&2; exit 2 ;}
kept="$(URL="${first}" awk '$1 != ENVIRON["URL"]' "${mirrors}")"
printf '%s\n' "${kept}" > "${mirrors}"
fSay "${first} at $((firstBps / 1000)) kB/s, under the $((minBps / 1000)) kB/s floor, and ${next} at $((nextBps / 1000)) kB/s, so apt uses ${next} first"


##	History:
##		- 2026-11-24 JC: Created, for 2026112314544545.
