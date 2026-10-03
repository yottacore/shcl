#!/usr/bin/env pwsh
#==============================================================================
## shcl.ps1
##
##	Shell binding for shcl (Simple Hierarchical Config Language): a convenient
##	front end to the compiled `shcl` binary. Run it as a script, or dot-source
##	it and call the functions - both take the same arguments and hand back the
##	binary's exit code (in $LASTEXITCODE).
##
##	Usage (as a script):
##		pwsh shcl.ps1 get --int  app.shcl  server.port
##		pwsh shcl.ps1 fmt --write app.shcl
##		pwsh shcl.ps1 check app.shcl
##
##	Usage (dot-sourced):
##		. ./shcl.ps1
##		$port = shcl get --int app.shcl server.port     ## the whole CLI
##		$port = shcl_int app.shcl server.port           ## same, typed helper
##		$svrhost = shcl_get app.shcl server.host        ## ($host is read-only)
##		if ((shcl_bool app.shcl features.debug) -eq 'true') { Enable-Debug }
##		$hosts = shcl_array --string app.shcl cluster.hosts
##
##	Two differences from the binary in dot-sourced use, both from PowerShell's
##	own argument parsing, and both answered by quoting:
##		- A bare `--` is its own end-of-parameters token and is dropped before
##		  a function sees its arguments, so `shcl get -- app.shcl -x` reaches
##		  the binary without the `--`. Quote it: `shcl get '--' app.shcl -x`.
##		- An unquoted comma makes an array for a function, where a native
##		  command takes the word whole, so `shcl set --set-literal=ports=80,443
##		  app.shcl` arrives as three arguments and is a usage error. Quote the
##		  argument: `shcl set '--set-literal=ports=80,443' app.shcl`.
##	The script forms and the binary itself take both as documented.
##
##	Functions defined when dot-sourced (each mirrors the CLI, sets $LASTEXITCODE):
##		shcl                 the whole CLI: get|set|fmt|check|init|count|instances|
##		                     children|paths ...
##		                     (pipeline input is forwarded, so `set` can be piped)
##		shcl_get             read a string (the default type)
##		shcl_int shcl_float shcl_bool shcl_datetime shcl_raw
##		shcl_duration shcl_size
##		                     read one typed value
##		shcl_array           read an array (pass a --type, else --string)
##		shcl_fmt shcl_check shcl_count shcl_instances shcl_children shcl_paths
##		shcl_migrate shcl_tokens
##		                     the matching subcommands
##
##	Finding the binary (first hit wins):
##		$env:SHCL_BIN, else a `shcl` beside this file, else `shcl` on PATH, else
##		the repo release/debug build. Set SHCL_BIN to pin an exact one. On Windows
##		a bare name also matches its `.exe`.
##
##	Exit codes (straight from the binary): 0 good, 1 usage error, 2 empty,
##	3 not found, 4 bad type, 5 multiple instances, 6 check failed, strict
##	load failure, a faulty init schema, or --check found a rewrite to make,
##	7 in-place write refused (--lossy overrides) or migrate left something
##	behind, 8 a file or stream could not be read or written. A nonzero code is
##	not an error to PowerShell - unless $PSNativeCommandUseErrorActionPreference
##	is on under an ErrorActionPreference of Stop, where a not-found read throws
##	instead of returning 3.
##
##	Runs on Windows PowerShell 5.1 and PowerShell 7 on Windows; elsewhere it
##	needs PowerShell 7.3 or newer (the execute-bit check reads UnixFileMode).
#==============================================================================

##	Copyright (C) 2026 Jim Collier
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Front end to the shcl binary, run as a script or dot-sourced for its functions.
.DESCRIPTION
Every argument goes to the binary as-is, and its exit code comes back in $LASTEXITCODE. Dot-sourced, it defines shcl and the shcl_* helpers, which do the same.
.EXAMPLE
pwsh shcl.ps1 get --int app.shcl server.port
.EXAMPLE
. ./shcl.ps1; $port = shcl_int app.shcl server.port
#>

## No script-level param block on purpose: it would try to bind `get`/`--int` as
## parameters. Without one, every argument ends up in $args verbatim, exactly what
## a passthrough front end wants.

#==============================================================================
# Core
#==============================================================================

## Plain one-line stderr message (Write-Error decorates with a multi-line block).
function _shcl_err([string]$msg) { [Console]::Error.WriteLine($msg) }

## Launchable? On Unix require an execute bit (any of user/group/other); on
## Windows (or pre-6 PowerShell, where $IsWindows is undefined) a leaf is enough,
## the OS decides by extension. Mirrors bash's `-x` test at every resolution site.
## The version test comes first so 5.1 never reads $IsWindows, which does not
## exist there and throws under a caller's strict mode.
function _shcl_executable([string]$path) {
	if (-not (Test-Path -LiteralPath $path -PathType Leaf))       { return $false }
	if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows)     { return $true }
	$mode = (Get-Item -LiteralPath $path).UnixFileMode
	$modes = [System.IO.UnixFileMode]
	$exec = $modes::UserExecute -bor $modes::GroupExecute -bor $modes::OtherExecute
	return ($mode -band $exec) -ne 0
}

## A base path is a match if it is launchable, or (Windows) if base.exe is.
## Returns the concrete path or $null.
function _shcl_exe([string]$base) {
	if (_shcl_executable $base)        { return $base }
	if (_shcl_executable "$base.exe")  { return "$base.exe" }
	return $null
}

## Real directory of this file, following symlinks, so a linked-in copy still
## finds its sibling binary and the repo release/debug build tree.
function _shcl_scriptdir([string]$self = $PSCommandPath) {
	if (-not $self) { return $PSScriptRoot }
	$item = Get-Item -LiteralPath $self -ErrorAction SilentlyContinue
	## ResolveLinkTarget arrived in .NET 6, so Windows PowerShell 5.1 has no
	## such method and calling it is an error the SilentlyContinue above does
	## not cover. Without it the path is used as given, links and all.
	if ($item -and ($item.PSObject.Methods.Name -contains 'ResolveLinkTarget')) {
		$target = $item.ResolveLinkTarget($true)
		if ($target) { $self = $target.FullName }
	}
	return [System.IO.Path]::GetDirectoryName($self)
}
$script:_SHCL_ROOT = _shcl_scriptdir

## Locate the shcl binary and cache it in $script:_SHCL_BIN. SHCL_BIN, if set,
## always wins; the PATH probe asks for an Application so our own shcl() function
## can't shadow it.
$script:_SHCL_BIN = $null
function _shcl_resolve {
	if ($env:SHCL_BIN) {
		$pinned = _shcl_exe $env:SHCL_BIN         ## same .exe fallback the others get
		if ($pinned) { $script:_SHCL_BIN = $pinned; return $true }
		_shcl_err "shcl.ps1: SHCL_BIN is set but not executable: $($env:SHCL_BIN)"
		return $false
	}
	if ($script:_SHCL_BIN -and (_shcl_executable $script:_SHCL_BIN)) { return $true }
	$onPath = Get-Command -Name shcl -CommandType Application -ErrorAction SilentlyContinue |
		Select-Object -First 1 -ExpandProperty Source
	$candidates = @(
		(_shcl_exe (Join-Path -Path $script:_SHCL_ROOT -ChildPath 'shcl')),
		$onPath,
		(_shcl_exe (Join-Path -Path $script:_SHCL_ROOT -ChildPath '../rust/target/release/shcl')),
		(_shcl_exe (Join-Path -Path $script:_SHCL_ROOT -ChildPath '../rust/target/debug/shcl'))
	)
	foreach ($candidate in $candidates) {
		if ($candidate -and (_shcl_executable $candidate)) {
			$script:_SHCL_BIN = $candidate
			return $true
		}
	}
	_shcl_err 'shcl.ps1: cannot find a shcl binary (set SHCL_BIN, or put it on PATH)'
	return $false
}

## The whole CLI. Everything else is sugar over this. On a resolve failure we
## mimic the binary's own usage code so callers still see a nonzero.
## Pipeline input only reaches a function through $input, and only forward it
## when there is some: an empty $input would hand the binary a closed stdin, so
## `set` would read zero ops instead of falling through to the console.
## The binary reads and writes UTF-8. PowerShell encodes what it pipes in with
## $OutputEncoding, us-ascii on Windows PowerShell 5.1, so an accented letter
## piped to shcl fmt - printed as '?' at exit 0. What it reads back is decoded
## with the console's code page. Both are UTF-8 for the call only and put back
## after. 7 reads the nearest scope, where a caller's own copy would win over
## the global, so it also gets a local one. 5.1 does not: with a local copy
## here it stops reading the global and pipes ASCII again, and a caller's own
## copy wins there either way. A host with no console can refuse the console's,
## and then it is left as it was.
## Windows PowerShell 5.1, 7 before 7.3, and 7.3 and later set to Legacy, hand
## a native command one command line built the old way. An embedded double
## quote goes through bare, so the binary's argument parser drops it, and an
## empty argument is left out. So each argument holding a blank or a quote is
## quoted here the way that parser reads it back: a quote escaped, and the
## backslashes before a quote or the closing one doubled. PowerShell leaves an
## argument that is already quoted alone. The other modes pass each argument
## through as is.
function _shcl_native_args {
	$legacy = $PSVersionTable.PSVersion -lt [version]'7.3'
	if (-not $legacy) { $legacy = (Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction Ignore) -eq 'Legacy' }
	if (-not $legacy) { return $args }
	foreach ($a in $args) {
		if ($a -isnot [string]) { $a }
		elseif ($a -eq '') { '""' }
		elseif ($a -match '[\s"]') { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
		else { $a }
	}
}

function shcl {
	if (-not (_shcl_resolve)) { $global:LASTEXITCODE = 1; return }
	$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
	$pipeWas = $global:OutputEncoding
	$global:OutputEncoding = $utf8
	if ($PSVersionTable.PSVersion.Major -ge 6) { $OutputEncoding = $utf8 }
	$consoleWas = $null
	try {
		if ([Console]::OutputEncoding.CodePage -ne 65001) {
			$consoleWas = [Console]::OutputEncoding
			[Console]::OutputEncoding = $utf8
		}
	} catch { $consoleWas = $null }
	$pass = @(_shcl_native_args @args)
	try {
		if ($MyInvocation.ExpectingInput) { $input | & $script:_SHCL_BIN @pass }
		else { & $script:_SHCL_BIN @pass }
	} finally {
		$global:OutputEncoding = $pipeWas
		if ($consoleWas) { try { [Console]::OutputEncoding = $consoleWas } catch { $null = $_ } }
	}
}

#==============================================================================
# Typed sugar (dot-sourced use; the reason to source rather than call the binary)
#==============================================================================

##	Each one forwards pipeline input the way `shcl` does. A function's own
##	$input does not reach the function it calls, so `'a: 5' | shcl_fmt -` read
##	nothing and printed nothing at exit 0 (20260918b item 32). Piping $input
##	unconditionally is not the same thing: with nothing piped it would hand the
##	binary an empty stdin where the console's is what a `-` FILE should read.

function shcl_get       { if ($MyInvocation.ExpectingInput) { $input | shcl get @args } else { shcl get @args } }
function shcl_int       { if ($MyInvocation.ExpectingInput) { $input | shcl get --int @args } else { shcl get --int @args } }
function shcl_float     { if ($MyInvocation.ExpectingInput) { $input | shcl get --float @args } else { shcl get --float @args } }
function shcl_bool      { if ($MyInvocation.ExpectingInput) { $input | shcl get --bool @args } else { shcl get --bool @args } }
function shcl_datetime  { if ($MyInvocation.ExpectingInput) { $input | shcl get --datetime @args } else { shcl get --datetime @args } }
function shcl_duration  { if ($MyInvocation.ExpectingInput) { $input | shcl get --duration @args } else { shcl get --duration @args } }   ## milliseconds; --unit for a bare number
function shcl_size      { if ($MyInvocation.ExpectingInput) { $input | shcl get --size @args } else { shcl get --size @args } }   ## bytes; --unit, --decimal
function shcl_raw       { if ($MyInvocation.ExpectingInput) { $input | shcl get --raw @args } else { shcl get --raw @args } }
function shcl_array     { if ($MyInvocation.ExpectingInput) { $input | shcl get --array @args } else { shcl get --array @args } }   ## prefix a --type, else string
function shcl_fmt       { if ($MyInvocation.ExpectingInput) { $input | shcl fmt @args } else { shcl fmt @args } }
function shcl_check     { if ($MyInvocation.ExpectingInput) { $input | shcl check @args } else { shcl check @args } }
function shcl_count     { if ($MyInvocation.ExpectingInput) { $input | shcl count @args } else { shcl count @args } }
function shcl_instances { if ($MyInvocation.ExpectingInput) { $input | shcl instances @args } else { shcl instances @args } }
function shcl_children { if ($MyInvocation.ExpectingInput) { $input | shcl children @args } else { shcl children @args } }
function shcl_paths { if ($MyInvocation.ExpectingInput) { $input | shcl paths @args } else { shcl paths @args } }
function shcl_migrate { if ($MyInvocation.ExpectingInput) { $input | shcl migrate @args } else { shcl migrate @args } }
function shcl_tokens { if ($MyInvocation.ExpectingInput) { $input | shcl tokens @args } else { shcl tokens @args } }

#==============================================================================
# Run path
#==============================================================================

## When executed (not dot-sourced), be the CLI: forward args, forward the code.
## InvocationName is '.' only when dot-sourced. Pipeline input is forwarded the
## way the function and the helpers forward it; without that, 'a: 5' |
## .\shcl.ps1 fmt - printed nothing at exit 0.
## Started by -File with stdin redirected, the script is also handed the
## process's own stdin as pipeline input, decoded to text. Forwarded, a bad
## byte or a lone CR changed on the way to a save, so the binary has to read
## stdin itself. A script started by -File has no invoking line, which tells the
## two apart. $input is looked up by name, since 7 reads all of stdin before the
## script runs when the script names $input at its top level.
if ($MyInvocation.InvocationName -ne '.') {
	if ($MyInvocation.ExpectingInput -and $MyInvocation.Line) { (Get-Variable -Name input -ValueOnly) | shcl @args }
	else { shcl @args }
	## Written the long way rather than with ??, so this runs on the Windows
	## PowerShell 5.1 that ships with the OS as well as on 7.
	$rc = $LASTEXITCODE
	if ($null -eq $rc) { $rc = 1 }   ## null only if nothing ran; treat as usage
	exit $rc
}
