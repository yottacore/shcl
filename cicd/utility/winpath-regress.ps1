#!/usr/bin/env pwsh
## winpath-regress.ps1 - the Windows installers' PATH handling, against the real
## registry, so it only runs on the hosted windows job (win-runners.bash guards
## that). Two subjects, both the shipped text rather than a copy of the logic:
## install.ps1's Update-ShclPath, lifted from the script by name and run against
## HKCU, and the setup's shclpath.ps1 run as the installer runs it, against
## HKLM. What they must preserve: %VAR% references (read unexpanded), the
## REG_EXPAND_SZ kind, and whole-segment comparison. Everything touched is
## saved first and restored in a finally.
##
## Exit: 0 = all checks pass, 1 = a check failed (named), 2 = cannot set up.
##
##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Tests the Windows installers' PATH handling against the real registry.
.DESCRIPTION
Runs install.ps1's Update-ShclPath against HKCU and the setup's shclpath.ps1 against HKLM, and restores both values after. Exits 0 when every check passes, 1 when one fails, and 2 when it cannot set up.
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File cicd/utility/winpath-regress.ps1
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'runs the function text lifted from the shipped installer')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ($env:OS -eq 'Windows_NT')) {
	Write-Output 'winpath-regress: not windows; nothing to test here'
	exit 2
}

$root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$failures = 0
## One status line per check, with its test ID.
function Test-Check {
	[CmdletBinding()]
	param([string]$Id, [bool]$Ok, [string]$Name)
	$status = 'ok'
	if (-not $Ok) { $status = 'FAIL'; $script:failures++ }
	Write-Output ('{0,-4} {1} winpath-regress {2}' -f $status, $Id, $Name)
}

## Lift Update-ShclPath out of install.ps1 by name - the shipped text, so a
## drift in the script is a drift in the test subject.
$lines = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'install.ps1')
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
	if ($lines[$i] -match '^\tfunction Update-ShclPath\b') { $start = $i; break }
}
if ($start -lt 0) { Write-Output 'winpath-regress: install.ps1 has no Update-ShclPath'; exit 2 }
$end = -1
for ($i = $start + 1; $i -lt $lines.Count; $i++) {
	if ($lines[$i] -match '^\t\}\s*$') { $end = $i; break }
}
if ($end -lt 0) { Write-Output 'winpath-regress: Update-ShclPath never closes'; exit 2 }
Invoke-Expression (($lines[$start..$end] -join "`n"))

function Get-RawPath {
	[CmdletBinding()]
	param([Microsoft.Win32.RegistryKey]$Key)
	[string]$Key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}
function Get-PathKind {
	[CmdletBinding()]
	param([Microsoft.Win32.RegistryKey]$Key)
	if ($Key.GetValueNames() -contains 'Path') { $Key.GetValueKind('Path') } else { $null }
}
function Restore-PathValue {
	[CmdletBinding()]
	param([Microsoft.Win32.RegistryKey]$Key, [string]$Value, [Nullable[Microsoft.Win32.RegistryValueKind]]$Kind)
	if ($null -eq $Kind) { if ($Key.GetValueNames() -contains 'Path') { $Key.DeleteValue('Path') } }
	else { $Key.SetValue('Path', $Value, $Kind) }
}

## HKCU: seed a user PATH the way real ones look - a %USERPROFILE% reference,
## stored REG_EXPAND_SZ - and check every property on the shipped function.
$cu = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$savedCu = Get-RawPath $cu
$savedCuKind = Get-PathKind $cu
try {
	$seed = '%USERPROFILE%\bin;C:\seeded'
	$cu.SetValue('Path', $seed, [Microsoft.Win32.RegistryValueKind]::ExpandString)
	$dir = 'C:\shcl-pathtest'
	Test-Check -Id 'EoeB8tI' (Update-ShclPath -Scope User -Dir $dir) 'user add reports a write'
	Test-Check -Id 'EoeB8tJ' ((Get-RawPath $cu) -eq "$seed;$dir") 'user add appends, references unexpanded'
	Test-Check -Id 'EoeB8tK' ((Get-PathKind $cu) -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'user add keeps REG_EXPAND_SZ'
	Test-Check -Id 'EoeB8tL' (-not (Update-ShclPath -Scope User -Dir $dir)) 'user add is idempotent'
	Test-Check -Id 'EoeB8tM' ((Get-RawPath $cu) -eq "$seed;$dir") 'idempotent add leaves the value alone'
	## Whole segments: a dir containing the other's name is not "already there".
	Test-Check -Id 'EoeB8tN' (Update-ShclPath -Scope User -Dir "${dir}2") 'a superstring dir still appends'
	Test-Check -Id 'EoeB8tO' ((Get-RawPath $cu) -eq "$seed;$dir;${dir}2") 'both segments present'
	Test-Check -Id 'EoeB8tP' (Update-ShclPath -Scope User -Dir $dir -Remove) 'user remove reports a write'
	Test-Check -Id 'EoeB8tQ' ((Get-RawPath $cu) -eq "$seed;${dir}2") 'remove takes its segment alone'
	Test-Check -Id 'EoeB8tR' ((Get-PathKind $cu) -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'remove keeps REG_EXPAND_SZ'
	Test-Check -Id 'EoeB8tS' (-not (Update-ShclPath -Scope User -Dir 'C:\never-there' -Remove)) 'removing an absent segment writes nothing'
	## A user PATH ending in ';' is common enough to pin. The add must not double
	## it, and the remove drops it, which is a rewrite of a segment nobody owns.
	$cu.SetValue('Path', "$seed;", [Microsoft.Win32.RegistryValueKind]::ExpandString)
	Test-Check -Id 'Eor6nHc' (Update-ShclPath -Scope User -Dir $dir) 'add onto a trailing semicolon reports a write'
	Test-Check -Id 'Eor6nHd' ((Get-RawPath $cu) -eq "$seed;$dir") 'add onto a trailing semicolon does not double it'
	Test-Check -Id 'Eor6nHe' (Update-ShclPath -Scope User -Dir $dir -Remove) 'remove from a trailing semicolon reports a write'
	Test-Check -Id 'Eor6nHf' ((Get-RawPath $cu) -eq $seed) 'remove drops the trailing semicolon'
	## A fresh profile has no user PATH at all.
	$cu.SetValue('Path', '', [Microsoft.Win32.RegistryValueKind]::ExpandString)
	Test-Check -Id 'Eor6nHg' (Update-ShclPath -Scope User -Dir $dir) 'add onto an empty PATH reports a write'
	Test-Check -Id 'Eor6nHh' ((Get-RawPath $cu) -eq $dir) 'add onto an empty PATH leaves no leading semicolon'
} finally {
	Restore-PathValue -Key $cu -Value $savedCu -Kind $savedCuKind
	$cu.Close()
}

## HKLM: the setup's shclpath.ps1, run the way the installer runs it. No
## seeding - the machine PATH is the runner's working one - so the assertions
## are segment-wise against what was there.
$lm = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
$savedLm = Get-RawPath $lm
$savedLmKind = Get-PathKind $lm
$script = Join-Path -Path $root -ChildPath 'cicd\packaging\shclpath.ps1'
$dir = 'C:\shcl-nsistest'
try {
	$before = @($savedLm -split ';' | Where-Object { $_ -ne '' })
	& powershell -NoProfile -ExecutionPolicy Bypass -File $script -Dir $dir
	Test-Check -Id 'EoeB8tT' ($LASTEXITCODE -eq 0) 'setup add exits 0'
	$after = @((Get-RawPath $lm) -split ';' | Where-Object { $_ -ne '' })
	Test-Check -Id 'EoeB8tU' (($after -join ';') -eq (($before + $dir) -join ';')) 'setup add appends one segment, the rest byte-identical'
	Test-Check -Id 'EoeB8tV' ((Get-PathKind $lm) -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'setup add keeps REG_EXPAND_SZ'
	& powershell -NoProfile -ExecutionPolicy Bypass -File $script -Dir $dir
	Test-Check -Id 'EoeB8tW' ((Get-RawPath $lm) -eq ($after -join ';')) 'setup add is idempotent'
	& powershell -NoProfile -ExecutionPolicy Bypass -File $script -Dir $dir -Remove
	Test-Check -Id 'EoeB8tX' ($LASTEXITCODE -eq 0) 'setup remove exits 0'
	Test-Check -Id 'EoeB8tY' ((Get-RawPath $lm) -eq ($before -join ';')) 'setup remove restores the segments'
	## The setup tells the user to fix PATH by hand only on a nonzero exit, and
	## the script used to exit 0 on any failure. Two copies that must fail: one
	## naming a key that is not there, and one opening the real key read-only so
	## SetValue throws.
	$shipped = [IO.File]::ReadAllText($script)
	$keyText = "'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', `$true)"
	if (-not $shipped.Contains($keyText)) { Write-Output 'winpath-regress: shclpath.ps1 no longer opens the key as expected'; exit 2 }
	$broken = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('shclpath-fail-' + [IO.Path]::GetRandomFileName())
	New-Item -ItemType Directory -Path $broken | Out-Null
	try {
		$noKey = Join-Path -Path $broken -ChildPath 'nokey.ps1'
		[IO.File]::WriteAllText($noKey, $shipped.Replace($keyText, "'SOFTWARE\shcl-winpath-regress-missing', `$true)"), [Text.UTF8Encoding]::new($true))
		& powershell -NoProfile -ExecutionPolicy Bypass -File $noKey -Dir $dir
		Test-Check -Id 'Eq8WEvT' ($LASTEXITCODE -ne 0) 'setup add fails on a missing key'
		$readOnly = Join-Path -Path $broken -ChildPath 'readonly.ps1'
		[IO.File]::WriteAllText($readOnly, $shipped.Replace($keyText, $keyText.Replace('$true', '$false')), [Text.UTF8Encoding]::new($true))
		& powershell -NoProfile -ExecutionPolicy Bypass -File $readOnly -Dir $dir
		Test-Check -Id 'Eq8WEvU' ($LASTEXITCODE -ne 0) 'setup add fails when the write throws'
		Test-Check -Id 'Eq8WEvV' ((Get-RawPath $lm) -eq ($before -join ';')) 'a failed setup add changes nothing'
	} finally {
		Remove-Item -Recurse -Force -LiteralPath $broken -ErrorAction SilentlyContinue
	}
} finally {
	Restore-PathValue -Key $lm -Value $savedLm -Kind $savedLmKind
	$lm.Close()
}

if ($failures -eq 0) { Write-Output 'winpath-regress: OK'; exit 0 }
Write-Output "winpath-regress: $failures check(s) failed"
exit 1
