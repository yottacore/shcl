// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

package shcl

import (
	"fmt"
	"syscall"
)

// fsShortForm is the 8.3 short form of a folder that's there, from the OS.
func fsShortForm(p string) string {
	long, err := syscall.UTF16PtrFromString(p)
	if err != nil {
		panic(err)
	}
	buf := make([]uint16, 1024)
	n, err := syscall.GetShortPathName(long, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 || int(n) >= len(buf) {
		panic(fmt.Sprintf("no short form of %s: %v", p, err))
	}
	return syscall.UTF16ToString(buf[:n])
}
