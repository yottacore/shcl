@echo off
SETLOCAL

::	Purpose:
::		Lets 'dogfood_shcl' be run from cmd.exe, Win+R, and a shortcut, and
::		none of those can run a .ps1 directly. It runs in this window, so
::		shcl's output stays readable, and it passes everything through.
::	History: At bottom of script.

::	Copyright (C) 2026 Jim Collier
::	Licensed under The MIT License (MIT). Full text at:
::		https://mit-license.org/
::	SPDX-License-Identifier: MIT

::----------------------------------------------------------------------------
:MAIN

	:: The util dir that 0_crossplatform is in is 4 levels up from
	:: mswin\cli\by-self\cmd\. In the repo all 3 files are side by side. The
	:: Dropbox path comes before the 'synced' junction, which Windows 11 can
	:: refuse as an untrusted mount point.
	set PSFILE=%~dp0..\..\..\..\0_crossplatform\dogfood_shcl.ps1
	if exist "%PSFILE%" goto :OK005
	set PSFILE=%~dp0dogfood_shcl.ps1
	if exist "%PSFILE%" goto :OK005
	set PSFILE=%USERPROFILE%\Dropbox\0-0\common\exec\util\0_crossplatform\dogfood_shcl.ps1
	if exist "%PSFILE%" goto :OK005
	set PSFILE=%USERPROFILE%\synced\0-0\common\exec\util\0_crossplatform\dogfood_shcl.ps1
	if exist "%PSFILE%" goto :OK005
		echo dogfood_shcl: dogfood_shcl.ps1 not found
		goto :ERROR
	:OK005

	:: Use PowerShell 7 when it's there, and Windows PowerShell 5.1 otherwise.
	set PSEXE=pwsh.exe
	where /q pwsh.exe
	if errorlevel 1 set PSEXE=powershell.exe

	%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%" %*
	set RC=%ERRORLEVEL%

ENDLOCAL & exit /b %RC%

::----------------------------------------------------------------------------
:ERROR
ENDLOCAL & exit /b 1

::	History:
::		- 20260924 JC: Created.
::		- 20260927 JC: Falls back to Windows PowerShell 5.1.
