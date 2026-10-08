// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build linux

package main

import (
	"syscall"
	"unsafe"
)

func init() {
	stdinIsTerminal = func() bool { return isTerminal(syscall.Stdin, syscall.TCGETS) }
}

// isTerminal asks for the terminal settings, which only a terminal has. The
// device test alone takes /dev/null for one.
func isTerminal(fd int, req uintptr) bool {
	var t syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, uintptr(unsafe.Pointer(&t)))
	return errno == 0
}
