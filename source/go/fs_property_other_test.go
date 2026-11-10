// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build !unix

package shcl

import "errors"

// No FIFO at a path here, so the event does nothing, as its rule's os says.
func fsMkfifo(string) error {
	return errors.New("no FIFO on this platform")
}
