#==============================================================================
## install.ps1
##
##	Release installer for shcl (Simple Hierarchical Config Language) on Windows.
##	Downloads the latest release from GitHub, checks the sha256sums file against
##	the release signing key before trusting a checksum out of it, and lays out
##	the binary plus the drop-in source files and wrappers. Idempotent:
##	re-running updates an existing install in place.
##
##	Usage (one-liner, defaults):
##		irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1 | iex
##	With options (download first, or wrap in a script block):
##		& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1))) -Target system -Yes
##
##	Options:
##		-Release <stable|dev>   stable (default) = newest full release, or the
##		                        newest pre-release while there is no full one;
##		                        dev = newest release including pre-releases.
##		-Target <user|system>   user (default): %LOCALAPPDATA%\Programs\Shcl,
##		                        added to the user PATH. No elevation.
##		                        system: C:\Program Files\Shcl, added to the
##		                        machine PATH (needs an elevated shell).
##		-Uninstall              remove what an install of the same -Target laid
##		                        down (binary, code\, scripts\, PATH entry).
##		-Yes                    skip the confirmation prompt.
##		-Version                print this installer's version and exit.
##		-Help                   print the options and exit.
##
##	Needs Windows PowerShell 5.1 or pwsh 7.
##
##	Layout under the install dir:
##		shcl.exe    the CLI binary
##		code\       drop-in single-file bindings (lib.rs, shcl.go, shcl.py,
##		            shcl.h, shcl.hpp)
##		scripts\    the PowerShell wrapper (shcl.ps1) and bash wrapper
#==============================================================================

##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Installs, updates or removes the shcl release binary on Windows.
.DESCRIPTION
Downloads a release from GitHub, checks the signed sha256sums file before trusting a checksum out of it, and installs the binary, the drop-in source files and the wrappers. Re-running updates an install in place.
.PARAMETER Release
stable (the default) takes the newest full release, or the newest pre-release while there is no full one. dev takes the newest release, pre-releases included.
.PARAMETER Target
user (the default) installs under LOCALAPPDATA\Programs and adds it to the user PATH. system installs under Program Files and adds it to the machine PATH, which needs an elevated shell.
.PARAMETER Yes
Skip the confirmation prompt.
.PARAMETER Uninstall
Remove what an install of the same -Target laid down, and nothing else.
.PARAMETER Version
Print the installer's version and exit.
.PARAMETER Help
Print the options and exit.
.EXAMPLE
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1))) -Target system -Yes
#>
[CmdletBinding()]
param(
	[ValidateSet('dev', 'development', 'stable')] [string]$Release = 'stable',
	[ValidateSet('user', 'system')] [string]$Target = 'user',
	[switch]$Yes,
	[switch]$Uninstall,
	[switch]$Version,
	[switch]$Help
)

## The body runs in a scope of its own, so strict mode, the preference
## variables and every function and variable below stay out of the shell that
## piped this script into iex. The options go in as arguments, and so does
## whether a file was invoked, since inside the block $MyInvocation names the
## block: under either documented one-liner there is no script file, and `exit`
## there ends the shell that ran it. Only a file invocation may exit;
## everything else returns or throws. Piped into iex from inside another
## script, $MyInvocation names that script, but $PSCommandPath is empty, so
## the two agree only when this file is what runs.
& {
	## ShowVersion, not Version: names ignore case, and $version below is the release's.
	param([string]$Release, [string]$Target, [bool]$Yes, [bool]$Uninstall, [bool]$ShowVersion, [bool]$Help, [bool]$invokedAsFile, [string]$scriptPath)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$installerVersion = '1.1.3'

	## Every run opens with a blank line and ends with one, errors included.
	Write-Output ''

	if ($ShowVersion) {
		Write-Output "install.ps1 $installerVersion"
		Write-Output ''
		return
	}

	## Spelled out here rather than left to Get-Help: the documented one-liner pipes
	## this script straight into the shell, so there is no file left to ask about.
	if ($Help) {
		@"
install.ps1 $installerVersion - shcl installer for Windows

Usage:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1))) -Target system

Options:
    -Release <stable|dev>   stable (default): newest full release, or the
                            newest pre-release while there is no full one.
                            dev: newest release including pre-releases.
    -Target <user|system>   user (default): %LOCALAPPDATA%\Programs\Shcl, added
                            to the user PATH. No elevation needed.
                            system: C:\Program Files\Shcl, added to the
                            machine PATH (needs an elevated shell).
    -Uninstall              remove what an install of the same -Target laid
                            down, and nothing else.
    -Yes                    skip the confirmation prompt.
    -Version                print this installer's version and exit.
    -Help                   this text.

Needs Windows PowerShell 5.1 or pwsh 7. The release signature is checked
before any checksum is read out of the sums file. Nothing unverified is
installed.
"@ | Write-Output
		Write-Output ''
		return
	}

	if ($Release -eq 'development') { $Release = 'dev' }

	$repo = 'yottacore/shcl'

	function Exit-Install {
		[CmdletBinding()]
		param([string]$Message)
		if ($invokedAsFile) {
			[Console]::Error.WriteLine("install.ps1: $Message")
			[Console]::Error.WriteLine('')
			exit 1
		}
		throw "install.ps1: $Message"
	}

	## 5.0 and older have no Get-FileHash, so a download could not be checked.
	if ($PSVersionTable.PSVersion -lt [version]'5.1') {
		Exit-Install "needs Windows PowerShell 5.1 or pwsh 7, and this is $($PSVersionTable.PSVersion) - see https://aka.ms/powershell"
	}

	## Release signing key, carried as raw RSA parameters rather than PEM on purpose:
	## ImportFromPem needs PowerShell 7, and 5.1 is still what most Windows boxes
	## run. Modulus + exponent import the same on both. The sha256sums file is signed
	## offline with the matching private key, so replacing a release asset is not
	## enough - an attacker would have to forge this signature too. Baked in rather
	## than fetched, because a key downloaded over the same channel as the artifact
	## proves nothing. Rotating it means publishing a new installer.
	$signingModulus = 'k5W58wTiFTlHUCsIuHESqexain6AC8WwFmCDsjfliOIDa2vPhkSVOqMsSbYH/OL94pHZ+Bs0agNXrl99ANolzwQ4rvu6gAsc4GCb0Krbbq2B+jKqTM8xeN7tFLWKd5E08IOF2HA4ugQSlK+rC6ezbBqP1MuJFFxqxDhEtGef9v/nuhX2kWq3v0uN6Y0umbghuNAR7gmoSOwbb8uYfVOAH1OAWV2To2wyIe6WWt4BPmFJBpEI53k4rmoDVdjmJFoj2vETHmEh2QfTPA5541jPLeuO8p8V6+Aa8i32EtVeT1+ozwHidku/CZZOAdxYZ7yXAZdG3eOOxcHVfmXVwqRxPR+lA3E/KcRcN9oeeveXS35jwH0h3hSh6sJOr1q0qMtM7bB4Lxt47wXHTJ0VPneG5xbmO5pUS3LMcZwnXXavYjh2kYS52ZLhi1JbPFgPyYUiIv76IUbwtpEXbONi12g7fioZ6cStZAekJs33Wkee6NmSY54AozxTkcNUJTgs81eMa/gRL8l3jud8AWqL5vykqpG1PTN70vSgrHD4wNMp2QX29Iv+A6+FO4B1oxjrnokg212rwqX004Ep0csu/JjOl9XHvwp0Iucfi8zCg7ozDcU3dsDnUJ8A3PtJ47jEt1n37/oiM6pWDXVVBjz4DI9iACmdUphTcGhYvn91ORZVxt0='
	$signingExponent = 'AQAB'

	## PATH, idempotently - straight at the registry. [Environment]::Get expands
	## %VAR% references before returning and Set writes the result back REG_SZ,
	## which freezes every reference and downgrades the value type (user PATHs
	## commonly carry %USERPROFILE%). Reading unexpanded and writing
	## REG_EXPAND_SZ keeps the stored value intact. True when it wrote.
	function Update-ShclPath {
		## The installer's own confirm prompt is the gate; a nested -WhatIf
		## plumbing would dead-end at the irm|iex one-liner anyway.
		[CmdletBinding()]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
		param([string]$Scope, [string]$Dir, [switch]$Remove)
		$hive = if ($Scope -eq 'Machine') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
		$subkey = if ($Scope -eq 'Machine') { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { 'Environment' }
		$envKey = $hive.OpenSubKey($subkey, $true)
		try {
			$current = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
			if ($Remove) {
				## Absent is no write: the rebuild below also drops empty
				## segments, so a PATH ending in ';' read as changed and was
				## rewritten with nothing of ours in it.
				if (-not (($current -split ';') -contains $Dir)) { return $false }
				$new = @($current -split ';' | Where-Object { $_ -and $_ -ne $Dir }) -join ';'
				if ($new -eq $current) { return $false }
				$envKey.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
				return $true
			}
			if (($current -split ';') -contains $Dir) { return $false }
			$joined = if ($current -and -not $current.EndsWith(';')) { "$current;$Dir" } else { "$current$Dir" }
			$envKey.SetValue('Path', $joined, [Microsoft.Win32.RegistryValueKind]::ExpandString)
			return $true
		} finally {
			$envKey.Close()
		}
	}

	## The HTTP status behind a failed request, or 0 when there was no response
	## at all (DNS, a refused connection, a proxy, a timeout). pwsh 7 throws an
	## HttpRequestException with no Response member and 5.1 a WebException whose
	## Response is null, and strict mode throws on reading either, so the
	## network-down message could never be reached.
	function Get-HttpStatus {
		[CmdletBinding()]
		param([System.Management.Automation.ErrorRecord]$ErrorRecord)
		$response = $ErrorRecord.Exception.PSObject.Properties['Response']
		if (-not $response -or -not $response.Value) { return 0 }
		return [int]$response.Value.StatusCode
	}

	## A failed download names the file and the reason. It used to show the raw
	## exception, several lines of .NET text with the file name buried in it.
	function Save-ReleaseAsset {
		[CmdletBinding()]
		param([string]$Uri, [string]$OutFile, [string]$Name)
		try {
			Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
		} catch {
			$status = Get-HttpStatus -ErrorRecord $_
			if ($status -gt 0) { Exit-Install "download failed: $Name (HTTP $status)" }
			$ex = $_.Exception
			while ($ex.InnerException) { $ex = $ex.InnerException }
			Exit-Install "download failed: $Name ($($ex.Message))"
		}
	}

	## Why the install cannot write where it means to, or nothing when it can.
	## Asked before any download. A running shcl.exe cannot be replaced, and
	## Windows reports that as access denied at the move, which sent people
	## looking at permissions. Opening the old file with no sharing tells the
	## two apart: a running image refuses it as a sharing violation.
	function Test-InstallTarget {
		[CmdletBinding()]
		param([string]$Dest)
		$near = $Dest
		while ($near -and -not (Test-Path -LiteralPath $near)) { $near = Split-Path -Path $near -Parent }
		if (-not $near) { return "cannot write $Dest - no part of that path exists" }
		$probe = Join-Path -Path $near -ChildPath ('.shcl-probe-' + [IO.Path]::GetRandomFileName())
		try {
			[IO.File]::Create($probe, 1, [IO.FileOptions]::DeleteOnClose).Dispose()
		} catch {
			return "cannot write $Dest - $near is not writable"
		}
		$exe = Join-Path -Path $Dest -ChildPath 'shcl.exe'
		if (Test-Path -LiteralPath $exe -PathType Leaf) {
			try {
				[IO.File]::Open($exe, 'Open', 'ReadWrite', 'None').Dispose()
			} catch {
				$ex = $_.Exception
				while ($ex.InnerException) { $ex = $ex.InnerException }
				if ($ex -is [UnauthorizedAccessException]) { return "cannot replace $exe - access denied" }
				return "cannot replace $exe - it is in use. Close any running shcl and run the install again"
			}
		}
		return $null
	}

	## The shcl program that comes first on PATH when it is not $Installed, or
	## nothing. On a first install there is none at all, since only the registry
	## PATH was written, and reading .Source off nothing threw under strict mode
	## after a good install, at exit 1. An Application, so a dot-sourced shcl
	## wrapper function is not taken for a program.
	function Get-ShclShadow {
		[CmdletBinding()]
		param([string]$Installed)
		$cmd = Get-Command -Name shcl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($cmd -and $cmd.Source -ne $Installed) { return $cmd.Source }
		return $null
	}

	## Stable falls back to the newest pre-release when there is no full release
	## at all, so a first beta still installs by default.
	function Select-ReleaseTag {
		[CmdletBinding()]
		param([string]$Channel, [object[]]$Releases)
		$all = @($Releases) | Where-Object { $_.tag_name -match '^v\d+\.\d+\.\d+' }
		$all = @($all) | Where-Object { -not $_.draft }
		if ($Channel -eq 'stable') {
			$full = @($all) | Where-Object { -not $_.prerelease }
			if (@($full).Count -gt 0) { $all = $full }
		}
		$order = @(
			@{ Expression = { [version](($_.tag_name.TrimStart('v') -split '-', 2)[0]) } },
			@{ Expression = { $_.tag_name -notmatch '-' } },
			@{ Expression = { [regex]::Replace((($_.tag_name -split '-', 2) + '')[1], '\d+', [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value.PadLeft(10, '0') }) } }
		)
		@($all) | Sort-Object -Property $order | Select-Object -Last 1
	}

	## Detached PKCS#1 v1.5 / SHA-256 signature over a file. Any failure - malformed
	## key, unreadable signature, bad maths - comes back false, never an exception
	## that a caller might mistake for a pass.
	function Test-ReleaseSignature {
		[CmdletBinding()]
		param([string]$Path, [string]$SignaturePath)
		try {
			$rsa = [System.Security.Cryptography.RSA]::Create()
			$rsaParams = New-Object -TypeName System.Security.Cryptography.RSAParameters
			$rsaParams.Modulus  = [Convert]::FromBase64String($signingModulus)
			$rsaParams.Exponent = [Convert]::FromBase64String($signingExponent)
			$rsa.ImportParameters($rsaParams)
			return $rsa.VerifyData(
				[System.IO.File]::ReadAllBytes($Path),
				[System.IO.File]::ReadAllBytes($SignaturePath),
				[System.Security.Cryptography.HashAlgorithmName]::SHA256,
				[System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
		} catch {
			return $false
		}
	}

	## Runs `EXE version` and hands back its exit code and output. Redirected and
	## status-tested rather than called bare, since a nonzero exit from a native
	## command throws under this script's own error preference on 7.4 and later.
	## Windows PowerShell 5.1 turns a native command's stderr into error records
	## under this redirect, and a Stop preference then throws before the exit
	## code is read, so the preference is Continue in here. A program that never
	## starts (blocked by AV or AppLocker) does not touch $LASTEXITCODE, and the
	## 0 tar left there read as a pass. So it is set to -1 first, and a start
	## failure that throws comes back as -1 too.
	function Invoke-ShclSmoke {
		[CmdletBinding()]
		param([string]$Exe)
		$ErrorActionPreference = 'Continue'
		## The global is the one a native command sets; a local would shadow it.
		$global:LASTEXITCODE = -1
		try {
			$out = & $Exe version 2>&1
			return @{ Code = $global:LASTEXITCODE; Out = $out }
		} catch {
			return @{ Code = -1; Out = $_.Exception.Message }
		}
	}

	## Removes the files an install writes, by name, the staging name an
	## interrupted install leaves, and each install dir once it is empty.
	## Deleting the whole code\ and scripts\ trees took whatever else someone
	## had put there, and a populated dir stays, since the setup .exe installs
	## here too. Hands back what would not go and whether anything this
	## installer did not write is left, since a locked file left behind used
	## to be reported as someone else's. What is left is judged by name within
	## its own dir: a full path read back can be spelled differently from the
	## one given, as a short 8.3 name is.
	function Remove-ShclFile {
		[CmdletBinding()]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
		param([string]$Dest)
		$layout = @(
			@{ Dir = (Join-Path -Path $Dest -ChildPath 'code'); Names = @('lib.rs', 'shcl.go', 'shcl.py', 'shcl.h', 'shcl.hpp') },
			@{ Dir = (Join-Path -Path $Dest -ChildPath 'scripts'); Names = @('shcl.ps1', 'shcl.bash') },
			@{ Dir = $Dest; Names = @('shcl.exe', '.shcl.exe.new', 'code', 'scripts') }
		)
		$stuck = [System.Collections.Generic.List[string]]::new()
		$foreign = $false
		foreach ($part in $layout) {
			if (-not (Test-Path -LiteralPath $part.Dir)) { continue }
			foreach ($name in $part.Names) {
				$path = Join-Path -Path $part.Dir -ChildPath $name
				if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
				try { Remove-Item -Force -LiteralPath $path -ErrorAction Stop } catch { $stuck.Add($path) }
			}
			$entries = @(Get-ChildItem -Force -LiteralPath $part.Dir)
			if ($entries.Count -eq 0) {
				try { Remove-Item -Force -LiteralPath $part.Dir -ErrorAction Stop } catch { $stuck.Add($part.Dir) }
			} elseif (@($entries | Where-Object { $part.Names -notcontains $_.Name }).Count -gt 0) {
				$foreign = $true
			}
		}
		[PSCustomObject]@{ Stuck = $stuck.ToArray(); Foreign = $foreign }
	}

	## Windows only; elsewhere install.bash (Linux) or build from source.
	if (($PSVersionTable.PSVersion.Major -ge 6) -and -not $IsWindows) {
		Exit-Install 'this installer is for Windows - on Linux use install.bash, elsewhere build from source (see README.md)'
	}

	## Destinations. A system install writes under Program Files and the machine
	## PATH, so it needs an elevated shell.
	if ($Target -eq 'system') {
		$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
		if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
			Exit-Install 'a system install needs an elevated shell (or pass -Target user)'
		}
		## A 32-bit host reads Program Files (x86) out of ProgramFiles, which is
		## the wrong home for a 64-bit binary. ProgramW6432 is the 64-bit one and
		## is only set where the two differ.
		$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
		$dest = Join-Path -Path $programFiles -ChildPath 'Shcl'
		$pathScope = 'Machine'
		$pathDir = $dest
	} else {
		## Per-user apps belong under LOCALAPPDATA\Programs - it is where Windows
		## itself puts them, and it is already excluded from roaming profiles.
		$dest = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Shcl'
		$pathScope = 'User'
		$pathDir = $dest
	}

	## Uninstall: the reverse of what the install lays down, and nothing else - the
	## binary, the two payload dirs, the install dir if it empties, and the PATH
	## entry. Never a recursive delete of a path the user may have pointed elsewhere.
	## It sits above the release lookup on purpose: removing needs no release to
	## exist, and offline or rate-limited it used to refuse and remove nothing.
	if ($Uninstall) {
		## Nothing of an install here: say so rather than "removed". A system
		## install from before user became the default is the usual case. A PATH
		## entry left behind still goes.
		if (-not (Test-Path -LiteralPath $dest)) {
			if (Update-ShclPath -Scope $pathScope -Dir $pathDir -Remove) {
				Write-Output "removed the $pathScope PATH entry; nothing else of shcl was in $dest"
			} else {
				Write-Output "nothing to remove: no shcl install in $dest"
			}
			$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
			if ($Target -eq 'user' -and (Test-Path -LiteralPath (Join-Path -Path $programFiles -ChildPath 'Shcl'))) {
				Write-Output "a system install is in $programFiles\Shcl; -Target system removes that one, from an elevated shell"
			}
			Write-Output ''
			return
		}
		## The setup .exe writes this same directory and registers itself with
		## Add/Remove Programs. Deleting its files here would leave that entry
		## pointing at nothing, so its own uninstaller has to run instead.
		$setupUninstaller = Join-Path -Path $dest -ChildPath 'uninstall.exe'
		if (Test-Path -LiteralPath $setupUninstaller) {
			Exit-Install "$dest was installed by the shcl setup - remove it from Add/Remove Programs, or run $setupUninstaller"
		}
		Write-Output "removing shcl: $dest (and the $pathScope PATH entry)"
		if (-not $Yes) {
			$reply = Read-Host 'Proceed? [y/N]'
			if ($reply -notin @('y', 'Y', 'yes', 'Yes', 'YES')) {
				Write-Output 'aborted'
				Write-Output ''
				if ($invokedAsFile) { exit 1 }
				return
			}
		}
		## A file that would not go is most likely a running shcl.exe, so the
		## PATH entry stays with it and a second run finishes the job.
		$removal = Remove-ShclFile -Dest $dest
		if ($removal.Stuck.Count -gt 0) {
			Exit-Install "could not remove $($removal.Stuck -join ', ') - close any running shcl and run the uninstall again"
		}
		$null = Update-ShclPath -Scope $pathScope -Dir $pathDir -Remove
		if ($removal.Foreign) {
			Write-Output 'removed what this installer laid down'
			Write-Output "left $dest in place: it holds files this installer did not put there"
		} else {
			Write-Output 'removed'
		}
		Write-Output ''
		return
	}

	## A 32-bit shell on a 64-bit OS reports x86; ARCHITEW6432 carries the real arch.
	$archRaw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
	$arch = switch ($archRaw) {
		'AMD64' { 'x86_64' }
		'ARM64' { 'arm64' }
		default { Exit-Install "no prebuilt binary for $archRaw" }
	}

	## Transport floor for every download: TLS 1.2+ (1.3 where the runtime knows it).
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
	} catch {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	}
	## Windows PowerShell repaints the progress bar per chunk, which slows a download
	## by an order of magnitude. Scoped to this script; nothing here needs the bar.
	$ProgressPreference = 'SilentlyContinue'

	## Resolve the tag. Highest version wins, never newest by date: GitHub's
	## /releases/latest is date-ordered, so a patch back-ported to an older line
	## after a newer one shipped would be handed out as "stable". A draft has no
	## published assets, so neither channel can install one; stable drops
	## pre-releases on top of that. Within one version a
	## final outranks its own pre-releases (v2.0.0-rc1 < v2.0.0); a pre-release
	## suffix compares with its digit runs zero-padded, so rc2 < rc10 - the same
	## order install.bash gets from sort -V.
	$api = "https://api.github.com/repos/$repo/releases?per_page=100"
	## A 403 from an unauthenticated request is the API's rate limit, and behind
	## a shared address it is common - "none published yet, or network down"
	## sent people looking in the wrong place. GITHUB_TOKEN is used when set.
	$apiHeaders = @{}
	if ($env:GITHUB_TOKEN) { $apiHeaders['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
	try {
		$rel = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers $apiHeaders
	} catch {
		$status = Get-HttpStatus -ErrorRecord $_
		if ($status -eq 403 -or $status -eq 429) {
			Exit-Install "GitHub's API refused the request (rate limit). Wait, or set GITHUB_TOKEN to a token with public read access and re-run"
		}
		if ($status -eq 401) {
			Exit-Install 'GitHub rejected the credentials in GITHUB_TOKEN - unset it, or replace it with one that has public read access'
		}
		Exit-Install "cannot fetch the $Release release (none published yet, or network down)"
	}
	$rel = Select-ReleaseTag -Channel $Release -Releases $rel
	if (-not $rel -or -not $rel.tag_name) { Exit-Install "no $Release release found" }
	$tag = $rel.tag_name
	$version = $tag.TrimStart('v')
	$channel = $Release
	if ($Release -eq 'stable' -and $rel.prerelease) { $channel = 'stable, but no full release yet, so the newest pre-release' }

	## The drop-in payload is a tar.gz. Windows 10 1803 and Server 2019 ship tar;
	## anything older finds out here, before a download, not after.
	if (-not (Get-Command -Name tar -ErrorAction SilentlyContinue)) {
		Exit-Install 'needs tar to unpack the drop-in payload (Windows 10 1803, Server 2019 and later ship it) - on an older Windows use the setup .exe from the releases page'
	}

	## State the plan, then confirm.
	$existing = if (Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'shcl.exe')) { 'updates the existing install' } else { 'new install' }
	Write-Output "shcl $version ($channel, windows-$arch) -> $dest ($existing)"
	Write-Output "  from     https://github.com/$repo/releases/tag/$tag"
	Write-Output "  binary   $dest\shcl.exe"
	Write-Output "  drop-ins $dest\code\, wrappers $dest\scripts\"
	Write-Output "  adds $pathDir to the $pathScope PATH if missing"
	if (-not $Yes) {
		$reply = Read-Host 'Proceed? [y/N]'
		if ($reply -notin @('y', 'Y', 'yes', 'Yes', 'YES')) {
			Write-Output 'aborted'
			Write-Output ''
			if ($invokedAsFile) { exit 1 }
			return
		}
	}

	$targetProblem = Test-InstallTarget -Dest $dest
	if ($targetProblem) {
		if ($Target -eq 'system') { Exit-Install $targetProblem }
		Exit-Install "$targetProblem (check that the folder is not read-only, and that antivirus is not blocking it)"
	}

	$tmp = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('shcl-install-' + [IO.Path]::GetRandomFileName())
	New-Item -ItemType Directory -Path $tmp | Out-Null
	try {
		## Download and verify the binary.
		Write-Output ''
		$asset = "shcl-$version-windows-$arch.exe"
		$tmpExe = Join-Path -Path $tmp -ChildPath 'shcl.exe'
		$sums = Join-Path -Path $tmp -ChildPath 'sums.txt'
		$sumsSig = Join-Path -Path $tmp -ChildPath 'sums.txt.sig'
		$base = "https://github.com/$repo/releases/download/$tag"
		Write-Output "downloading $asset..."
		Save-ReleaseAsset -Uri "$base/$asset" -OutFile $tmpExe -Name $asset
		Save-ReleaseAsset -Uri "$base/shcl-$version-sha256sums.txt" -OutFile $sums -Name 'sha256sums'
		Save-ReleaseAsset -Uri "$base/shcl-$version-sha256sums.txt.sig" -OutFile $sumsSig -Name 'sha256sums signature'

		## Check the signature before trusting anything the sums file says. Order is
		## the whole point: a checksum read out of an unverified file proves nothing.
		if (-not (Test-ReleaseSignature -Path $sums -SignaturePath $sumsSig)) {
			Exit-Install 'signature check failed on sha256sums - refusing to install'
		}

		## Anchored on the name, the way install.bash greps it: the sums file has a
		## line per binary and per package, and an unanchored match would take
		## whichever of those came first once one asset name contains another.
		$want = (Get-Content -LiteralPath $sums | Where-Object { $_ -cmatch ('\s' + [regex]::Escape($asset) + '$') } | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmpExe).Hash.ToLower()
		if (-not $want -or $got -ne $want.ToLower()) { Exit-Install "sha256 mismatch on $asset" }

		## Drop-in code files and wrappers come from a release asset covered by the
		## same signed sums file as the binary. They used to come from GitHub's
		## generated source zipball, which carries neither a signature nor a
		## checksum. Releases predating the asset install the binary alone.
		$dropins = "shcl-$version-dropins.tar.gz"
		$wantSrc = (Get-Content -LiteralPath $sums | Where-Object { $_ -cmatch ('\s' + [regex]::Escape($dropins) + '$') } | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
		$haveDropins = $false
		$srcroot = $null
		if ($wantSrc) {
			Write-Output "downloading $dropins..."
			Save-ReleaseAsset -Uri "$base/$dropins" -OutFile (Join-Path -Path $tmp -ChildPath 'dropins.tgz') -Name $dropins
			$gotSrc = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $tmp -ChildPath 'dropins.tgz')).Hash.ToLower()
			if ($gotSrc -ne $wantSrc.ToLower()) { Exit-Install "sha256 mismatch on $dropins" }
			$unpackDir = Join-Path -Path $tmp -ChildPath 'x'
			New-Item -ItemType Directory -Path $unpackDir | Out-Null
			tar -xzf (Join-Path -Path $tmp -ChildPath 'dropins.tgz') -C $unpackDir
			if ($LASTEXITCODE -ne 0) { Exit-Install "cannot unpack $dropins" }
			$srcroot = Get-Item -LiteralPath $unpackDir
			$haveDropins = $true
		}

		## Run it from the temp dir before anything is written, the way the Linux
		## installer does: a binary that will not start here should never become
		## an install.
		$smoke = Invoke-ShclSmoke -Exe $tmpExe
		$smokeOut = $smoke.Out
		if ($smoke.Code -ne 0) {
			Exit-Install "the downloaded shcl.exe does not run here: $($smokeOut -join ' ')"
		}

		## Install. The binary goes in via a temp name + Move-Item in the same dir,
		## so a running copy only ever sees the complete old or new file.
		## A failure here is one message, not the raw exception.
		try {
			New-Item -ItemType Directory -Force -Path $dest | Out-Null
			Copy-Item -LiteralPath $tmpExe -Destination (Join-Path -Path $dest -ChildPath '.shcl.exe.new')
			Move-Item -Force -LiteralPath (Join-Path -Path $dest -ChildPath '.shcl.exe.new') -Destination (Join-Path -Path $dest -ChildPath 'shcl.exe')
			if ($haveDropins) {
				New-Item -ItemType Directory -Force -Path (Join-Path -Path $dest -ChildPath 'code'), (Join-Path -Path $dest -ChildPath 'scripts') | Out-Null
				$payloadRoot = $srcroot.FullName
				Copy-Item -LiteralPath "$payloadRoot\source\rust\src\lib.rs", "$payloadRoot\source\go\shcl.go", "$payloadRoot\source\python\shcl.py", "$payloadRoot\source\c\shcl.h", "$payloadRoot\source\c\shcl.hpp" -Destination (Join-Path -Path $dest -ChildPath 'code')
				Copy-Item -LiteralPath "$payloadRoot\source\powershell\shcl.ps1", "$payloadRoot\source\bash\shcl.bash" -Destination (Join-Path -Path $dest -ChildPath 'scripts')
			}
		} catch {
			$ex = $_.Exception
			while ($ex.InnerException) { $ex = $ex.InnerException }
			Exit-Install "cannot write $dest - $($ex.Message)"
		}

		if (Update-ShclPath -Scope $pathScope -Dir $pathDir) {
			Write-Output "added $pathDir to the $pathScope PATH (new shells pick it up)"
			## Nudge running shells; best-effort.
			try {
				$sig = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
				$w32 = Add-Type -MemberDefinition $sig -Name 'ShclEnvBroadcast' -Namespace 'Win32' -PassThru
				$out = [UIntPtr]::Zero
				$null = $w32::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$out)
			} catch {
				Write-Output 'PATH change broadcast skipped (new shells still pick it up)'
			}
		}

		Write-Output ''
		Write-Output "installed shcl $version -> $dest\shcl.exe"
		## Written over a setup install: its Add/Remove Programs entry still
		## names the version it put there, which is no longer what is on disk.
		if (Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'uninstall.exe')) {
			Write-Output "note: $dest came from the shcl setup - its Add/Remove Programs entry still shows the version it installed"
		}
		if (-not $haveDropins) { Write-Output "note: this release ships no signed drop-in payload, so $dest\code and $dest\scripts were skipped - take them from the repo if you want them" }
		$rerun = if ($invokedAsFile) { "& '$scriptPath'" } else { '& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1)))' }
		Write-Output "to remove it again: $rerun -Uninstall -Target $Target"
		## And what `shcl` actually resolves to: the receipt below runs the copy
		## just written, so another one earlier on PATH used to be invisible
		## here. A user install cannot get ahead of a machine one - windows puts
		## the machine entries first - so a setup.exe install shadows it until
		## that one is removed, and saying so is all this can do.
		$onPath = Get-ShclShadow -Installed "$dest\shcl.exe"
		if ($onPath) {
			Write-Output "note: shcl on your PATH is $onPath, not the copy just installed - it comes first on PATH"
		}
		## Already proved above, from the temp dir; this line is the receipt.
		Write-Output $smokeOut
		Write-Output ''
	} finally {
		Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
	}
} $Release $Target $Yes $Uninstall $Version $Help ($MyInvocation.MyCommand -is [Management.Automation.ExternalScriptInfo] -and $MyInvocation.MyCommand.Path -eq $PSCommandPath) $PSCommandPath
