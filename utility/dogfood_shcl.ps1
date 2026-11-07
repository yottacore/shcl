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
##		dogfood_shcl.ps1 --print-path        ## print what would run, run nothing
##
##	On Linux and macOS the bash launcher takes --print-path's answer and runs
##	it itself, so the arguments as typed and a Ctrl+C's exit code reach shcl
##	without going through pwsh.
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
##	the build's write time in local time and the invariant culture, so the
##	names read the same in any culture. A DST change or a new time zone can
##	put one out of order once.
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
Every argument but --no-update and --print-path goes to shcl as it came, and shcl's exit code comes back. --no-update runs the newest build already held and copies nothing. --print-path prints the path that would run instead of running it, and takes no other argument but --no-update. For shcl's own help, run it with --help.
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
$RetiredNames = @()

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

## The stamp as a date, or nothing when it names no real one, such as a 13th
## month. A name like that is not one this script wrote.
function ConvertFrom-Stamp {
	[CmdletBinding()]
	param([string]$Stamp)
	$when = [datetime]::MinValue
	if ([datetime]::TryParseExact($Stamp, $StampFormat, $Invariant, [Globalization.DateTimeStyles]::None, [ref]$when)) { return $when }
	return $null
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
## exact name with a real date counts, so anything else put in the directory
## is left alone. A version copied in this run has no role yet.
function Get-HeldVersion {
	[CmdletBinding()]
	param()
	if (-not (Test-Path -LiteralPath $PoolDir)) { return , @() }
	$rx = '^' + [regex]::Escape($ProgramName) + '_(?<stamp>\d{8}-\d{6})(_[a-z]+)?' + [regex]::Escape($ExeExt) + '$'
	$found = @(Get-ChildItem -LiteralPath $PoolDir -File | Where-Object { $_.Name -match $rx } | ForEach-Object {
			$null = $_.Name -match $rx
			$stamp = ConvertFrom-Stamp -Stamp $Matches.stamp
			if ($null -ne $stamp) { [PSCustomObject]@{ File = $_; Name = $_.Name; Stamp = $stamp } }
		})
	return , @($found | Sort-Object -Property Stamp, Name)
}

## A held version with the same bytes as the source build, or nothing. The sync
## layer restamps what it has, so a build already held can look new.
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
## name of this process's own and renamed, so a copy that dies partway never
## passes for a version, and two runs as a build arrives can't cut one file
## under each other's rename. True when it took one.
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
	$partial = "$dest.$PID.partial"
	try {
		Copy-Item -LiteralPath $src.FullName -Destination $partial -Force
		if (-not $OnWindows) { & chmod 755 $partial }
		## Another run got there first, with the same bytes.
		if (Test-Path -LiteralPath $dest) { return $false }
		Move-Item -LiteralPath $partial -Destination $dest -Force
		Write-Note "new build $stamp from $($src.DirectoryName)"
		return $true
	} catch {
		Write-Note "could not copy the new build: $($_.Exception.Message)"
		return $false
	} finally {
		Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
	}
}

## A run killed partway leaves its temp file behind: a copy in the pool, or a
## new fixed name beside the old one. One whose process is gone, or that is a
## day old, is nobody's. A name without a process ID is from before they had one.
function Remove-StaleTemp {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
	param()
	$name = [regex]::Escape($ProgramName)
	$ext = [regex]::Escape($ExeExt)
	$spots = @(
		@{ Dir = $PoolDir; Rx = '^' + $name + '_\d{8}-\d{6}' + $ext + '(\.(?<id>\d+))?\.partial$' }
		@{ Dir = $LinkDir; Rx = '^' + $name + $ext + '\.(?<id>\d+)\.new$' }
	)
	$dayAgo = (Get-Date).AddDays(-1)
	foreach ($spot in $spots) {
		if (-not (Test-Path -LiteralPath $spot.Dir)) { continue }
		foreach ($f in @(Get-ChildItem -LiteralPath $spot.Dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $spot.Rx })) {
			$null = $f.Name -match $spot.Rx
			$id = if ($Matches['id']) { [int]$Matches['id'] } else { 0 }
			if ($id -and $f.LastWriteTime -gt $dayAgo -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) { continue }
			Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
		}
	}
}

## Rename From over To, replacing it in one step where .NET can. Windows
## PowerShell 5.1's has no replacing rename, so there To goes first.
function Move-Over {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
	param([string]$From, [string]$To)
	if ([IO.File].GetMethod('Move', [type[]]@([string], [string], [bool]))) {
		[IO.File]::Move($From, $To, $true)
		return
	}
	if (Get-Item -LiteralPath $To -Force -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $To -Force -ErrorAction Stop }
	[IO.File]::Move($From, $To)
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
		## A rename of the version the fixed name points at, from this run or
		## another, would leave shcl on PATH dangling until the link moves. So the
		## new name comes as a second link, and the old one goes once nothing
		## points at it. Not on Windows, where a running image keeps its old
		## name, and the twin would hold a place in the pool.
		if (-not $OnWindows) {
			try {
				$null = New-Item -ItemType HardLink -Path $wantPath -Target $v.File.FullName -ErrorAction Stop
				$script:RetiredNames += $v.File.FullName
				continue
			} catch { $null = $_ }
		}
		## A running image refuses the rename on Windows. The next run tries again.
		try { Move-Item -LiteralPath $v.File.FullName -Destination $wantPath -ErrorAction Stop } catch { $null = $_ }
	}
}

## The old names rotation left behind, once the fixed name points elsewhere.
function Remove-RetiredName {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
	param()
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	$linked = if ($cur -and $cur.LinkType -eq 'SymbolicLink') { "$($cur.Target)" } else { '' }
	foreach ($old in $script:RetiredNames) {
		if ($old -ne $linked) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
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
	## Made beside the fixed name and renamed over it, so shcl on PATH is never
	## missing for a moment.
	$null = New-Item -ItemType Directory -Force -Path $LinkDir
	$next = "$LinkPath.$PID.new"
	$made = $false
	foreach ($kind in @('SymbolicLink', 'HardLink')) {
		try {
			$null = New-Item -ItemType $kind -Path $next -Target $target -Force -ErrorAction Stop
			$made = $true
			break
		} catch { $null = $_ }
	}
	if (-not $made) {
		try {
			Copy-Item -LiteralPath $target -Destination $next -Force -ErrorAction Stop
		} catch {
			Remove-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue
			Write-Note "could not update ${LinkPath}: $($_.Exception.Message)"
			return
		}
	}
	try {
		Move-Over -From $next -To $LinkPath
	} catch {
		Remove-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue
		if ($Fresh) { Write-Note "$LinkPath is in use, so it still names the older build" }
		return
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

## Started by -File, PowerShell has parsed the arguments as its own before the
## script sees them. A `-`-led one with a colon became a name and a value, so
## `--set=url=http://x` reached shcl as `--set=url=http` and `//x`. The
## process's own argument list still has them as typed, after this script's
## path. Nothing when no argument there names this script. Taken from the
## retired shcl.ps1, now in project/legacy/.
function Get-FileArgument {
	[CmdletBinding()]
	[OutputType([string[]])]
	param([string]$Self)
	$argv = [Environment]::GetCommandLineArgs()
	$leaf = ($Self -split '[\\/]')[-1]
	for ($i = 1; $i -lt $argv.Count; $i++) {
		if (($argv[$i] -split '[\\/]')[-1] -eq $leaf) { return , [string[]]@($argv | Select-Object -Skip ($i + 1)) }
	}
	return $null
}

## Called from a session, an unquoted `-x:y` reaches the script as a marked
## `-x:` and a `y`, and splatted on to shcl the `-x:` is dropped. The calling
## line tells it apart from `-x: y`, which a direct call passes as two
## arguments. With no command there whose colon parameters match, the pair is
## joined. Plain strings come back. Taken from _shcl_colon_args in the
## retired shcl.ps1.
function Join-ColonArgument {
	[CmdletBinding()]
	param([object[]]$Argument)
	$mark = '<CommandParameterName>'
	$names = @(foreach ($a in $Argument) { if ($null -ne $a -and $a.PSObject.Properties[$mark] -and "$a".EndsWith(':')) { $a.PSObject.Properties[$mark].Value } })
	if ($names.Count -eq 0) { return $Argument }
	$wanted = $names -join ' '
	$spaced = $null
	foreach ($frame in Get-PSCallStack) {
		if ($null -eq $frame.Position -or -not $frame.Position.Text) { continue }
		$ast = [System.Management.Automation.Language.Parser]::ParseInput($frame.Position.Text, [ref]$null, [ref]$null)
		foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
			$params = @($command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $null -ne $_.Argument })
			if ((@($params | ForEach-Object { $_.ParameterName }) -join ' ') -eq $wanted) {
				$spaced = @($params | ForEach-Object { $_.Argument.Extent.StartOffset -gt $_.ErrorPosition.EndOffset })
				break
			}
		}
		if ($null -ne $spaced) { break }
	}
	$k = 0
	for ($i = 0; $i -lt $Argument.Count; $i++) {
		$a = $Argument[$i]
		if ($null -eq $a -or -not $a.PSObject.Properties[$mark] -or -not "$a".EndsWith(':') -or $i + 1 -ge $Argument.Count) { $a; continue }
		if ($null -ne $spaced -and $k -lt $spaced.Count -and $spaced[$k]) { "$a" }
		else { $i++; "$a" + (@($Argument[$i]) -join ',') }
		$k++
	}
}

## Windows PowerShell 5.1, 7 before 7.3, and 7.3 and later set to Legacy, hand
## a native command one command line built the old way, where an embedded
## quote goes through bare and an empty argument is left out. So each argument
## with a blank or a quote is quoted the way shcl's parser reads it back.
## Taken from _shcl_native_args in the retired shcl.ps1.
function ConvertTo-NativeArgument {
	[CmdletBinding()]
	param([object[]]$Argument)
	$legacy = $PSVersionTable.PSVersion -lt [version]'7.3'
	if (-not $legacy) { $legacy = (Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction Ignore) -eq 'Legacy' }
	if (-not $legacy) { return $Argument }
	foreach ($a in $Argument) {
		if ($a -isnot [string]) { $a }
		elseif ($a -eq '') { '""' }
		elseif ($a -match '[\s"]') { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
		else { $a }
	}
}

## pwsh on Linux and macOS expands wildcards and ~ in a native command's
## arguments, splatted ones too, and leaves only a quoted literal alone. So
## each string goes on a built command line in single quotes. Anything else,
## such as an array from a session, is passed by reference as before.
function Invoke-NativeLiteral {
	[CmdletBinding()]
	param([string]$Path, [object[]]$Argument)
	$line = [Text.StringBuilder]::new('& $args[0]')
	for ($i = 0; $i -lt $Argument.Count; $i++) {
		if ($Argument[$i] -is [string]) { $null = $line.Append(" '").Append([Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Argument[$i])).Append("'") }
		else { $null = $line.Append(" `$args[1][$i]") }
	}
	& ([scriptblock]::Create($line.ToString())) $Path $Argument
}

#==============================================================================
# Main
#==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

## Its own flags are taken out; everything else goes to shcl as it came, `-v`
## and `-h` included, which is why there is no param() block to bind them.
$given = @(Join-ColonArgument -Argument $args)
if (-not $MyInvocation.Line) {
	$fromFile = Get-FileArgument -Self $PSCommandPath
	if ($null -ne $fromFile) { $given = $fromFile }
}
## The flag goes on the left. A `$true` from `-k:$true` on the left equals any
## word, so that run copied nothing and then found no build.
$noUpdate = $false
$printPath = $false
$passArgs = @()
foreach ($arg in $given) {
	if ('--no-update' -ceq $arg) { $noUpdate = $true }
	elseif ('--print-path' -ceq $arg) { $printPath = $true }
	else { $passArgs += $arg }
}
if ($printPath -and $passArgs.Count -gt 0) { Exit-Launcher "--print-path runs nothing, so it takes no argument for $ProgramName, such as '$($passArgs[0])'" }

if (-not $noUpdate) {
	Remove-StaleTemp
	$fresh = Copy-NewBuild
	Invoke-Rotation
	Update-FixedName -Fresh:$fresh
	Remove-RetiredName
}

$exe = Get-RunTarget
if (-not $exe) { Exit-Launcher "no $ProgramName build held, and none in $($SourceDirs -join ' or ')" }
if ($printPath) {
	Write-Output -InputObject $exe
	exit 0
}
$nativeArgs = @(ConvertTo-NativeArgument -Argument $passArgs)
Invoke-NativeLiteral -Path $exe -Argument $nativeArgs
exit $LASTEXITCODE

##	History:
##		- 2026-09-24 JC: Created, in place of n8runshcl.ps1. Takes the build from the synced dogfood dir rather than the repo, and keeps a GFS-rotated pool with a fixed name on the newest.
##		- 2026-09-27 JC: Runs under Windows PowerShell 5.1. The Windows fixed name is in install.ps1's user folder. Stamps in UTC and the invariant culture. Runs the fixed name only when it names the newest pool version. Says why the fixed name was not updated only on a run that took a build. Help block.
##		- 2026-09-28 JC: Stamps back in local time. A pool name holding an impossible date is skipped rather than stopping every run.
##		- 2026-10-04 JC: Takes its arguments from the process when started by -File, which split a `-x:y` one. Quotes them for 5.1 the way shcl.ps1 does.
##		- 2026-10-04 JC: Called from a session, keeps an unquoted `-x:y` whole rather than passing on only the `y`.
##		- 2026-11-02 JC: --print-path, for the bash launcher to run the build itself. Passes each argument as a quoted literal, so pwsh on Linux and macOS no longer expands wildcards and ~ in them.
##		- 2026-11-06 JC: Each run copies a new build through a temp name of its own, and a killed run's is cleared by the next. The fixed name is replaced by a rename, and rotation gives a version its new name before taking the old one, so the fixed name never dangles.
