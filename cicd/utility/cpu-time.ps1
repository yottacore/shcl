#!/usr/bin/env pwsh
## cpu-time.ps1 - runs a program on this process's stdin, stdout and stderr,
## and writes the CPU time it used, user then kernel seconds, to a file.
## perf-gate.bash times a native CLI this way on Windows, since git bash's time
## counts only its own processes (2026103016433965).
##
## Exit: the program's, 124 when it ran past SECS and was killed, or 2 for
## usage.
##
##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Runs a program and writes its CPU time to a file.
.DESCRIPTION
Takes OUT SECS PROGRAM ARG... Starts PROGRAM with the ARGs on this process's own standard handles, waits up to SECS seconds, and writes "USER KERNEL" in seconds to OUT. A program still running then is killed with its children, and the exit code is 124, as timeout gives. pwsh 7 only.
.EXAMPLE
pwsh -NoProfile -File cpu-time.ps1 cpu.txt 300 shcl.exe check --schema s.shcl doc.shcl
#>

## No param block: -File would read an ARG such as --schema as one of its
## names, and -- doesn't stop it there.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($args.Count -lt 3) { exit 2 }
$Out = [string]$args[0]
$Secs = [int]$args[1]

## No redirection, so the child gets these handles: perf-gate's files.
$psi = [Diagnostics.ProcessStartInfo]::new([string]$args[2])
$psi.UseShellExecute = $false
for ($k = 3; $k -lt $args.Count; $k++) { $psi.ArgumentList.Add([string]$args[$k]) }
$p = [Diagnostics.Process]::Start($psi)
if (-not $p.WaitForExit($Secs * 1000)) {
	$p.Kill($true)
	$p.WaitForExit()
	exit 124
}
$p.WaitForExit()
$c = [Globalization.CultureInfo]::InvariantCulture
$line = '{0} {1}' -f $p.UserProcessorTime.TotalSeconds.ToString('0.000', $c), $p.PrivilegedProcessorTime.TotalSeconds.ToString('0.000', $c)
[IO.File]::WriteAllText($Out, $line + "`n", [Text.UTF8Encoding]::new($false))
exit $p.ExitCode

##	History:
##		2026-10-31  Created, for 2026103016433965.
