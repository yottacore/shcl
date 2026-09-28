#!/usr/bin/env pwsh
## winpath-sandbox.ps1 - run winpath-regress.ps1 inside Windows Sandbox, so a
## developer box gets the registry gate the hosted runner gets without its own
## PATH being rewritten. The sandbox is a throwaway machine with a throwaway
## registry and an administrator user, which is what that test needs and what a
## workstation cannot offer. The repo is mapped read-only and a scratch dir
## read-write, which is the only way anything comes back out.
##
## Exit: 0 = the inner run passed, 1 = it failed, 2 = cannot set up.
##
##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Runs winpath-regress.ps1 inside Windows Sandbox.
.DESCRIPTION
Gives a developer box the registry test the hosted runner gets, without rewriting its own PATH. The repo is mapped read-only and a scratch dir read-write. Exits 0 when the inner run passed, 1 when it failed, and 2 when it cannot set up.
.PARAMETER TimeoutSeconds
How long to wait for the sandbox run to finish.
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File cicd/utility/winpath-sandbox.ps1
#>
[CmdletBinding()]
param([int]$TimeoutSeconds = 420)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Exit-Setup {
	[CmdletBinding()]
	param([string]$Why)
	Write-Output "winpath-sandbox: $Why"
	exit 2
}

if (-not ($env:OS -eq 'Windows_NT')) { Exit-Setup 'not windows; nothing to run here' }

$sandboxExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sandboxExe)) { Exit-Setup 'Windows Sandbox is not installed on this host' }

## Only one sandbox runs at a time, so one already up is somebody else's and
## closing it at the end would not be ours to do.
if (Get-Process -Name 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue) {
	Exit-Setup 'a sandbox is already running; not touching it'
}

$root = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
$work = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('shcl-wsb-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$out = Join-Path -Path $work -ChildPath 'out'
New-Item -ItemType Directory -Path $out -Force | Out-Null

## The batch file is what the sandbox runs at logon. It writes the marker last,
## so seeing the marker means the result file is already complete. The echo
## lines put the redirect FIRST: `echo EXIT=%ERRORLEVEL%>>f` ends in `0>>f`,
## which cmd reads as a redirect of handle 0 and the exit code never arrives.
$runCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File C:\repo\cicd\utility\winpath-regress.ps1 > C:\out\result.txt 2>&1
>>C:\out\result.txt echo EXIT=%ERRORLEVEL%
>C:\out\done.txt echo done
'@
Set-Content -Path (Join-Path -Path $out -ChildPath 'run.cmd') -Value $runCmd -Encoding ASCII

$wsb = @"
<Configuration>
	<MappedFolders>
		<MappedFolder>
			<HostFolder>$root</HostFolder>
			<SandboxFolder>C:\repo</SandboxFolder>
			<ReadOnly>true</ReadOnly>
		</MappedFolder>
		<MappedFolder>
			<HostFolder>$out</HostFolder>
			<SandboxFolder>C:\out</SandboxFolder>
			<ReadOnly>false</ReadOnly>
		</MappedFolder>
	</MappedFolders>
	<LogonCommand>
		<Command>cmd.exe /c C:\out\run.cmd</Command>
	</LogonCommand>
	<Networking>Disable</Networking>
</Configuration>
"@
$wsbPath = Join-Path -Path $work -ChildPath 'winpath.wsb'
Set-Content -Path $wsbPath -Value $wsb -Encoding UTF8

$marker = Join-Path -Path $out -ChildPath 'done.txt'
$result = Join-Path -Path $out -ChildPath 'result.txt'
$failed = 0
try {
	Write-Output "winpath-sandbox: starting a sandbox on $root"
	# Start-Process -ArgumentList does not quote, so a profile path holding a
	# space arrived as two arguments, the sandbox never started, and the run
	# waited out its timeout and reported the test as failed rather than the
	# setup. The quotes go on by hand: ProcessStartInfo.ArgumentList would do
	# it, but 5.1 runs on .NET Framework, which does not have it, and
	# win-runners.bash runs this under 5.1. A path cannot hold a quote.
	$psi = [Diagnostics.ProcessStartInfo]::new($sandboxExe)
	$psi.Arguments = '"' + $wsbPath + '"'
	$psi.UseShellExecute = $false
	[Diagnostics.Process]::Start($psi) | Out-Null
	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
	if (-not (Test-Path -LiteralPath $marker)) {
		Write-Output "winpath-sandbox: the run did not finish within $TimeoutSeconds seconds"
		if (Test-Path -LiteralPath $result) { Get-Content -LiteralPath $result | ForEach-Object { Write-Output $_ } }
		$failed = 1
	}
	else {
		$lines = @(Get-Content -LiteralPath $result)
		$lines | ForEach-Object { Write-Output $_ }
		$tail = $lines | Where-Object { $_ -match '^EXIT=' } | Select-Object -Last 1
		if ($null -eq $tail) { Write-Output 'winpath-sandbox: no exit code came back'; $failed = 1 }
		elseif ($tail.Trim() -ne 'EXIT=0') { $failed = 1 }
	}
}
finally {
	## Nothing was running when this started, so any session now is the one
	## started above. Closing the client tears down the whole machine.
	Get-Process -Name 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue |
		Stop-Process -Force -ErrorAction SilentlyContinue
	Start-Sleep -Seconds 3
	Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

if ($failed -eq 0) { Write-Output 'winpath-sandbox: OK'; exit 0 }
Write-Output 'winpath-sandbox: FAILED'
exit 1
