// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build !windows

package shcl

// fsShortForm is the folder as given, since only Windows makes short names.
func fsShortForm(p string) string {
	return p
}
