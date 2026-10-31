#!/usr/bin/env pwsh
## box-cases.ps1 - the Windows box half of check-boxes.bash. ssh to a Windows
## box opens in cmd, so check-boxes.bash copies this and in.tar into a work
## folder of its own on the box and runs it there with -File. It unpacks the
## tar, runs shcl.exe over cases.tsv the way the sh driver does elsewhere, and
## packs rc.lst and o\ into out.tar beside it for check-boxes.bash to fetch.
## check-boxes.bash removes the folder after (2026103016433921).
##
## Exit: 0 = ran, 91 = the tar did not unpack.
##
##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Runs the release build over the CLI cases on a Windows test box.
.DESCRIPTION
Unpacks in.tar beside the script, runs shcl.exe over each row of cases.tsv with no stdin, and packs each run's stdout, stderr and exit code into out.tar. pwsh 7 only.
.EXAMPLE
pwsh -NoProfile -ExecutionPolicy Bypass -File box-cases.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

## Children inherit BelowNormal, so every case runs at low priority too.
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
Set-Location -LiteralPath $PSScriptRoot

& tar.exe -xf in.tar
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath cases.tsv)) { exit 91 }
$null = New-Item -ItemType Directory -Path o

$utf8 = [Text.UTF8Encoding]::new($false)
$cases = [IO.File]::ReadAllLines((Join-Path -Path $PSScriptRoot -ChildPath 'cases.tsv'), $utf8)

## Half the CPUs, a quarter when the box is busy. Windows has no load average,
## so busy is a CPU load over half.
$load = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$share = 2
if ($load -gt 50) { $share = 4 }
$jobs = [Math]::Max(1, [int][Math]::Floor([Environment]::ProcessorCount / $share))

## Each runspace takes every jobs-th case. A process gets its arguments as a
## list, which .NET quotes the way the C runtime and Rust read them back, and a
## closed pipe for stdin, which reads as EOF as /dev/null does. The bytes are
## kept as they came, with no decode.
$rows = 0..($jobs - 1) | ForEach-Object -ThrottleLimit $jobs -Parallel {
	$all = $using:cases
	$step = $using:jobs
	$dir = $using:PSScriptRoot
	$bin = Join-Path -Path $dir -ChildPath 'shcl.exe'
	for ($i = $_; $i -lt $all.Count; $i += $step) {
		$f = $all[$i].Split("`t", [StringSplitOptions]::RemoveEmptyEntries)
		$psi = [Diagnostics.ProcessStartInfo]::new($bin)
		$psi.WorkingDirectory = $dir
		for ($k = 1; $k -lt $f.Count; $k++) { $psi.ArgumentList.Add($f[$k]) }
		$psi.UseShellExecute = $false
		$psi.RedirectStandardInput = $true
		$psi.RedirectStandardOutput = $true
		$psi.RedirectStandardError = $true
		$p = [Diagnostics.Process]::Start($psi)
		$p.StandardInput.Close()
		$out = [IO.MemoryStream]::new()
		$err = [IO.MemoryStream]::new()
		$readOut = $p.StandardOutput.BaseStream.CopyToAsync($out)
		$readErr = $p.StandardError.BaseStream.CopyToAsync($err)
		## The same 60 s cap check-win-release gives a case, as timeout's 124.
		if ($p.WaitForExit(60000)) { $p.WaitForExit(); $rc = $p.ExitCode }
		else { $p.Kill($true); $p.WaitForExit(); $rc = 124 }
		$readOut.Wait()
		$readErr.Wait()
		[IO.File]::WriteAllBytes((Join-Path -Path $dir -ChildPath ('o\{0}.o' -f $f[0])), $out.ToArray())
		[IO.File]::WriteAllBytes((Join-Path -Path $dir -ChildPath ('o\{0}.e' -f $f[0])), $err.ToArray())
		[pscustomobject]@{ Index = $i; Line = ('{0} rc {1}' -f $f[0], $rc) }
	}
}

## rc.lst in case order, LF only, as the sh driver writes it.
$lines = @($rows | Sort-Object -Property Index | ForEach-Object { $_.Line })
[IO.File]::WriteAllText((Join-Path -Path $PSScriptRoot -ChildPath 'rc.lst'), (($lines -join "`n") + "`n"), $utf8)

& tar.exe -cf out.tar rc.lst o
exit $LASTEXITCODE

##	History:
##		2026-10-30  Created, for 2026103016433921.
