#==============================================================================
## dogfood_shcl.ps1
##
##	Runs the newest dogfood build of shcl. The same script on Linux, Windows
##	and macOS, under PowerShell 7, and under Windows PowerShell 5.1.
##
##	The pipeline drops each release build into the synced dogfood dir. This
##	copies it into a local pool of dated versions, points a fixed name at the
##	newest, and runs that with every argument passed through. A copy that is
##	running is never overwritten or deleted, so a long run keeps going while a
##	newer build arrives.
##
##	Usage:
##		dogfood_shcl get --int app.shcl server.port
##		dogfood_shcl --no-update --version   ## run what is held, copy nothing
##
##	Where things go:
##		Linux, macOS  ~/.local/bin/shcl_versions/, fixed name ~/.local/bin/shcl
##		Windows       %LOCALAPPDATA%\Programs\shcl_versions\, fixed name
##		              %LOCALAPPDATA%\Programs\Shcl\shcl.exe
##	The fixed name is where a user install puts shcl too, and this takes it
##	over; on Windows that folder is the one install.ps1 puts on PATH. A
##	regular file there on Linux or macOS is left alone.
##
##	The pool keeps at most 10 versions and at least 5, and between those only
##	as many as fit in 1 GB. Which ones stay is a GFS rotation: the oldest, the
##	newest, the last of each recent hour, day, week, month and year, and the
##	few most recent. Each file is named shcl_<yyyyMMdd-HHmmss>_<role>, from
##	the build's write time in UTC, so the names sort the same in any culture
##	and across a clock change.
##
##	Output: shcl's own stdout and stderr, and its exit code. What this script
##	has to say goes to stderr, and only on a run that took a new build or
##	changed something, so a pipe sees what shcl printed and nothing else.
##
##	Windows runs it unelevated, in the same window, where shcl's output can be
##	read. The fixed name is a symlink where the account may make one, and a
##	hard link or a copy where it may not.
##
##	History: At bottom of script.
#==============================================================================

##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Runs the newest dogfood build of shcl, taking a new one from the synced dogfood dir first.
.DESCRIPTION
Every argument but --no-update goes to shcl as it came, and shcl's exit code comes back. --no-update runs the newest build already held and copies nothing.
.EXAMPLE
dogfood_shcl get --int app.shcl server.port
.EXAMPLE
dogfood_shcl --no-update --version
#>

#==============================================================================
# Configuration
#==============================================================================

## Windows PowerShell 5.1 has no $IsWindows and runs only on Windows, and
## strict mode refuses a name that was never set, so the platform is asked once
## here.
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$OnMac = (-not $OnWindows) -and $IsMacOS

$ProgramName = 'shcl'
$LauncherName = "dogfood_$ProgramName"
$ExeExt = if ($OnWindows) { '.exe' } else { '' }
$ExeName = "$ProgramName$ExeExt"

## Where the pipeline's dogfood stage puts a build. The first that holds one
## wins. On Windows the real Dropbox path comes first: Windows 11 can refuse
## the 'synced' junction into it as an untrusted mount point.
$SourceDirs = if ($OnWindows) {
	@(
		(Join-Path -Path $HOME -ChildPath 'Dropbox\0-0\common\exec\util\mswin\cli\by-self\win64')
		(Join-Path -Path $HOME -ChildPath 'synced\0-0\common\exec\util\mswin\cli\by-self\win64')
	)
} elseif ($OnMac) {
	@(
		(Join-Path -Path $HOME -ChildPath 'synced/0-0/common/exec/util/macos/bin')
		(Join-Path -Path $HOME -ChildPath 'Dropbox/0-0/common/exec/util/macos/bin')
	)
} else {
	@(
		(Join-Path -Path $HOME -ChildPath 'synced/0-0/common/exec/util/linux/bin')
		(Join-Path -Path $HOME -ChildPath 'Dropbox/0-0/common/exec/util/linux/bin')
	)
}

## Local on purpose. Versions churn with every build and have no business in
## the sync tree.
$InstallDir = if ($OnWindows) { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs' } else { Join-Path -Path $HOME -ChildPath '.local/bin' }
$PoolDir = Join-Path -Path $InstallDir -ChildPath "${ProgramName}_versions"
## Where a user install puts shcl: install.ps1's folder on Windows, which it
## adds to PATH (20260924d item 5).
$LinkDir = if ($OnWindows) { Join-Path -Path $InstallDir -ChildPath 'Shcl' } else { $InstallDir }
$LinkPath = Join-Path -Path $LinkDir -ChildPath $ExeName

$MaxVersions = 10
$MinVersions = 5
$MaxPoolBytes = 1GB

## GFS roles, before the budget above trims them. A period role goes to the
## last version of a period that has ended.
$KeepFrequent = 5
$KeepHourly = 3
$KeepDaily = 3
$KeepWeekly = 2
$KeepMonthly = 1
$KeepYearly = 1

$StampFormat = 'yyyyMMdd-HHmmss'
## Stamps are local time, written and read in one culture. A current culture
## with another calendar wrote a year the invariant read took as a different
## one. A DST change or a new time zone can put a stamp out of order once.
$Invariant = [Globalization.CultureInfo]::InvariantCulture

#==============================================================================
# Functions
#==============================================================================

function Write-Note {
	[CmdletBinding()]
	param([string]$Message)
	[Console]::Error.WriteLine("${LauncherName}: $Message")
}

function Exit-Launcher {
	[CmdletBinding()]
	param([string]$Message)
	[Console]::Error.WriteLine("${LauncherName}: $Message")
	exit 1
}

function ConvertFrom-Stamp {
	[CmdletBinding()]
	param([string]$Stamp)
	return [datetime]::ParseExact($Stamp, $StampFormat, $Invariant)
}

## The newest build in the first source dir that has one, or nothing.
function Get-SourceBuild {
	[CmdletBinding()]
	param()
	foreach ($dir in $SourceDirs) {
		$item = Get-Item -LiteralPath (Join-Path -Path $dir -ChildPath $ExeName) -ErrorAction SilentlyContinue
		if ($item) { return $item }
	}
	return $null
}

## Every version in the pool, as { File, Name, Stamp }, oldest first. Only an
## exact name counts, so anything else put in the directory is left alone. A
## version copied in this run has no role yet.
function Get-HeldVersion {
	[CmdletBinding()]
	param()
	if (-not (Test-Path -LiteralPath $PoolDir)) { return , @() }
	$rx = '^' + [regex]::Escape($ProgramName) + '_(?<stamp>\d{8}-\d{6})(_[a-z]+)?' + [regex]::Escape($ExeExt) + '$'
	$found = @(Get-ChildItem -LiteralPath $PoolDir -File | Where-Object { $_.Name -match $rx } | ForEach-Object {
			$null = $_.Name -match $rx
			[PSCustomObject]@{ File = $_; Name = $_.Name; Stamp = (ConvertFrom-Stamp -Stamp $Matches.stamp) }
		})
	return , @($found | Sort-Object -Property Stamp, Name)
}

## A held version with the same bytes as the source build, or nothing. The sync
## layer restamps what it carries, so a build already held can look new.
function Find-HeldTwin {
	[CmdletBinding()]
	param($Source)
	$held = Get-HeldVersion
	$same = @($held | Where-Object { $_.File.Length -eq $Source.Length })
	if ($same.Count -eq 0) { return $null }
	$want = (Get-FileHash -LiteralPath $Source.FullName -Algorithm SHA256).Hash
	for ($i = $same.Count - 1; $i -ge 0; $i--) {
		if ((Get-FileHash -LiteralPath $same[$i].File.FullName -Algorithm SHA256).Hash -eq $want) { return $same[$i] }
	}
	return $null
}

## Copy the source build in when nothing held matches it. Written to a temp
## name and renamed, so a copy that dies partway never passes for a version.
## True when it took one.
function Copy-NewBuild {
	[CmdletBinding()]
	param()
	$src = Get-SourceBuild
	if (-not $src) { return $false }
	$stamp = $src.LastWriteTime.ToString($StampFormat, $Invariant)
	$held = Get-HeldVersion
	if ($held.Count -gt 0 -and $held[-1].Stamp -ge (ConvertFrom-Stamp -Stamp $stamp)) { return $false }
	if (Find-HeldTwin -Source $src) { return $false }

	$null = New-Item -ItemType Directory -Force -Path $PoolDir
	$dest = Join-Path -Path $PoolDir -ChildPath "${ProgramName}_$stamp$ExeExt"
	$partial = "$dest.partial"
	try {
		Copy-Item -LiteralPath $src.FullName -Destination $partial -Force
		if (-not $OnWindows) { & chmod 755 $partial }
		Move-Item -LiteralPath $partial -Destination $dest -Force
		Write-Note "new build $stamp from $($src.DirectoryName)"
		return $true
	} catch {
		Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
		Write-Note "could not copy the new build: $($_.Exception.Message)"
		return $false
	}
}

function Get-PeriodKey {
	[CmdletBinding()]
	param([datetime]$When)
	return @{
		hour = $When.ToString('yyyyMMddHH', $Invariant)
		day = $When.ToString('yyyyMMdd', $Invariant)
		week = Get-IsoWeek -When $When
		month = $When.ToString('yyyyMM', $Invariant)
		year = $When.ToString('yyyy', $Invariant)
	}
}

## The ISO week, as yyyyww: the Thursday of a week decides its year. By hand,
## since .NET Framework under 5.1 has no ISOWeek.
function Get-IsoWeek {
	[CmdletBinding()]
	param([datetime]$When)
	$day = [int]$When.DayOfWeek
	if ($day -eq 0) { $day = 7 }
	$thursday = $When.Date.AddDays(4 - $day)
	return '{0:D4}{1:D2}' -f $thursday.Year, [int]([Math]::Floor(($thursday.DayOfYear - 1) / 7) + 1)
}

## Each version's role, by name. A version with none is one nothing keeps. The
## coarser role wins where two apply; oldest and newest win over all of them.
function Get-GfsRole {
	[CmdletBinding()]
	param([object[]]$Versions)
	$periods = @('year', 'month', 'week', 'day', 'hour')
	$current = Get-PeriodKey -When (Get-Date)
	$lastIn = @{}
	foreach ($p in $periods) { $lastIn[$p] = @{} }
	foreach ($v in $Versions) {
		$keys = Get-PeriodKey -When $v.Stamp
		foreach ($p in $periods) {
			if ($keys[$p] -ne $current[$p]) { $lastIn[$p][$keys[$p]] = $v }
		}
	}
	$roles = @{}
	$roles[$Versions[0].Name] = 'oldest'
	$roles[$Versions[-1].Name] = 'newest'
	$quota = @{ year = $KeepYearly; month = $KeepMonthly; week = $KeepWeekly; day = $KeepDaily; hour = $KeepHourly }
	foreach ($p in $periods) {
		$keys = @($lastIn[$p].Keys | Sort-Object)
		for ($i = [Math]::Max(0, $keys.Count - $quota[$p]); $i -lt $keys.Count; $i++) {
			$name = $lastIn[$p][$keys[$i]].Name
			if (-not $roles.ContainsKey($name)) { $roles[$name] = $p }
		}
	}
	for ($i = [Math]::Max(0, $Versions.Count - $KeepFrequent); $i -lt $Versions.Count; $i++) {
		if (-not $roles.ContainsKey($Versions[$i].Name)) { $roles[$Versions[$i].Name] = 'frequent' }
	}
	return $roles
}

## The names that fit the budget. The newest goes in first whatever it weighs,
## since the fixed name points at it, then the oldest, then the rest newest
## first until the count or the bytes run out.
function Select-Budget {
	[CmdletBinding()]
	param([object[]]$Versions, [hashtable]$Roles)
	$keep = [Collections.Generic.HashSet[string]]::new()
	$ranked = @($Versions | Where-Object { $Roles.ContainsKey($_.Name) } | Sort-Object -Property Stamp -Descending)
	if ($ranked.Count -eq 0) { return , $keep }
	$order = @($ranked[0])
	if ($ranked.Count -gt 1) { $order += $ranked[-1] }
	if ($ranked.Count -gt 2) { $order += $ranked[1..($ranked.Count - 2)] }
	$bytes = 0
	foreach ($v in $order) {
		if ($keep.Count -ge $MaxVersions) { break }
		if ($keep.Count -ge $MinVersions -and ($bytes + $v.File.Length) -gt $MaxPoolBytes) { break }
		$null = $keep.Add($v.Name)
		$bytes += $v.File.Length
	}
	return , $keep
}

## The image paths of what is running now. A process that cannot be read is
## not protected by this, but a running image refuses the delete on Windows.
function Get-RunningPath {
	[CmdletBinding()]
	param()
	return @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ })
}

## Prune what the budget leaves out, unless it is running, then give each kept
## version its role in its name.
function Invoke-Rotation {
	[CmdletBinding()]
	param()
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return }
	$roles = Get-GfsRole -Versions $versions
	$keep = Select-Budget -Versions $versions -Roles $roles
	$running = Get-RunningPath
	foreach ($v in $versions) {
		if ($keep.Contains($v.Name)) { continue }
		if ($running -contains $v.File.FullName) { continue }
		try {
			Remove-Item -LiteralPath $v.File.FullName -Force -ErrorAction Stop
		} catch {
			Write-Note "could not remove $($v.Name): $($_.Exception.Message)"
		}
	}
	foreach ($v in $versions) {
		if (-not $keep.Contains($v.Name)) { continue }
		$want = "${ProgramName}_$($v.Stamp.ToString($StampFormat, $Invariant))_$($roles[$v.Name])$ExeExt"
		if ($v.Name -eq $want) { continue }
		$wantPath = Join-Path -Path $PoolDir -ChildPath $want
		if (Test-Path -LiteralPath $wantPath) { continue }
		## A running image refuses the rename on Windows. The next run tries again.
		try { Move-Item -LiteralPath $v.File.FullName -Destination $wantPath -ErrorAction Stop } catch { $null = $_ }
	}
}

## Point the fixed name at the newest version. A reason it cannot is said
## only on a run that took a new build, since it holds until someone acts.
function Update-FixedName {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
	param([switch]$Fresh)
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return }
	$target = $versions[-1].File.FullName
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if ($cur -and $cur.LinkType -eq 'SymbolicLink' -and $cur.Target -eq $target) { return }
	if ($cur -and -not $cur.LinkType -and -not $OnWindows) {
		if ($Fresh) { Write-Note "$LinkPath is a regular file, so it was left alone, and a bare shcl there is not this build" }
		return
	}
	## On Windows a hard link or a plain file here is this script's own fallback,
	## and the same bytes as the newest need no rewrite.
	if ($cur -and $OnWindows -and $cur.LinkType -ne 'SymbolicLink' -and $cur.Length -eq $versions[-1].File.Length) {
		if ((Get-FileHash -LiteralPath $LinkPath).Hash -eq (Get-FileHash -LiteralPath $target).Hash) { return }
	}
	try {
		if ($cur) { Remove-Item -LiteralPath $LinkPath -Force -ErrorAction Stop }
	} catch {
		if ($Fresh) { Write-Note "$LinkPath is in use, so it still names the older build" }
		return
	}
	$null = New-Item -ItemType Directory -Force -Path $LinkDir
	$made = $false
	foreach ($kind in @('SymbolicLink', 'HardLink')) {
		try {
			$null = New-Item -ItemType $kind -Path $LinkPath -Target $target -Force -ErrorAction Stop
			$made = $true
			break
		} catch { $null = $_ }
	}
	if (-not $made) {
		try {
			Copy-Item -LiteralPath $target -Destination $LinkPath -Force -ErrorAction Stop
		} catch {
			Write-Note "could not update ${LinkPath}: $($_.Exception.Message)"
			return
		}
	}
	Write-Note "$LinkPath -> $($versions[-1].Name)"
}

## What to run: the fixed name when it names the newest pool version, else that
## version itself. Anything else at the fixed name is someone else's, as an
## installed release a link points at, or a file there on Linux or macOS.
function Get-RunTarget {
	[CmdletBinding()]
	param()
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return $null }
	$newest = $versions[-1].File
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if (-not $cur) { return $newest.FullName }
	if ($cur.LinkType -eq 'SymbolicLink') {
		if ("$($cur.Target)" -eq $newest.FullName) { return $LinkPath }
		return $newest.FullName
	}
	## On Windows the fallback is a hard link or a copy, so it counts when it
	## holds the newest version's bytes.
	if ($OnWindows -and $cur.Length -eq $newest.Length -and (Get-FileHash -LiteralPath $LinkPath).Hash -eq (Get-FileHash -LiteralPath $newest.FullName).Hash) { return $LinkPath }
	return $newest.FullName
}

#==============================================================================
# Main
#==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

## Its own flag is taken out; everything else goes to shcl as it came, `-v` and
## `-h` included, which is why there is no param() block to bind them.
$noUpdate = $false
$passArgs = @()
foreach ($arg in $args) {
	if ($arg -ceq '--no-update') { $noUpdate = $true } else { $passArgs += $arg }
}

if (-not $noUpdate) {
	$fresh = Copy-NewBuild
	Invoke-Rotation
	Update-FixedName -Fresh:$fresh
}

$exe = Get-RunTarget
if (-not $exe) { Exit-Launcher "no $ProgramName build held, and none in $($SourceDirs -join ' or ')" }
& $exe @passArgs
exit $LASTEXITCODE

##	History:
##		- 2026-09-24 JC: Created, in place of n8runshcl.ps1. Takes the build from the synced dogfood dir rather than the repo, and keeps a GFS-rotated pool with a fixed name on the newest.
##		- 2026-09-27 JC: Runs under Windows PowerShell 5.1. The Windows fixed name is in install.ps1's user folder. Stamps in UTC and the invariant culture. Runs the fixed name only when it names the newest pool version. Says why the fixed name was not updated only on a run that took a build. Help block.
##		- 2026-09-28 JC: Stamps back in local time.
