// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build unix

package shcl

import (
	"syscall"
	"testing"
)

// The flag table is written out so shcl.go builds on wasm. Here, where the
// constant exists, they have to agree (2026110611562400).
func TestNoWaitFlagIsNonblock(t *testing.T) {
	defer testID(t, "deyvb")
	if got := noWaitFlag(); got != syscall.O_NONBLOCK {
		t.Fatalf("noWaitFlag() = %#x, syscall.O_NONBLOCK = %#x", got, syscall.O_NONBLOCK)
	}
}
