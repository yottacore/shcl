; NSIS installer for shcl (Windows). Driven by cicd/utility/package.bash:
;   makensis -DVERSION=... -DSRCEXE=... -DPAYLOAD=... -DOUTFILE=... shcl.nsi
; Layout matches the system-install spec: $PROGRAMFILES64\Shcl with the binary,
; code\ (drop-in files), added to the machine PATH.
; The payload's man\ and completions\ are Linux-only and are not staged for
; this setup: Windows has no man and the completions are bash/zsh.

!ifndef VERSION
	!error "pass /DVERSION="
!endif
!ifndef SRCEXE
	!error "pass /DSRCEXE="
!endif
!ifndef PAYLOAD
	!error "pass /DPAYLOAD="
!endif
!ifndef OUTFILE
	!error "pass /DOUTFILE="
!endif
!ifndef VERQUAD
	!error "pass /DVERQUAD="
!endif
!ifndef UNINSTLIST
	!error "pass /DUNINSTLIST="
!endif

Unicode true
Name "SHCL ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\Shcl"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

; Same icon the executable has, and the metadata Windows shows for the
; setup itself. VIProductVersion needs four integers and nothing else, so the
; caller passes VERQUAD; the display strings keep the full version, prerelease
; tail and all.
!ifdef ICON
	Icon "${ICON}"
	UninstallIcon "${ICON}"
!endif
VIProductVersion "${VERQUAD}"
VIAddVersionKey "ProductName"     "SHCL"
VIAddVersionKey "FileDescription" "SHCL installer"
VIAddVersionKey "FileVersion"     "${VERSION}"
VIAddVersionKey "ProductVersion"  "${VERSION}"
VIAddVersionKey "CompanyName"     "Jim Collier"
VIAddVersionKey "LegalCopyright"  "Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. MIT License."

!include "WinMessages.nsh"

!define REG_UNINST "Software\Microsoft\Windows\CurrentVersion\Uninstall\Shcl"

; The machine PATH is edited by PowerShell against the registry directly, never
; through NSIS variables: NSIS strings are capped at NSIS_MAX_STRLEN (1024), so
; a longer PATH came back truncated - or empty, which no length guard can tell
; from a genuinely empty value - and writing that back destroyed it. The script
; is a real file (shclpath.ps1, beside this one) rather than FileWrite lines,
; so the text that ships is the text the hosted gate runs.
!macro WriteShclPathPs1
	File "/oname=$PLUGINSDIR\shclpath.ps1" "shclpath.ps1"
!macroend

Section "Install"
	; A running shcl.exe cannot be overwritten, and NSIS would only find out
	; mid-copy with its own generic retry box. Probe first: opening the file
	; for write fails while any process holds the image. Silent installs take
	; Cancel, so a scripted upgrade fails cleanly instead of hanging on a box.
	IfFileExists "$INSTDIR\shcl.exe" 0 notRunning
	retryRunning:
	FileOpen $0 "$INSTDIR\shcl.exe" a
	StrCmp $0 "" 0 notInUse
	MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
		"shcl.exe is in use. Close every program that is running it, then Retry." \
		/SD IDCANCEL IDRETRY retryRunning
	Abort "shcl.exe is in use; setup cannot continue"
	notInUse:
	FileClose $0
	notRunning:

	; Say what an upgrade replaces; a fresh install has no key to read.
	ReadRegStr $1 HKLM "${REG_UNINST}" "DisplayVersion"
	StrCmp $1 "" +2
	DetailPrint "Upgrading from $1 to ${VERSION}"

	SetOutPath "$INSTDIR"
	File "/oname=shcl.exe" "${SRCEXE}"
	SetOutPath "$INSTDIR\code"
	File "${PAYLOAD}\code\*.*"
	; The shell wrappers are retired. An upgrade takes out the copies an older
	; setup put in scripts\, and the dir if nothing else is in it.
	Delete "$INSTDIR\scripts\shcl.ps1"
	Delete "$INSTDIR\scripts\shcl.bash"
	RMDir "$INSTDIR\scripts"
	WriteUninstaller "$INSTDIR\uninstall.exe"

	WriteRegStr HKLM "${REG_UNINST}" "DisplayName" "SHCL"
	WriteRegStr HKLM "${REG_UNINST}" "DisplayVersion" "${VERSION}"
	WriteRegStr HKLM "${REG_UNINST}" "Publisher" "Jim Collier"
	WriteRegStr HKLM "${REG_UNINST}" "URLInfoAbout" "https://github.com/yottacore/shcl"
	WriteRegStr HKLM "${REG_UNINST}" "InstallLocation" "$INSTDIR"
	WriteRegStr HKLM "${REG_UNINST}" "UninstallString" '"$INSTDIR\uninstall.exe"'
	WriteRegDWORD HKLM "${REG_UNINST}" "NoModify" 1
	WriteRegDWORD HKLM "${REG_UNINST}" "NoRepair" 1

	; Append to the machine PATH once (segment-wise, REG_EXPAND_SZ preserved).
	; PowerShell by full path in both sections: a bare name is looked up in the
	; setup's own directory first, which for a download is Downloads, and this
	; runs elevated. From the 32-bit stub that path reaches the 32-bit
	; PowerShell, which is fine, since the Environment key is not redirected.
	InitPluginsDir
	!insertmacro WriteShclPathPs1
	nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\shclpath.ps1" -Dir "$INSTDIR"'
	Pop $1
	StrCmp $1 "0" +2
	DetailPrint "PATH update failed; add $INSTDIR to the machine PATH manually"
	SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=5000
SectionEnd

Section "Uninstall"
	; Best-effort segment-wise PATH removal, then the files.
	InitPluginsDir
	!insertmacro WriteShclPathPs1
	nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\shclpath.ps1" -Dir "$INSTDIR" -Remove'
	Pop $1
	StrCmp $1 "0" +2
	DetailPrint "PATH cleanup failed; remove $INSTDIR from the machine PATH manually"
	SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=5000
	Delete "$INSTDIR\shcl.exe"
	; The payload by name, written by package.bash from the file set the
	; install copies. A glob took anything else kept in code\ as well, where
	; both script installers remove only what they laid down. scripts\ is from
	; a setup before the wrappers were retired.
	!include "${UNINSTLIST}"
	Delete "$INSTDIR\scripts\shcl.ps1"
	Delete "$INSTDIR\scripts\shcl.bash"
	RMDir "$INSTDIR\code"
	RMDir "$INSTDIR\scripts"
	Delete "$INSTDIR\uninstall.exe"
	RMDir "$INSTDIR"
	DeleteRegKey HKLM "${REG_UNINST}"
SectionEnd
