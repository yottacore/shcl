## shclpath.ps1 - the setup's machine-PATH edit, packed into the installer and
## run at install and uninstall. It goes straight at the registry, never through
## NSIS variables: NSIS strings are capped at NSIS_MAX_STRLEN (1024), so a
## longer PATH came back truncated - or empty, which no length guard can tell
## from a genuinely empty value - and writing that back destroyed it. Segments
## are compared whole (a substring test let any directory containing the name
## suppress the append), the value is read unexpanded so %VAR% references
## survive, and it is written back REG_EXPAND_SZ so the type does not downgrade.
##
##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Adds a directory to the machine PATH, or takes it out with -Remove.
.DESCRIPTION
Run by the shcl setup at install and uninstall. Exits 1 on any failure, so the setup can tell the user to edit PATH by hand.
.PARAMETER Dir
The directory, compared as a whole PATH segment.
.PARAMETER Remove
Take the directory out instead of adding it.
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File shclpath.ps1 -Dir 'C:\Program Files\Shcl'
#>
[CmdletBinding()]
param([string]$Dir, [switch]$Remove)
Set-StrictMode -Version Latest
## Exit 1 on any failure, since the setup only tells the user to edit PATH by
## hand when this exits nonzero. By default a missing key or a throwing
## SetValue printed an error and still exited 0.
$ErrorActionPreference = 'Stop'
try {
	$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
	if ($null -eq $key) { throw 'no Environment key' }
	try {
		$cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
		## The value is written only when our segment changes, as install.ps1's
		## Update-ShclPath does: absent is no write on a remove, and an add
		## appends to the value as it was. Rebuilding from the split dropped
		## empty segments, so a PATH ending in ';' was rewritten with nothing of
		## ours in it.
		$has = ($cur -split ';') -contains $Dir
		if ($Remove) {
			if ($has) {
				$new = @($cur -split ';' | Where-Object { $_ -and $_ -ne $Dir }) -join ';'
				$key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
			}
		} elseif (-not $has) {
			$new = if ($cur -and -not $cur.EndsWith(';')) { "$cur;$Dir" } else { "$cur$Dir" }
			$key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
		}
	} finally {
		$key.Close()
	}
} catch {
	[Console]::Error.WriteLine("shclpath.ps1: $_")
	exit 1
}
