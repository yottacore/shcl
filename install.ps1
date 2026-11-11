#==============================================================================
## install.ps1
##
##	Release installer for shcl (Simple Hierarchical Config Language) on Windows.
##	It downloads the latest release from GitHub, checks the sha256sums file
##	against the release signing key before it trusts any checksum in it, and
##	lays out the binary and the drop-in source files. Running it again updates
##	an existing install in place, and removes the retired shell wrappers that an
##	older install put in scripts\.
##
##	Usage (one-liner, defaults):
##		irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1 | iex
##	With options, download it first or wrap it in a script block:
##		& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1))) -Target system -Yes
##
##	Options:
##		-Release <stable|dev>   stable (default): newest full release, or the
##		                        newest pre-release while there is no full one.
##		                        dev: newest release including pre-releases.
##		-Target <user|system>   user (default): %LOCALAPPDATA%\Programs\Shcl,
##		                        added to the user PATH. No elevation.
##		                        system: C:\Program Files\Shcl, added to the
##		                        machine PATH (needs an elevated shell).
##		-Uninstall              remove what an install of the same -Target laid
##		                        down (binary, code\, PATH entry, and an older
##		                        install's scripts\).
##		-Yes                    skip the confirmation prompt.
##		-Version                print this installer's version and exit.
##		-Help                   print the options and exit.
##
##	It needs Windows PowerShell 5.1 or pwsh 7.
##
##	Layout under the install dir:
##		shcl.exe    the CLI binary
##		code\       drop-in single-file bindings (lib.rs, shcl.go, shcl.py,
##		            shcl.h, shcl.hpp)
#==============================================================================

##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Installs, updates, or removes the shcl release binary on Windows.
.DESCRIPTION
Downloads a release from GitHub, checks the signed sha256sums file before trusting a checksum out of it, and installs the binary and the drop-in source files. Re-running updates an install in place, and removes the shell wrappers an older install put in scripts\.
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
## variables, and every function and variable below stay out of the shell that
## piped this script into iex. The options go in as arguments, and so does
## whether a file was invoked, since inside the block $MyInvocation names the
## block. Under either documented one-liner there isn't a script file, and
## `exit` there ends the shell that ran it. Only a file invocation may exit,
## and everything else returns or throws. When this script is piped into iex
## from inside another script, $MyInvocation names that script but
## $PSCommandPath is empty, so the two agree only when this file is what runs.
& {
	## ShowVersion, not Version: names ignore case, and $version below is the release's.
	param([string]$Release, [string]$Target, [bool]$Yes, [bool]$Uninstall, [bool]$ShowVersion, [bool]$Help, [bool]$invokedAsFile, [string]$scriptPath)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$installerVersion = '1.3.0'

	## Every run opens with a blank line and ends with one, errors included.
	Write-Output ''

	if ($ShowVersion) {
		Write-Output "install.ps1 $installerVersion"
		Write-Output ''
		return
	}

	## The help is written out here rather than left to Get-Help, because the
	## documented one-liner pipes this script straight into the shell, so there
	## isn't a file for Get-Help to read.
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
    -Help                   print this text and exit.

It needs Windows PowerShell 5.1 or pwsh 7. The release signature is checked
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

	## 5.0 and older don't have Get-FileHash, so a download couldn't be checked.
	if ($PSVersionTable.PSVersion -lt [version]'5.1') {
		Exit-Install "needs Windows PowerShell 5.1 or pwsh 7, and this is $($PSVersionTable.PSVersion) - see https://aka.ms/powershell"
	}

	## Release signing key. It's stored as raw RSA parameters rather than PEM,
	## because ImportFromPem needs PowerShell 7, and most Windows boxes still run
	## 5.1. The modulus and exponent import the same on both. The sha256sums file
	## is signed offline with the matching private key, so an attacker who
	## replaces a release asset would also have to forge this signature. The key
	## is baked in rather than fetched, because a key downloaded over the same
	## channel as the artifact proves nothing. Rotating it means publishing a new
	## installer.
	$signingModulus = 'k5W58wTiFTlHUCsIuHESqexain6AC8WwFmCDsjfliOIDa2vPhkSVOqMsSbYH/OL94pHZ+Bs0agNXrl99ANolzwQ4rvu6gAsc4GCb0Krbbq2B+jKqTM8xeN7tFLWKd5E08IOF2HA4ugQSlK+rC6ezbBqP1MuJFFxqxDhEtGef9v/nuhX2kWq3v0uN6Y0umbghuNAR7gmoSOwbb8uYfVOAH1OAWV2To2wyIe6WWt4BPmFJBpEI53k4rmoDVdjmJFoj2vETHmEh2QfTPA5541jPLeuO8p8V6+Aa8i32EtVeT1+ozwHidku/CZZOAdxYZ7yXAZdG3eOOxcHVfmXVwqRxPR+lA3E/KcRcN9oeeveXS35jwH0h3hSh6sJOr1q0qMtM7bB4Lxt47wXHTJ0VPneG5xbmO5pUS3LMcZwnXXavYjh2kYS52ZLhi1JbPFgPyYUiIv76IUbwtpEXbONi12g7fioZ6cStZAekJs33Wkee6NmSY54AozxTkcNUJTgs81eMa/gRL8l3jud8AWqL5vykqpG1PTN70vSgrHD4wNMp2QX29Iv+A6+FO4B1oxjrnokg212rwqX004Ep0csu/JjOl9XHvwp0Iucfi8zCg7ozDcU3dsDnUJ8A3PtJ47jEt1n37/oiM6pWDXVVBjz4DI9iACmdUphTcGhYvn91ORZVxt0='
	$signingExponent = 'AQAB'

	## Adds or removes the PATH entry directly in the registry, and running it
	## twice changes nothing. [Environment]::Get expands %VAR% references before
	## returning, and Set writes the result back as REG_SZ, which freezes every
	## reference and downgrades the value type. User PATHs often contain
	## %USERPROFILE%. Reading unexpanded and writing REG_EXPAND_SZ leaves the
	## stored value intact. It returns true when it wrote.
	function Update-ShclPath {
		## The installer's own confirm prompt is the gate. A nested -WhatIf
		## would dead-end at the irm|iex one-liner anyway.
		[CmdletBinding()]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
		param([string]$Scope, [string]$Dir, [switch]$Remove)
		$hive = if ($Scope -eq 'Machine') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
		$subkey = if ($Scope -eq 'Machine') { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { 'Environment' }
		$envKey = $hive.OpenSubKey($subkey, $true)
		try {
			$current = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
			if ($Remove) {
				## When our entry is absent, don't write anything. The rebuild
				## below also drops empty segments, so a PATH ending in ';' read
				## as changed and was rewritten without anything of ours in it.
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

	## Returns the HTTP status behind a failed request, or 0 when there wasn't
	## any response, as with DNS, a refused connection, a proxy, or a timeout.
	## pwsh 7 throws an HttpRequestException without a Response member, and 5.1
	## throws a WebException whose Response is null. Strict mode throws on
	## reading either, so the network-down message could never be reached.
	function Get-HttpStatus {
		[CmdletBinding()]
		param([System.Management.Automation.ErrorRecord]$ErrorRecord)
		$response = $ErrorRecord.Exception.PSObject.Properties['Response']
		if (-not $response -or -not $response.Value) { return 0 }
		return [int]$response.Value.StatusCode
	}

	## A failed download names the file and the reason. It used to show the raw
	## exception, which was several lines of .NET text with the file name buried
	## in it.
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

	## Returns why the install can't write where it means to, or nothing when it
	## can. It's asked before any download. A running shcl.exe can't be
	## replaced, and Windows reports that as access denied at the move, which
	## sent people looking at permissions. Opening the old file without sharing
	## tells the two apart, because a running image refuses it as a sharing
	## violation.
	function Test-InstallTarget {
		[CmdletBinding()]
		param([string]$Dest)
		$near = $Dest
		while ($near -and -not (Test-Path -LiteralPath $near)) { $near = Split-Path -Path $near -Parent }
		if (-not $near) { return "can't write $Dest - no part of that path exists" }
		$probe = Join-Path -Path $near -ChildPath ('.shcl-probe-' + [IO.Path]::GetRandomFileName())
		try {
			[IO.File]::Create($probe, 1, [IO.FileOptions]::DeleteOnClose).Dispose()
		} catch {
			return "can't write $Dest - $near isn't writable"
		}
		$exe = Join-Path -Path $Dest -ChildPath 'shcl.exe'
		if (Test-Path -LiteralPath $exe -PathType Leaf) {
			try {
				[IO.File]::Open($exe, 'Open', 'ReadWrite', 'None').Dispose()
			} catch {
				$ex = $_.Exception
				while ($ex.InnerException) { $ex = $ex.InnerException }
				if ($ex -is [UnauthorizedAccessException]) { return "can't replace $exe - access denied" }
				return "can't replace $exe - it's in use. Close any running shcl and run the install again"
			}
		}
		return $null
	}

	## Returns the shcl program that comes first on PATH when it isn't
	## $Installed, or nothing. On a first install there isn't one at all, since
	## only the registry PATH was written, and reading .Source off nothing threw
	## under strict mode after a good install, at exit 1. It asks for an
	## Application, so a dot-sourced shcl wrapper function isn't taken for a
	## program.
	function Get-ShclShadow {
		[CmdletBinding()]
		param([string]$Installed)
		$cmd = Get-Command -Name shcl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($cmd -and $cmd.Source -ne $Installed) { return $cmd.Source }
		return $null
	}

	## Stable falls back to the newest pre-release when there isn't any full
	## release, so a first beta still installs by default.
	function Select-ReleaseTag {
		[CmdletBinding()]
		param([string]$Channel, [object[]]$Releases)
		$all = @($Releases) | Where-Object { $_.tag_name -match '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' }
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

	## Checks a detached PKCS#1 v1.5 SHA-256 signature over a file. Any failure,
	## such as a malformed key, an unreadable signature, or bad math, comes back
	## false, never as an exception that a caller might mistake for a pass.
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

	## Runs `EXE --version` and returns its exit code and output. The call is
	## redirected and its status tested rather than called bare, since a nonzero
	## exit from a native command throws under this script's own error
	## preference on 7.4 and later. Windows PowerShell 5.1 turns a native
	## command's stderr into error records under this redirect, and a Stop
	## preference then throws before the exit code is read, so the preference is
	## Continue in here. A program that never starts, because AV or AppLocker
	## blocked it, doesn't touch $LASTEXITCODE, and the 0 that tar left there
	## read as a pass. So it's set to -1 first, and a start failure that throws
	## comes back as -1 too.
	function Invoke-ShclSmoke {
		[CmdletBinding()]
		param([string]$Exe)
		$ErrorActionPreference = 'Continue'
		## A native command sets the global, and a local would shadow it.
		$global:LASTEXITCODE = -1
		## shcl writes UTF-8, and PowerShell decodes a native command's output
		## with the console's code page, so under the usual 437 the copyright
		## line in the receipt came back garbled. The encoding is put back
		## after, since under iex this is the caller's own console. A host
		## without a console can refuse the set, and then the output stays as
		## it was.
		$oldEncoding = $null
		try {
			$oldEncoding = [Console]::OutputEncoding
			[Console]::OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
		} catch {
			$oldEncoding = $null
		}
		try {
			$out = & $Exe --version 2>&1
			return @{ Code = $global:LASTEXITCODE; Out = $out }
		} catch {
			return @{ Code = -1; Out = $_.Exception.Message }
		} finally {
			if ($oldEncoding) {
				try { [Console]::OutputEncoding = $oldEncoding } catch { $null = $_ }
			}
		}
	}

	## Returns the version the installed binary reports, or nothing when it
	## doesn't run. The binary itself is asked, so an install from before this
	## check counts too.
	function Get-InstalledVersion {
		[CmdletBinding()]
		param([string]$Exe)
		$run = Invoke-ShclSmoke -Exe $Exe
		if ($run.Code -ne 0) { return '' }
		$first = "$(@($run.Out)[0])"
		if ($first -match '^shcl v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)') { return $Matches[1] }
		return ''
	}

	## Is A older than B? It uses the same order that Select-ReleaseTag ranks
	## tags in.
	function Test-OlderVersion {
		[CmdletBinding()]
		param([string]$Older, [string]$Newer)
		if ($Older -eq $Newer) { return $false }
		$pair = @($Older, $Newer) | ForEach-Object { [PSCustomObject]@{ tag_name = "v$_"; draft = $false; prerelease = $false } }
		(Select-ReleaseTag -Channel dev -Releases $pair).tag_name -eq "v$Newer"
	}

	## Use Windows' own tar, by full path. A GNU tar from Git for Windows, MSYS2,
	## or Cygwin ahead of System32 on PATH reads C:\... as a remote host and
	## file, so a lookup by name couldn't unpack the payload. The exit code is
	## left in $LASTEXITCODE for the caller.
	function Get-ShclTar {
		[CmdletBinding()]
		param()
		Join-Path -Path $env:SystemRoot -ChildPath 'System32\tar.exe'
	}
	function Expand-ShclPayload {
		[CmdletBinding()]
		param([string]$Archive, [string]$Dest)
		& (Get-ShclTar) -xzf $Archive -C $Dest
	}

	## Removes the files an install writes, by name, the staging name that an
	## interrupted install leaves, and each install dir once it's empty.
	## scripts\ is from an install before the wrappers were retired.
	## Deleting the whole code\ and scripts\ trees took whatever else someone
	## had put there, and a dir with other files in it stays, since the setup
	## .exe installs here too. It returns what wouldn't go, and whether
	## anything this installer didn't write is left, because a locked file
	## left behind used to be reported as someone else's. What's left is
	## judged by name within its own dir, because a full path that's read back
	## can be written differently from the one given, as a short 8.3 name is.
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

	## The shell wrappers are retired to project/legacy/. An update removes the
	## copies an older install left in scripts\, and the dir once that empties
	## it. A file that won't go stays, since the wrapper was only ever extra.
	function Remove-OldWrapper {
		[CmdletBinding()]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
		param([string]$Dest)
		$dir = Join-Path -Path $Dest -ChildPath 'scripts'
		if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
		foreach ($name in 'shcl.ps1', 'shcl.bash') {
			$path = Join-Path -Path $dir -ChildPath $name
			if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -Force -LiteralPath $path -ErrorAction SilentlyContinue }
		}
		if (@(Get-ChildItem -Force -LiteralPath $dir).Count -eq 0) { Remove-Item -Force -LiteralPath $dir -ErrorAction SilentlyContinue }
	}

	## This is a copy of the function in cicd/utility/include/safe-rm.ps1, since
	## under irm there isn't a file beside this one to load. shell-regress checks
	## that the two have the same text.
	function Remove-SafeTree {
		[CmdletBinding()]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
		param([string]$Parent, [string]$Path)
		$reparse = [IO.FileAttributes]::ReparsePoint
		$readOnly = [IO.FileAttributes]::ReadOnly
		$sep = [IO.Path]::DirectorySeparatorChar
		$case = [StringComparison]::Ordinal
		if ($sep -eq '\') { $case = [StringComparison]::OrdinalIgnoreCase }
		$top = "$Parent".TrimEnd('\', '/')
		$p = "$Path".TrimEnd('\', '/')
		## By segment, not GetFullPath, which on 5.1 can spell out an 8.3 name.
		$full = $p -notmatch '[\r\n]'
		foreach ($q in $p, $top) {
			if ($sep -eq '\' -and $q -match '^[A-Za-z]:\\') { $q = $q.Substring(3) }
			elseif ($sep -eq '\' -and $q -match '^\\\\[^\\]') { $q = $q.Substring(2) }
			elseif ($sep -eq '/' -and $q.StartsWith('/')) { $q = $q.Substring(1) }
			else { $full = $false }
			foreach ($seg in $q -split '[\\/]') { if ($seg -in '', '.', '..') { $full = $false } }
		}
		$why = ''
		if (-not $full) { $why = 'bad path' }
		elseif (-not $p.StartsWith($top + $sep, $case)) { $why = "not under $top" }
		else {
			for ($x = $p; $x.Length -gt $top.Length; $x = $x.Substring(0, $x.LastIndexOf($sep))) {
				$info = [IO.DirectoryInfo]::new($x)
				if (-not $info.Exists) { $why = 'not there'; break }
				if ($info.Attributes -band $reparse) {
					$why = 'goes through a link'
					if ($x -eq $p) { $why = 'a link' }
					break
				}
			}
		}
		if ($why) { Write-Error "safe-rm: refused, ${why}: $Path"; return }
		try {
			$dirs = [Collections.Generic.List[IO.DirectoryInfo]]::new()
			$dirs.Add([IO.DirectoryInfo]::new($p))
			for ($i = 0; $i -lt $dirs.Count; $i++) {
				$d = $dirs[$i]
				if ($d.Attributes -band $readOnly) { $d.Attributes = $d.Attributes -bxor $readOnly }
				foreach ($entry in $d.GetFileSystemInfos()) {
					if ($entry.Attributes -band $reparse) { $entry.Delete() }
					elseif ($entry -is [IO.DirectoryInfo]) { $dirs.Add($entry) }
					else {
						if ($entry.IsReadOnly) { $entry.IsReadOnly = $false }
						$entry.Delete()
					}
				}
			}
			for ($i = $dirs.Count - 1; $i -ge 0; $i--) { $dirs[$i].Delete() }
		} catch {
			Write-Error "safe-rm: could not remove ${Path}: $($_.Exception.Message)"
		}
	}

	## This installer is for Windows only. Linux, macOS, and FreeBSD use
	## install.bash, and anything else builds from source.
	if (($PSVersionTable.PSVersion.Major -ge 6) -and -not $IsWindows) {
		Exit-Install 'this installer is for Windows - on Linux, macOS, or FreeBSD use install.bash, and elsewhere build from source, as described in https://github.com/yottacore/shcl/blob/main/project/install.md#diy-install'
	}

	## A system install writes under Program Files and the machine PATH, so it
	## needs an elevated shell.
	if ($Target -eq 'system') {
		$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
		if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
			Exit-Install 'a system install needs an elevated shell (or pass -Target user)'
		}
		## A 32-bit host reads Program Files (x86) out of ProgramFiles, which is
		## the wrong place for a 64-bit binary. ProgramW6432 is the 64-bit one,
		## and it's only set where the two differ.
		$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
		$dest = Join-Path -Path $programFiles -ChildPath 'Shcl'
		$pathScope = 'Machine'
		$pathDir = $dest
	} else {
		## Per-user apps belong under LOCALAPPDATA\Programs. Windows itself puts
		## them there, and it's already excluded from roaming profiles.
		$dest = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Shcl'
		$pathScope = 'User'
		$pathDir = $dest
	}

	## The uninstall reverses what the install lays down, and nothing else. It
	## removes the binary, the 2 payload dirs, the install dir if it empties,
	## and the PATH entry. It never deletes recursively, since the user may have
	## pointed a path elsewhere. It comes before the release lookup, because
	## removing doesn't need a release to exist, and offline or rate-limited it
	## used to refuse and remove nothing.
	if ($Uninstall) {
		## When there's nothing of an install here, say so rather than
		## "removed". The usual case is a system install from before user became
		## the default. A PATH entry left behind still goes.
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
		## pointing at nothing, so the setup's own uninstaller has to run
		## instead.
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
			Exit-Install "couldn't remove $($removal.Stuck -join ', ') - close any running shcl and run the uninstall again"
		}
		$null = Update-ShclPath -Scope $pathScope -Dir $pathDir -Remove
		if ($removal.Foreign) {
			Write-Output 'removed what this installer laid down'
			Write-Output "left $dest in place, since it has files this installer didn't put there"
		} else {
			Write-Output 'removed'
		}
		Write-Output ''
		return
	}

	## A 32-bit shell on a 64-bit OS reports x86; ARCHITEW6432 has the real arch.
	$archRaw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
	$arch = switch ($archRaw) {
		'AMD64' { 'x86_64' }
		'ARM64' { 'arm64' }
		default { Exit-Install "no prebuilt binary for $archRaw" }
	}

	## Every download needs TLS 1.2 or newer, and 1.3 where the runtime knows it.
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
	} catch {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	}
	## Windows PowerShell repaints the progress bar per chunk, which slows a
	## download by an order of magnitude. The setting is scoped to this script,
	## and nothing here needs the bar.
	$ProgressPreference = 'SilentlyContinue'

	## Resolve the tag. The highest version wins, never the newest by date.
	## GitHub's /releases/latest is ordered by date, so a patch back-ported to
	## an older line after a newer release was published would be handed out as
	## "stable". A draft doesn't have any published assets, so neither channel
	## can install one, and stable also drops pre-releases. Within one version
	## a final outranks its own pre-releases, so v2.0.0-rc1 < v2.0.0. A
	## pre-release suffix compares with its digit runs zero-padded, so
	## rc2 < rc10, which is the same order install.bash gets from sort -V.
	$api = "https://api.github.com/repos/$repo/releases?per_page=100"
	## A 403 from an unauthenticated request is the API's rate limit, and it's
	## common behind a shared address. "none published yet, or network down"
	## sent people looking in the wrong place. GITHUB_TOKEN is used when set.
	$apiHeaders = @{}
	if ($env:GITHUB_TOKEN) { $apiHeaders['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
	## Windows PowerShell 5.1 follows a redirect from https to plain http, which
	## 7 refuses, and the release list picks the tag. The API doesn't redirect
	## this URL, so 5.1 isn't allowed to follow a redirect here. The downloads
	## may redirect, and each is checked against its signature.
	$apiRedirects = @{}
	if ($PSVersionTable.PSVersion.Major -lt 6) { $apiRedirects['MaximumRedirection'] = 0 }
	try {
		$rel = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers $apiHeaders @apiRedirects
	} catch {
		$status = Get-HttpStatus -ErrorRecord $_
		if ($status -eq 403 -or $status -eq 429) {
			Exit-Install "GitHub's API refused the request because of its rate limit. Wait, or set GITHUB_TOKEN to a token with public read access and re-run"
		}
		if ($status -eq 401) {
			Exit-Install 'GitHub rejected the credentials in GITHUB_TOKEN - unset it, or replace it with one that has public read access'
		}
		Exit-Install "can't fetch the $Release release (none published yet, or network down)"
	}
	$rel = Select-ReleaseTag -Channel $Release -Releases $rel
	if (-not $rel -or -not $rel.tag_name) { Exit-Install "no $Release release found" }
	$tag = $rel.tag_name
	$version = $tag.TrimStart('v')
	$channel = $Release
	if ($Release -eq 'stable' -and $rel.prerelease) { $channel = 'stable, but no full release yet, so the newest pre-release' }

	## The drop-in payload is a tar.gz. Windows 10 1803 and Server 2019 include
	## tar, and anything older finds out here, before a download.
	if (-not (Test-Path -LiteralPath (Get-ShclTar) -PathType Leaf)) {
		Exit-Install 'needs tar to unpack the drop-in payload, which Windows 10 1803, Server 2019, and later include - on an older Windows use the setup .exe from the releases page'
	}

	## State the plan, then confirm.
	## A plain run after -Release dev goes back to the stable release, and the
	## plan used to show that as an ordinary update.
	$existing = 'new install'
	$installed = ''
	$older = $false
	if (Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'shcl.exe')) {
		$existing = 'updates the existing install'
		$installed = Get-InstalledVersion -Exe (Join-Path -Path $dest -ChildPath 'shcl.exe')
		if ($installed -and (Test-OlderVersion -Older $version -Newer $installed)) {
			$older = $true
			$existing = "replaces the newer $installed with an older release"
		}
	}
	Write-Output "shcl $version ($channel, windows-$arch) -> $dest ($existing)"
	Write-Output "  from     https://github.com/$repo/releases/tag/$tag"
	Write-Output "  binary   $dest\shcl.exe"
	Write-Output "  drop-ins $dest\code\"
	if (Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'scripts')) { Write-Output "  removes  the retired wrappers in $dest\scripts\" }
	Write-Output "  adds $pathDir to the $pathScope PATH if missing"
	if ($older -and $Release -eq 'stable') { Write-Output "  note     to keep $installed, re-run with -Release dev" }
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
		Exit-Install "$targetProblem (check that the folder isn't read-only, and that antivirus isn't blocking it)"
	}

	$tmpParent = [IO.Path]::GetTempPath()
	$tmp = Join-Path -Path $tmpParent -ChildPath ('shcl-install-' + [IO.Path]::GetRandomFileName())
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

		## Check the signature before trusting anything the sums file says, because
		## a checksum read out of an unverified file proves nothing.
		if (-not (Test-ReleaseSignature -Path $sums -SignaturePath $sumsSig)) {
			Exit-Install 'signature check failed on sha256sums - refusing to install'
		}

		## The match is anchored on the name, the way install.bash greps it. The
		## sums file has a line per binary and per package, and an unanchored
		## match would take whichever of those came first once one asset name
		## contains another.
		$want = (Get-Content -LiteralPath $sums | Where-Object { $_ -cmatch ('\s' + [regex]::Escape($asset) + '$') } | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmpExe).Hash.ToLower()
		if (-not $want -or $got -ne $want.ToLower()) { Exit-Install "sha256 mismatch on $asset" }

		## Drop-in code files come from a release asset that's listed in the
		## same signed sums file as the binary. They used to come from GitHub's
		## generated source zipball, which doesn't have a signature or a
		## checksum. A release from before the asset installs the binary alone.
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
			Expand-ShclPayload -Archive (Join-Path -Path $tmp -ChildPath 'dropins.tgz') -Dest $unpackDir
			if ($LASTEXITCODE -ne 0) { Exit-Install "can't unpack $dropins" }
			$srcroot = Get-Item -LiteralPath $unpackDir
			$haveDropins = $true
		}

		## Run it from the temp dir before anything is written, the way
		## install.bash does, because a binary that won't start here should never
		## become an install.
		$smoke = Invoke-ShclSmoke -Exe $tmpExe
		$smokeOut = $smoke.Out
		if ($smoke.Code -ne 0) {
			Exit-Install "the downloaded shcl.exe doesn't run here: $($smokeOut -join ' ')"
		}

		## Install. The binary goes in through a temp name and a Move-Item in the
		## same dir, so a running copy only ever sees the complete old or new
		## file. A failure here prints one message instead of the raw exception.
		try {
			New-Item -ItemType Directory -Force -Path $dest | Out-Null
			Copy-Item -LiteralPath $tmpExe -Destination (Join-Path -Path $dest -ChildPath '.shcl.exe.new')
			Move-Item -Force -LiteralPath (Join-Path -Path $dest -ChildPath '.shcl.exe.new') -Destination (Join-Path -Path $dest -ChildPath 'shcl.exe')
			if ($haveDropins) {
				New-Item -ItemType Directory -Force -Path (Join-Path -Path $dest -ChildPath 'code') | Out-Null
				$payloadRoot = $srcroot.FullName
				Copy-Item -LiteralPath "$payloadRoot\source\rust\src\lib.rs", "$payloadRoot\source\go\shcl.go", "$payloadRoot\source\python\shcl.py", "$payloadRoot\source\c\shcl.h", "$payloadRoot\source\c\shcl.hpp" -Destination (Join-Path -Path $dest -ChildPath 'code')
			}
			## When the install was another version, the files this release
			## doesn't include are removed by name. A newer release's drop-ins
			## left beside an older binary describe the wrong format. On the same
			## version they can only have been put there by hand, so they stay.
			$dropped = $false
			$codeDir = Join-Path -Path $dest -ChildPath 'code'
			if (-not $haveDropins -and $installed -ne $version -and (Test-Path -LiteralPath $codeDir -PathType Container)) {
				foreach ($name in 'lib.rs', 'shcl.go', 'shcl.py', 'shcl.h', 'shcl.hpp') {
					$path = Join-Path -Path $codeDir -ChildPath $name
					if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -Force -LiteralPath $path -ErrorAction Stop }
				}
				if (@(Get-ChildItem -Force -LiteralPath $codeDir).Count -eq 0) { Remove-Item -Force -LiteralPath $codeDir -ErrorAction Stop }
				$dropped = $true
			}
			Remove-OldWrapper -Dest $dest
		} catch {
			$ex = $_.Exception
			while ($ex.InnerException) { $ex = $ex.InnerException }
			Exit-Install "can't write $dest - $($ex.Message)"
		}

		if (Update-ShclPath -Scope $pathScope -Dir $pathDir) {
			Write-Output "added $pathDir to the $pathScope PATH (new shells pick it up)"
			## Nudge running shells, if Windows lets us.
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
		if ($older) {
			Write-Output "installed shcl $version -> $dest\shcl.exe (older than the $installed it replaced)"
		} else {
			Write-Output "installed shcl $version -> $dest\shcl.exe"
		}
		if ($dropped) {
			$was = if ($installed) { $installed } else { 'earlier' }
			Write-Output "note: removed the drop-ins the $was install had, since this release doesn't include them"
		}
		## After writing over a setup install, its Add/Remove Programs entry
		## still names the version it put there, which isn't what's on disk now.
		if (Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'uninstall.exe')) {
			Write-Output "note: $dest came from the shcl setup - its Add/Remove Programs entry still shows the version it installed"
		}
		if (-not $haveDropins) { Write-Output "note: this release doesn't have a signed drop-in payload, so $dest\code was skipped - take the files from the repo if you want them" }
		$rerun = if ($invokedAsFile) { "& '$scriptPath'" } else { '& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1)))' }
		Write-Output "to remove it again: $rerun -Uninstall -Target $Target"
		## Also say what `shcl` resolves to. The receipt below runs the copy just
		## written, so another one earlier on PATH used to go unseen here. A user
		## install can't get ahead of a machine one, since Windows puts the
		## machine entries first. So a setup.exe install shadows it until that
		## one is removed, and the note is all the installer can do about it.
		$onPath = Get-ShclShadow -Installed "$dest\shcl.exe"
		if ($onPath) {
			Write-Output "note: the shcl on your PATH is $onPath, which comes before the copy just installed"
		}
		## The smoke test above already ran it from the temp dir, so this line
		## is only the receipt.
		Write-Output $smokeOut
		Write-Output ''
	} finally {
		Remove-SafeTree -Parent $tmpParent -Path $tmp -ErrorAction Continue
	}
} $Release $Target $Yes $Uninstall $Version $Help ($MyInvocation.MyCommand -is [Management.Automation.ExternalScriptInfo] -and $MyInvocation.MyCommand.Path -eq $PSCommandPath) $PSCommandPath
