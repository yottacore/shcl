## safe-rm.ps1 - the one way a PowerShell script here takes a folder down, of
## the same kind as fSafeRmUnder in safe-rm.bash. Dot-sourced by
## winpath-regress.ps1 and winpath-sandbox.ps1. install.ps1 holds a copy of
## its own, since under irm there is no file beside it to load, and
## shell-regress holds the two to the same text.
##
##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Removes a folder strictly under the one parent named.
.DESCRIPTION
Refuses an empty path, one not in full form (. or .., a doubled separator, a relative path), one not strictly under PARENT, a link, a path through a link below PARENT, and one that is not there. PARENT itself may sit behind a link. A link or mount point inside is removed, never followed, which keeps it on one filesystem. A refusal or a failure is a non-terminating error, so a caller cleaning up in a finally passes -ErrorAction Continue.
.PARAMETER Parent
The folder the removal must stay under.
.PARAMETER Path
The folder to remove.
.EXAMPLE
Remove-SafeTree -Parent ([IO.Path]::GetTempPath()) -Path $work -ErrorAction Continue
#>
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
