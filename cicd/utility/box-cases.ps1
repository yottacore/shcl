#!/usr/bin/env pwsh
## box-cases.ps1 - the Windows box half of check-boxes.bash. ssh to a Windows
## box opens in cmd, so check-boxes.bash copies this and in.tar into a work
## folder of its own on the box and runs it there with -File. It unpacks the
## tar, runs shcl.exe over cases.tsv the way the sh driver does elsewhere, and
## packs rc.lst and o\ into out.tar beside it for check-boxes.bash to fetch.
## With a source tree in the tar, it runs win-runners.bash there too, and packs
## s\ as well. check-boxes.bash removes the folder after (2026103016433921).
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
Unpacks in.tar beside the script, runs shcl.exe over each row of cases.tsv with no stdin, and packs each run's stdout, stderr and exit code into out.tar. With a src folder in the tar, it also runs win-runners.bash there under git's bash and packs its log and exit code. pwsh 7 only.
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

## With a copy of the tracked source in src\, win-runners.bash runs there under
## git's bash, as the hosted windows job runs it, winpath-regress.ps1 included
## (2026103016433943). Its log and exit code go back in s\. The caches and temp
## files stay in the work folder, so they go with it.
$packed = @('rc.lst', 'o')
if (Test-Path -LiteralPath src) {
	$s = Join-Path -Path $PSScriptRoot -ChildPath 's'
	$null = New-Item -ItemType Directory -Path $s
	$packed += 's'
	$bash = Join-Path -Path $env:ProgramFiles -ChildPath 'Git\bin\bash.exe'
	if (-not (Test-Path -LiteralPath $bash)) {
		[IO.File]::WriteAllText((Join-Path -Path $s -ChildPath 'rc'), "skip no git bash on the box`n", $utf8)
	} else {
		$t = Join-Path -Path $PSScriptRoot -ChildPath 't'
		$null = New-Item -ItemType Directory -Path $t
		$env:TMP = $t; $env:TEMP = $t; $env:TMPDIR = $t
		$env:CARGO_HOME = Join-Path -Path $t -ChildPath 'cargo-home'
		$env:GOCACHE = Join-Path -Path $t -ChildPath 'go-cache'
		$env:GOPATH = Join-Path -Path $t -ChildPath 'go-path'
		foreach ($v in 'CPU_CAP', 'CARGO_BUILD_JOBS', 'RUST_TEST_THREADS', 'GOMAXPROCS') { Set-Item -Path "env:$v" -Value $jobs }
		## A bare python3 can be the Store stub.
		$py = 'C:\Python314\python.exe'
		if (-not $env:PYTHON -and (Test-Path -LiteralPath $py)) { $env:PYTHON = $py }
		## pwsh 7's own module path, passed down, stops Windows PowerShell 5.1
		## loading Get-Acl's module, which cli-regress's ACL row calls.
		$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
		& $bash -c 'cd src || exit 1; bash cicd/utility/win-runners.bash > ../s/win-runners.log 2>&1; echo "$?" > ../s/rc' 2>&1 | Out-Null
	}
}

& tar.exe -cf out.tar @packed
exit $LASTEXITCODE

##	History:
##		2026-10-30  Created, for 2026103016433921.
##		2026-10-31  Runs win-runners.bash over a source tree in src\, for 2026103016433943.
