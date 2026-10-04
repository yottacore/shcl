// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build unix

// The path a Schema line names can turn into a FIFO between the stat and the
// open, and opening a FIFO waits for a writer. So the open does not wait, and
// the flag comes straight back off: only the open waits, and the caller's
// fstat refuses a FIFO before any read.

package main

import (
	"os"
	"syscall"
)

func init() {
	openNoWait = unixOpenNoWait
}

func unixOpenNoWait(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	if err := syscall.SetNonblock(int(f.Fd()), false); err != nil {
		_ = f.Close() // nothing was read, so nothing is lost
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return f, nil
}
