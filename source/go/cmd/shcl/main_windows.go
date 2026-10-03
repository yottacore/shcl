// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build windows

// A --write FILE the CLI is going to refuse must not be read first, and a read
// of CON waits on the console. os.Stat sees a device it can open; a reserved
// name with no device behind it needs the full path, which resolves into the
// device namespace from whatever directory the name is typed in. The library
// has the same call for its own save, private there, so this is its own copy -
// the CLI has to answer before the read, not after.

package main

import (
	"io/fs"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

func init() {
	notADiskFile = windowsNotADiskFile
	createCopy = windowsCreateCopy
}

func windowsNotADiskFile(path string) bool {
	const fileReadAttributes = 0x80
	p, perr := syscall.UTF16PtrFromString(path)
	if perr != nil {
		return false
	}
	h, herr := syscall.CreateFile(p, fileReadAttributes,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil, syscall.OPEN_EXISTING, syscall.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if herr == nil {
		kind, kerr := syscall.GetFileType(h)
		_ = syscall.CloseHandle(h) // opened for attributes only, so nothing is lost
		return kerr == nil && kind != syscall.FILE_TYPE_DISK
	}
	full, ferr := syscall.FullPath(path)
	if ferr != nil || !strings.HasPrefix(full, `\\.\`) {
		return false
	}
	// A drive after the prefix is a volume path to a file that is not there
	// yet, which a create has to be let through (20260926 item 8).
	rest := full[4:]
	drive := len(rest) >= 2 && rest[1] == ':' && ((rest[0] >= 'A' && rest[0] <= 'Z') || (rest[0] >= 'a' && rest[0] <= 'z'))
	return !drive
}

var (
	advapi32                         = syscall.NewLazyDLL("advapi32.dll")
	procGetFileSecurityW             = advapi32.NewProc("GetFileSecurityW")
	procSetFileSecurityW             = advapi32.NewProc("SetFileSecurityW")
	procGetSecurityDescriptorControl = advapi32.NewProc("GetSecurityDescriptorControl")
	procSetSecurityDescriptorControl = advapi32.NewProc("SetSecurityDescriptorControl")
)

// windowsCreateCopy is the exclusive create of the old copy. A new file takes
// the directory's ACL, while the save keeps the original's on the migrated
// file, so a private config got a backup others could read. The copy is born
// with the original's DACL instead. Best effort: when that cannot be read, the
// directory's it is.
func windowsCreateCopy(file, old string) (*os.File, error) {
	const (
		daclSecurityInformation = 0x4
		seDaclAutoInheritReq    = 0x0100
		seDaclAutoInherited     = 0x0400
	)
	dst, err := syscall.UTF16PtrFromString(old)
	if err != nil {
		return nil, &fs.PathError{Op: "open", Path: old, Err: err}
	}
	// uint64 words, since a security descriptor wants more than byte alignment.
	var sd []uint64
	if src, serr := syscall.UTF16PtrFromString(file); serr == nil {
		var need uint32
		_, _, _ = procGetFileSecurityW.Call(uintptr(unsafe.Pointer(src)), daclSecurityInformation, 0, 0, uintptr(unsafe.Pointer(&need)))
		if need > 0 {
			sd = make([]uint64, (need+7)/8)
			r, _, _ := procGetFileSecurityW.Call(uintptr(unsafe.Pointer(src)), daclSecurityInformation,
				uintptr(unsafe.Pointer(&sd[0])), uintptr(len(sd)*8), uintptr(unsafe.Pointer(&need)))
			if r == 0 {
				sd = nil
			}
		}
	}
	var sa *syscall.SecurityAttributes
	if sd != nil {
		sa = &syscall.SecurityAttributes{
			Length:             uint32(unsafe.Sizeof(syscall.SecurityAttributes{})),
			SecurityDescriptor: uintptr(unsafe.Pointer(&sd[0])),
		}
	}
	h, err := syscall.CreateFile(dst, syscall.GENERIC_WRITE,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		sa, syscall.CREATE_NEW, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &fs.PathError{Op: "open", Path: old, Err: err}
	}
	// A create takes the ACEs but drops the auto-inherited mark, and without it
	// a later change to the directory's ACL is not passed down to the copy.
	// Setting the same DACL again with the request bit puts it back.
	if sd != nil {
		var control uint16
		var revision uint32
		p := uintptr(unsafe.Pointer(&sd[0]))
		r, _, _ := procGetSecurityDescriptorControl.Call(p, uintptr(unsafe.Pointer(&control)), uintptr(unsafe.Pointer(&revision)))
		if r != 0 && control&seDaclAutoInherited != 0 {
			if r, _, _ = procSetSecurityDescriptorControl.Call(p, seDaclAutoInheritReq, seDaclAutoInheritReq); r != 0 {
				_, _, _ = procSetFileSecurityW.Call(uintptr(unsafe.Pointer(dst)), daclSecurityInformation, p)
			}
		}
	}
	return os.NewFile(uintptr(h), old), nil
}
