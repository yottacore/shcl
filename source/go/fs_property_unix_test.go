// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build unix

package shcl

import "syscall"

func fsMkfifo(p string) error {
	return syscall.Mkfifo(p, 0o600)
}
