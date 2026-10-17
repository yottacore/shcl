// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build race

package shcl

// The race detector makes memory access several times dearer, more so on a
// big document, so a timed ratio judges the detector rather than the code.
const raceOn = true
