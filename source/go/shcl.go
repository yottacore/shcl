// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Package shcl is the Go binding of SHCL: parser, accessor, writer/formatter.
// Single file on purpose - the drop-in story is "copy this file into your tree".
// Behavior is pinned to the Rust reference: the conformance corpus in
// project/conformance/ plus the cicd cross-binding differential check keep the
// two byte-for-byte identical, so any divergence here is a bug by definition.
// Structure deliberately mirrors the reference over Go idiom, so a fix there
// ports here by mechanical diff (parity over idiom - see
// project/style-guide_code.md).
//
// Writing a mapper - the shape of a real consumer that walks a document into
// its own model (the surface is 60+ methods, but a mapper needs about six):
//
//	doc := shcl.LoadAndValidate(text, schemaText, shcl.Standard)
//	if doc.ErrorCount() > 0 {
//		for _, d := range doc.Diagnostics() { // one combined list: parse + validation
//			log.Printf("line %d: %s: %s", d.Line, d.Code, d.Message)
//		}
//	}
//	// Iterate instances positionally: Count + [#i]. By-value selectors are
//	// for point lookups; they collapse same-named entities and misread
//	// numeric names, so a mapper walks by index.
//	for i := 0; i < doc.Count("table"); i++ {
//		base := fmt.Sprintf("table[#%d]", i)
//		name := doc.ReadString(base).Value // the discriminator
//		// Open (map-shaped) sections: ask what keys exist, in file order.
//		for _, col := range doc.Children(base + ".columns") {
//			path := base + ".columns." + shcl.QuoteSegment(col) // user-typed names are quoted, never spliced bare
//			r := doc.ReadString(path)
//			if r.Status != shcl.Good {
//				log.Printf("line %d: bad column %q", r.Line, col)
//			}
//			_ = r.Value
//		}
//		_ = name
//	}
//	// Verbatim multi-line content (DDL, templates) lives in fenced raw
//	// blocks: ReadRaw returns it byte-for-byte, ReadRawInfo the fence tag.
package shcl

import (
	"errors"
	"fmt"
	"io"
	"math"
	"math/bits"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"
)

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

// Strictness is the per-document forgiveness knob. Set once at load.
type Strictness int

const (
	Loose    Strictness = iota // widest read coercions (re-admits currency and friends)
	Standard                   // the default
	Strict                     // any error diagnostic fails the load
)

// StrictnessFromArg accepts the CLI spellings: loose|standard|strict or 1|2|3.
func StrictnessFromArg(s string) (Strictness, bool) {
	switch asciiLower(s) {
	case "loose", "1":
		return Loose, true
	case "standard", "2":
		return Standard, true
	case "strict", "3":
		return Strict, true
	}
	return Standard, false
}

// Severity is how much a diagnostic counts. Only Error fails a strict load; Hint
// flags legal-but-lookalike input.
type Severity int

const (
	SeverityError Severity = iota // fails a strict load
	SeverityHint                  // legal-but-lookalike input
)

// String is the severity as check prints it.
func (s Severity) String() string {
	if s == SeverityHint {
		return "Hint"
	}
	return "Error"
}

// Diagnostic is one parser or validator finding, tied to a source line.
type Diagnostic struct {
	Line     int // 1-based
	Severity Severity
	Message  string
	// Code is the stable machine code (E001.., H001..) identifying the diagnostic
	// kind - the contract; Message is a free, per-binding voice.
	Code string
}

// Status is the read sentinel. Empty is informational - the empty value is
// still returned.
type Status int

const (
	Good     Status = iota // value present and coercible
	Empty                  // path resolved but has no value
	NotFound               // path resolved to no node
	BadType                // value would not coerce to the asked type
	Multiple               // path resolved to more than one node
)

// String names the status.
func (s Status) String() string {
	switch s {
	case Good:
		return "Good"
	case Empty:
		return "Empty"
	case NotFound:
		return "NotFound"
	case BadType:
		return "BadType"
	case Multiple:
		return "Multiple"
	}
	return "Good"
}

// WriteReason is why a write would fail (WriteReason()): the distinctions
// behind a setter's bare false. Writable = the path passes the writer's
// validation; the rest name the five ways it cannot.
type WriteReason int

const (
	Writable    WriteReason = iota // the path passes the writer's validation
	BadPath                        // empty path, or the scanner rejected it
	ValueInPath                    // the path has a `: value` part; writes take values separately
	Wildcard                       // wildcard selectors are query-only
	NoSuchIndex                    // a `[#k]` instance that does not (and can never) exist
	TooDeep                        // deeper than the nesting cap; the writer never creates past it
)

// String names the reason.
func (r WriteReason) String() string {
	switch r {
	case Writable:
		return "Writable"
	case BadPath:
		return "BadPath"
	case ValueInPath:
		return "ValueInPath"
	case Wildcard:
		return "Wildcard"
	case NoSuchIndex:
		return "NoSuchIndex"
	case TooDeep:
		return "TooDeep"
	}
	return "Writable"
}

// Read is the full-tier read result: value plus status plus the original raw
// text (when the path resolved), so a caller can always recover what was
// actually in the file. Array reads also give one status per slot (element,
// or wildcard instance) in Slots; Status is then the worst slot. Scalar reads
// leave Slots nil.
// Line is the 1-based source line of the resolved binding (0 when the path
// did not resolve to one node, or the node was writer-built), so a consumer
// check the schema cannot express can still cite the line. Quoted is true
// when the read's single scalar element was quoted in the source - the escape
// hatch that lets a downstream language reserve `@null` while `"@null"` stays
// a plain string. Arrays, raw blocks, and empties leave it false. A written
// value counts as quoted when a save would quote it.
type Read[T any] struct {
	Value  T
	Status Status
	Raw    *string
	Slots  []Status
	Line   int
	Quoted bool
}

// Ok reports whether the author addressed this field at all: Good or Empty.
// Note this deliberately answers differently from the *Or tier, which falls
// back on Empty like any other non-Good read - Ok asks "is this field spoken
// for", GetIntOr asks "do I have a usable value", and an explicitly emptied
// field is the case where those two diverge.
func (r Read[T]) Ok() bool { return r.Status == Good || r.Status == Empty }

func (r Read[T]) at(line int, quoted bool) Read[T] {
	r.Line = line
	r.Quoted = quoted
	return r
}

// LoadError is a failed Strict load: the diagnostics that failed it, plus the
// recovered tree.
type LoadError struct {
	Diagnostics []Diagnostic
	// Document is the tree the parse produced anyway. Recover-and-continue
	// means the diagnostics are the point of a failed strict load, and the
	// tree is what a Standard load would have kept.
	Document *Document
}

// Error summarizes the failure, naming the first few error diagnostics.
func (e *LoadError) Error() string {
	// Name the first few failures right in the message; the bare count made
	// callers dig for information the error was already holding.
	var errs []Diagnostic
	for _, d := range e.Diagnostics {
		if d.Severity == SeverityError {
			errs = append(errs, d)
		}
	}
	msg := fmt.Sprintf("strict load failed: %d error diagnostic(s)", len(errs))
	for i, d := range errs {
		if i == 3 {
			msg += fmt.Sprintf("; +%d more", len(errs)-3)
			break
		}
		msg += fmt.Sprintf("; line %d: %s %s", d.Line, d.Code, d.Message)
	}
	return msg
}

// ZoneKind says how a datetime's zone suffix was written.
type ZoneKind int

const (
	ZoneUTC    ZoneKind = iota // trailing Z
	ZoneOffset                 // +hh:mm / -hh:mm
)

// Zone is a datetime's zone suffix as written.
type Zone struct {
	Kind          ZoneKind
	OffsetMinutes int
}

// DateTime is a local (floating) date/time unless a zone suffix was present.
// Fields mirror what was written: a date-only value has no time, and vice versa.
type DateTime struct {
	HasDate          bool
	Year, Month, Day int
	HasTime          bool
	Hour, Minute     int
	HasSeconds       bool
	Second           int
	Frac             string // fractional-second digits as typed ("" = none)
	Zone             *Zone
}

// String is the canonical spelling, mirroring what was written.
func (dt DateTime) String() string {
	var b strings.Builder
	if dt.HasDate {
		fmt.Fprintf(&b, "%04d-%02d-%02d", dt.Year, dt.Month, dt.Day)
		if dt.HasTime {
			b.WriteByte('T')
		}
	}
	if dt.HasTime {
		fmt.Fprintf(&b, "%02d:%02d", dt.Hour, dt.Minute)
		if dt.HasSeconds {
			fmt.Fprintf(&b, ":%02d", dt.Second)
		}
		if dt.Frac != "" {
			b.WriteByte('.')
			b.WriteString(dt.Frac)
		}
	}
	if dt.Zone != nil {
		if dt.Zone.Kind == ZoneUTC {
			b.WriteByte('Z')
		} else {
			off := dt.Zone.OffsetMinutes
			sign := byte('+')
			if off < 0 {
				sign = '-'
				off = -off
			}
			fmt.Fprintf(&b, "%c%02d:%02d", sign, off/60, off%60)
		}
	}
	return b.String()
}

// FormatFloat renders a float the way the reference does (shortest round-trip
// decimal, never scientific notation) - the cross-binding contract for CLI and
// corpus output.
func FormatFloat(v float64) string {
	if math.IsNaN(v) {
		return "NaN"
	}
	if math.IsInf(v, 1) {
		return "inf"
	}
	if math.IsInf(v, -1) {
		return "-inf"
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}

// ---------------------------------------------------------------------------
// In-memory model
// ---------------------------------------------------------------------------
// One rule covers everything: a node is (field-name, value, children); nodes
// merge when (name, value) matches; empty values merge into the wrapper node.

type element struct {
	text   string // the logical string: quotes stripped, escapes resolved
	quoted bool
}

// lead is one whole-line comment held as trivia, plus whether a blank line
// preceded it - so a blank between comment-only regions survives the
// round-trip (blank runs collapse to one, same as nodes).
type lead struct {
	text        string
	blankBefore bool
	// Levels deeper than the place it is emitted at. A comment written under
	// the one before it keeps that nesting, so a commented-out block comes
	// back in its shape.
	depth int
	// The source line it was read from, for the save that keeps lines; 0 for
	// one a write made or moved.
	line int
	// A misplaced line kept as written that the settle turned into a comment,
	// since as written it would bind. It is still the user's line, not a
	// comment, so ClearComments and Comments leave it alone.
	kept bool
}

func plainLead(text string) lead {
	return lead{text: text}
}

func (l *lead) isComment() bool {
	return strings.HasPrefix(l.text, "#") && !l.kept
}

// isKeptLine: a line the load kept as written, settled or not. The save gate
// counts these (design.md, Kept lines under edits).
func (l *lead) isKeptLine() bool {
	return l.kept || !strings.HasPrefix(l.text, "#")
}

// depthEnt is one comment on a commentDepth chain: its indent and depth.
type depthEnt struct {
	indent string
	depth  int
}

// commentDepth says how many levels past its place a pending line is
// written: the place's own level for a comment no deeper than base, the
// place's own indent, which also starts a new chain; for a deeper one, one
// level under the nearest comment before it whose indent its own extends,
// level with one it equals, or at the place's level when there is none. chain
// holds those comments' indents with their depths, innermost last. A field
// line kept for its value or name goes by the same rule over held, the kept
// lines before it: it holds its level on a reload, so it goes deeper only
// under one of those, which a reload holds open for it. That line then takes
// its place in chain at its own level, so a comment nests under it too
// (2026100218185700). A misplaced line, which has its own indent, sits at the
// place's level and leaves both alone.
func commentDepth(chain, held *[]depthEnt, base, text, indent string) int {
	if strings.HasPrefix(text, " ") || strings.HasPrefix(text, "\t") {
		return 0
	}
	if strings.HasPrefix(text, "#") {
		return chainDepth(chain, base, indent)
	}
	depth := chainDepth(held, base, indent)
	// It is written at its own level, so on a reload nothing at that level or
	// deeper is left for a comment after it to nest under.
	for len(*chain) > 0 {
		top := (*chain)[len(*chain)-1]
		if top.depth < depth && len(indent) > len(top.indent) && strings.HasPrefix(indent, top.indent) {
			break
		}
		*chain = (*chain)[:len(*chain)-1]
	}
	*chain = append(*chain, depthEnt{indent: indent, depth: depth})
	return depth
}

// chainDepth is commentDepth over one chain.
func chainDepth(chain *[]depthEnt, base, indent string) int {
	if !(len(indent) > len(base) && strings.HasPrefix(indent, base)) {
		*chain = append((*chain)[:0], depthEnt{indent: indent})
		return 0
	}
	for len(*chain) > 0 {
		top := (*chain)[len(*chain)-1]
		if top.indent == indent {
			return top.depth
		}
		if len(indent) > len(top.indent) && strings.HasPrefix(indent, top.indent) {
			break
		}
		*chain = (*chain)[:len(*chain)-1]
	}
	depth := 0
	if len(*chain) > 0 {
		depth = (*chain)[len(*chain)-1].depth + 1
	}
	*chain = append(*chain, depthEnt{indent: indent, depth: depth})
	return depth
}

// isField: a pending line kept for what it says, not for where it sits:
// neither a comment nor a misplaced line, which has its own indent.
func isField(text string) bool {
	return !strings.HasPrefix(text, "#") && !strings.HasPrefix(text, " ") && !strings.HasPrefix(text, "\t")
}

// pend is a pending whole-line comment during parse: text, source indent (used
// only to decide whether it hangs on a deeper block), and the blank it consumed.
// ceiling is the shortest incoming indent already checked against it: a later
// check can only hang it from a shorter one, so a longer one skips it.
type pend struct {
	text        string
	indent      string
	blankBefore bool
	ceiling     int
	line        int
}

// pendMark: every pending entry before end has a ceiling at or under indentLen.
type pendMark struct {
	end       int
	indentLen int
}

type valueKind int

const (
	vEmpty valueKind = iota
	vCell            // one element = scalar, more = inline array
	vRaw
)

type rawValue struct {
	content   string
	info      string
	fenceChar byte
	fenceLen  int
}

type value struct {
	kind valueKind
	els  []element
	raw  *rawValue // behind a pointer: inline, its four fields would ride on every node
}

// display is the spelled-out form; also what selectors match against (case-sensitive).
func (v *value) display() string {
	switch v.kind {
	case vEmpty:
		return ""
	case vCell:
		parts := make([]string, len(v.els))
		for i, e := range v.els {
			parts[i] = e.text
		}
		return strings.Join(parts, ", ")
	}
	return v.raw.content
}

func (v *value) isEmpty() bool {
	return v.kind == vEmpty
}

type nodeData struct {
	name      string // ASCII-folded to lower; non-ASCII never folds
	value     value
	children  []int
	parent    int
	line      int
	starList  bool // value built from stacked "* " lines
	starMixed bool // mix of "* " and field children already diagnosed
	// Blank-line grouping is the other half of hand-authored layout: set when
	// a blank line preceded this node's binding line (runs collapse to one).
	blankBefore bool
	// This node has decided its src - set by the first source line whose
	// value the node holds, whether or not a string was worth keeping.
	srcSet bool
	// Comment trivia, kept off to the side: most nodes have none, and the
	// four empty containers were a third of every node.
	trivia *trivia
	// Verbatim value text from the source line (after the colon, comment
	// stripped, trimmed) - what a read's Raw hands back. nil when the value
	// was synthesized (writer, stacked list, fence) OR when the spelling is
	// exactly the display form; raw falls back to the display form either way.
	src *string
	// The name as the author wrote it (case unfolded, quotes and escapes
	// resolved) - what AuthoredName() hands back, via authored(). Merged
	// instances keep the first binding's spelling, like Line() and comments.
	// Empty = written exactly like name (the overwhelmingly common case).
	nameSrc string
}

// trivia is comment trivia, verbatim from `#` to end of line. Never part of
// identity or reads; merged instances concatenate leading, first trailing
// wins (later ones demote to leading - a canonical line has room for one).
type trivia struct {
	leading  []lead
	trailing string // empty = none
	// Whole-line comments that followed this node's subtree at a deeper indent
	// than the next binding - they belong to this block, not the next node, so
	// a run trailing a block's last child stays put instead of re-attaching
	// dedented. Emitted after the subtree at this node's depth.
	after []lead
	// Whole-line comments written inside this node's block when no bound child
	// could take them - a header whose children are all commented still owns
	// those lines. Emitted after the subtree one level deeper than this node.
	inside []lead
	// Kept lines that sat among this node's stacked list elements, each with
	// the number of elements before it. They keep the list stacked on output,
	// so a line fixed by hand is still inside the list.
	among []amongLead
}

// amongLead is a kept line among a list's elements: how many came before it.
type amongLead struct {
	before int
	lead   lead
}

func (n *nodeData) leading() []lead {
	if n.trivia == nil {
		return nil
	}
	return n.trivia.leading
}

func (n *nodeData) trailing() string {
	if n.trivia == nil {
		return ""
	}
	return n.trivia.trailing
}

func (n *nodeData) after() []lead {
	if n.trivia == nil {
		return nil
	}
	return n.trivia.after
}

func (n *nodeData) inside() []lead {
	if n.trivia == nil {
		return nil
	}
	return n.trivia.inside
}

func (n *nodeData) among() []amongLead {
	if n.trivia == nil {
		return nil
	}
	return n.trivia.among
}

func (n *nodeData) trivMut() *trivia {
	if n.trivia == nil {
		n.trivia = &trivia{}
	}
	return n.trivia
}

// authored is the as-authored name spelling; empty nameSrc means "same as name".
func (n *nodeData) authored() string {
	if n.nameSrc == "" {
		return n.name
	}
	return n.nameSrc
}

// spelled stores a name's authored spelling: the empty sentinel when it
// matches the folded name, so the duplicate string never gets allocated.
func spelled(name, nameSrc string) string {
	if nameSrc == name {
		return ""
	}
	return nameSrc
}

// srcMatchesDisplay: true when a source value spelling is exactly the display
// form - the case where src need not be stored, since raw's fallback
// reproduces it.
func srcMatchesDisplay(v *value, s string) bool {
	switch v.kind {
	case vEmpty:
		return s == ""
	case vRaw:
		return s == v.raw.content
	}
	rest := s
	for i := range v.els {
		var ok bool
		if i > 0 {
			rest, ok = strings.CutPrefix(rest, ", ")
			if !ok {
				return false
			}
		}
		rest, ok = strings.CutPrefix(rest, v.els[i].text)
		if !ok {
			return false
		}
	}
	return rest == ""
}

// Document is a parsed SHCL document: the tree, its diagnostics, and its
// strictness level.
type Document struct {
	arena      []nodeData
	diags      []Diagnostic
	strictness Strictness
	orphans    []lead // top-level comments after the last binding line
	// Lines or values parsing dropped that canonical output cannot re-emit
	// (bad indentation, an unusable selector, past the depth cap, ...).
	// Content-malformed lines are NOT counted - they are retained as trivia
	// and survive a save. LostCount() serves it; SaveFile() gates on it.
	lost int
	// How many kept lines the document must still write: the load's, plus a
	// merged layer's, less those design.md's kept-lines table lets an edit
	// take. Fewer in the tree than this counts as lost.
	keptOwed int
	// Built on the first path lookup and kept current by the writer (a new
	// child appends, a removed one unlinks); only a merge drops it. Without it
	// every lookup scans the parent's children, so a flat document read or
	// written key by key was quadratic. Reads may run concurrently, so the
	// build is guarded and the pointer is atomic; a write is exclusive anyway.
	index   atomic.Pointer[nameIndex]
	indexMu sync.Mutex
	// probe is set only on the document a default form checks values against,
	// never on one a caller holds: setValue stops once the value is judged, so
	// a probe is never written. probeDoc is built on the first default form
	// that finds its path already there.
	probe    bool
	probeDoc *Document
	// kept: holds a misplaced line kept as written, so edits have to settle it.
	kept bool
	// What the last settle's kept lines were modeled through, and a sum of
	// it, so an edit that changes none of it skips the settle. Removing a
	// block above all of it goes unseen, which leaves kept set with no such
	// line left: the next check costs the same, and nothing is wrong.
	keptNear []nearNode
	keptSum  uint64
	// The parse's multi-line bindings, from the binding line to the last line
	// each took. Edits leave it alone; only a reparse reads it.
	ends [][2]int
	// Each line counted in lost, once per count, when the parse was asked for
	// them. Only a reparse reads it.
	dropped []int
	// The text a load kept for ToTextKeepLines(), and empty when that text was
	// already canonical, since the canonical form is then the one that keeps
	// its lines. A merge drops it: the layer's lines are not this text's. Nil
	// when none was kept.
	source *string
}

// nameIndex is the first child of each (parent, name), chained on to the next
// same-named sibling, plus the chain tail so an append is O(1). A hash
// collision chains a stranger in; the lookup checks the name, so the chain is
// only ever a superset.
type nameIndex struct {
	first    map[uint64]int
	last     map[uint64]int
	nextSame []int // per node; nilNode ends the chain
}

const nilNode = -1

func (ix *nameIndex) append(key uint64, node int) {
	for len(ix.nextSame) <= node {
		ix.nextSame = append(ix.nextSame, nilNode)
	}
	ix.nextSame[node] = nilNode
	if prev, seen := ix.last[key]; seen {
		ix.nextSame[prev] = node
	} else {
		ix.first[key] = node
	}
	ix.last[key] = node
}

// unlink walks the chain to find the predecessor; a chain is one name's
// siblings.
func (ix *nameIndex) unlink(key uint64, node int) {
	head, hit := ix.first[key]
	if !hit {
		return
	}
	next := ix.nextSame[node]
	if head == node {
		if next == nilNode {
			delete(ix.first, key)
			delete(ix.last, key)
		} else {
			ix.first[key] = next
		}
	} else {
		c := head
		for c != nilNode && ix.nextSame[c] != node {
			c = ix.nextSame[c]
		}
		if c == nilNode {
			return
		}
		ix.nextSame[c] = next
		if next == nilNode {
			ix.last[key] = c
		}
	}
	ix.nextSame[node] = nilNode
}

func nameKey(parent int, name string) uint64 {
	h := newFnv()
	h.dec(parent)
	h.byte(0xFF)
	h.bytes(name)
	return h.h
}

const root = 0

// dead is the stack entry for a binding line that was skipped: it still owns
// its indent level, so the lines written under it are skipped with it instead
// of re-parenting one level up.
const dead = -1

// unopened is the stack entry for a line whose indent matched no open level
// (E012): never a level a sibling can bind at, but deeper lines are still
// under it. It sits on top of the levels open before it without closing any
// of them.
const unopened = -2

// lazy is the stack entry for a field line refused for its value alone (E019,
// E023, E024): it binds nothing, but its path is fine, so the first line that
// binds under it opens the path as `name:` would and binds there.
const lazy = -3

// lazyLevel is a lazy level's line, for opening it: the stack entry it sits
// at, its path, and how many pending lines go with it, its own included.
type lazyLevel struct {
	at     int
	segs   []segment
	line   int
	indent string
	pend   int
	depth  int
}

// foldNodeInto merges a later instance into an earlier one under the in-file
// merge rule: children and trivia move over, first trailing wins (a second
// demotes to a leading line), first spelling stays. The caller drops the loser
// from the parent's child list; it keeps its arena slot, unreferenced.
func foldNodeInto(arena []nodeData, survivor, loser int) {
	kids := arena[loser].children
	arena[loser].children = nil
	for _, k := range kids {
		arena[k].parent = survivor
	}
	arena[survivor].children = append(arena[survivor].children, kids...)
	if lt := arena[loser].trivia; lt != nil {
		arena[loser].trivia = nil
		st := arena[survivor].trivMut()
		st.leading = append(st.leading, lt.leading...)
		if lt.trailing != "" {
			if st.trailing == "" {
				st.trailing = lt.trailing
			} else {
				st.leading = append(st.leading, plainLead(lt.trailing))
			}
		}
		st.after = append(st.after, lt.after...)
		st.inside = append(st.inside, lt.inside...)
		st.among = append(st.among, lt.among...)
		sort.SliceStable(st.among, func(i, j int) bool { return st.among[i].before < st.among[j].before })
	}
}

// settleBlock files a block's comments where a reload does, in place. A
// block's inside comments are written after its last child's block, at that
// child's level, so a reload files them as the last child's own. A child's
// comments at its own level sit right above the next sibling, so a reload
// files them as that sibling's leading ones, from the first one at that level
// on. The load runs this once the tree is final; a merge, a new child and the
// writer's fold run it where they change a child list, or the next step comes out
// differently depending on whether the file was saved in between. The text
// does not move. from is the first child whose leading list may gain, so a new
// last child costs one pair; it cannot put a fence after an empty binding
// either, so only a full pass looks for one.
func settleBlock(arena []nodeData, n, from int) {
	kids := arena[n].children
	if len(kids) == 0 {
		return
	}
	if from <= 1 {
		settleFenceTrailing(arena, n)
	}
	if t := arena[n].trivia; t != nil && len(t.inside) > 0 {
		kt := arena[kids[len(kids)-1]].trivMut()
		kt.after = append(kt.after, t.inside...)
		t.inside = nil
	}
	if from < 1 {
		from = 1
	}
	for i := from; i < len(kids); i++ {
		t := arena[kids[i-1]].trivia
		if t == nil {
			continue
		}
		at := 0
		for at < len(t.after) && t.after[at].depth != 0 {
			at++
		}
		if at == len(t.after) {
			continue
		}
		nt := arena[kids[i]].trivMut()
		moved := make([]lead, 0, len(t.after)-at+len(nt.leading))
		nt.leading = append(append(moved, t.after[at:]...), nt.leading...)
		t.after = t.after[:at:at]
	}
}

// settleFenceTrailing: a raw block after an empty binding of its name is
// written with the fence on the binding's line, where no comment can follow
// it, so the emitter writes its trailing comment on a line of its own above,
// after the node's blank. A reload files that line as a leading comment, so
// file it there now.
func settleFenceTrailing(arena []nodeData, n int) {
	fenced := func(nd *nodeData) bool { return nd.value.kind == vRaw && nd.trailing() != "" }
	hit := false
	for _, c := range arena[n].children {
		if fenced(&arena[c]) || stacks(&arena[c]) {
			hit = true
			break
		}
	}
	if !hit {
		return
	}
	empties := map[string]bool{}
	for _, c := range arena[n].children {
		nd := &arena[c]
		if fenced(nd) && empties[nd.name] {
			trailingToLeading(nd)
		} else if stacks(nd) && empties[nd.name] {
			unstack(nd)
		} else if nd.value.isEmpty() {
			empties[nd.name] = true
		}
	}
}

// stacks: written stacked, a list holding a kept line among its elements or
// after its last one.
func stacks(nd *nodeData) bool {
	if nd.value.kind != vCell {
		return false
	}
	if len(nd.among()) > 0 {
		return true
	}
	if nd.starList {
		for _, c := range nd.inside() {
			if !strings.HasPrefix(c.text, "#") {
				return true
			}
		}
	}
	return false
}

// unstack: a list after an empty binding of its name cannot be written
// stacked, since its bare header would merge into that binding on a reload.
// It goes inline, and the lines among its elements go above it, where a
// reload files what sits there.
func unstack(nd *nodeData) {
	nd.starList = false
	if t := nd.trivia; t != nil {
		for _, a := range t.among {
			t.leading = append(t.leading, a.lead)
		}
		t.among = nil
	}
}

// trailingToLeading: the trailing comment becomes the last leading line, taking
// the node's blank with it, which is the order the emitter writes them in.
func trailingToLeading(nd *nodeData) {
	t := nd.trivia
	t.leading = append(t.leading, lead{text: t.trailing, blankBefore: nd.blankBefore})
	t.trailing = ""
	nd.blankBefore = false
}

// settleFirstBlank: the emitter drops a blank before the first thing it
// prints, so a document that kept one there would not survive its own
// canonical form, and a merge or a new first line - where it is no longer
// first - would place a blank nobody wrote. Clear it wherever output starts.
func settleFirstBlank(arena []nodeData, orphans []lead) {
	if kids := arena[root].children; len(kids) > 0 {
		n := &arena[kids[0]]
		if n.trivia != nil && len(n.trivia.leading) > 0 {
			n.trivia.leading[0].blankBefore = false
		} else {
			n.blankBefore = false
		}
	} else if len(orphans) > 0 {
		orphans[0].blankBefore = false
	}
}

// MaxDepth is the maximum nesting depth (levels below the document root),
// enforced at load and by the Writer. Deeper lines are skipped with an E016
// error. The cap is what keeps the recursive tree walks (emit, merge, clone)
// safely inside every binding's stack, so a hostile or machine-generated
// document can make a load fail but never crash the consumer.
const MaxDepth = 512

// How much of a file's own name the temporary file beside it borrows, in bytes.
const tmpNameBytes = 64

// ---------------------------------------------------------------------------
// Tokenizer - the one place the lexical rules live
// ---------------------------------------------------------------------------
//
// Every reading of a line's parts goes through Tokenize: the parser's line
// dispatch, the path scanner behind every lookup and setter, the comment and
// comma splits, the element cap, the unterminated-quote check, SetLiteral
// and the CLI's --set split. Seven scanners used to have their own copy of
// these rules, and every scanner defect since July was two of them
// disagreeing. The rules, one sentence each:
//
//   - A piece (a name, a selector body, a value element) is quoted only when
//     its first character is a quote and the next matching quote is the last
//     thing before the piece ends; inside double quotes a backslash escapes the
//     next character, inside single quotes nothing does. Anywhere else a quote
//     is an ordinary character, and a piece that began with one it never closed
//     is kept literally and reported (E017).
//   - Escapes are processed inside double quotes only; bare text and single
//     quotes never process a backslash.
//   - `#` outside quotes opens a comment, wherever it sits.
//   - A space, a tab and a carriage return are blanks: trimmed at a piece's
//     edge, content in the middle of one.
//   - A bare name is ASCII letters, digits, `-` and `_`; a `[` right after a
//     name opens a selector, whose bare body runs to the first `]`; a `[` after
//     the separator starts the value, which the parser refuses (E019).
//   - A value is split on unquoted commas, each piece trimmed.
//
// Under RulesV2 the tokenizer reads the 2.x spellings instead, for Migrate: a
// backslash shields the next character in bare and single-quoted value text, a
// bare selector body still runs to its first `]`, a separator followed by `[`
// is the selector sugar, and an open quote swallows the rest of the line.

// Quote is how a piece was quoted. QuoteOpen is a piece that began with a
// quote and never closed with the matching quote as its last character: the
// whole piece is kept literally, quotes and all.
type Quote int

const (
	QuoteNone Quote = iota
	QuoteSingle
	QuoteDouble
	QuoteOpen
)

// Piece is one piece of the text: byte offsets of its content. For a quoted
// piece the quotes sit just outside the span; for an open or bare piece the
// span is the trimmed text itself.
type Piece struct {
	Start int
	End   int
	Quote Quote
}

// SegTok is one path segment: its name, an optional [selector] body, and
// whether the name was the bare `*` wildcard (lookups only).
type SegTok struct {
	Name     Piece
	Selector *Piece
	Star     bool
}

// Tokens is the spans of one line, or of one lookup path. Nothing is copied:
// every field is an offset into the text that was tokenized. Tokenize sets
// every field, so a zero Tokens is only a buffer to hand it.
type Tokens struct {
	Segments []SegTok
	// Sep is the offset of the separator (`:` on a line, `=` in --set); -1
	// when the path ran to the end of the text or into a comment.
	Sep int
	// Value is everything after the separator up to the comment, trimmed.
	Value [2]int
	// Elements are the value's comma-separated pieces, empty ones included,
	// each trimmed.
	Elements []Piece
	// Comment is the offset of the `#` that opens a trailing comment; -1
	// when there is none.
	Comment int
	// Fault is where the path stopped making sense (-1 when it did not), and
	// FaultReason says why. A faulted line is malformed as a whole (E014).
	Fault       int
	FaultReason string
	// Cap is the caller's element cap (0 = none): the scan stops as soon as
	// the value holds more elements than this, so a capped parse never builds
	// the array it is going to refuse. Kept across Tokenize calls.
	Cap int
	// Capped is true when the cap stopped the scan; Elements is then
	// incomplete.
	Capped bool
}

func (t *Tokens) clear() {
	t.Segments = t.Segments[:0]
	t.Sep = -1
	t.Value = [2]int{0, 0}
	t.Elements = t.Elements[:0]
	t.Comment = -1
	t.Fault = -1
	t.FaultReason = ""
	t.Capped = false
}

// ElementCount is how many elements the value holds: a quoted piece counts
// even when empty ("" is a real element), an empty bare slot does not.
func (t *Tokens) ElementCount() int {
	n := 0
	for i := range t.Elements {
		if t.Elements[i].Quote != QuoteNone || t.Elements[i].End > t.Elements[i].Start {
			n++
		}
	}
	return n
}

// Rules is which spelling the tokenizer reads.
type Rules int

const (
	// RulesCurrent is the current rules, listed at the top of this section.
	RulesCurrent Rules = iota
	// RulesV2 is the 2.x rules, for Migrate only.
	RulesV2
)

// isWspByte is a blank: space, tab, or a carriage return, which is trimmed
// wherever a blank is and content in the middle of a piece.
func isWspByte(b byte) bool {
	return b == ' ' || b == '\t' || b == '\r'
}

// looksLikeBinding: `* name: value` is the YAML habit for a list of objects.
// Here it is one string element, so the parser says so (H003): the text up to
// its first colon has no blank, and the colon ends the text or a blank follows
// it.
func looksLikeBinding(s string) bool {
	i := strings.IndexByte(s, ':')
	if i <= 0 {
		return false
	}
	for j := 0; j < i; j++ {
		if isWspByte(s[j]) {
			return false
		}
	}
	return i+1 == len(s) || isWspByte(s[i+1])
}

func isBareNameByte(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || isASCIIDigit(b) || b == '-' || b == '_'
}

func skipWsp(s string, pos int) int {
	for pos < len(s) && isWspByte(s[pos]) {
		pos++
	}
	return pos
}

// utf8Len is the byte length of the UTF-8 character that starts with b. The
// scan only ever compares against ASCII structure characters, which UTF-8
// guarantees cannot appear inside a multibyte sequence, so it advances by
// whole characters and every offset it records is a character boundary.
func utf8Len(b byte) int {
	switch {
	case b <= 0x7F:
		return 1
	case b >= 0xC0 && b <= 0xDF:
		return 2
	case b >= 0xE0 && b <= 0xEF:
		return 3
	}
	return 4
}

// quoteClose is the offset of the quote that closes the one at pos, or -1.
func quoteClose(s string, pos int, rules Rules) int {
	q := s[pos]
	escapes := q == '"' || rules == RulesV2
	i := pos + 1
	for i < len(s) {
		if escapes && s[i] == '\\' && i+1 < len(s) {
			i += 1 + utf8Len(s[i+1])
			continue
		}
		if s[i] == q {
			return i
		}
		i += utf8Len(s[i])
	}
	return -1
}

// commentAt is true when the byte at i opens a comment. Being outside quotes
// is the caller's business.
func commentAt(s string, i int) bool {
	return s[i] == '#'
}

// scanPiece reads one piece from pos: a value element up to an unquoted comma
// or comment, or a selector body up to an unquoted `]` (term). Returns the
// trimmed piece and the offset of what ended it: the terminator, a comment's
// `#`, or the end of the text. comments is false only for a selector body in
// a lookup path, where `[#N]` is the index spelling.
func scanPiece(s string, pos int, term byte, rules Rules, comments bool) (Piece, int) {
	clamp := func(i int) int {
		if i > len(s) {
			return len(s)
		}
		return i
	}
	pos = skipWsp(s, pos)
	start := pos
	quote := QuoteNone
	if pos < len(s) && (s[pos] == '"' || s[pos] == '\'') {
		if close := quoteClose(s, pos, rules); close >= 0 {
			// A value piece may also end at a comment or the line end;
			// a selector body ends at its bracket and nowhere else.
			i := skipWsp(s, close+1)
			var ended bool
			if i < len(s) {
				ended = s[i] == term || (term == ',' && commentAt(s, i))
			} else {
				ended = term == ','
			}
			if ended {
				q := QuoteSingle
				if s[pos] == '"' {
					q = QuoteDouble
				}
				return Piece{Start: pos + 1, End: close, Quote: q}, i
			}
			// Text after the closing quote: the quote was a character
			// after all, and the scan restarts at it. 2.x went on from
			// the close with the quotes read as a pair.
			quote = QuoteOpen
			if rules == RulesV2 {
				pos = close + 1
			}
		} else {
			quote = QuoteOpen
			if rules == RulesV2 {
				// 2.x: an open quote swallowed the rest of the line.
				end := len(s)
				for end > start && isWspByte(s[end-1]) {
					end--
				}
				return Piece{Start: start, End: end, Quote: quote}, len(s)
			}
		}
	}
	// 2.x shielded a backslash in value text only. A bare selector body ran to
	// its first `]`, the same as now, so shielding one here would hide the `]`.
	shield := rules == RulesV2 && term == ','
	contentEnd := start
	for pos < len(s) {
		b := s[pos]
		if shield && b == '\\' && pos+1 < len(s) {
			pos += 1 + utf8Len(s[pos+1])
			contentEnd = clamp(pos)
			continue
		}
		if b == term || (comments && commentAt(s, pos)) {
			break
		}
		pos += utf8Len(b)
		if !isWspByte(b) {
			contentEnd = clamp(pos)
		}
	}
	// 2.x judged a value piece quoted by its shape after the scan: a quote at
	// both ends, the last one not escaped, however many closes sat between. A
	// selector body had to close right before its `]`, or the line was E014.
	if rules == RulesV2 && term == ',' && quote == QuoteOpen && contentEnd-start >= 2 && s[contentEnd-1] == s[start] {
		run := 0
		for j := contentEnd - 2; j >= start && s[j] == '\\'; j-- {
			run++
		}
		if run%2 == 0 {
			q := QuoteSingle
			if s[start] == '"' {
				q = QuoteDouble
			}
			return Piece{Start: start + 1, End: contentEnd - 1, Quote: q}, clamp(pos)
		}
	}
	return Piece{Start: start, End: contentEnd, Quote: quote}, clamp(pos)
}

// TokenizeValue reads the value half: everything from the byte offset from on,
// split into pieces, with the comment found on the way. A negative offset
// reads as 0: the reference's offset is unsigned, so there is nothing else one
// can mean, and Go panicked on it (20260918b item 31).
func TokenizeValue(text string, from int, rules Rules, out *Tokens) {
	out.clear()
	if from < 0 {
		from = 0
	}
	scanValue(text, from, rules, out)
}

func scanValue(text string, from int, rules Rules, out *Tokens) {
	s := text
	pos := from
	var stopAt int
	count := 0
	for {
		piece, stop := scanPiece(s, pos, ',', rules, true)
		out.Elements = append(out.Elements, piece)
		if piece.Quote != QuoteNone || piece.End > piece.Start {
			count++
			if out.Cap != 0 && count > out.Cap {
				out.Capped = true
				out.Value = [2]int{from, from}
				return
			}
		}
		if stop < len(s) && s[stop] == ',' {
			pos = stop + 1
			continue
		}
		if stop < len(s) {
			out.Comment = stop
		}
		stopAt = stop
		break
	}
	a := skipWsp(s, from)
	b := stopAt
	for b > a && isWspByte(s[b-1]) {
		b--
	}
	if a > b {
		a = b
	}
	out.Value = [2]int{a, b}
	if n := len(out.Elements); n > 0 {
		last := &out.Elements[n-1]
		if last.Quote != QuoteSingle && last.Quote != QuoteDouble && last.End > b {
			last.End = b
			if last.End < last.Start {
				last.End = last.Start
			}
		}
	}
}

// Tokenize reads one line (sep = ':') or one lookup path (path: the bare `*`
// name wildcard is admitted, and a `#` in a selector body is the `[#N]` index
// rather than a comment); the CLI's --set passes '='. out is cleared and
// reused, so a parse allocates once per document rather than once per line.
// text is the line after its indent, or the path.
func Tokenize(text string, sep byte, path bool, rules Rules, out *Tokens) {
	out.clear()
	s := text
	pos := 0
	for {
		pos = skipWsp(s, pos)
		if pos >= len(s) {
			out.Fault, out.FaultReason = pos, "expected a field name"
			return
		}
		star := false
		var name Piece
		if s[pos] == '"' || s[pos] == '\'' {
			close := quoteClose(s, pos, rules)
			if close < 0 {
				out.Fault, out.FaultReason = pos, "unterminated quote in a field name"
				return
			}
			q := QuoteSingle
			if s[pos] == '"' {
				q = QuoteDouble
			}
			name = Piece{Start: pos + 1, End: close, Quote: q}
			pos = close + 1
		} else if path && s[pos] == '*' {
			star = true
			pos++
			name = Piece{Start: pos - 1, End: pos, Quote: QuoteNone}
		} else {
			start := pos
			for pos < len(s) && isBareNameByte(s[pos]) {
				pos++
			}
			if pos == start {
				out.Fault, out.FaultReason = pos, "expected a field name"
				return
			}
			name = Piece{Start: start, End: pos, Quote: QuoteNone}
		}
		pos = skipWsp(s, pos)
		var selector *Piece
		open := -1
		if pos < len(s) && s[pos] == '[' {
			open = pos
		}
		if open < 0 && rules == RulesV2 && pos < len(s) && s[pos] == sep {
			q := skipWsp(s, pos+1)
			if q < len(s) && s[q] == '[' {
				open = q
			}
		}
		if open >= 0 {
			if star {
				out.Fault, out.FaultReason = open, "selector on a name wildcard"
				return
			}
			piece, stop := scanPiece(s, open+1, ']', rules, !path)
			if stop >= len(s) || s[stop] != ']' {
				out.Fault, out.FaultReason = open, "unterminated selector"
				return
			}
			if piece.End == piece.Start && piece.Quote == QuoteNone {
				out.Fault, out.FaultReason = open, "empty selector"
				return
			}
			if piece.Quote == QuoteOpen && rules == RulesV2 {
				out.Fault, out.FaultReason = open, "unterminated quote in a selector"
				return
			}
			selector = &piece
			pos = skipWsp(s, stop+1)
		}
		out.Segments = append(out.Segments, SegTok{Name: name, Selector: selector, Star: star})
		if pos >= len(s) {
			return
		}
		b := s[pos]
		if b == '.' {
			pos++
			continue
		}
		if b == sep {
			out.Sep = pos
			scanValue(text, pos+1, rules, out)
			return
		}
		if commentAt(s, pos) {
			out.Comment = pos
			return
		}
		out.Fault, out.FaultReason = pos, "unexpected character after the path"
		return
	}
}

// pieceText is the text of a piece as the reader sees it: escapes applied
// inside double quotes, everything else as written.
func pieceText(p *Piece, text string) string {
	raw := text[p.Start:p.End]
	if p.Quote == QuoteDouble && strings.Contains(raw, "\\") {
		return applyEscapes(raw)
	}
	return raw
}

// pieceIs is true when a piece reads as this exact text, without building it.
func pieceIs(p *Piece, text, want string) bool {
	raw := text[p.Start:p.End]
	if p.Quote == QuoteDouble && strings.Contains(raw, "\\") {
		return applyEscapes(raw) == want
	}
	return raw == want
}

// elementOf is the element a value piece makes, or ok=false for an empty bare
// slot (dropped, never an error).
func elementOf(p *Piece, text string) (element, bool) {
	if p.Quote == QuoteNone && p.End == p.Start {
		return element{}, false
	}
	return element{text: pieceText(p, text), quoted: p.Quote == QuoteSingle || p.Quote == QuoteDouble}, true
}

// cellOfTokens is the value the tokenized pieces give.
func cellOfTokens(tok *Tokens, text string) value {
	els := make([]element, 0, len(tok.Elements))
	for i := range tok.Elements {
		if e, ok := elementOf(&tok.Elements[i], text); ok {
			els = append(els, e)
		}
	}
	if len(els) == 0 {
		return value{kind: vEmpty}
	}
	return value{kind: vCell, els: els}
}

// asciiLower folds A-Z only; non-ASCII passes through untouched. Nearly every
// name is already folded, so the scan comes first: copying and then finding
// nothing to change was the whole cost on the common path.
func asciiLower(s string) string {
	i := 0
	for ; i < len(s); i++ {
		if s[i] >= 'A' && s[i] <= 'Z' {
			break
		}
	}
	if i == len(s) {
		return s
	}
	b := []byte(s)
	for ; i < len(b); i++ {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

func isBareNameChar(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
}

func isASCIIAlpha(b byte) bool { return (b|0x20) >= 'a' && (b|0x20) <= 'z' }

func isASCIIDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

// allDigits reports whether every byte is an ASCII digit (true for "").
func allDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isASCIIDigit(s[i]) {
			return false
		}
	}
	return true
}

// stripSign removes one leading '+' or '-'.
func stripSign(s string) string {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		return s[1:]
	}
	return s
}

func trimEndWS(s string) string {
	return strings.TrimRightFunc(s, isWsp)
}

// isWsp is the grammar's wsp: a space, a tab or a carriage return. The parser
// trims with this and nothing wider - a no-break space or a line separator
// after a value is content, and a Unicode trim used to delete it with no
// diagnostic.
func isWsp(c rune) bool { return c == ' ' || c == '\t' || c == '\r' }

func trimWsp(s string) string { return strings.TrimFunc(s, isWsp) }

// leadingWS is the leading space/tab run of a line (the indent).
func leadingWS(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	return s[:i]
}

// oneLine is value text for a diagnostic message: line breaks and tabs escaped,
// so one diagnostic is one line. A raw block's body is the value that made this
// necessary - it contains its own newlines. The replacer is built once, since
// building it was most of what a validation with range faults allocated.
func oneLine(s string) string {
	return oneLineReplacer.Replace(s)
}

var oneLineReplacer = strings.NewReplacer("\\", "\\\\", "\n", "\\n", "\r", "\\r", "\t", "\\t")

// schemaText is schema text for a diagnostic or a generated comment: a path or
// a type as the schema wrote it, with a line break written `\n`, so one
// diagnostic stays one line. Only the break is escaped, so a path reads the
// way it was written.
func schemaText(s string) string {
	return strings.ReplaceAll(s, "\n", "\\n")
}

// applyEscapes handles string reads: \t \n \\ \" \' \uXXXX \UXXXXXXXX. An
// unknown pair stays literal, which only 2.x text still reaches: the current
// rules refuse one (E023) before anything is read.
func applyEscapes(s string) string {
	return resolveEscapes(s, RulesCurrent)
}

// applyEscapesV2 is the 2.x reading, for migrate: no \u, so 2.x kept
// \u0041 as written.
func applyEscapesV2(s string) string {
	return resolveEscapes(s, RulesV2)
}

func resolveEscapes(s string, rules Rules) string {
	// Bytes: every escape this recognizes is ASCII, and any other byte - a
	// continuation byte included - is copied through untouched, so the result
	// is the same string the rune walk built without decoding and re-encoding
	// it. This runs on every string read and on every selector compare.
	if !strings.ContainsRune(s, '\\') {
		return s
	}
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c != '\\' {
			out = append(out, c)
			continue
		}
		if i+1 >= len(s) {
			out = append(out, '\\')
			break
		}
		i++
		switch s[i] {
		case 't':
			out = append(out, '\t')
		case 'n':
			out = append(out, '\n')
		case '\\':
			out = append(out, '\\')
		case '"':
			out = append(out, '"')
		case '\'':
			out = append(out, '\'')
		case 'u', 'U':
			if r, n, ok := unicodeEscape(s[i], s[i+1:]); ok && rules == RulesCurrent {
				out = utf8.AppendRune(out, r)
				i += n
			} else {
				out = append(out, '\\', s[i])
			}
		default:
			out = append(out, '\\', s[i])
		}
	}
	return string(out)
}

// unicodeEscape is the character a \u or \U escape names, and how many hex
// digits it takes: four after u, eight after U, as in TOML. Not ok for a
// short run, a surrogate or a value past U+10FFFF.
func unicodeEscape(kind byte, after string) (rune, int, bool) {
	n := 4
	if kind == 'U' {
		n = 8
	}
	if len(after) < n {
		return 0, 0, false
	}
	var v uint32
	for i := 0; i < n; i++ {
		d := hexDigit(after[i])
		if d < 0 {
			return 0, 0, false
		}
		v = v<<4 | uint32(d)
	}
	if v > unicode.MaxRune || (v >= 0xD800 && v <= 0xDFFF) {
		return 0, 0, false
	}
	return rune(v), n, true
}

// gen-escapes.py: begin
// Generated from Unicode 18.0 by cicd/utility/gen-escapes.py. Edit the script, not this block.
var invisibleRanges = [][2]rune{
	{0x0000, 0x0008},
	{0x000B, 0x001F},
	{0x007F, 0x009F},
	{0x00AD, 0x00AD},
	{0x034F, 0x034F},
	{0x061C, 0x061C},
	{0x115F, 0x1160},
	{0x17B4, 0x17B5},
	{0x180B, 0x180F},
	{0x200B, 0x200B},
	{0x200E, 0x200F},
	{0x2028, 0x202E},
	{0x2060, 0x206F},
	{0x3164, 0x3164},
	{0xFE00, 0xFE0F},
	{0xFEFF, 0xFEFF},
	{0xFFA0, 0xFFA0},
	{0xFFF0, 0xFFFB},
	{0x1BCA0, 0x1BCA3},
	{0x1D173, 0x1D17A},
	{0xE0000, 0xE0FFF},
}
var selectorRanges = [][2]rune{
	{0x180B, 0x180D},
	{0x180F, 0x180F},
	{0xFE00, 0xFE0F},
	{0xE0100, 0xE01EF},
}

// gen-escapes.py: end

// invisible reports a character canonical output writes as a \u escape, so a
// reader of the file sees every character that is there: controls with no
// short escape, the line and paragraph separators, the interlinear annotation
// marks, and what Unicode calls default-ignorable, such as zero-width spaces,
// direction marks and tag characters. The zero-width joiner and non-joiner are
// not in the list, since emoji and several scripts need them, and invisibleAt
// keeps two more kinds where text needs them.
func invisible(r rune) bool {
	return (r < ' ' || r > '~') && inRanges(invisibleRanges, r)
}

func inRanges(ranges [][2]rune, r rune) bool {
	for _, rg := range ranges {
		if r < rg[0] {
			return false
		}
		if r <= rg[1] {
			return true
		}
	}
	return false
}

// invisibleAt decodes the character at t[i] with its width in bytes, and
// reports whether it is written as a \u escape. A variation selector stays as
// written directly after a visible character, and the tags of a subdivision
// flag stay too; anywhere else they hide text. Bytes that are not UTF-8 are
// never escaped.
func invisibleAt(t string, i int) (rune, int, bool) {
	r, n := rune(t[i]), 1
	if r >= utf8.RuneSelf {
		r, n = utf8.DecodeRuneInString(t[i:])
		if r == utf8.RuneError {
			return 0, 1, false
		}
	}
	if !invisible(r) {
		return r, n, false
	}
	if inRanges(selectorRanges, r) {
		p, pn := utf8.DecodeLastRuneInString(t[:i])
		return r, n, !(pn > 0 && !(p == utf8.RuneError && pn == 1) && selectorBase(p))
	}
	if r >= 0xE0020 && r <= 0xE007F {
		return r, n, !flagTag(t, i)
	}
	return r, n, true
}

// selectorBase reports a character a variation selector can modify: one
// written as itself that is not a blank or a joiner. Another selector is not
// one, so a run of them cannot contain hidden text.
func selectorBase(r rune) bool {
	return r > ' ' && r != 0x200C && r != 0x200D && !invisible(r)
}

// flagTag reports whether the tag at t[i] is part of a subdivision flag, as
// UTS #51 defines one: U+1F3F4, three to seven tag digits or lowercase tag
// letters, and the cancel tag.
func flagTag(t string, i int) bool {
	spec := func(r rune) bool { return (r >= 0xE0030 && r <= 0xE0039) || (r >= 0xE0061 && r <= 0xE007A) }
	start, count := i, 0
	for start > 0 {
		r, n := utf8.DecodeLastRuneInString(t[:start])
		if !spec(r) {
			break
		}
		count++
		if count > 7 {
			return false
		}
		start -= n
	}
	if !strings.HasSuffix(t[:start], "\U0001F3F4") {
		return false
	}
	count = 0
	for _, r := range t[start:] {
		if !spec(r) {
			return r == 0xE007F && count >= 3
		}
		count++
		if count > 7 {
			return false
		}
	}
	return false
}

// hasInvisible reports whether the text holds a character invisibleAt
// escapes.
func hasInvisible(t string) bool {
	for i := 0; i < len(t); {
		_, n, ok := invisibleAt(t, i)
		if ok {
			return true
		}
		i += n
	}
	return false
}

// writeUnicodeEscape writes r as \u with four digits, or as \U with eight
// past U+FFFF, since \u takes four.
func writeUnicodeEscape(out *strings.Builder, r rune) {
	if r > 0xFFFF {
		fmt.Fprintf(out, "\\U%08X", r)
		return
	}
	fmt.Fprintf(out, "\\u%04X", r)
}

// singleScalar is the restriction a QUOTED [value] selector adds on top of
// the display match: quoting selects the scalar spelling only, so the scalar
// "a, b" and the list a, b stop meeting the same selector.
func singleScalar(v *value) bool {
	return v.kind == vCell && len(v.els) == 1
}

// dispKey is the predicate a [value] selector matches with: the display form,
// which is built from logical strings, so ["q\"uote"] finds 'q"uote' - a
// logical-string match, not spelling against spelling.
func dispKey(v *value) string {
	return v.display()
}

// fnv is FNV-1a, fed the same byte sequence the key strings would contain -
// the accelerator maps key on a uint64 and verify hits against the arena, so
// the strings themselves never get built. The hash only has to be stable
// within one parse, not injective; a collision just chains in the slot.
type fnv struct {
	h uint64
}

func newFnv() fnv {
	return fnv{h: 0xcbf29ce484222325}
}

func (f *fnv) byte(b byte) {
	f.h = (f.h ^ uint64(b)) * 0x100000001b3
}

func (f *fnv) bytes(s string) {
	for i := 0; i < len(s); i++ {
		f.byte(s[i])
	}
}

// dec writes a length prefix in decimal, without allocating.
func (f *fnv) dec(n int) {
	var buf [20]byte
	i := len(buf)
	for {
		i--
		buf[i] = '0' + byte(n%10)
		n /= 10
		if n == 0 {
			break
		}
	}
	for ; i < len(buf); i++ {
		f.byte(buf[i])
	}
}

// mergeHash hashes the (name, merge-key) pair: nodes with equal pairs
// collapse into one. The key is 'e', or each cell element (and the raw
// info-string) length-prefixed so the sequence is injective - a bare NUL
// separator lets `[a, b]` collide with the single element "a\0b". Info-string
// is part of identity (a `sql` and a `python` block are different values even
// with equal bodies); fence style is not.
func mergeHash(name string, v *value) uint64 {
	f := newFnv()
	f.bytes(name)
	f.byte(0xFF) // separator; equality still verifies both parts
	switch v.kind {
	case vEmpty:
		f.byte('e')
	case vCell:
		f.bytes("c:")
		for i := range v.els {
			f.dec(len(v.els[i].text))
			f.byte(':')
			f.bytes(v.els[i].text)
		}
	default:
		f.bytes("r:")
		f.dec(len(v.raw.info))
		f.byte(':')
		f.bytes(v.raw.info)
		f.bytes(v.raw.content)
	}
	return f.h
}

// valueHash hashes the value's merge key alone (no name part).
func valueHash(v *value) uint64 {
	return mergeHash("", v)
}

// mergeEq is the exact (name, merge-key) equality a hashed hit is verified
// with - compares what the two key strings would hold, element by element.
func mergeEq(nameA string, va *value, nameB string, vb *value) bool {
	if nameA != nameB || va.kind != vb.kind {
		return false
	}
	switch va.kind {
	case vEmpty:
		return true
	case vCell:
		if len(va.els) != len(vb.els) {
			return false
		}
		for i := range va.els {
			if va.els[i].text != vb.els[i].text {
				return false
			}
		}
		return true
	}
	return va.raw.info == vb.raw.info && va.raw.content == vb.raw.content
}

// dispHash hashes the (name, display) pair a `[value]` selector matches with -
// what dispKey would give, streamed instead of built. Elements hold the
// logical string, so the bytes feed straight in.
func dispHash(name string, v *value) uint64 {
	f := newFnv()
	f.bytes(name)
	f.byte(0xFF)
	switch v.kind {
	case vEmpty:
	case vCell:
		for i := range v.els {
			if i > 0 {
				f.bytes(", ")
			}
			f.bytes(v.els[i].text)
		}
	default:
		f.bytes(v.raw.content)
	}
	return f.h
}

// dispHashText is the query-side twin of dispHash: the selector's logical
// text, the same bytes the display would contain.
func dispHashText(name, want string) uint64 {
	f := newFnv()
	f.bytes(name)
	f.byte(0xFF)
	f.bytes(want)
	return f.h
}

// slot is one accelerator bucket: node indices in insertion order. Nearly
// always one entry; a second means two different keys collided in the 64-bit
// hash.
type slot struct {
	one  int
	many []int // nil = the single entry is `one`
}

func (s *slot) push(idx int) {
	if s.many == nil {
		s.many = []int{s.one, idx}
	} else {
		s.many = append(s.many, idx)
	}
}

func (s *slot) firstMatch(f func(int) bool) (int, bool) {
	if s.many == nil {
		if f(s.one) {
			return s.one, true
		}
		return 0, false
	}
	for _, c := range s.many {
		if f(c) {
			return c, true
		}
	}
	return 0, false
}

// remove drops idx if present; true = the slot is now empty and the caller
// should remove the map entry.
func (s *slot) remove(idx int) bool {
	if s.many == nil {
		return s.one == idx
	}
	kept := s.many[:0]
	for _, c := range s.many {
		if c != idx {
			kept = append(kept, c)
		}
	}
	if len(kept) == 1 {
		s.one = kept[0]
		s.many = nil
		return false
	}
	s.many = kept
	return len(kept) == 0
}

// The bucket helpers below do the read-modify-write a map entry needs
// (map values are not addressable), so the call sites stay one line each.

// slotInsert chains idx into the bucket at h, insertion order preserved.
func slotInsert(m map[uint64]slot, h uint64, idx int) {
	if s, ok := m[h]; ok {
		s.push(idx)
		m[h] = s
	} else {
		m[h] = slot{one: idx}
	}
}

// slotFirstMatch: the first index in the bucket at h passing the verify
// callback (nil map = no bucket).
func slotFirstMatch(m map[uint64]slot, h uint64, f func(int) bool) (int, bool) {
	if m == nil {
		return 0, false
	}
	s, ok := m[h]
	if !ok {
		return 0, false
	}
	return s.firstMatch(f)
}

// slotRemove drops idx from the bucket at h, deleting the entry when it empties.
func slotRemove(m map[uint64]slot, h uint64, idx int) {
	s, ok := m[h]
	if !ok {
		return
	}
	if s.remove(idx) {
		delete(m, h)
	} else {
		m[h] = s
	}
}

// childFence is the fence a line opens under the field above it, read as a
// value.
func childFence(rest string, tok *Tokens) (ch byte, length int, info string, ok bool) {
	TokenizeValue(rest, 0, RulesCurrent, tok)
	// A capped scan zeroed the value, and a fence is told by its leading run
	// alone.
	if tok.Capped {
		return fenceOpen(rest)
	}
	return fenceOpen(rest[tok.Value[0]:tok.Value[1]])
}

// fenceOpen matches an opening fence: a run of >=3 backticks or tildes, then
// an optional info-string.
func fenceOpen(rest string) (ch byte, length int, info string, ok bool) {
	if rest == "" {
		return 0, 0, "", false
	}
	first := rest[0]
	if first != '`' && first != '~' {
		return 0, 0, "", false
	}
	run := 0
	for run < len(rest) && rest[run] == first {
		run++
	}
	if run < 3 {
		return 0, 0, "", false
	}
	return first, run, trimWsp(rest[run:]), true
}

// minLen is the opening fence's length, which the grammar puts at three or
// more, so the length test already rules out the empty line the loop below
// would otherwise accept.
func isFenceClose(line string, ch byte, minLen int) bool {
	// A raw body keeps its carriage returns, so only a space or tab is trimmed.
	t := strings.Trim(line, " \t")
	if len(t) < minLen {
		return false
	}
	for i := 0; i < len(t); i++ {
		if t[i] != ch {
			return false
		}
	}
	return true
}

// stripCommon removes a raw block's nesting indent from one content line: only
// what the line actually shares with it, so a shallower line (whitespace-only,
// or written flush left) keeps its own spacing rather than being blanked.
func stripCommon(line, common string) string {
	k := 0
	for k < len(common) && k < len(line) && common[k] == line[k] {
		k++
	}
	return line[k:]
}

// ---------------------------------------------------------------------------
// Migration: a 2.x document rewritten for the current lexical rules
// ---------------------------------------------------------------------------

// openFence is the fence a migration is inside, so its body passes through
// untouched.
type openFence struct {
	ch     byte
	length int
	open   bool
}

// FormatMajor is the format major the info block names. It moves with the
// format, not with the module: a file says which rule set it was written for,
// and nothing else does. The banner's Syntax link names the tag that opened
// this major, and moves with it.
const FormatMajor = 3

// FormatLineHead is the start of the block's version line, up to the number.
// Migrate matches on this and reads the digits after it, so a later major can
// still tell an older file from one of its own.
const FormatLineHead = "##    Format   "

// FormatLine is the whole version line, as the block has it. A program
// writing a config of its own emits GenBanner, which includes this; Migrate
// appends this line on its own to a file it rewrote, since that file has no
// block to add it to and inventing one would write bytes the document does
// not hold.
const FormatLine = "##    Format   3"

// SchemaLineHead is the start of a line naming the file's schema, written
// like the Format line, for check and for editors:
// `##    Schema   ./app.schema.shcl`.
const SchemaLineHead = "##    Schema   "

// The info block's first two text lines. SetBanner finds an old block by the
// first, which no release has worded differently.
const (
	bannerTitle = "## This config file format is SHCL."
	bannerName  = "## \"Simple Hierarchical Config Language\""
)

// MigratedLine is written under FormatLine on a file Migrate actually changed.
// It is a note for whoever opens the file; nothing reads it back.
const MigratedLine = "##    Migrated from SHCL 2.x."

// Migration is what Migrate produced, and what it could not keep.
type Migration struct {
	Text string
	// Current: the file already names its format, so there was nothing to
	// migrate and Text is the input.
	Current bool
	// Ambiguous: pieces the two rule sets read differently and nothing can
	// decide between, left as written. Always 0 when the caller said 2.x.
	Ambiguous int
	// Lost: lines 2.x bound a value on that nothing binds now - bracket text
	// after the colon, or a line break in a value that starts like a Windows
	// path, neither of which has a spelling here.
	Lost int
}

// migrating keeps the counters a line rewrite reports back, and the one
// thing it asks.
type migrating struct {
	fromV2    bool
	ambiguous int
	lost      int
}

// FormatVersion is the format major a document's `##    Format   N` line
// names, read the way Migrate reads it. ok is false when no line names one,
// which is every 2.x file and a current one written without the info block.
// Migrate hands a file back untouched exactly when this is FormatMajor or
// more, so a program can ask before it rewrites anything.
func FormatVersion(text string) (int, bool) {
	return formatLineVersion(strings.TrimPrefix(text, "\ufeff"))
}

// SchemaRef is the schema a document's `##    Schema   REF` line names: a
// path, or a URL for an editor to fetch. ok is false when no line names one.
// The first such line wins, and one inside a raw body is that block's
// content, as with the Format line. Either line may be indented, since the
// formatter indents a comment to the field below it. A relative path is the
// caller's to resolve, from the config file's directory.
func SchemaRef(text string) (string, bool) {
	text = strings.TrimPrefix(text, "\ufeff")
	// The Schema line is new in this format, so the blocks are the parser's.
	lines := newRawLines(RulesCurrent)
	for _, line := range strings.Split(text, "\n") {
		rest, ok := lines.step(line)
		if !ok {
			continue
		}
		if r, ok := strings.CutPrefix(rest, SchemaLineHead); ok {
			if r = trimWsp(r); r != "" {
				return r, true
			}
		}
	}
	return "", false
}

// rawLines walks a document's lines and tells raw-body content from the rest,
// the way one rule set reads the file: the current rules find a block where
// the parser does, and the 2.x rules where the rewrite does.
type rawLines struct {
	rules Rules
	tok   Tokens
	fence openFence
	// Only the blocks a line opens are wanted, not what the rewrite counts.
	dry migrating
}

func newRawLines(rules Rules) *rawLines {
	return &rawLines{rules: rules, dry: migrating{fromV2: true}}
}

// step reads the next line. ok is false when it is part of a raw block,
// fences included; otherwise rest is its text past the indent.
func (w *rawLines) step(line string) (rest string, ok bool) {
	body := strings.TrimRight(line, "\r")
	if w.fence.open {
		if isFenceClose(body, w.fence.ch, w.fence.length) {
			w.fence.open = false
		}
		return "", false
	}
	rest = trimEndWS(body[len(leadingWS(body)):])
	// Only a line with a run of three backticks or tildes can open a block,
	// so the rest skip the tokenizer.
	if strings.Contains(rest, "```") || strings.Contains(rest, "~~~") {
		if w.rules == RulesCurrent {
			w.fence = opensRaw(rest, &w.tok)
		} else {
			migrateLine(rest, &w.tok, &w.fence, &w.dry)
		}
	}
	return rest, true
}

// opensRaw is the raw block a line opens under the current rules: a fence
// line under a field, or a field line whose value is a fence, read as the
// parser reads them. A line refused for where it sits or for its text still
// takes its body.
func opensRaw(rest string, tok *Tokens) openFence {
	rest = strings.TrimLeftFunc(rest, isWsp)
	var ch byte
	var length int
	var ok bool
	switch {
	case rest[0] == '`' || rest[0] == '~':
		ch, length, _, ok = childFence(rest, tok)
	case rest[0] == '#' || rest[0] == '*':
	default:
		Tokenize(rest, ':', false, RulesCurrent, tok)
		ch, length, _, ok = lineFence(tok, rest)
	}
	return openFence{ch: ch, length: length, open: ok}
}

// formatLineVersion is FormatVersion on text with the BOM already off. Digits
// that do not fit 32 bits are not a 2.x file either, so they read as this
// major and there is nothing to migrate.
//
// A Format line pasted into a raw body is that block's content, and taking it
// as the file's would rewrite a current file, or leave an old one alone. Where
// the blocks are turns on the rules the file was written under, which is what
// the line itself says: a line naming this format counts outside the blocks
// the parser finds, and an older one outside the blocks the rewrite skips. The
// two differ on a single-quoted name ending in a backslash. A file naming this
// format on any line has nothing to migrate, so the highest line decides: the
// stamp Migrate adds comes after an older one, and the next run has to see it.
func formatLineVersion(text string) (int, bool) {
	now := newRawLines(RulesCurrent)
	then := newRawLines(RulesV2)
	found, has := 0, false
	for _, line := range strings.Split(text, "\n") {
		current, inNow := now.step(line)
		old, inThen := then.step(line)
		rest := current
		if !inNow {
			rest = old
		}
		n, ok := strings.CutPrefix(rest, FormatLineHead)
		if !(inNow || inThen) || !ok || n == "" {
			continue
		}
		digits := true
		for i := 0; i < len(n); i++ {
			if n[i] < '0' || n[i] > '9' {
				digits = false
				break
			}
		}
		if !digits {
			continue
		}
		v, err := strconv.Atoi(n)
		if err != nil || v > math.MaxUint32 {
			v = FormatMajor
		}
		if v >= FormatMajor {
			if inNow {
				return v, true
			}
		} else if inThen && (!has || v > found) {
			found, has = v, true
		}
	}
	return found, has
}

// Migrate rewrites a document written under the 2.x rules so this parser
// reads the same tree. Each line is read with the 2.x tokenizer and
// rewritten only where the two rule sets disagree: a bare or single-quoted
// piece whose backslash meant an escape is double-quoted with that escape; a
// piece that opened a quote it never closed is quoted whole; the
// `name:[disc]` selector sugar loses its colon, and on a last segment becomes
// `name: disc`, with `disc` written the way the formatter writes a value. A
// rewritten piece holding a backslash is double-quoted, so the result reads
// the same under 2.x and a second run changes nothing.
// Everything else - comments, blank lines, raw bodies, layout, a line 2.x
// could not read - comes through as written. One shape has no spelling here
// at all: a fence label holding a `#`, which 2.x ran to the end of the line
// and which now ends at the `#`.
// Which file this is cannot be read off the text: `p: 'C:\temp'` is one value
// under 2.x and another under these rules, so rewriting a 3.0 file changes
// what it says. So the version line decides. A file that names this format is
// returned untouched; one that names an older format, or a caller passing
// fromV2, gets the backslash re-spellings; anything else gets every other
// rewrite and leaves those pieces alone, counted in Ambiguous for the caller
// to refuse over. A rewritten file is stamped with the version line, so the
// second run has an answer the first one did not.
func Migrate(text string, fromV2 bool) Migration {
	return migrateText(text, fromV2, true)
}

// MigrateUnstamped is Migrate without the version line or the migrated note,
// for a program that writes GenBanner itself, which includes the version line.
// The next run can tell the result is current only once that is written.
func MigrateUnstamped(text string, fromV2 bool) Migration {
	return migrateText(text, fromV2, false)
}

// majorityEol is the line ending most of the text's lines end with. A tie
// goes to LF.
func majorityEol(text string) string {
	crlf := strings.Count(text, "\r\n")
	lf := strings.Count(text, "\n") - crlf
	if crlf > lf {
		return "\r\n"
	}
	return "\n"
}

func migrateText(text string, fromV2, stamp bool) Migration {
	whole := text
	bom := ""
	if strings.HasPrefix(text, "\ufeff") {
		bom = "\ufeff"
		text = text[len(bom):]
	}
	version, hasVersion := formatLineVersion(text)
	if hasVersion && version >= FormatMajor {
		return Migration{Text: whole, Current: true}
	}
	st := migrating{fromV2: fromV2 || hasVersion}
	var out strings.Builder
	out.Grow(len(text) + 96)
	out.WriteString(bom)
	var tok Tokens
	var fence openFence
	changed := false
	// The output as the parser will read it, for where its raw blocks are.
	now := newRawLines(RulesCurrent)
	split := false
	for i, line := range strings.Split(text, "\n") {
		if i > 0 {
			out.WriteByte('\n')
		}
		start := out.Len()
		rawThen := fence.open
		body := strings.TrimRight(line, "\r")
		cr := line[len(body):]
		if fence.open {
			if isFenceClose(body, fence.ch, fence.length) {
				fence.open = false
			}
			out.WriteString(line)
		} else {
			indent := leadingWS(body)
			restFull := body[len(indent):]
			rest := trimEndWS(restFull)
			// lost counts lines, and one line can lose several values.
			lostBefore := st.lost
			migrated := migrateLine(rest, &tok, &fence, &st)
			if st.lost > lostBefore {
				st.lost = lostBefore + 1
			}
			if migrated != rest {
				changed = true
			}
			out.WriteString(indent)
			out.WriteString(migrated)
			out.WriteString(restFull[len(rest):])
			out.WriteString(cr)
		}
		// Lines one rule set reads as a raw body and the other as fields are
		// one more thing that reads two ways, counted once per run of them.
		_, outside := now.step(out.String()[start:])
		differs := !outside != rawThen
		if differs && !split && !st.fromV2 {
			st.ambiguous++
		}
		split = differs
	}
	// Stamping a file whose ambiguous pieces were left alone would claim a
	// migration that did not finish, and the next run would then skip it. A
	// document that never closes its raw block has nowhere to put the line
	// either, under either rule set: appended, it would be another line of the
	// block's content. The lines end the way most of the file's do.
	if stamp && st.ambiguous == 0 && !fence.open && !now.fence.open {
		eol := majorityEol(text)
		s := out.String()
		if s != "" && !strings.HasSuffix(s, "\n") {
			out.WriteString(eol)
		}
		out.WriteString(FormatLine)
		out.WriteString(eol)
		if changed {
			out.WriteString(MigratedLine)
			out.WriteString(eol)
		}
	}
	return Migration{Text: out.String(), Ambiguous: st.ambiguous, Lost: st.lost}
}

// edit is one edit to a line: replace start..end with the text.
type edit struct {
	start int
	end   int
	with  string
}

func splice(text string, edits []edit) string {
	sort.SliceStable(edits, func(a, b int) bool { return edits[a].start < edits[b].start })
	var out strings.Builder
	out.Grow(len(text) + 8)
	at := 0
	for _, e := range edits {
		out.WriteString(text[at:e.start])
		out.WriteString(e.with)
		at = e.end
	}
	out.WriteString(text[at:])
	return out.String()
}

// readsSame is true when the current tokenizer reads this spelling as one
// whole piece, quoted the same way, with exactly this text, so nothing has
// to change.
func readsSame(spelling string, quoted bool, logical string) bool {
	var tok Tokens
	TokenizeValue(spelling, 0, RulesCurrent, &tok)
	if len(tok.Elements) != 1 || tok.Value != [2]int{0, len(spelling)} {
		return false
	}
	if _, bad := badEscape(&tok, spelling, true); bad {
		return false
	}
	p := &tok.Elements[0]
	return (p.Quote == QuoteSingle || p.Quote == QuoteDouble) == quoted &&
		p.Quote != QuoteOpen && !pathLike(p, spelling) && pieceText(p, spelling) == logical
}

// migrateSpelling is how a changed piece is written. 2.x read a backslash
// in bare and single-quoted text as an escape too, and double quotes are
// where both rule sets read one alike. No \u goes in, since 2.x would keep it
// as written. So the migrated file reads the same under 2.x, and a second run
// changes nothing. A line break in a value that starts like a Windows path
// has no such spelling: written this way it is E024, so the caller counts it
// lost.
func migrateSpelling(logical string, bare bool) string {
	if strings.Contains(logical, "\\") {
		return quoteDoubleAs(logical, RulesV2)
	}
	if bare && !needsQuotes(logical) {
		return logical
	}
	return quoteTextAs(logical, RulesV2)
}

// v2BracketArray is true when 2.x read this bare `[...]` body as the JSON-habit
// array rather than a discriminator: more than one element, where a comma
// behind a backslash was not one.
func v2BracketArray(body string) bool {
	var tok Tokens
	TokenizeValue(body, 0, RulesV2, &tok)
	return len(tok.Elements) > 1
}

// valueEdits collects the re-spellings a value's pieces need. Each piece is
// read the 2.x way (escapes everywhere, an open quote kept whole, a quote at
// both ends making it quoted) and rewritten only where the current rules
// would read the same text as something else.
func valueEdits(text string, tok *Tokens, edits *[]edit, st *migrating) {
	for i := range tok.Elements {
		p := &tok.Elements[i]
		raw := text[p.Start:p.End]
		quoted := p.Quote == QuoteSingle || p.Quote == QuoteDouble
		a, b := p.Start, p.End
		if quoted {
			a, b = p.Start-1, p.End+1
		}
		if p.Quote == QuoteNone && !strings.Contains(raw, "\\") && raw != "" {
			continue
		}
		logical := applyEscapesV2(raw)
		if readsSame(text[a:b], quoted, logical) {
			continue
		}
		// A resolved escape is the one edit that turns on which rule set wrote
		// the file: these bytes say one thing under 2.x and another here. An
		// open quote or an empty slot reads alike either way, so it still goes,
		// and so does an unknown pair in double quotes, which both kept. A \u
		// in double quotes is a character now and was text in 2.x.
		differs := logical != raw
		if p.Quote == QuoteDouble {
			differs = unicodePairDiffers(raw)
		}
		if differs && !st.fromV2 {
			st.ambiguous++
			continue
		}
		spelling := migrateSpelling(logical, !(quoted || p.Quote == QuoteOpen))
		// Written the way 2.x read it, the line is E024 and binds nothing.
		if strings.HasPrefix(spelling, "\"") && spellsPathEscape(spelling) {
			st.lost++
		}
		*edits = append(*edits, edit{start: a, end: b, with: spelling})
	}
}

func migrateLine(rest string, tok *Tokens, fence *openFence, st *migrating) string {
	if rest == "" || strings.HasPrefix(rest, "#") {
		return rest
	}
	// A child-indent fence: 2.x read the info string to the end of the line.
	if ch, length, _, ok := fenceOpen(rest); ok {
		*fence = openFence{ch: ch, length: length, open: true}
		return rest
	}
	s := rest
	var edits []edit
	if strings.HasPrefix(rest, "*") && len(s) > 1 && isWspByte(s[1]) {
		TokenizeValue(rest, 1, RulesV2, tok)
		// A bare comma was refused (E010), so there is nothing to convert.
		if len(tok.Elements) == 1 {
			valueEdits(rest, tok, &edits, st)
		}
	} else {
		Tokenize(rest, ':', false, RulesV2, tok)
		if tok.Fault >= 0 {
			return rest
		}
		last := len(tok.Segments) - 1
		for i := range tok.Segments {
			seg := &tok.Segments[i]
			name := rest[seg.Name.Start:seg.Name.End]
			// An unknown pair in double quotes read the same in 2.x, and is
			// E023 now, so its backslash is doubled whichever wrote the file.
			// A \u pair is a character now, so that one needs --from-2x.
			if seg.Name.Quote == QuoteDouble && v2KeptEscape(name) {
				if unicodePairDiffers(name) && !st.fromV2 {
					st.ambiguous++
				} else {
					edits = append(edits, edit{start: seg.Name.Start - 1, end: seg.Name.End + 1, with: escapeNameAs(applyEscapesV2(name), RulesV2)})
				}
			}
			if seg.Name.Quote == QuoteSingle && applyEscapesV2(name) != name {
				if st.fromV2 {
					edits = append(edits, edit{start: seg.Name.Start - 1, end: seg.Name.End + 1, with: escapeNameAs(applyEscapesV2(name), RulesV2)})
				} else {
					st.ambiguous++
				}
			}
			sel := seg.Selector
			if sel == nil {
				continue
			}
			quoted := sel.Quote == QuoteSingle || sel.Quote == QuoteDouble
			// Back from the body to the `[`, and forward to the `]`.
			open := sel.Start
			if quoted {
				open = sel.Start - 1
			}
			for open > 0 && isWspByte(s[open-1]) {
				open--
			}
			open--
			close := sel.End
			if quoted {
				close = sel.End + 1
			}
			for s[close] != ']' {
				close++
			}
			colon := -1
			k := open
			for k > 0 && isWspByte(s[k-1]) {
				k--
			}
			if k > 0 && s[k-1] == ':' {
				colon = k - 1
			}
			body := rest[sel.Start:sel.End]
			logical := applyEscapesV2(body)
			unknown := sel.Quote == QuoteDouble && v2KeptEscape(body)
			if i == last && tok.Sep < 0 {
				if colon >= 0 {
					// `name:[disc]` with nothing after it: 2.x read it as
					// `name: disc`. Two or more elements in there was refused
					// as a bracket array - a comma behind a backslash was not
					// one - and an index or the wildcard was refused as a
					// selector, so those stay as written. A bare body moves
					// into a value, where a fence run opens a raw block and a
					// leading `[` is bracket text, so the emitter writes it.
					if !quoted && (indexShape(body) || body == "*") {
						return rest
					}
					// 2.x bound the bracket array, as one folded string. There
					// is no spelling to move that to - a value beginning with
					// `[` is bracket text now - so the binding goes, and the
					// caller hears about it rather than reading exit 0.
					if !quoted && v2BracketArray(body) {
						st.lost++
						return rest
					}
					if logical != body && !st.fromV2 {
						st.ambiguous++
						continue
					}
					var spelling string
					if logical != body {
						spelling = migrateSpelling(logical, false)
					} else if quoted && !unknown {
						spelling = trimWsp(rest[open+1 : close])
					} else {
						spelling = migrateSpelling(logical, true)
					}
					// As a value, a path holding a `\t` or `\n` is E024.
					if strings.HasPrefix(spelling, "\"") && spellsPathEscape(spelling) {
						spelling = migrateSpelling(logical, false)
						if strings.HasPrefix(spelling, "\"") && spellsPathEscape(spelling) {
							st.lost++
						}
					}
					edits = append(edits, edit{start: colon, end: close + 1, with: ": " + spelling})
					continue
				}
			} else if colon >= 0 {
				// The colon goes, and one space after it when the author
				// spaced both sides, so `base : [x]` comes out `base [x]`.
				end := colon + 1
				if colon > 0 && isWspByte(s[colon-1]) && isWspByte(s[colon+1]) {
					end++
				}
				edits = append(edits, edit{start: colon, end: end})
			}
			// Double quotes already read alike on both sides, so only the other
			// spellings turn on which rule set wrote the file.
			if unknown && unicodePairDiffers(body) && !st.fromV2 {
				st.ambiguous++
			} else if unknown {
				edits = append(edits, edit{start: sel.Start - 1, end: sel.End + 1, with: migrateSpelling(logical, false)})
			} else if logical != body && sel.Quote != QuoteDouble {
				if st.fromV2 {
					a, b := sel.Start, sel.End
					if quoted {
						a, b = sel.Start-1, sel.End+1
					}
					edits = append(edits, edit{start: a, end: b, with: migrateSpelling(logical, false)})
				} else {
					st.ambiguous++
				}
			}
		}
		if tok.Sep >= 0 {
			// A same-line fence: the info string ran to the end of the line.
			if ch, length, _, ok := fenceOpen(rest[tok.Value[0]:]); ok {
				*fence = openFence{ch: ch, length: length, open: true}
				return splice(rest, edits)
			}
			valueEdits(rest, tok, &edits, st)
		}
	}
	return splice(rest, edits)
}

// ---------------------------------------------------------------------------
// Path scanner (shared by file lines and accessor queries)
// ---------------------------------------------------------------------------

type selKind int

const (
	selByValue selKind = iota
	selByIndex
	selWildcard
)

type selector struct {
	kind  selKind
	value string
	index uint64
	// quoted: the selector text was quoted in the path. A quoted selector is
	// scalar-only - it matches a single-element value whose logical string
	// equals the text - so quoting distinguishes the scalar "a, b" from the
	// two-element list a, b, the same way quoting escapes elsewhere.
	quoted bool
}

type segment struct {
	name    string // folded, escapes resolved
	nameSrc string // as authored: unfolded, quotes stripped, escapes as written
	sel     *selector
	star    bool // bare `*` name wildcard; quoted "*" stays a literal name
}

type pathScan struct {
	segments  []segment
	valueText string // text after the separator colon, before any comment, trimmed
	hasValue  bool   // there was a separator colon
}

// parseIndex mirrors the reference's unsigned-integer parse: one optional
// leading '+', then ASCII digits, 64-bit range.
func parseIndex(s string) (uint64, bool) {
	t := s
	if t != "" && t[0] == '+' {
		t = t[1:]
	}
	if t == "" || !allDigits(t) {
		return 0, false
	}
	n, err := strconv.ParseUint(t, 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

// selectorOf is what a selector body means: `*` the wildcard, an index shape
// an index, a quoted body a value match, anything else a bare value match.
func selectorOf(p *Piece, text string) selector {
	body := pieceText(p, text)
	if p.Quote == QuoteSingle || p.Quote == QuoteDouble {
		// quotes force a value match, even numeric - and scalar-only
		return selector{kind: selByValue, value: body, quoted: true}
	}
	if body == "*" {
		return selector{kind: selWildcard}
	}
	if n, ok := hashIndex(body); ok {
		return selector{kind: selByIndex, index: n}
	}
	if n, ok := parseIndex(body); ok {
		return selector{kind: selByIndex, index: n}
	}
	if indexShape(body) {
		// All digits but past uint64: an index no instance can have, not a
		// value selector that would create one on a write.
		return selector{kind: selByIndex, index: math.MaxUint64}
	}
	return selector{kind: selByValue, value: body}
}

// selectorOpenQuote reports whether any segment's selector opens a quote it
// never closes. The tokenizer records it; selectorOf reads the body bare
// either way, so only the diagnostic depends on this.
func selectorOpenQuote(tok *Tokens) bool {
	for i := range tok.Segments {
		if sel := tok.Segments[i].Selector; sel != nil && sel.Quote == QuoteOpen {
			return true
		}
	}
	return false
}

// unknownEscape is the character after the first backslash in raw that starts
// no escape, or the u or U of one that names no character. Only meaningful for
// a double-quoted piece.
func unknownEscape(raw string) (rune, bool) {
	if !strings.Contains(raw, "\\") {
		return 0, false
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] != '\\' {
			continue
		}
		// A double-quoted piece cannot end on a lone backslash: it would have
		// escaped the closing quote.
		if i+1 >= len(raw) {
			return 0, false
		}
		i++
		switch raw[i] {
		case 't', 'n', '\\', '"', '\'':
		case 'u', 'U':
			if _, _, ok := unicodeEscape(raw[i], raw[i+1:]); !ok {
				return rune(raw[i]), true
			}
		default:
			r, _ := utf8.DecodeRuneInString(raw[i:])
			return r, true
		}
	}
	return 0, false
}

// v2KeptEscape is unknownEscape by the 2.x rules, which had no \u: a pair 2.x
// kept as written, so migrate doubles its backslash.
func v2KeptEscape(raw string) bool {
	for i := 0; i < len(raw); i++ {
		if raw[i] != '\\' {
			continue
		}
		if i+1 >= len(raw) {
			return false
		}
		i++
		switch raw[i] {
		case 't', 'n', '\\', '"', '\'':
		default:
			return true
		}
	}
	return false
}

// unicodePairDiffers reports a 2.x pair that is a real \u escape now: 2.x read
// the text as written and the current rules read a character, so only
// --from-2x can say which.
func unicodePairDiffers(raw string) bool {
	_, bad := unknownEscape(raw)
	return v2KeptEscape(raw) && !bad
}

// badEscape finds the first unknown escape in a double-quoted name, selector
// body or, when values is set, value element (E023). `"C:\work\new"` is the
// usual way to get one, and by then its `\n` is already a newline, so the line
// is refused rather than read with the pair kept. A raw block's info string is
// not escape text, so a fence line passes values false.
func badEscape(tok *Tokens, text string, values bool) (rune, bool) {
	dq := func(p *Piece) (rune, bool) {
		if p == nil || p.Quote != QuoteDouble {
			return 0, false
		}
		return unknownEscape(text[p.Start:p.End])
	}
	for i := range tok.Segments {
		if r, ok := dq(&tok.Segments[i].Name); ok {
			return r, true
		}
		if r, ok := dq(tok.Segments[i].Selector); ok {
			return r, true
		}
	}
	if values {
		for i := range tok.Elements {
			if r, ok := dq(&tok.Elements[i]); ok {
				return r, true
			}
		}
	}
	return 0, false
}

// pathLike reports a double-quoted value that starts like a Windows path, a
// drive (`C:\`) or a share (`\\`), and holds a `\t` or `\n` escape (E024).
// `"C:\temp"` would read as `C:`, a tab and `emp`, which a path almost never
// means. Any other pair made the line E023 before this is asked.
func pathLike(p *Piece, text string) bool {
	if p.Quote != QuoteDouble {
		return false
	}
	raw := text[p.Start:p.End]
	drive := len(raw) >= 3 && (raw[0]|0x20 >= 'a' && raw[0]|0x20 <= 'z') && raw[1] == ':' && raw[2] == '\\'
	if !drive && !strings.HasPrefix(raw, "\\\\") {
		return false
	}
	for i := 0; i+1 < len(raw); {
		if raw[i] != '\\' {
			i++
			continue
		}
		if raw[i+1] == 't' || raw[i+1] == 'n' {
			return true
		}
		i += 2
	}
	return false
}

const pathMsg = "value starts like a Windows path, and its \\t or \\n would read as a tab or newline; write a backslash as '\\\\' or use single quotes"

// anyPathLike reports a value element pathLike holds for.
func anyPathLike(tok *Tokens, text string) bool {
	for i := range tok.Elements {
		if pathLike(&tok.Elements[i], text) {
			return true
		}
	}
	return false
}

func escapeMsg(r rune) string {
	if r == 'u' || r == 'U' {
		return "bad escape '\\" + string(r) + "' in double quotes; \\u takes 4 hex digits and \\U takes 8, naming a Unicode character; write a backslash as '\\\\' or use single quotes"
	}
	return "unknown escape '\\" + oneLine(string(r)) + "' in double quotes; write a backslash as '\\\\' or use single quotes"
}

// lineFault is why a field line that scanned is refused for its value,
// before the element cap: bracket text, a bad escape, or a value that starts
// like a Windows path and holds a `\t` or `\n` escape.
func lineFault(tok *Tokens, text string) (code, msg string, bad bool) {
	if bracketText(tok, text) {
		return "E019", "bracket array syntax; an array is comma-separated, without brackets", true
	}
	_, _, _, fenced := lineFence(tok, text)
	if r, ok := badEscape(tok, text, !fenced); ok {
		return "E023", escapeMsg(r), true
	}
	if !fenced && anyPathLike(tok, text) {
		return "E024", pathMsg, true
	}
	return "", "", false
}

// opensAsWritten reports a path segment a lazy level can open: no index or
// wildcard selector, which could fail to place it.
func opensAsWritten(seg *segment) bool {
	return seg.sel == nil || seg.sel.kind == selByValue
}

// opensLater reports a kept line whose level a reload holds open (lazy): a
// field line refused for its value alone, with a path that opens.
func opensLater(text string) bool {
	if strings.HasPrefix(text, "#") || strings.HasPrefix(text, "*") {
		return false
	}
	var tok Tokens
	Tokenize(text, ':', false, RulesCurrent, &tok)
	scan, err := pathOf(&tok, text)
	if err != nil {
		return false
	}
	if _, inPath := badEscape(&tok, text, false); inPath {
		return false
	}
	for i := range scan.segments {
		if !opensAsWritten(&scan.segments[i]) {
			return false
		}
	}
	_, _, bad := lineFault(&tok, text)
	return bad
}

// bracketText reports bracket text (E019): a `[` first after the colon. Read
// off the first piece rather than the value span, since a capped scan
// empties the span and keeps the pieces it built.
func bracketText(tok *Tokens, text string) bool {
	if tok.Sep < 0 || len(tok.Elements) == 0 {
		return false
	}
	p := tok.Elements[0]
	return p.Quote == QuoteNone && p.End > p.Start && text[p.Start] == '['
}

// pathOf is the path the tokens give. An error is the tokenizer's fault:
// input that is not a path at all, which the caller skips with a diagnostic.
func pathOf(tok *Tokens, text string) (pathScan, error) {
	if tok.Fault >= 0 {
		return pathScan{}, errors.New(tok.FaultReason)
	}
	segments := make([]segment, 0, len(tok.Segments))
	for i := range tok.Segments {
		seg := &tok.Segments[i]
		raw := text[seg.Name.Start:seg.Name.End]
		// Names resolve escapes, the same rule values follow when they are
		// compared: two spellings of one name are one name. nameSrc keeps
		// the source spelling, which is what AuthoredName hands back - empty
		// when it matches, the same sentinel nodeData uses.
		//
		// A name with nothing to resolve and no upper case is already its
		// own resolved, folded spelling, so the source text becomes the name
		// and nothing else is allocated. That is nearly every name in a
		// document, and this runs once per segment per line.
		upper := false
		for k := 0; k < len(raw); k++ {
			if raw[k] >= 'A' && raw[k] <= 'Z' {
				upper = true
				break
			}
		}
		plain := (seg.Name.Quote != QuoteDouble || !strings.Contains(raw, "\\")) && !upper
		name, nameSrc := raw, ""
		if !plain {
			name, nameSrc = asciiLower(pieceText(&seg.Name, text)), raw
		}
		var sel *selector
		if seg.Selector != nil {
			s := selectorOf(seg.Selector, text)
			sel = &s
		}
		segments = append(segments, segment{name: name, nameSrc: nameSrc, sel: sel, star: seg.Star})
	}
	scan := pathScan{segments: segments}
	if tok.Sep >= 0 {
		scan.valueText, scan.hasValue = text[tok.Value[0]:tok.Value[1]], true
	}
	return scan, nil
}

// scanLookup scans a lookup path `a . b [sel] . c`: the document-line
// spelling plus the bare `*` segment (the name wildcard - any child name),
// which document lines never take; only lookups (reads, the writer probe,
// schema paths) do. Whitespace around dots, colons and brackets is
// insignificant.
func scanLookup(input string) (pathScan, error) {
	var tok Tokens
	Tokenize(input, ':', true, RulesCurrent, &tok)
	if _, bad := badEscape(&tok, input, false); bad {
		return pathScan{}, errors.New("unknown escape in double quotes")
	}
	return pathOf(&tok, input)
}

// indexShape is the spelling of an index selector - an optional `#`, an
// optional `+`, then digits - whatever its size. The grammar says 1*DIGIT,
// with no upper bound.
func indexShape(body string) bool {
	b := strings.TrimPrefix(body, "#")
	b = strings.TrimPrefix(b, "+")
	return b != "" && allDigits(b)
}

func hashIndex(body string) (uint64, bool) {
	if !strings.HasPrefix(body, "#") {
		return 0, false
	}
	return parseIndex(body[1:])
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

type stackEnt struct {
	indent string
	node   int
}

type parser struct {
	arena []nodeData
	diags []Diagnostic
	// (indent, node) for each open level; [0] is the virtual root.
	stack []stackEnt
	// Per-node hash-of-(name, value-key) -> matching children, parallel to
	// arena and nil until a parent's first insert, so leaves never allocate
	// one. Pure lookup accelerator for selectOrCreate; children keeps the
	// order. No key strings are stored - a hit is verified against the arena
	// with mergeEq.
	childMap []map[uint64]slot
	// Per-node hash-of-(name, display) -> first matching child: the `[value]`
	// selector accelerator (its predicate is display(), a different and
	// non-injective key from childMap's). Same first-wins discipline, same
	// mutation sites; ownership is by hash, and a query verifies its hit.
	dispMap []map[uint64]int
	// Whole-line comments waiting for the next line that binds a node. The
	// source indent is kept only to decide after-attachment (a comment deeper
	// than the next binding hangs on the block it sits in).
	pending []pend
	// Lengths rise along the stack, so a hang check pops the marks above its
	// own indent and walks only what they covered. Without it a run of
	// retained bad lines is rewalked per line and a plain text file parses in
	// quadratic time.
	pendMarks []pendMark
	sawBlank  bool // a blank line waits to become the next bound node's blankBefore
	// An open stacked list defers its merge-key remap (rebuilding the key per
	// element is O(list^2) time); (node, key hash, display hash) at deferral
	// start, flushed before any map lookup and at end of parse.
	starOpen bool
	starNode int
	starKey  uint64
	starDisp uint64
	// Parents where a remap ended up on a key a sibling already held: the only
	// places a duplicate can survive the keyed lookup, so the fold starts here.
	lateDups []int
	// Node -> line of the re-open that H002-hinted it. A merge under a hinted
	// container combines the same two textual regions, so it hints too even
	// when it ends up on the newest child at its own scope - that is how every
	// merged level reports, not just the outermost. The stored line splits old
	// children (hint) from ones the re-opened region itself created (silent).
	reentered map[int]int
	lost      int // dropped lines/values canonical output cannot re-emit
	keptOwed  int // lines kept as written, one per Retained outcome
	// Indent of the last E012 line kept as written, while the lines after it
	// sit under it; those are E018 and are kept as written too.
	keptHold string
	keptHeld bool
	keptAny  bool
	// ParseLimited's caps, 0 = uncapped: nodes counted against the arena
	// (root excluded), elements against a single value's cell, diagnostics
	// against the list. Past the diagnostic cap nothing is listed, only
	// counted (errors, hints), for the one tail entry the parse ends with.
	maxNodes       int
	maxElements    int
	maxDiags       int
	unlistedErrors int
	unlistedHints  int
	// A raw block's or a stacked list's binding line and the last line it
	// took, for the save that keeps lines.
	ends [][2]int
	// Each line counted in lost, kept only for the save that keeps lines,
	// since a capped parse of a huge bad file would hold one per line.
	trackDropped bool
	dropped      []int
	lazies       []lazyLevel
}

func newParser() *parser {
	return &parser{
		arena:     []nodeData{{}},
		stack:     []stackEnt{{}},
		childMap:  []map[uint64]slot{nil},
		dispMap:   []map[uint64]int{nil},
		reentered: map[int]int{},
	}
}

func (p *parser) err(line int, code, msg string) {
	p.diag(Diagnostic{Line: line, Severity: SeverityError, Message: msg, Code: code})
}

// diag: every parse diagnostic goes through here, so the cap sees them all.
func (p *parser) diag(d Diagnostic) {
	if p.maxDiags != 0 && len(p.diags) >= p.maxDiags {
		if d.Severity == SeverityError {
			p.unlistedErrors++
		} else {
			p.unlistedHints++
		}
		return
	}
	p.diags = append(p.diags, d)
}

// selectOrCreate finds (or creates by merge rule) the child of parent with
// this (name, value).
func (p *parser) selectOrCreate(parent int, name, nameSrc string, v value, line int) int {
	p.starFlush()
	h := mergeHash(name, &v)
	if c, ok := slotFirstMatch(p.childMap[parent], h, func(c int) bool {
		return mergeEq(p.arena[c].name, &p.arena[c].value, name, &v)
	}); ok {
		return c
	}
	idx := len(p.arena)
	hd := dispHash(name, &v)
	p.arena = append(p.arena, nodeData{name: name, nameSrc: spelled(name, nameSrc), value: v, parent: parent, line: line})
	p.arena[parent].children = append(p.arena[parent].children, idx)
	p.childMap = append(p.childMap, nil)
	p.dispMap = append(p.dispMap, nil)
	if p.childMap[parent] == nil {
		p.childMap[parent] = map[uint64]slot{}
	}
	slotInsert(p.childMap[parent], h, idx)
	if p.dispMap[parent] == nil {
		p.dispMap[parent] = map[uint64]int{}
	}
	if _, ok := p.dispMap[parent][hd]; !ok {
		p.dispMap[parent][hd] = idx
	}
	return idx
}

// starFlush applies an open stacked list's deferred remap. Runs before any map
// lookup (and at end of parse), so both maps are always fresh when queried.
func (p *parser) starFlush() {
	if p.starOpen {
		p.starOpen = false
		p.remapChild(p.starNode, p.starKey, p.starDisp)
	}
}

// remapChild: a node's value mutated in place (empty field filled, star element
// added): move its map entry from the old key to the new one. First-wins on
// both sides so lookups keep matching the earliest sibling, like the scan did.
func (p *parser) remapChild(node int, oldKey, oldDisp uint64) {
	parent := p.arena[node].parent
	if p.childMap[parent] != nil {
		slotRemove(p.childMap[parent], oldKey, node)
	}
	newKey := mergeHash(p.arena[node].name, &p.arena[node].value)
	_, already := slotFirstMatch(p.childMap[parent], newKey, func(c int) bool {
		return mergeEq(p.arena[c].name, &p.arena[c].value, p.arena[node].name, &p.arena[node].value)
	})
	if !already {
		if p.childMap[parent] == nil {
			p.childMap[parent] = map[uint64]slot{}
		}
		slotInsert(p.childMap[parent], newKey, node)
	} else {
		p.lateDups = append(p.lateDups, parent)
	}
	if m := p.dispMap[parent]; m != nil {
		if c, ok := m[oldDisp]; ok && c == node {
			delete(m, oldDisp)
		}
	}
	newDisp := dispHash(p.arena[node].name, &p.arena[node].value)
	if p.dispMap[parent] == nil {
		p.dispMap[parent] = map[uint64]int{}
	}
	if _, ok := p.dispMap[parent][newDisp]; !ok {
		p.dispMap[parent][newDisp] = node
	}
}

// foldLateDups: a value that mutates after its sibling group was keyed - an
// empty field filled by a fence, a stacked list closed - can end up on a key an
// earlier sibling already holds, which the keyed lookup can no longer catch.
// Fold those pairs so the tree matches a reparse of its own canonical text.
// Only the parents remapChild flagged can hold one. Shallowest first, since a
// fold hands the survivor more children and the order they arrive in decides
// whose trailing comment wins; folding keeps depths.
func (p *parser) foldLateDups() {
	type flagged struct{ depth, node int }
	parents := make([]flagged, 0, len(p.lateDups))
	for _, n := range p.lateDups {
		depth := 0
		for up := n; up != root; up = p.arena[up].parent {
			depth++
		}
		parents = append(parents, flagged{depth, n})
	}
	p.lateDups = nil
	sort.Slice(parents, func(i, j int) bool {
		if parents[i].depth != parents[j].depth {
			return parents[i].depth < parents[j].depth
		}
		return parents[i].node < parents[j].node
	})
	for i, f := range parents {
		if i > 0 && parents[i-1] == f {
			continue
		}
		p.foldDupsFrom(f.node)
	}
}

// foldDupsFrom: depth-first below start, and only into survivors: a fold moves
// the loser's children up to join the survivor's, where they can pair. A fold
// hints the way a merge at parse time does (selectOrCreate): when the two were
// not next to each other, or sit under a hinted re-open (20260923 item 11).
func (p *parser) foldDupsFrom(start int) {
	stack := []int{start}
	for len(stack) > 0 {
		parent := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		kids := p.arena[parent].children
		p.arena[parent].children = nil
		// Keyed to positions in keep, so a survivor's grew flag sits beside it.
		first := make(map[uint64]slot, len(kids))
		keep := make([]int, 0, len(kids))
		grew := make([]bool, 0, len(kids))
		for _, c := range kids {
			h := mergeHash(p.arena[c].name, &p.arena[c].value)
			if i, ok := slotFirstMatch(first, h, func(x int) bool {
				return mergeEq(p.arena[keep[x]].name, &p.arena[keep[x]].value, p.arena[c].name, &p.arena[c].value)
			}); ok {
				// Apart when a sibling kept since stands between them, as a
				// merge at parse time asks of the newest child.
				p.hintFold(parent, keep[i], c, i+1 != len(keep))
				foldNodeInto(p.arena, keep[i], c)
				grew[i] = true
			} else {
				slotInsert(first, h, len(keep))
				keep = append(keep, c)
				grew = append(grew, false)
			}
		}
		for i, g := range grew {
			if g {
				stack = append(stack, keep[i])
			}
		}
		p.arena[parent].children = keep
	}
}

func (p *parser) hintFold(parent, kept, gone int, apart bool) {
	at, line := p.arena[kept].line, p.arena[gone].line
	rl, ok := p.reentered[parent]
	crossRegion := ok && at < rl
	if at != line && (apart || crossRegion) {
		p.diag(Diagnostic{
			Line:     line,
			Severity: SeverityHint,
			Message:  fmt.Sprintf("%sline %d (same name and value combine)", h002Head(p.arena[kept].name), at),
			Code:     "H002",
		})
		p.reentered[kept] = line
	}
}

// attachTrivia hands pending leading comments (and this line's trailing one)
// to a node. First trailing wins; a later one demotes to leading so nothing
// is lost.
func (p *parser) attachTrivia(node int, indent, trailing string) {
	if len(p.pending) > 0 {
		t := p.arena[node].trivMut()
		var chain, held []depthEnt
		for _, pn := range p.pending {
			t.leading = append(t.leading, lead{text: pn.text, blankBefore: pn.blankBefore, depth: commentDepth(&chain, &held, indent, pn.text, pn.indent), line: pn.line})
		}
		p.pending = p.pending[:0]
		p.pendMarks = p.pendMarks[:0]
	}
	if trailing != "" {
		t := p.arena[node].trivMut()
		if t.trailing == "" {
			t.trailing = trailing
		} else {
			t.leading = append(t.leading, plainLead(trailing))
		}
	}
}

// hangDeeperPending: comments written deeper than the incoming line belong to
// the block they sit in, not to the next binding: hang each on the deepest node
// whose bound indent prefixes the comment's, among the levels the incoming
// line is closing. Written at that node's own level the comment trails it
// (after); written deeper it sits inside the node's block (inside) - so a
// header whose children are all commented still owns them at their depth. Runs
// before the incoming line resolves (and at end of parse with the empty
// indent, so tail comments keep their block).
func (p *parser) hangDeeperPending(newIndent string) {
	if len(p.pending) == 0 {
		return
	}
	newLen := len(newIndent)
	// Only entries above the last mark at or under this indent can hang.
	for len(p.pendMarks) > 0 && p.pendMarks[len(p.pendMarks)-1].indentLen > newLen {
		p.pendMarks = p.pendMarks[:len(p.pendMarks)-1]
	}
	start := 0
	if len(p.pendMarks) > 0 {
		start = p.pendMarks[len(p.pendMarks)-1].end
	}
	// Filtered in place: a kept entry is written back at or below the one
	// being read, so nothing unread is overwritten.
	taken := p.pending[start:]
	w := start
	// A comment never goes ahead of the one written before it. Once one stays
	// for the incoming line every later one stays too, and one whose block
	// would be written out before the last one's goes there with it instead.
	// What sits before start stays, so no comment after it can hang. A kept
	// field line is the exception below.
	kept := start > 0
	// Where the last comment went: stack index, node, at its own level.
	lastSi, lastNode, lastOwn := -1, -1, false
	lastFieldSi, lastFieldOwn := -1, false
	var chain, held []depthEnt
	for _, pn := range taken {
		// A kept field line goes to the block it sits in whatever stays
		// before it, since that block is its parent on a reload. Comments
		// give way to it.
		field := isField(pn.text)
		if (!kept || field) && pn.ceiling > newLen {
			// A level shallower than the incoming line stays open and may
			// still gain children, so a comment must not hang there - it
			// would emit below the child; keep it pending instead.
			si, target := -1, -1
			atOwnLevel := false
			for j := len(p.stack) - 1; j >= 0; j-- {
				ent := p.stack[j]
				if ent.node != root && ent.node != dead && ent.node != unopened && ent.node != lazy && len(ent.indent) >= len(newIndent) &&
					strings.HasPrefix(pn.indent, ent.indent) {
					si, target = j, ent.node
					// A list element's column is an entry with the list's
					// node on the list's own entry. It is inside the list,
					// not its level.
					column := j > 0 && p.stack[j-1].node == ent.node
					atOwnLevel = len(ent.indent) == len(pn.indent) && !column
					break
				}
			}
			// A root node's trailing comment emits at column zero, which is
			// exactly how the document's own trailing comment is written, so
			// keeping the two apart here made a merge depend on whether the
			// layer had been formatted first. Let it orphan, the way a reload
			// of this document's own output reads it. A comment deeper than the
			// node keeps an indent of its own and comes back where it was, so
			// it still hangs.
			if target >= 0 && (!atOwnLevel || p.arena[target].parent != root) {
				// A deeper block is written out first, and a block's inside
				// comments before its after ones.
				if lastSi >= 0 && !field && (si > lastSi || (si == lastSi && !atOwnLevel && lastOwn)) {
					si, target, atOwnLevel = lastSi, lastNode, lastOwn
				}
				if si != lastSi || atOwnLevel != lastOwn {
					chain = chain[:0]
				}
				lastSi, lastNode, lastOwn = si, target, atOwnLevel
				// A kept line's parent goes to the same block it does,
				// whatever block the comments between them went to.
				if field && (si != lastFieldSi || atOwnLevel != lastFieldOwn) {
					held = held[:0]
					lastFieldSi, lastFieldOwn = si, atOwnLevel
				}
				base := p.stack[si].indent
				var leads []lead
				// The comments that stayed right above it go along, so the two
				// keep their order and a save can keep both lines.
				if field {
					from := w
					for from > start && strings.HasPrefix(p.pending[from-1].text, "#") {
						from--
					}
					for _, c := range p.pending[from:w] {
						leads = append(leads, lead{text: c.text, blankBefore: c.blankBefore, depth: commentDepth(&chain, &held, base, c.text, c.indent), line: c.line})
					}
					w = from
					kept = w > 0
				}
				leads = append(leads, lead{text: pn.text, blankBefore: pn.blankBefore, depth: commentDepth(&chain, &held, base, pn.text, pn.indent), line: pn.line})
				t := p.arena[target].trivMut()
				if atOwnLevel {
					t.after = append(t.after, leads...)
				} else {
					t.inside = append(t.inside, leads...)
				}
				continue
			}
		}
		kept = true
		if pn.ceiling > newLen {
			pn.ceiling = newLen
		}
		p.pending[w] = pn
		w++
	}
	p.pending = p.pending[:w]
	if n := len(p.pendMarks); n > 0 && p.pendMarks[n-1].indentLen == newLen {
		p.pendMarks[n-1].end = len(p.pending)
	} else {
		p.pendMarks = append(p.pendMarks, pendMark{end: len(p.pending), indentLen: newLen})
	}
}

// resolveParent resolves which open level this indent belongs to, walking
// down from the top. Equal to a level is its sibling. Deeper than a level is
// its child, unless a level opened under that one is still open, in which case
// the line falls between the two. Anything else is a recoverable error. found
// is locate() on the same indent, which the line loop has already asked.
func (p *parser) resolveParent(indent string, found located) (int, bool) {
	c := found.cut
	if c.push {
		if c.hold >= 0 {
			p.stack = p.stack[:c.hold]
		}
		p.stack = append(p.stack, stackEnt{indent: indent, node: unopened})
	} else {
		p.stack = p.stack[:c.to]
	}
	return found.parent, found.ok
}

// locate is resolveParent() without moving anything.
func (p *parser) locate(indent string) located {
	return locateIn(p.stack, indent)
}

// located is what resolveParent() hands back for an indent, and how it cuts
// the stack to get there.
type located struct {
	parent int
	ok     bool
	cut    cut
}

// cut is how resolveParent() cuts the stack: back to a length, or past a
// skipped line's column (hold, -1 for none) to push this one's.
type cut struct {
	to   int
	push bool
	hold int
}

// locateIn is resolveParent() on a level stack, without moving anything. The
// emitter runs it on its model of the stack a reload will have.
func locateIn(stack []stackEnt, indent string) located {
	hold := -1
	for i := len(stack) - 1; i >= 0; i-- {
		ent := stack[i]
		if ent.indent == indent {
			if ent.node == unopened {
				// Back at a skipped line's column: refused the same way.
				return located{cut: cut{to: i + 1}}
			}
			// Sibling of stack[i]: its parent is the entry below it. Keep the
			// sentinel; a top-level line resolves to root.
			parent := root
			if i > 0 {
				parent = stack[i-1].node
			}
			keep := i
			if keep < 1 {
				keep = 1
			}
			if parent == unopened {
				parent = dead
			}
			return located{parent: parent, ok: true, cut: cut{to: keep}}
		}
		if len(indent) > len(ent.indent) && strings.HasPrefix(indent, ent.indent) {
			// A skipped line's unopened level sits on top without opening
			// anything, so it does not count as a level in between.
			if i+1 < len(stack) && stack[i+1].node != unopened {
				break
			}
			node := ent.node
			if node == unopened {
				node = dead
			}
			return located{parent: node, ok: true, cut: cut{to: i + 1}}
		}
		if ent.node == unopened {
			hold = i
		}
	}
	// Skipped, but it holds its own column: whatever is written deeper is
	// skipped with it, and a line back at it is refused the same way instead
	// of binding one level up. It closes nothing, so a later line that matches
	// a level open before it still binds there, as in 2.0.0. The hold ends at
	// the first line neither under it nor at it, this one included, which
	// keeps one on the stack at most.
	return located{cut: cut{push: true, hold: hold}}
}

// outcome: what became of a line the parser did not bind whole. Only the
// funnel (parser.refuse) reads it; the count and the level follow from it.
type outcome struct {
	kind        int
	text        string   // retained: the line, kept verbatim
	blankBefore bool     // retained: a blank line preceded it
	rest        []string // stopped: the lines never read
}

const (
	// The line binds; a value on it has nowhere to go and is gone.
	outcomeValueDropped = iota
	// Content-malformed: kept verbatim as trivia and written back in place,
	// where it re-diagnoses identically and never reads as a binding.
	outcomeRetained
	// Read but not applicable here; re-emitted it could bind elsewhere, so
	// it is gone and counts.
	outcomeDropped
	// The parse stopped before this line; the rest was never read.
	outcomeStopped
)

var (
	outValueDropped = outcome{kind: outcomeValueDropped}
	outDropped      = outcome{kind: outcomeDropped}
)

func outRetained(text string, blankBefore bool) outcome {
	return outcome{kind: outcomeRetained, text: text, blankBefore: blankBefore}
}

func outStopped(rest []string) outcome { return outcome{kind: outcomeStopped, rest: rest} }

// refuse is the one exit for a line the parser does not bind whole. An arm
// says what became of the line and nothing else: the lost count and the
// level the line holds follow from the outcome here, so no arm can forget
// either. design.md's outcome table gives each code its row.
func (p *parser) refuse(line int, code, msg string, out outcome, indent string) {
	p.err(line, code, msg)
	holds := out.kind == outcomeRetained || out.kind == outcomeDropped
	n := 0
	switch out.kind {
	case outcomeValueDropped, outcomeDropped:
		n = 1
	case outcomeStopped:
		for _, l := range out.rest {
			if trimWsp(l) != "" {
				n++
			}
		}
	}
	p.lost += n
	// Which line that was, for the save that keeps lines. Its parse has no
	// node cap, so it never stops early.
	if p.trackDropped && (out.kind == outcomeValueDropped || out.kind == outcomeDropped) {
		p.dropped = append(p.dropped, line)
	}
	if out.kind == outcomeRetained {
		// One Retained outcome makes one pend, and each pend becomes one
		// lead, so right after a load keptLines() equals this. An arm that
		// files a retained line nowhere breaks that, and the save gate then
		// refuses even a plain fmt --write, as it should.
		p.keptOwed++
		// A line kept as written never hangs on a block: its indent is not
		// one the output's levels are written with, so the block it would
		// match here is not the one it matches on a reload. It waits for the
		// next binding line, as do the pending lines after it.
		ceiling := len(indent)
		if strings.HasPrefix(out.text, " ") || strings.HasPrefix(out.text, "\t") {
			ceiling = 0
		}
		p.pending = append(p.pending, pend{text: out.text, indent: indent, blankBefore: out.blankBefore, ceiling: ceiling, line: line})
	}
	// A refused line owns its indent, so what is written deeper is skipped
	// with it (E018). An indent that matched no level already holds an
	// unopened one, which refuses a sibling the same way; that one stays.
	top := len(p.stack) - 1
	if holds && !(top >= 0 && p.stack[top].indent == indent && p.stack[top].node == unopened) {
		p.stack = append(p.stack, stackEnt{indent: indent, node: dead})
	}
}

// misplaced refuses a line for where it sits rather than for what it says:
// E012, or E018 under one. Written back exactly as it was, it sits the same
// way on a reload, as long as its indent holds a space, since no level the
// emitter opens is written with one. A tab-only indent would bind there, and
// a line opening a raw block would take its body along, so those are
// dropped. An E018 line is kept only under a kept E012 one.
func (p *parser) misplaced(line int, code, indent, rest string, hadBlank, raw bool) {
	keep := false
	if !raw {
		if code == "E012" {
			keep = strings.Contains(indent, " ")
		} else {
			keep = p.keptHeld && len(indent) > len(p.keptHold) && strings.HasPrefix(indent, p.keptHold)
		}
	}
	p.keptAny = p.keptAny || keep
	msg := "parent line was skipped; line skipped"
	if code == "E012" {
		p.keptHeld, p.keptHold = keep, indent
		msg = "indentation matches no open level"
	}
	out := outDropped
	if keep {
		out = outRetained(indent+trimEndWS(rest), hadBlank)
	}
	p.refuse(line, code, msg, out, indent)
}

// skipUnderDead diagnoses a line written under a skipped line, and skips it
// too. Its own level stays dead so deeper lines go the same way.
func (p *parser) skipUnderDead(line int, indent string) {
	p.refuse(line, "E018", "parent line was skipped; line skipped", outDropped, indent)
}

// holdOpen keeps the level of a field line refused for its value alone open
// for what is written under it. Called right after the refusal pushed the
// line's level. A path that could not open, or would open past the nesting
// cap, leaves the level dead.
func (p *parser) holdOpen(parent int, segs []segment, line int, indent string) {
	at := len(p.stack) - 1
	if p.stack[at].node != dead || p.stack[at].indent != indent {
		return
	}
	for i := range segs {
		if !opensAsWritten(&segs[i]) {
			return
		}
	}
	kept := p.lazies[:0]
	for _, l := range p.lazies {
		if l.at < at {
			kept = append(kept, l)
		}
	}
	p.lazies = kept
	depth := 0
	if parent == lazy {
		if n := len(p.lazies); n > 0 {
			depth = p.lazies[n-1].depth
		}
	} else {
		for up := parent; up != root; up = p.arena[up].parent {
			depth++
		}
	}
	if depth+len(segs) > MaxDepth {
		return
	}
	p.stack[at].node = lazy
	p.lazies = append(p.lazies, lazyLevel{at: at, segs: segs, line: line, indent: indent, pend: len(p.pending), depth: depth + len(segs)})
}

// openLazy is the node a line binds under: a lazy level, and any lazy one it
// sits under, opens here as an empty field, the way its line would have bound
// with nothing after the colon. Its own line and the comments before it go
// with it.
func (p *parser) openLazy(parent int) int {
	if parent != lazy {
		return parent
	}
	top := len(p.stack) - 1
	from := top
	for from > 1 && p.stack[from-1].node == lazy {
		from--
	}
	node := p.stack[from-1].node
	for at := from; at <= top; at++ {
		k := -1
		for j := len(p.lazies) - 1; j >= 0; j-- {
			if p.lazies[j].at == at {
				k = j
				break
			}
		}
		if k < 0 {
			break
		}
		l := p.lazies[k]
		p.lazies = append(p.lazies[:k], p.lazies[k+1:]...)
		// holdOpen let through only a path that opens.
		if n, ok := p.attachPath(node, l.segs, value{kind: vEmpty}, l.line, l.indent); ok {
			node = n
		}
		p.stack[at].node = node
		count := l.pend
		if count > len(p.pending) {
			count = len(p.pending)
		}
		p.givePending(p.headOf(node, len(l.segs)), l.indent, count, false)
	}
	return node
}

// headOf is the node a path's first segment bound, from the one its last did.
func (p *parser) headOf(node, nsegs int) int {
	head := node
	for i := 1; i < nsegs; i++ {
		head = p.arena[head].parent
	}
	return head
}

// givePending makes the first count pending lines the node's leading lines,
// or the lines inside its block, after its children.
func (p *parser) givePending(node int, indent string, count int, inside bool) {
	if count == 0 {
		return
	}
	t := p.arena[node].trivMut()
	list := &t.leading
	if inside {
		list = &t.inside
	}
	var chain, held []depthEnt
	for _, pn := range p.pending[:count] {
		*list = append(*list, lead{text: pn.text, blankBefore: pn.blankBefore, depth: commentDepth(&chain, &held, indent, pn.text, pn.indent), line: pn.line})
	}
	p.pending = append(p.pending[:0], p.pending[count:]...)
	for j := range p.pendMarks {
		p.pendMarks[j].end -= count
		if p.pendMarks[j].end < 0 {
			p.pendMarks[j].end = 0
		}
	}
	for j := range p.lazies {
		p.lazies[j].pend -= count
		if p.lazies[j].pend < 0 {
			p.lazies[j].pend = 0
		}
	}
}

// skipFieldLine is where the parse resumes after a refused field line. Every
// arm that skips one comes through here, so a skipped line whose value opens a
// raw block takes the body with it: read as lines, the body would bind or be
// refused line by line, and its closing fence would open a block that runs to
// the end of the file. A line whose path did not parse takes it too, when a
// fence follows its colon (lineFence).
func (p *parser) skipFieldLine(lines []string, i int, indent string, tok *Tokens, rest string) int {
	if ch, length, info, ok := lineFence(tok, rest); ok {
		_, next := p.consumeRaw(lines, i+1, i+1, indent, ch, length, info)
		return next
	}
	return i + 1
}

// keepBody is skipFieldLine for a line the refusal just kept: the body is kept
// too, on the end of the line's text, so a save writes it back under its line
// and the load still holds one kept line for it. As in a field's block, the
// closing fence's indent comes off each body line, and the body goes one level
// under the line when it is written. A block that never closed gets its
// closing fence, or whatever a save writes after it would read as its body.
func (p *parser) keepBody(lines []string, i int, indent string, tok *Tokens, rest string) int {
	ch, length, info, ok := lineFence(tok, rest)
	if !ok {
		return i + 1
	}
	_, next := p.consumeRaw(lines, i+1, i+1, indent, ch, length, info)
	closed := next > i+1 && isFenceClose(lines[next-1], ch, length)
	body, nest, closer := lines[i+1:next], indent, strings.Repeat(string(ch), length)
	if closed {
		fenceLine := lines[next-1]
		body, nest, closer = lines[i+1:next-1], leadingWS(fenceLine), strings.Trim(fenceLine, " \t")
	}
	if len(p.pending) == 0 {
		return next
	}
	last := &p.pending[len(p.pending)-1]
	var b strings.Builder
	b.WriteString(last.text)
	for _, l := range body {
		b.WriteByte('\n')
		b.WriteString(stripCommon(l, nest))
	}
	b.WriteByte('\n')
	b.WriteString(closer)
	last.text = b.String()
	if next > i+1 {
		p.ends = append(p.ends, [2]int{i + 1, next})
	}
	return next
}

// lineFence is the fence a field line's value opens, if it opens one. A line
// that did not tokenize opens one too when a fence follows its first colon
// past where it stopped making sense, with no comment before that colon. Read
// as lines, such a body would bind, and its closing fence would open a block
// of its own.
func lineFence(tok *Tokens, rest string) (ch byte, length int, info string, ok bool) {
	if tok.Fault >= 0 {
		sep := -1
		for k := tok.Fault; k < len(rest); k++ {
			if rest[k] == ':' || commentAt(rest, k) {
				sep = k
				break
			}
		}
		if sep < 0 || rest[sep] != ':' {
			return 0, 0, "", false
		}
		var v Tokens
		TokenizeValue(rest, sep+1, RulesCurrent, &v)
		return fenceOpen(rest[v.Value[0]:v.Value[1]])
	}
	if tok.Sep < 0 {
		return 0, 0, "", false
	}
	// A capped scan zeroed the value, and a fence is told by its leading run
	// alone.
	v := rest[tok.Value[0]:tok.Value[1]]
	if tok.Capped {
		v = trimWsp(rest[tok.Value[0]:])
	}
	return fenceOpen(v)
}

// attachPath walks path segments under parent, select-or-creating; returns the
// node for the last segment with v. ok=false aborts the line (diagnosed).
func (p *parser) attachPath(parent int, segs []segment, v value, line int, indent string) (int, bool) {
	p.starFlush()
	// Field child under a stacked list: diagnose the mix once, keep the field.
	if p.arena[parent].starList && !p.arena[parent].starMixed {
		p.arena[parent].starMixed = true
		p.err(line, "E001", "field mixed with list elements")
	}
	// Nesting cap: parent depth plus the segments this line adds. Checked
	// before any node is created so a rejected line leaves nothing behind.
	parentDepth := 0
	for up := parent; up != root; up = p.arena[up].parent {
		parentDepth++
	}
	if parentDepth+len(segs) > MaxDepth {
		p.refuse(line, "E016", fmt.Sprintf("nesting deeper than %d levels; line skipped", MaxDepth), outDropped, indent)
		return 0, false
	}
	cur := parent
	for i := range segs {
		seg := &segs[i]
		isLast := i+1 == len(segs)
		switch {
		case seg.sel != nil && seg.sel.kind == selByValue:
			// Same escape-applied display predicate resolution uses, so a
			// selector also selects an array-valued instance instead of creating
			// a spurious second one - via the dispMap accelerator (the inline
			// spelling was quadratic in siblings without it). Create only when
			// nothing matches.
			// A quoted selector is scalar-only, so it is the one that needs the
			// fallback scan: the accelerator keeps just the first same-display
			// child, which may be the non-scalar one. An unquoted selector takes
			// whatever the accelerator holds and does not scan, so it can bind a
			// raw block where a quoted selector picks the scalar sibling.
			if found, ok := p.findByValue(cur, seg.name, seg.sel.value, seg.sel.quoted); ok {
				cur = found
			} else {
				disc := value{kind: vCell, els: []element{newElement(seg.sel.value)}}
				cur = p.selectOrCreate(cur, seg.name, seg.nameSrc, disc, line)
			}
			if isLast && !v.isEmpty() {
				// `a.b[X]: v` - the discriminator is the value; a second
				// value has nowhere unambiguous to go.
				p.refuse(line, "E002", fmt.Sprintf("value after selector on '%s' ignored", diagName(seg.name)), outValueDropped, indent)
			}
		case seg.sel != nil && seg.sel.kind == selByIndex:
			found, ok := 0, false
			var nth uint64
			for _, c := range p.arena[cur].children {
				if p.arena[c].name != seg.name {
					continue
				}
				if nth == seg.sel.index {
					found, ok = c, true
					break
				}
				nth++
			}
			if ok {
				cur = found
			} else {
				p.refuse(line, "E003", fmt.Sprintf("no instance %d of '%s'", seg.sel.index, diagName(seg.name)), outDropped, indent)
				return 0, false
			}
			if isLast && !v.isEmpty() {
				// Same as the value selector: the instance is already chosen,
				// so a trailing value has nowhere to bind.
				p.refuse(line, "E002", fmt.Sprintf("value after selector on '%s' ignored", diagName(seg.name)), outValueDropped, indent)
			}
		case seg.sel != nil:
			p.refuse(line, "E004", "wildcard selector is query-only", outDropped, indent)
			return 0, false
		case !isLast:
			cur = p.selectOrCreate(cur, seg.name, seg.nameSrc, value{kind: vEmpty}, line)
		default:
			parent := cur
			before := len(p.arena)
			cur = p.selectOrCreate(cur, seg.name, seg.nameSrc, v, line)
			// Two separately-written bindings just combined: legal (the
			// merge rule), but only the parser can see it happened, so
			// say so. Adjacent re-mentions (still the newest binding at
			// this scope) and selector/path-intermediate merges stay
			// silent - those are the deliberate redundant-path idiom.
			// Under a hinted container the newest-child pass does not
			// apply to children the earlier region wrote: those merges
			// combine the same two regions, so every level reports.
			if cur < before && p.arena[cur].line != line {
				kids := p.arena[parent].children
				nonLast := len(kids) == 0 || kids[len(kids)-1] != cur
				rl, ok := p.reentered[parent]
				crossRegion := ok && p.arena[cur].line < rl
				if nonLast || crossRegion {
					p.diag(Diagnostic{
						Line:     line,
						Severity: SeverityHint,
						Message:  fmt.Sprintf("%sline %d (same name and value combine)", h002Head(seg.name), p.arena[cur].line),
						Code:     "H002",
					})
					p.reentered[cur] = line
				}
			}
		}
	}
	return cur, true
}

// findByValue: the child of cur named name whose display form is the selector
// text (escapes applied), or ok=false. Quoted selectors only match a single
// scalar.
func (p *parser) findByValue(cur int, name, text string, quoted bool) (int, bool) {
	want := text
	found, ok := 0, false
	if m := p.dispMap[cur]; m != nil {
		if c, hit := m[dispHashText(name, want)]; hit && p.arena[c].name == name && dispKey(&p.arena[c].value) == want {
			found, ok = c, true
		}
	}
	if ok && quoted && !singleScalar(&p.arena[found].value) {
		ok = false
	}
	if !ok && quoted {
		// The display map keeps only the first same-display child, which may
		// be an array where a quoted selector wants the scalar. A scalar child
		// with this text is exactly the one-element value the merge map is
		// keyed on, so ask that map: a scan of every sibling was the same
		// answer, quadratic on the create path.
		disc := value{kind: vCell, els: []element{newElement(want)}}
		found, ok = slotFirstMatch(p.childMap[cur], mergeHash(name, &disc), func(c int) bool {
			return mergeEq(p.arena[c].name, &p.arena[c].value, name, &disc)
		})
	}
	return found, ok
}

// consumeRaw consumes raw-block content after an opening fence. Returns the
// value and the next line index. The closing fence's indent is stripped from
// each content line (the opening line's when the block never closes); the
// rest is content.
func (p *parser) consumeRaw(
	lines []string, i, openLine int, openIndent string, ch byte, length int, info string,
) (value, int) {
	var content []string
	nest := openIndent
	closed := false
	for i < len(lines) {
		if isFenceClose(lines[i], ch, length) {
			// The closing fence's indent is the nesting; everything a content
			// line has past it is content, so a body whose lines all
			// share an indent keeps it (a writer-built block depends on that).
			nest = leadingWS(lines[i])
			closed = true
			i++
			break
		}
		content = append(content, lines[i])
		i++
	}
	if !closed {
		p.err(openLine, "E005", "unterminated raw block")
	}
	stripped := make([]string, len(content))
	for j, l := range content {
		stripped[j] = stripCommon(l, nest)
	}
	return value{
		kind: vRaw,
		raw:  &rawValue{content: strings.Join(stripped, "\n"), info: info, fenceChar: ch, fenceLen: length},
	}, i
}

// bindBlock: a bare fence line is a value line for its parent field: fills an
// empty value, else creates a new instance of that field (the repeated-leaf
// rule). Returns the node the block ended up on (-1 = no parent, diagnosed).
func (p *parser) bindBlock(parent int, v value, line int, indent string) int {
	if parent == root {
		p.refuse(line, "E006", "raw block with no parent field", outDropped, indent)
		return -1
	}
	if p.arena[parent].value.isEmpty() {
		oldKey := mergeHash(p.arena[parent].name, &p.arena[parent].value)
		oldDisp := dispHash(p.arena[parent].name, &p.arena[parent].value)
		p.arena[parent].value = v
		p.remapChild(parent, oldKey, oldDisp)
		return parent
	}
	name, nameSrc, grand := p.arena[parent].name, p.arena[parent].authored(), p.arena[parent].parent
	return p.selectOrCreate(grand, name, nameSrc, v, line)
}

// addStarElement: one stacked-list element (`* scalar`) appends to the
// parent's array.
func (p *parser) addStarElement(parent int, tok *Tokens, text string, line int, indent string) bool {
	if parent == root {
		p.refuse(line, "E007", "list element with no parent field", outDropped, indent)
		return false
	}
	// Uniform-or-nothing (spec): a mix with field children is not a block array.
	if len(p.arena[parent].children) != 0 {
		p.refuse(line, "E008", "list element mixed with field children; ignored", outDropped, indent)
		return false
	}
	// One scalar per line; a bare comma is an error, not a second element.
	if len(tok.Elements) > 1 {
		p.refuse(line, "E010", "bare comma in list element (one element per line)", outDropped, indent)
		return false
	}
	piece := tok.Elements[0]
	el, ok := elementOf(&piece, text)
	if !ok {
		p.refuse(line, "E009", "empty list element", outDropped, indent)
		return false
	}
	if piece.Quote == QuoteOpen {
		p.err(line, "E017", "unterminated quote in value")
	}
	bindingLike := !el.quoted && looksLikeBinding(el.text)
	clash, clashed := unitClash(p.arena[parent].name, el.text)
	// Element cap: each element line past it is refused on its own, the way
	// any other bad element line is. Only a line that would join the list:
	// under a field that already has a value it is E011, cap or not.
	if p.maxElements != 0 && p.arena[parent].starList && p.arena[parent].value.kind == vCell && len(p.arena[parent].value.els) >= p.maxElements {
		p.refuse(line, "E021", fmt.Sprintf("array longer than %d elements; line skipped", p.maxElements), outDropped, indent)
		return false
	}
	switch {
	case p.arena[parent].value.isEmpty():
		oldKey := mergeHash(p.arena[parent].name, &p.arena[parent].value)
		oldDisp := dispHash(p.arena[parent].name, &p.arena[parent].value)
		p.arena[parent].value = value{kind: vCell, els: []element{el}}
		p.arena[parent].starList = true
		// First element: remap now (Empty -> cell changes both keys), then
		// open the deferral window with the current keys. Rebuilding the
		// keys per appended element was O(list^2) time; the maps only need
		// to be fresh when queried, and every query flushes first.
		p.remapChild(parent, oldKey, oldDisp)
		p.starOpen = true
		p.starNode = parent
		p.starKey = mergeHash(p.arena[parent].name, &p.arena[parent].value)
		p.starDisp = dispHash(p.arena[parent].name, &p.arena[parent].value)
	case p.arena[parent].value.kind == vCell && p.arena[parent].starList:
		if !(p.starOpen && p.starNode == parent) {
			p.starFlush()
			p.starOpen = true
			p.starNode = parent
			p.starKey = mergeHash(p.arena[parent].name, &p.arena[parent].value)
			p.starDisp = dispHash(p.arena[parent].name, &p.arena[parent].value)
		}
		p.arena[parent].value.els = append(p.arena[parent].value.els, el)
	default:
		p.refuse(line, "E011", "field already has a value; list element ignored", outDropped, indent)
		return false
	}
	if bindingLike {
		p.diag(Diagnostic{
			Line:     line,
			Severity: SeverityHint,
			Message:  "list element looks like a field binding; it is read as a string (quote it to say so)",
			Code:     "H003",
		})
	}
	if clashed {
		p.diag(Diagnostic{Line: line, Severity: SeverityHint, Message: clash, Code: "H005"})
	}
	// A kept element holds its column as a dropped one does, with the field as
	// that level's node: a line written deeper binds where it always did, and a
	// line back at the element's column is its sibling, where no level had been
	// opened there and every later sibling was E012 (20260918b item 28).
	p.stack = append(p.stack, stackEnt{indent: indent, node: parent})
	return true
}

// keepAmong: kept lines waiting for the list element that just joined sat
// among the list's elements, so they stay there; comments still ride the
// field.
func (p *parser) keepAmong(parent int, indent string) {
	anyKept := false
	for _, pn := range p.pending {
		if !strings.HasPrefix(pn.text, "#") {
			anyKept = true
			break
		}
	}
	if !anyKept || p.arena[parent].value.kind != vCell {
		return
	}
	before := len(p.arena[parent].value.els) - 1
	rest := make([]pend, 0, len(p.pending))
	var chain, held []depthEnt
	for _, pn := range p.pending {
		if strings.HasPrefix(pn.text, "#") {
			rest = append(rest, pn)
			continue
		}
		t := p.arena[parent].trivMut()
		t.among = append(t.among, amongLead{before: before, lead: lead{text: pn.text, blankBefore: pn.blankBefore, depth: commentDepth(&chain, &held, indent, pn.text, pn.indent)}})
	}
	p.pending = rest
	p.pendMarks = p.pendMarks[:0]
}

// emitRepeatedLeafHints flags legal input that looks like a common mistake: a
// field repeating as a bare scalar leaf. Mandatory hint per spec (never fails
// a load). Groups are in first-appearance order so hint order is deterministic
// across bindings.
func (p *parser) emitRepeatedLeafHints() {
	// The node list is made only when a name repeats. Nearly every name is
	// seen once, and a list per child was most of what this pass allocated.
	type group struct {
		name  string
		first int
		nodes []int
	}
	for parent := range p.arena {
		children := p.arena[parent].children
		if len(children) < 2 {
			continue
		}
		byName := make([]group, 0, len(children))
		groupOf := make(map[string]int)
		for _, c := range children {
			name := p.arena[c].name
			if g, ok := groupOf[name]; ok {
				if byName[g].nodes == nil {
					byName[g].nodes = []int{byName[g].first}
				}
				byName[g].nodes = append(byName[g].nodes, c)
			} else {
				groupOf[name] = len(byName)
				byName = append(byName, group{name: name, first: c})
			}
		}
		for _, g := range byName {
			if len(g.nodes) < 2 {
				continue
			}
			allScalarLeaves := true
			for _, c := range g.nodes {
				n := &p.arena[c]
				if len(n.children) != 0 || n.value.kind != vCell || n.starList {
					allScalarLeaves = false
					break
				}
			}
			if !allScalarLeaves {
				continue
			}
			line := 0
			vals := make([]string, 0, len(g.nodes))
			for _, c := range g.nodes {
				if p.arena[c].line > line {
					line = p.arena[c].line
				}
				vals = append(vals, diagValue(&p.arena[c].value))
			}
			p.diag(Diagnostic{
				Line:     line,
				Severity: SeverityHint,
				Message:  fmt.Sprintf("%s%s'?", h001Head(g.name), strings.Join(vals, ", ")),
				Code:     "H001",
			})
		}
	}
}

// trimCountingNodeLines takes the carriage returns off every line and counts
// the lines that can make a node, which sizes the arena. Only a guess, so it
// stays cheap, but a raw body is skipped: a document of embedded blocks
// otherwise reserved half again what it used.
func trimCountingNodeLines(lines []string) int {
	n := 0
	var bodyCh byte
	bodyLen := 0
	for j, l := range lines {
		l = strings.TrimRight(l, "\r")
		lines[j] = l
		if bodyLen > 0 {
			if isFenceClose(l, bodyCh, bodyLen) {
				bodyLen = 0
			}
			continue
		}
		t := strings.TrimLeft(l, " \t")
		if t == "" || t[0] == '#' || t[0] == '*' {
			continue
		}
		n++
		if k := strings.IndexByte(t, ':'); k >= 0 {
			t = strings.TrimLeft(t[k+1:], " \t")
		}
		if ch, length, _, ok := fenceOpen(t); ok {
			bodyCh, bodyLen = ch, length
		}
	}
	return n
}

// arenaWant is the arena's starting size: the root plus every counted line,
// held to what the node cap lets the parse build. Compared without adding to
// the cap, which may be near MaxInt. A negative cap stops the parse at the
// first line, so it gets the root alone.
func arenaWant(nodeLines, maxNodes int) int {
	if maxNodes < 0 {
		return 1
	}
	want := nodeLines + 1
	if maxNodes > 0 && want-2 > maxNodes {
		want = maxNodes + 2
	}
	return want
}

func (p *parser) parse(text string, strictness Strictness) *Document {
	// UTF-8 BOM strip, then split keeping raw lines (CR stripped per line).
	// The whole trailing CR run goes, not just one: a raw block keeps its content
	// untrimmed, so a line left ending in CR would be written back as CRLF and
	// read as neither - the one shape where the count is visible.
	text = strings.TrimPrefix(text, "\uFEFF")
	lines := strings.Split(text, "\n")
	nodeLines := trimCountingNodeLines(lines)
	// A newline-terminated text splits into one more piece than it has lines.
	// An unterminated raw block took that empty tail as a body line, so the
	// same last line read differently with and without its newline, which
	// the grammar says are one document.
	if strings.HasSuffix(text, "\n") {
		lines = lines[:len(lines)-1]
	}
	// Growing the arena by append cost about an eighth of fmt on a large
	// file, and more than that in peak memory.
	want := arenaWant(nodeLines, p.maxNodes)
	p.arena = append(make([]nodeData, 0, want), p.arena...)
	p.childMap = append(make([]map[uint64]slot, 0, want), p.childMap...)
	p.dispMap = append(make([]map[uint64]int, 0, want), p.dispMap...)
	i := 0
	nodeCapped := false
	tok := Tokens{Cap: p.maxElements}
	for i < len(lines) {
		// Node cap: reported at the first line not parsed, so the count can
		// overshoot by at most one line's path. The unparsed remainder counts
		// as lost, which is what keeps SaveFile from writing a silently
		// truncated document.
		if p.maxNodes != 0 && len(p.arena)-1 > p.maxNodes {
			p.refuse(i+1, "E020", fmt.Sprintf("node cap of %d exceeded; parse stopped", p.maxNodes), outStopped(lines[i:]), "")
			nodeCapped = true
			break
		}
		lineno := i + 1
		line := trimEndWS(lines[i])
		indent := leadingWS(line)
		// A carriage return is a blank but never indent, so a run of blanks
		// holding one comes off the front of the rest instead.
		rest := strings.TrimLeftFunc(line[len(indent):], isWsp)
		lead := len(line) - len(indent) - len(rest)
		if rest == "" {
			p.sawBlank = true
			i++
			continue
		}
		// Whole-line comment: hold it for the next line that binds a node.
		// It consumes a pending blank into its own flag, so a blank between
		// comment-only regions survives the round-trip.
		if strings.HasPrefix(rest, "#") {
			p.pending = append(p.pending, pend{text: rest, indent: indent, blankBefore: p.sawBlank, ceiling: len(indent), line: lineno})
			p.sawBlank = false
			i++
			continue
		}
		// A kept misplaced line holds only the lines written under it.
		if p.keptHeld && !(len(indent) > len(p.keptHold) && strings.HasPrefix(indent, p.keptHold)) {
			p.keptHeld = false
		}
		// Any other line consumes the pending blank; only a field line that
		// binds turns it into grouping.
		hadBlank := p.sawBlank
		p.sawBlank = false
		// A binding line claims the pending comments - but deeper-written
		// ones hang on their own block first. A line refused for where it
		// sits closes nothing, so it leaves them for the next line: kept, its
		// indent would measure the levels differently on a reload, and
		// dropped, a reload never sees it.
		found := p.locate(indent)
		if found.ok && found.parent != dead {
			p.hangDeeperPending(indent)
		}
		// Child-indent fence: a value line for its parent field. The fence
		// and its info string are the value; a comment may follow them.
		if rest[0] == '`' || rest[0] == '~' {
			if ch, length, info, ok := childFence(rest, &tok); ok {
				comment := ""
				if tok.Comment >= 0 {
					comment = rest[tok.Comment:]
				}
				parent, okp := p.resolveParent(indent, found)
				v, next := p.consumeRaw(lines, i+1, lineno, indent, ch, length, info)
				if !okp {
					// The body goes with its fence: parsed live, it would read as
					// root bindings and the closing fence would open a second block.
					p.refuse(lineno, "E012", "indentation matches no open level", outDropped, indent)
					i = next
					continue
				}
				if parent == dead {
					p.skipUnderDead(lineno, indent)
				} else if tok.Capped {
					// The block goes with its line, or the body would read as live
					// lines.
					p.refuse(lineno, "E021", fmt.Sprintf("array longer than %d elements; line skipped", p.maxElements), outDropped, indent)
				} else {
					parent = p.openLazy(parent)
					// The fence binds its field again, so a kept field line
					// before it, which sits under that field, stays in the
					// block, with the comments before it. A misplaced line
					// never hangs on a block, so it waits for the next line.
					k := -1
					for j := len(p.pending) - 1; j >= 0; j-- {
						if isField(p.pending[j].text) {
							k = j
							break
						}
					}
					si := len(p.stack) - 1
					for si >= 0 && p.stack[si].node != parent {
						si--
					}
					if parent != root && k >= 0 && si >= 0 {
						moved := make([]pend, 0, len(p.pending))
						var misplaced []pend
						for _, pn := range p.pending[:k+1] {
							if strings.HasPrefix(pn.text, " ") || strings.HasPrefix(pn.text, "\t") {
								misplaced = append(misplaced, pn)
							} else {
								moved = append(moved, pn)
							}
						}
						count := len(moved)
						moved = append(moved, misplaced...)
						p.pending = append(moved, p.pending[k+1:]...)
						p.givePending(parent, p.stack[si].indent, count, true)
					}
					if node := p.bindBlock(parent, v, lineno, indent); node >= 0 {
						p.ends = append(p.ends, [2]int{p.arena[node].line, next})
						p.attachTrivia(node, indent, comment)
					}
				}
				i = next
				continue
			}
		}
		// Stacked-list element: colon-less by construction ('*' can't begin a name).
		if strings.HasPrefix(rest, "*") {
			after := rest[1:]
			// A `*` alone after the trim: whether a space followed it decides
			// between an empty element and a malformed line, and only the
			// untrimmed line still knows.
			spaced := after != "" && isWspByte(after[0])
			if after == "" && len(lines[i]) > len(indent)+lead+1 {
				spaced = isWspByte(lines[i][len(indent)+lead+1])
			}
			if spaced {
				parent, okp := p.resolveParent(indent, found)
				if !okp {
					p.misplaced(lineno, "E012", indent, rest, hadBlank, false)
					i++
					continue
				}
				if parent == dead {
					p.misplaced(lineno, "E018", indent, rest, hadBlank, false)
					i++
					continue
				}
				TokenizeValue(rest, 1, RulesCurrent, &tok)
				code, msg := "", ""
				if r, bad := badEscape(&tok, rest, true); bad {
					code, msg = "E023", escapeMsg(r)
				} else if anyPathLike(&tok, rest) {
					code, msg = "E024", pathMsg
				}
				if code != "" {
					p.refuse(lineno, code, msg, outRetained(trimEndWS(rest), hadBlank), indent)
					i++
					continue
				}
				parent = p.openLazy(parent)
				comment := ""
				if tok.Comment >= 0 {
					comment = rest[tok.Comment:]
				}
				// Elements have no node of their own; trivia rides the field. At the
				// root there is no field (E007), so the comment rides the document like
				// any other pending one.
				if parent != root {
					if p.addStarElement(parent, &tok, rest, lineno, indent) {
						p.keepAmong(parent, indent)
					}
					head := p.arena[parent].line
					if n := len(p.ends); n > 0 && p.ends[n-1][0] == head {
						p.ends[n-1][1] = lineno
					} else {
						p.ends = append(p.ends, [2]int{head, lineno})
					}
					p.attachTrivia(parent, indent, comment)
				} else {
					if comment != "" {
						p.pending = append(p.pending, pend{text: comment, indent: indent, blankBefore: hadBlank, ceiling: len(indent)})
					}
					p.addStarElement(parent, &tok, rest, lineno, indent)
				}
				i++
				continue
			}
			parent, okp := p.resolveParent(indent, found)
			if !okp {
				p.misplaced(lineno, "E012", indent, rest, hadBlank, false)
				i++
				continue
			}
			if parent == dead {
				p.misplaced(lineno, "E018", indent, rest, hadBlank, false)
				i++
				continue
			}
			// Content-malformed at any position, so safe to retain. The BOM
			// exception the field arm makes cannot apply here: this line
			// starts with the '*' that brought us in.
			p.refuse(lineno, "E013", "malformed line: '*' must be followed by a space", outRetained(trimEndWS(rest), hadBlank), indent)
			i++
			continue
		}
		// Field line.
		Tokenize(rest, ':', false, RulesCurrent, &tok)
		comment := ""
		if tok.Comment >= 0 {
			comment = rest[tok.Comment:]
		}
		parent, okp := p.resolveParent(indent, found)
		if !okp {
			_, _, _, raw := lineFence(&tok, rest)
			p.misplaced(lineno, "E012", indent, rest, hadBlank, raw)
			i = p.skipFieldLine(lines, i, indent, &tok, rest)
			continue
		}
		if parent == dead {
			_, _, _, raw := lineFence(&tok, rest)
			p.misplaced(lineno, "E018", indent, rest, hadBlank, raw)
			i = p.skipFieldLine(lines, i, indent, &tok, rest)
			continue
		}
		scan, serr := pathOf(&tok, rest)
		if serr != nil {
			// Content-malformed at any position, so retained - except a line
			// led by a BOM, which the file-start strip would rewrite into
			// something that can bind.
			bom := strings.HasPrefix(rest, "\ufeff")
			out := outRetained(trimEndWS(rest), hadBlank)
			if bom {
				out = outDropped
			}
			// The column counts bytes from the line start, so all four bindings
			// report it the same on non-ASCII text.
			msg := fmt.Sprintf("malformed line skipped: %s, at column %d", serr.Error(), len(indent)+lead+tok.Fault+1)
			p.refuse(lineno, "E014", msg, out, indent)
			if bom {
				i = p.skipFieldLine(lines, i, indent, &tok, rest)
			} else {
				i = p.keepBody(lines, i, indent, &tok, rest)
			}
			continue
		}
		next := i + 1
		// A selector body takes the same open-quote rule as a value element,
		// and the same code: the body is read bare, quotes and all, so the
		// line still binds - somewhere the author did not mean.
		if selectorOpenQuote(&tok) {
			p.err(lineno, "E017", "unterminated quote in selector")
		}
		// A value written the way JSON, TOML and YAML write an array, or an
		// escape that cannot be read as written or as an escape without
		// guessing. The brackets are not a selector after the colon, and
		// reading the text without them would bake a changed value in, so the
		// line is kept verbatim. Judged before the cap and from the first
		// piece, which the cap keeps: a cap refuses only a line that would
		// bind. Only the value is wrong, so the lines under it still load,
		// under the path opened empty.
		if code, msg, bad := lineFault(&tok, rest); bad {
			p.refuse(lineno, code, msg, outRetained(trimEndWS(rest), hadBlank), indent)
			if _, inPath := badEscape(&tok, rest, false); !inPath {
				p.holdOpen(parent, scan.segments, lineno, indent)
			}
			// Only a fault in the name leaves a fence to read here.
			i = p.keepBody(lines, i, indent, &tok, rest)
			continue
		}
		// Element cap: the whole line is refused, so a capped load never
		// holds a truncated array that would read as the document's value.
		// The scan stopped at the cap, so nothing past it was built either,
		// and the value span is empty: this has to come before the value is
		// read, or the line would bind as empty.
		if tok.Capped {
			p.refuse(lineno, "E021", fmt.Sprintf("array longer than %d elements; line skipped", p.maxElements), outDropped, indent)
			i = p.skipFieldLine(lines, i, indent, &tok, rest)
			continue
		}
		// The verbatim value span, kept for reads' Raw (only the plain
		// scalar/inline-array case has a one-line source spelling).
		srcText, haveSrc := "", false
		var v value
		switch {
		case !scan.hasValue:
			// A clean path with no colon is the one defined repair: the
			// obvious intent is that path with an empty value.
			p.err(lineno, "E015", "missing colon; repaired as an empty value")
			v = value{kind: vEmpty}
		case scan.valueText == "":
			v = value{kind: vEmpty}
		default:
			if ch, length, info, ok := fenceOpen(scan.valueText); ok {
				// Same-line fence spelling.
				v, next = p.consumeRaw(lines, i+1, lineno, indent, ch, length, info)
			} else {
				for k := range tok.Elements {
					if tok.Elements[k].Quote == QuoteOpen {
						p.err(lineno, "E017", "unterminated quote in value")
						break
					}
				}
				srcText, haveSrc = scan.valueText, true
				v = cellOfTokens(&tok, rest)
			}
		}
		// Record only when the bound node holds exactly this line's value
		// (a merge into an equal-valued node keeps the first line's span;
		// a value dropped after a last-segment selector records nothing).
		var vkey uint64
		if haveSrc {
			vkey = valueHash(&v)
		}
		parent = p.openLazy(parent)
		nsegs := len(scan.segments)
		if node, ok := p.attachPath(parent, scan.segments, v, lineno, indent); ok {
			if haveSrc {
				for i := 0; unitNamed(p.arena[node].name) && i < len(tok.Elements); i++ {
					if m, ok := unitClash(p.arena[node].name, pieceText(&tok.Elements[i], rest)); ok {
						p.diag(Diagnostic{Line: lineno, Severity: SeverityHint, Message: m, Code: "H005"})
						break
					}
				}
			}
			if haveSrc && !p.arena[node].srcSet && valueHash(&p.arena[node].value) == vkey {
				p.arena[node].srcSet = true
				if !srcMatchesDisplay(&p.arena[node].value, srcText) {
					s := srcText
					p.arena[node].src = &s
				}
			}
			if hadBlank {
				p.arena[node].blankBefore = true
			}
			if next > i+1 {
				p.ends = append(p.ends, [2]int{lineno, next})
			}
			// A kept line before a dotted line sits level with its first
			// segment, so it goes there with the comments before it. Under the
			// last one it would be written deeper and read as a child.
			if nsegs > 1 {
				for k := len(p.pending) - 1; k >= 0; k-- {
					if isField(p.pending[k].text) {
						p.givePending(p.headOf(node, nsegs), indent, k+1, false)
						break
					}
				}
			}
			p.attachTrivia(node, indent, comment)
			p.stack = append(p.stack, stackEnt{indent: indent, node: node})
		}
		i = next
	}
	// A cap crossed on the document's last line still reports, with nothing
	// left to skip.
	if !nodeCapped && p.maxNodes != 0 && len(p.arena)-1 > p.maxNodes {
		p.refuse(len(lines), "E020", fmt.Sprintf("node cap of %d exceeded; parse stopped", p.maxNodes), outStopped(nil), "")
	}
	p.starFlush()
	// Indented tail comments keep their block; only top-level ones orphan.
	// Before the fold, which moves a dropped instance's comments over to the
	// one it joins: after it they would hang on the dropped one.
	p.hangDeeperPending("")
	p.foldLateDups()
	for n := range p.arena {
		settleBlock(p.arena, n, 1)
	}
	p.emitRepeatedLeafHints()
	// Line order, so a hint found only after the pass (a fold, a repeated
	// leaf) sits with its line. Stable, so two on one line keep the order
	// they were found in. Before the cap entry, which ends the list.
	sort.SliceStable(p.diags, func(i, j int) bool { return p.diags[i].Line < p.diags[j].Line })
	orphans := make([]lead, 0, len(p.pending))
	var chain, held []depthEnt
	for _, pn := range p.pending {
		orphans = append(orphans, lead{text: pn.text, blankBefore: pn.blankBefore, depth: commentDepth(&chain, &held, "", pn.text, pn.indent), line: pn.line})
	}
	p.pending = p.pending[:0]
	settleFirstBlank(p.arena, orphans)
	// The one entry past the cap: what was not listed, and whether any of it
	// was an error, so a consumer scanning the list for errors still finds
	// one and a Strict load still fails.
	if more := p.unlistedErrors + p.unlistedHints; more > 0 {
		sev := SeverityHint
		if p.unlistedErrors > 0 {
			sev = SeverityError
		}
		p.diags = append(p.diags, Diagnostic{
			Line:     0, // about the list, not a line
			Severity: sev,
			Code:     "E022",
			Message:  fmt.Sprintf("diagnostic cap of %d reached; %d more not listed, %d of them errors", p.maxDiags, more, p.unlistedErrors),
		})
	}
	// The arena was sized to the line count, and comments, blank lines and
	// list elements make no node. The document keeps it, so give back what
	// growing by append would not have left unused.
	if 2*len(p.arena) < cap(p.arena) {
		p.arena = append([]nodeData(nil), p.arena...)
	}
	doc := &Document{arena: p.arena, diags: p.diags, strictness: strictness, orphans: orphans, lost: p.lost, keptOwed: p.keptOwed, kept: p.keptAny, ends: p.ends, dropped: p.dropped}
	doc.settleKept()
	return doc
}

// ---------------------------------------------------------------------------
// Document: load, diagnostics, formatter
// ---------------------------------------------------------------------------

// Parse parses at Standard strictness. Never fails: bad lines are skipped and
// diagnosed, good values stay readable.
func Parse(text string) *Document {
	return newParser().parse(text, Standard)
}

// ParseWith parses at a chosen strictness. Only Strict can fail (any error
// diagnostic). The Document comes back even then - non-nil alongside the
// error, with the error including it too - so `doc, err :=` callers can
// inspect doc.Diagnostics() without a nil check blowing up.
func ParseWith(text string, strictness Strictness) (*Document, error) {
	doc := newParser().parse(text, strictness)
	if strictness == Strict {
		for _, d := range doc.diags {
			if d.Severity == SeverityError {
				return doc, &LoadError{Diagnostics: append([]Diagnostic(nil), doc.diags...), Document: doc}
			}
		}
	}
	return doc, nil
}

// ParseLimited parses with resource caps beside the strictness, for input the
// consumer does not control: a document amplifies to many times its byte size
// in memory, so a size cap alone cannot bound what a load allocates. maxNodes
// stops the parse once a line takes the node count past it - one E020 error,
// and the unparsed remainder counts as lost so a save cannot silently
// truncate. maxElements refuses any line whose array would hold more elements
// (E021, that line alone is skipped). maxDiags bounds the diagnostics list
// itself - a document of nothing but bad lines costs a diagnostic per line -
// by listing the first that many and ending with one E022 that counts the
// rest; ErrorCount and the Strict gate see that tail as an error whenever an
// unlisted one was. 0 disables a cap, making this ParseWith. The caps are
// parse-time only; the write API is the consumer's own arithmetic. As
// everywhere, the error fires only at Strict, and a cap diagnostic is an
// error, so a capped Strict load fails; at other levels the parsed part stays
// readable.
func ParseLimited(text string, strictness Strictness, maxNodes, maxElements, maxDiags int) (*Document, error) {
	p := newParser()
	p.maxNodes = maxNodes
	p.maxElements = maxElements
	p.maxDiags = maxDiags
	doc := p.parse(text, strictness)
	if strictness == Strict {
		for _, d := range doc.diags {
			if d.Severity == SeverityError {
				return doc, &LoadError{Diagnostics: append([]Diagnostic(nil), doc.diags...), Document: doc}
			}
		}
	}
	return doc, nil
}

// Diagnostics is everything the load recorded (after LoadAndValidate,
// validation findings too).
func (d *Document) Diagnostics() []Diagnostic {
	// A copy: the reference hands out a borrowed view nobody can append to,
	// and a Go slice sharing the document's backing array would let a
	// caller's append and the document's next one overwrite each other.
	return append([]Diagnostic(nil), d.diags...)
}

// LostCount is how many lines or values parsing dropped that canonical
// output cannot re-emit - bad indentation, an unusable selector, a line past
// the depth cap. Content-malformed lines do NOT count: those are retained as
// trivia and survive a save. Nonzero means a SaveFile would delete
// hand-written content, so SaveFile refuses then (SaveFileLossy overrides),
// and SaveFileKeepLines does when it cannot keep the lines. It also counts
// lines the load kept as written that an edit took and design.md's
// kept-lines table does not let it take.
func (d *Document) LostCount() int {
	return d.lost + d.keptShortfall()
}

// keptShortfall is the kept lines the document owes and no longer holds. Free
// on a document that never had one.
func (d *Document) keptShortfall() int {
	if d.keptOwed == 0 {
		return 0
	}
	if short := d.keptOwed - d.keptLines(); short > 0 {
		return short
	}
	return 0
}

// keptLines counts kept lines in the live tree and the orphans. From root,
// since a removed node stays in the arena; a stack, since a recursive walk
// overflowed Windows' 1 MB main stack on the deepest legal document.
func (d *Document) keptLines() int {
	n := keptIn(d.orphans)
	stack := []int{root}
	for len(stack) > 0 {
		i := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		n += keptInLists(&d.arena[i])
		stack = append(stack, d.arena[i].children...)
	}
	return n
}

// taken is the kept lines a remove of node takes, by design.md's table:
// every one written inside its block, and the one written as its own line.
// Read from where the lines sit before the edit, so a remove that drops one
// beside its target is caught by the gate rather than allowed.
func (d *Document) taken(node int) int {
	nd := &d.arena[node]
	n := keptIn(nd.inside()) + keptAmong(nd.among())
	if headsBlock(nd) {
		if l := nd.leading(); l[len(l)-1].isKeptLine() {
			n++
		}
	}
	stack := append([]int(nil), nd.children...)
	for len(stack) > 0 {
		i := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		n += keptInLists(&d.arena[i])
		stack = append(stack, d.arena[i].children...)
	}
	return n
}

func keptIn(leads []lead) int {
	n := 0
	for i := range leads {
		if leads[i].isKeptLine() {
			n++
		}
	}
	return n
}

func keptAmong(among []amongLead) int {
	n := 0
	for i := range among {
		if among[i].lead.isKeptLine() {
			n++
		}
	}
	return n
}

// keptInLists counts kept lines in all of one node's trivia lists.
func keptInLists(nd *nodeData) int {
	return keptIn(nd.leading()) + keptIn(nd.after()) + keptIn(nd.inside()) + keptAmong(nd.among())
}

// restep: a reload starts a comment run at 0 and steps one level at a time
// past the comment or kept field line before it, so a comment left after the
// line it sat under went is pulled back to fit.
func restep(leads []lead) {
	room := 0
	for k := range leads {
		if strings.HasPrefix(leads[k].text, "#") {
			leads[k].depth = minInt(leads[k].depth, room)
			room = leads[k].depth + 1
		} else if isField(leads[k].text) {
			room = leads[k].depth + 1
		}
	}
}

// besideKept is what a remove of this node leaves of its lines, by
// design.md's kept-lines table: the kept lines beside it, with the comments
// that sit with them. Above it that is everything up to its last kept line,
// below it everything from its first, so a comment written against the node
// goes with it. The kept line written in place of its `name:` line goes too.
func besideKept(nd *nodeData) []lead {
	heads := headsBlock(nd)
	t := nd.trivia
	if t == nil {
		return nil
	}
	left := t.leading
	t.leading = nil
	if heads {
		left = left[:len(left)-1]
	}
	end := 0
	for k := len(left) - 1; k >= 0; k-- {
		if left[k].isKeptLine() {
			end = k + 1
			break
		}
	}
	left = left[:end]
	from := len(t.after)
	for k := range t.after {
		if t.after[k].isKeptLine() {
			from = k
			break
		}
	}
	left = append(left, t.after[from:]...)
	t.after = t.after[:from]
	return left
}

// ErrorCount is how many error-severity diagnostics the document has - the
// "did this file have errors?" predicate, so recover-and-continue can't read
// as success by accident. Counts whatever Diagnostics() holds (after
// LoadAndValidate, that includes validation errors).
func (d *Document) ErrorCount() int {
	n := 0
	for _, dg := range d.diags {
		if dg.Severity == SeverityError {
			n++
		}
	}
	return n
}

// LoadAndValidate is the one-shot load-and-validate: parse at a strictness,
// validate against a schema, and hand back the document with ONE combined
// diagnostics list (parse first, then validation - the order `check --schema`
// prints), so half the errors can't vanish because a caller forgot one of the
// two lists. Never fails: a strict-failing document comes back as the document
// plus its diagnostics (ErrorCount answers "did it fail"). An empty schema
// text skips validation entirely. H001 hints the schema disavows (a declared
// repeat upper bound above 1) are dropped.
func LoadAndValidate(text, schemaText string, strictness Strictness) *Document {
	doc := newParser().parse(text, strictness)
	if strings.TrimSpace(schemaText) != "" {
		schema := Parse(schemaText)
		// A schema that did not load would silently drop the constraints on
		// its broken lines, or report every field as unknown - either way
		// blaming the document for the schema. Say so instead, as `check`
		// does, and validate nothing.
		for _, sd := range schema.diags {
			if sd.Severity == SeverityError {
				doc.diags = append(doc.diags, Diagnostic{
					Line: 0, Severity: SeverityError, Message: "schema failed to load", Code: "V099",
				})
				return doc
			}
		}
		doc.diags = append(doc.diags, doc.Validate(schema)...)
		doc.diags = SuppressDeclaredRepeats(schema, doc.diags)
		doc.diags = SuppressDeclaredReopens(schema, doc.diags)
	}
	return doc
}

// Strictness is the level the document was loaded at.
func (d *Document) Strictness() Strictness {
	return d.strictness
}

// writeTabs writes a comment's depth past the place it is emitted at.
func writeTabs(out *strings.Builder, n int) {
	for i := 0; i < n; i++ {
		out.WriteByte('\t')
	}
}

// ToCanonical emits the canonical form: block layout, tabs, insertion order,
// minimal quoting, redundancy collapsed, comments re-emitted as attached
// trivia. Scalar text is never rewritten.
func (d *Document) ToCanonical() string {
	e := newEmit(len(d.arena)*24, false)
	d.emitAll(e)
	return e.out.String()
}

// ParseKeepLines is ParseWith, keeping the text for ToTextKeepLines(). The
// document is the same one ParseWith gives; only the save differs.
func ParseKeepLines(text string, strictness Strictness) (*Document, error) {
	doc, err := ParseWith(text, strictness)
	doc.keepSource(text)
	return doc, err
}

func (d *Document) keepSource(text string) {
	if d.ToCanonical() == text {
		text = ""
	}
	d.source = &text
}

// LoadFileKeepLines is LoadFileWith, keeping the text for ToTextKeepLines().
func LoadFileKeepLines(path string, level Strictness) (*Document, FileStatus) {
	text, st := ReadFile(path, 0)
	if st != FileClean {
		return newParser().parse("", level), st
	}
	doc := newParser().parse(text, level)
	doc.keepSource(text)
	for _, d := range doc.diags {
		if d.Severity == SeverityError {
			return doc, FileHadErrors
		}
	}
	return doc, FileClean
}

// ToTextKeepLines returns the text a save that keeps lines writes, and whether
// it kept them. Each line the edits did not touch is the loaded text's own
// line, byte for byte; a changed value is written into its line; new lines are
// indented the way the lines around them are. The result has to reload as this
// document. When it does not, or the document was not loaded with
// ParseKeepLines or LoadFileKeepLines, or it took a merge, or an edit took a
// kept line it should not have, this is ToCanonical() and false.
func (d *Document) ToTextKeepLines() (string, bool) {
	// The reparse check cannot see a kept line gone from both the tree and
	// the text, so falling back leaves it to the lost-count gate.
	if d.source != nil && d.keptShortfall() == 0 {
		if t, ok := keepLines(*d.source, d); ok {
			return t, true
		}
	}
	return d.ToCanonical(), false
}

// SaveFileKeepLines is SaveFile with ToTextKeepLines(): true when it kept the
// lines, false when it wrote the canonical form instead. A line the load
// dropped comes back as written when the lines are kept, so this refuses the
// way SaveFile does only when it would write canonical.
func (d *Document) SaveFileKeepLines(path string) (bool, error) {
	text, kept := d.ToTextKeepLines()
	if lost := d.LostCount(); !kept && lost > 0 {
		return false, &SaveRefused{Path: path, Lost: lost}
	}
	if err := WriteFileAtomic(path, text); err != nil {
		return false, err
	}
	return kept, nil
}

func (d *Document) emitMarked() *emit {
	e := newEmit(len(d.arena)*24, false)
	e.lines = true
	d.emitAll(e)
	return e
}

func (d *Document) emitAll(e *emit) {
	d.emitChildren(d.arena[root].children, 0, e)
	// Comments that never found a following line re-emit at the end.
	e.near(root, 0)
	pushLeads(e, d.orphans, 0, root, siteOrphans, 0)
}

// settleKept makes a misplaced line kept as written into the comment the
// emitter writes it as, wherever it would now bind as written, so the document
// is the one its saved text reloads as and the next edit comes out the same
// either way. One among a list's elements goes above the list, as a reload
// files a comment there. Runs after a load and after each edit, and only
// while the document holds such a line.
func (d *Document) settleKept() {
	// A line moved out of a list can leave it written inline, which changes
	// what the lines after it sit under, so go again until nothing moves.
	for d.kept && d.settleKeptOnce() {
	}
	if d.kept {
		d.keptSum = d.nearSum()
	}
}

// resettleKept runs after an edit. A kept line binds or not by the lines
// between it and the binding line above, so an edit that changed none of the
// nodes those came from cannot move it, and the whole-document emit is
// skipped (20260924d item 2).
func (d *Document) resettleKept() {
	if d.kept && d.nearSum() != d.keptSum {
		d.settleKept()
	}
}

// nearSum is everything the emit model reads from the nodes in keptNear: each
// one still at its place in its parent's list, its child count, its value's
// form and its comment lines. A kept line's parent chain needs no entry, since
// a binding line resets the model to its own depth.
func (d *Document) nearSum() uint64 {
	h := newFnv()
	addLead := func(l lead) {
		h.dec(l.depth)
		h.dec(len(l.text))
		h.bytes(l.text)
	}
	for _, at := range d.keptNear {
		n := at.node
		nd := &d.arena[n]
		h.dec(n)
		h.dec(len(nd.children))
		if n == root {
			h.dec(len(d.orphans))
			for _, l := range d.orphans {
				addLead(l)
			}
			continue
		}
		linked := byte(0)
		if nd.parent >= 0 && nd.parent < len(d.arena) {
			if kids := d.arena[nd.parent].children; at.pos < len(kids) && kids[at.pos] == n {
				linked = 1
			}
		}
		h.byte(linked)
		if stacks(nd) {
			h.byte(1)
		} else {
			h.byte(0)
		}
		switch nd.value.kind {
		case vEmpty:
			h.byte(0)
		case vCell:
			h.byte(1)
			h.dec(len(nd.value.els))
		default:
			h.byte(2)
		}
		t := nd.trivia
		if t == nil {
			h.byte(0)
			continue
		}
		for _, list := range [][]lead{t.leading, t.inside, t.after} {
			h.dec(len(list))
			for _, l := range list {
				addLead(l)
			}
		}
		h.dec(len(t.among))
		for _, a := range t.among {
			h.dec(a.before)
			addLead(a.lead)
		}
	}
	return h.h
}

func (d *Document) settleKeptOnce() bool {
	e := newEmit(0, true)
	d.emitAll(e)
	d.kept = e.verbatim > 0
	d.keptNear = e.keptNear
	var among []fell
	for _, f := range e.fell {
		var list []lead
		switch f.site {
		case siteOrphans:
			list = d.orphans
		case siteAmong:
			among = append(among, f)
			continue
		case siteLeading:
			list = d.arena[f.node].trivia.leading
		case siteInside:
			list = d.arena[f.node].trivia.inside
		default:
			list = d.arena[f.node].trivia.after
		}
		list[f.i].text = commented(list[f.i].text)
		list[f.i].depth = f.depth
		list[f.i].kept = true
	}
	// Out of each list latest first, so a removal leaves the earlier indices
	// alone, then onto the end of the leading lines in order.
	movedAny := len(among) > 0
	var moved []lead
	for len(among) > 0 {
		f := among[len(among)-1]
		among = among[:len(among)-1]
		t := d.arena[f.node].trivMut()
		moved = append(moved, t.among[f.i].lead)
		t.among = append(t.among[:f.i], t.among[f.i+1:]...)
		if len(among) > 0 && among[len(among)-1].node == f.node {
			continue
		}
		depth := 0
		for j := len(t.leading) - 1; j >= 0; j-- {
			if !strings.HasPrefix(t.leading[j].text, " ") && !strings.HasPrefix(t.leading[j].text, "\t") {
				depth = t.leading[j].depth
				break
			}
		}
		for j := len(moved) - 1; j >= 0; j-- {
			l := moved[j]
			l.text = commented(l.text)
			l.depth = depth
			l.line = 0
			l.kept = true
			t.leading = append(t.leading, l)
		}
		moved = moved[:0]
	}
	// A line moved above the first list in the file is now the first
	// thing written, so its blank goes the way the load's did.
	if movedAny {
		settleFirstBlank(d.arena, d.orphans)
	}
	return movedAny
}

// emit is canonical text on its way out, with a model of the level stack a
// reload of it will have at this point: the sentinel and one level per tab up
// to open, which the last binding line leaves, then what the lines refused
// since then pushed, and the indent of a kept misplaced line that the lines
// under it are kept with.
type emit struct {
	out  strings.Builder
	open int
	tail []stackEnt
	hold string
	held bool
	// settleKept() only: the lines written as comments, where they sit and at
	// what depth, and how many went out as written. Then the nodes the lines
	// since the last binding line came from, each with its place in its
	// parent's list, and those a kept line was modeled through.
	record   bool
	fell     []fell
	verbatim int
	nearBy   []nearNode
	flushed  int
	keptNear []nearNode
	// ToTextKeepLines() only: where the lines from each source line start
	// (0 for none), each raw body with the tabs its lines are padded with,
	// and where each value is written on its binding line.
	lines  bool
	marks  [][2]int
	bodies [][3]int
	spans  [][2]int
}

// nearNode is a node an emit passed through and its index in its parent's
// children.
type nearNode struct {
	node int
	pos  int
}

// fell is a kept line written as a comment: its list, its index there and
// the depth it went out at.
type fell struct {
	node  int
	site  site
	i     int
	depth int
}

// site is which trivia list a line sits in.
type site int

const (
	siteLeading site = iota
	siteInside
	siteAfter
	siteAmong
	siteOrphans
)

func newEmit(capacity int, record bool) *emit {
	e := &emit{open: -1, record: record}
	e.out.Grow(capacity)
	return e
}

func (e *emit) mark(line int) {
	if e.lines {
		e.marks = append(e.marks, [2]int{e.out.Len(), line})
	}
}

// span records a value written from at to here, the space before it included.
func (e *emit) span(at int) {
	if e.lines {
		e.spans = append(e.spans, [2]int{at, e.out.Len()})
	}
}

// bound: a binding line at this depth, so the stack is its levels and
// nothing else.
func (e *emit) bound(depth int) {
	e.open = depth
	e.tail = e.tail[:0]
	e.held = false
	e.nearBy = e.nearBy[:0]
	e.flushed = 0
}

func (e *emit) near(idx, pos int) {
	if e.record {
		e.nearBy = append(e.nearBy, nearNode{node: idx, pos: pos})
	}
}

// resolve runs a line at this indent through the reload's resolveParent():
// the parent it finds, and the model as it leaves it, not yet taken.
func (e *emit) resolve(indent string) (located, int, []stackEnt) {
	levels := e.open + 2
	stack := make([]stackEnt, 0, levels+len(e.tail)+1)
	stack = append(stack, stackEnt{indent: "", node: root})
	for depth := 0; depth < levels-1; depth++ {
		stack = append(stack, stackEnt{indent: strings.Repeat("\t", depth), node: root})
	}
	stack = append(stack, e.tail...)
	found := locateIn(stack, indent)
	c := found.cut
	if c.push {
		if c.hold >= 0 {
			stack = stack[:c.hold]
		}
		stack = append(stack, stackEnt{indent: indent, node: unopened})
	} else {
		stack = stack[:c.to]
	}
	if len(stack) <= levels {
		return found, len(stack) - 2, nil
	}
	return found, e.open, append([]stackEnt(nil), stack[levels:]...)
}

// refused takes a resolve, then the refusal's push: a refused line holds its
// own column unless it already sits there as a skipped line's.
func (e *emit) refused(indent string, open int, tail []stackEnt) {
	e.open = open
	e.tail = tail
	n := len(e.tail)
	if !(n > 0 && e.tail[n-1].indent == indent && e.tail[n-1].node == unopened) {
		e.tail = append(e.tail, stackEnt{indent: indent, node: dead})
	}
}

// placed: a line a reload binds, such as a list element, resolves, then holds
// its column with a live node.
func (e *emit) placed(indent string) {
	_, open, tail := e.resolve(indent)
	e.open = open
	e.tail = append(tail, stackEnt{indent: indent, node: root})
	e.held = false
}

// headsBlock reports a field whose last leading line is one kept for its
// value alone, naming just this field, so that line is written in place of
// the bare `name:` line: a reload opens the field from it the same way. An
// empty block keeps its own line, since nothing would open the field. Only
// what a reload restores counts, so a document and its reload agree.
func headsBlock(node *nodeData) bool {
	return len(node.children) != 0 && openedByKept(node)
}

// openedByKept is headsBlock() but for the children: a field a reload would
// open only from the lines under it, so it goes with the last of them.
func openedByKept(node *nodeData) bool {
	if !node.value.isEmpty() || node.blankBefore || node.trailing() != "" {
		return false
	}
	leads := node.leading()
	if len(leads) == 0 {
		return false
	}
	l := leads[len(leads)-1]
	if l.depth != 0 || strings.HasPrefix(l.text, " ") || strings.HasPrefix(l.text, "\t") || !opensLater(l.text) {
		return false
	}
	var tok Tokens
	Tokenize(l.text, ':', false, RulesCurrent, &tok)
	scan, err := pathOf(&tok, l.text)
	return err == nil && len(scan.segments) == 1 && scan.segments[0].sel == nil && scan.segments[0].name == node.name
}

// commented is a misplaced line's text as the comment it falls back to.
func commented(text string) string {
	return "# " + text[len(leadingWS(text)):]
}

// noteText is a path in a note, kept to one line.
func noteText(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\n", `\n`), "\r", `\r`)
}

// noteStamp is the local time to the second, with the zone, for a setter's
// note on a line it commented out. SHCL_TEST_CLOCK stands in for the system
// clock and zone, so tests can pin the text: "YYYY-mm-DD HH:MM:SS
// OFFSET_MINUTES [NAME]".
func noteStamp() string {
	when, offset, name, ok := testClock(os.Getenv("SHCL_TEST_CLOCK"))
	if !ok {
		when, offset, name = localClock()
	}
	return when + " " + zoneLabel(offset, name)
}

func testClock(spec string) (string, int, string, bool) {
	f := strings.Fields(spec)
	if len(f) != 3 && len(f) != 4 {
		return "", 0, "", false
	}
	offset, err := strconv.ParseInt(f[2], 10, 32)
	if err != nil {
		return "", 0, "", false
	}
	name := ""
	if len(f) == 4 {
		name = f[3]
	}
	return f[0] + " " + f[1], int(offset), name, true
}

// zoneLabel is the zone's short name, such as PDT, or its offset when it has
// none: Windows gives only long names, and some zones a number such as `+03`.
func zoneLabel(offset int, name string) string {
	if name != "" && strings.IndexFunc(name, func(r rune) bool {
		return !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z')
	}) < 0 {
		return name
	}
	sign := '+'
	if offset < 0 {
		sign = '-'
		offset = -offset
	}
	return fmt.Sprintf("UTC%c%02d:%02d", sign, offset/60, offset%60)
}

// localClock is the local time, its offset from UTC in minutes, and the
// zone's short name. Windows names a zone only in full, such as "Pacific
// Daylight Time", so there the label is always the offset.
func localClock() (string, int, string) {
	now := time.Now()
	name, secs := now.Zone()
	if runtime.GOOS == "windows" {
		name = ""
	}
	return now.Format("2006-01-02 15:04:05"), secs / 60, name
}

// pushLeads writes a run of comments and kept lines, base levels deep. A
// misplaced line kept as written (its text has its own indent, a
// comment's never does) goes back as it was only where a reload keeps it
// again, which the model of the reload's stack answers the way the parser
// will: refused for its indent, or under the kept line before it. A merge or
// an edit can leave it where it would bind, and there it is written as a
// comment, which reads the same. node, at and from name the list and the
// index of its first line, for settleKept().
func pushLeads(e *emit, leads []lead, base, node int, at site, from int) {
	lastComment := 0
	for i, c := range leads {
		if c.blankBefore && e.out.Len() > 0 {
			e.out.WriteByte('\n')
		}
		// A kept line among list elements is part of the list's run.
		if at != siteAmong {
			e.mark(c.line)
		}
		if strings.HasPrefix(c.text, " ") || strings.HasPrefix(c.text, "\t") {
			indent := leadingWS(c.text)
			found, open, tail := e.resolve(indent)
			under := e.held && len(indent) > len(e.hold) && strings.HasPrefix(indent, e.hold)
			keep := false
			switch {
			case !found.ok:
				keep = strings.Contains(indent, " ")
			case found.parent == dead:
				keep = under
			}
			if keep {
				if !found.ok {
					e.hold, e.held = indent, true
				}
				e.refused(indent, open, tail)
				e.verbatim++
				if e.record {
					e.keptNear = append(e.keptNear, e.nearBy[e.flushed:]...)
					e.flushed = len(e.nearBy)
				}
				e.out.WriteString(c.text)
				e.out.WriteByte('\n')
			} else {
				// Level with the comment or kept field line before it, so the
				// run's nesting reads back the same.
				if e.record {
					e.fell = append(e.fell, fell{node: node, site: at, i: from + i, depth: lastComment})
				}
				writeTabs(&e.out, base+lastComment)
				e.out.WriteString(commented(c.text))
				e.out.WriteByte('\n')
			}
			continue
		}
		pad := base + c.depth
		lastComment = c.depth
		if !strings.HasPrefix(c.text, "#") {
			// A kept malformed line resolves and holds its column on a reload,
			// open for the lines under it when only its value was wrong.
			indent := strings.Repeat("\t", pad)
			found, open, tail := e.resolve(indent)
			e.held = false
			if found.ok && found.parent != dead && opensLater(c.text) {
				e.open = open
				e.tail = append(tail, stackEnt{indent: indent, node: root})
			} else {
				e.refused(indent, open, tail)
			}
		}
		writeTabs(&e.out, pad)
		pushKept(e, c.text, pad)
	}
}

// pushKept writes a kept line, and the raw body and fence it took, if any,
// which go one level under it, as a field's block does. The body moves with
// its line.
func pushKept(e *emit, text string, pad int) {
	line, block, hasBody := strings.Cut(text, "\n")
	e.out.WriteString(line)
	e.out.WriteByte('\n')
	if !hasBody {
		return
	}
	body := e.out.Len()
	fence := block
	if k := strings.LastIndexByte(block, '\n'); k >= 0 {
		for _, l := range strings.Split(block[:k], "\n") {
			if l != "" {
				writeTabs(&e.out, pad+1)
			}
			e.out.WriteString(l)
			e.out.WriteByte('\n')
		}
		fence = block[k+1:]
	}
	end := e.out.Len()
	writeTabs(&e.out, pad+1)
	e.out.WriteString(fence)
	e.out.WriteByte('\n')
	if e.lines {
		e.bodies = append(e.bodies, [3]int{body, end, pad + 1})
	}
}

// unit is a run of canonical lines from one source line on (0: from none),
// with the blank lines written before it and the spans of its values. As a
// group, line is the first source line of its runs and partFrom..partTo the
// runs.
type unit struct {
	line     int
	start    int
	end      int
	blanks   int
	spanFrom int
	spanTo   int
	partFrom int
	partTo   int
}

func unitsOf(e *emit, text string) []unit {
	var units []unit
	mi, bi, tag, blanks, open := 0, 0, 0, 0, false
	pos := 0
	for pos < len(text) {
		next := lineEnd(text, pos)
		for mi < len(e.marks) && e.marks[mi][0] <= pos {
			tag = e.marks[mi][1]
			mi++
		}
		for bi < len(e.bodies) && e.bodies[bi][1] <= pos {
			bi++
		}
		inBody := bi < len(e.bodies) && e.bodies[bi][0] <= pos
		switch {
		case text[pos] == '\n' && !inBody:
			blanks++
			open = false
		case open && len(units) > 0 && units[len(units)-1].line == tag:
			units[len(units)-1].end = next
		default:
			units = append(units, unit{line: tag, start: pos, end: next, blanks: blanks})
			blanks = 0
			open = true
		}
		pos = next
	}
	si := 0
	for k := range units {
		u := &units[k]
		for si < len(e.spans) && e.spans[si][0] < u.start {
			si++
		}
		from := si
		for si < len(e.spans) && e.spans[si][0] < u.end {
			si++
		}
		u.spanFrom, u.spanTo = from, si
		u.partFrom, u.partTo = k, k+1
	}
	return units
}

// groupUnits: the runs one source line wrote, and every run between them, as
// one group, with a line inside a raw block or a stacked list counted as the
// binding line's. A comment the canonical form writes between a dotted line's
// block and its child sits inside such a group, and the group is kept or
// rewritten whole (20260925b item 2).
func groupUnits(units []unit, owner []int) []unit {
	of := func(u unit) int {
		if u.line < len(owner) {
			return owner[u.line]
		}
		return u.line
	}
	size := len(owner)
	for _, u := range units {
		if u.line+1 > size {
			size = u.line + 1
		}
	}
	last := make([]int, size)
	for i, u := range units {
		last[of(u)] = i
	}
	var groups []unit
	for i := 0; i < len(units); {
		j, line := i, 0
		for k := i; k <= j; k++ {
			if o := of(units[k]); o != 0 {
				j = maxInt(j, last[o])
				if line == 0 || o < line {
					line = o
				}
			}
		}
		groups = append(groups, unit{
			line: line, start: units[i].start, end: units[j].end, blanks: units[i].blanks,
			spanFrom: units[i].spanFrom, spanTo: units[j].spanTo, partFrom: i, partTo: j + 1,
		})
		i = j + 1
	}
	return groups
}

// lineEnd is where the line starting at pos ends, past its newline.
func lineEnd(text string, pos int) int {
	if i := strings.IndexByte(text[pos:], '\n'); i >= 0 {
		return pos + i + 1
	}
	return len(text)
}

// eolOf is the line ending t ends with: CRLF, LF or none.
func eolOf(t string) string {
	if strings.HasSuffix(t, "\r\n") {
		return "\r\n"
	} else if strings.HasSuffix(t, "\n") {
		return "\n"
	}
	return ""
}

func tabs(s string) int {
	n := 0
	for n < len(s) && s[n] == '\t' {
		n++
	}
	return n
}

// indentFor is the indent a new line depth levels down gets: the last one
// written there, or the nearest shallower one plus a level.
func indentFor(indents []*string, depth int, step string) string {
	j := depth
	for j > 0 && (j >= len(indents) || indents[j] == nil) {
		j--
	}
	base := ""
	if j < len(indents) && indents[j] != nil {
		base = *indents[j]
	}
	return base + strings.Repeat(step, depth-j)
}

// setIndent records indent at depth, dropping what was known deeper.
func setIndent(indents []*string, depth int, indent string) []*string {
	for len(indents) < depth+1 {
		indents = append(indents, nil)
	}
	indents = indents[:depth+1]
	indents[depth] = &indent
	return indents
}

// noteIndent: a source line written at depth. One whose indent does not nest
// under the level above it, a dotted path for one, says nothing about the
// levels after it.
func noteIndent(indents []*string, depth int, indent string) []*string {
	fits := false
	if depth == 0 {
		fits = indent == ""
	} else if indent != "" {
		fits = true
		if depth-1 < len(indents) && indents[depth-1] != nil {
			up := *indents[depth-1]
			fits = len(indent) > len(up) && strings.HasPrefix(indent, up)
		}
	}
	if fits {
		return setIndent(indents, depth, indent)
	}
	return indents[:1]
}

// writeRun writes a run the edits wrote, indented the way the lines around it
// are. A raw body keeps its own tabs past the pad, and a kept line its indent.
func writeRun(out *strings.Builder, e *emit, text string, pos, end int, indents []*string, step, eol string) []*string {
	for pos < end {
		next := lineEnd(text, pos)
		line := text[pos : next-1]
		b := sort.Search(len(e.bodies), func(k int) bool { return e.bodies[k][0] > pos })
		if b > 0 && pos < e.bodies[b-1][1] {
			pad := e.bodies[b-1][2]
			if line != "" {
				out.WriteString(indentFor(indents, pad, step))
				out.WriteString(line[pad:])
			}
		} else {
			depth := tabs(line)
			if strings.HasPrefix(line[depth:], " ") {
				out.WriteString(line)
			} else {
				indent := indentFor(indents, depth, step)
				out.WriteString(indent)
				out.WriteString(line[depth:])
				indents = setIndent(indents, depth, indent)
			}
		}
		out.WriteString(eol)
		pos = next
	}
	return indents
}

// authoredHead is a binding line the edits rewrote, with the name written the
// way the source line wrote it. False unless both lines bind one plain name.
func authoredHead(src, canon string) (string, bool) {
	t := trimEndWS(strings.TrimSuffix(src, "\n"))
	ilen := len(leadingWS(t))
	rest := strings.TrimLeftFunc(t[ilen:], isWsp)
	head := len(t) - len(rest)
	c := canon[tabs(canon):]
	var tok Tokens
	var sep [2]int
	for k, text := range []string{rest, c} {
		if strings.HasPrefix(text, "#") || strings.HasPrefix(text, "*") {
			return "", false
		}
		Tokenize(text, ':', false, RulesCurrent, &tok)
		if len(tok.Segments) != 1 || tok.Segments[0].Selector != nil || tok.Fault >= 0 || tok.Sep < 0 {
			return "", false
		}
		sep[k] = tok.Sep
	}
	return t[:head+sep[0]+1] + c[sep[1]+1:], true
}

// spliceValue: a run whose only change is its last value, written into the
// source line in place of the old one, so the name, spacing and comment stay
// as they were. False when anything else changed or the line is not a plain
// field.
func spliceValue(line string, was *emit, t0 string, w unit, now *emit, t1 string, u unit) (string, bool) {
	s0, s1 := was.spans[w.spanFrom:w.spanTo], now.spans[u.spanFrom:u.spanTo]
	if len(s0) == 0 || len(s0) != len(s1) {
		return "", false
	}
	p0, p1 := w.start, u.start
	for k := range s0 {
		a, b := s0[k], s1[k]
		if t0[p0:a[0]] != t1[p1:b[0]] || (k+1 < len(s0) && t0[a[0]:a[1]] != t1[b[0]:b[1]]) {
			return "", false
		}
		p0, p1 = a[1], b[1]
	}
	if t0[p0:w.end] != t1[p1:u.end] {
		return "", false
	}
	last := s1[len(s1)-1]
	value := t1[last[0]:last[1]]
	t := trimEndWS(strings.TrimSuffix(line, "\n"))
	tail := line[len(t):]
	ilen := len(leadingWS(t))
	rest := strings.TrimLeftFunc(t[ilen:], isWsp)
	head := len(t) - len(rest)
	if strings.HasPrefix(rest, "#") || strings.HasPrefix(rest, "*") {
		return "", false
	}
	var tok Tokens
	Tokenize(rest, ':', false, RulesCurrent, &tok)
	colon := tok.Sep
	if colon < 0 {
		return "", false
	}
	scan, err := pathOf(&tok, rest)
	if err != nil || !scan.hasValue {
		return "", false
	}
	a, b := tok.Value[0], tok.Value[1]
	if _, _, _, ok := fenceOpen(rest[a:b]); ok || bracketText(&tok, rest) {
		return "", false
	}
	// The blanks after the colon stay as they were when there was a value and
	// still is one; the canonical value comes with one space.
	gap, from := "", b
	if a == b {
		from = colon + 1
	} else if v, ok := strings.CutPrefix(value, " "); ok {
		gap, value = rest[colon+1:a], v
	}
	return t[:head+colon+1] + gap + value + rest[from:] + tail, true
}

// spliceGroup is spliceValue for a group: the runs line up one for one and
// differ in one, the last its source line wrote, so the line's last value is
// its value. The line and its new text.
func spliceGroup(lines []string, was *emit, t0 string, wr []unit, w unit, now *emit, t1 string, ur []unit, u unit) (int, string, bool) {
	a, b := wr[w.partFrom:w.partTo], ur[u.partFrom:u.partTo]
	if len(a) != len(b) {
		return 0, "", false
	}
	hit := -1
	for k := range a {
		x, y := a[k], b[k]
		if x.line != y.line || x.blanks != y.blanks {
			return 0, "", false
		}
		if t0[x.start:x.end] != t1[y.start:y.end] {
			if hit >= 0 {
				return 0, "", false
			}
			hit = k
		}
	}
	if hit < 0 {
		return 0, "", false
	}
	for _, x := range a[hit+1:] {
		if x.line == a[hit].line {
			return 0, "", false
		}
	}
	l := a[hit].line
	if l < 1 || l > len(lines) {
		return 0, "", false
	}
	t, ok := spliceValue(lines[l-1], was, t0, a[hit], now, t1, b[hit])
	return l, t, ok
}

// keepLines is ToTextKeepLines() on a loaded text: the loaded document's
// canonical runs line up with the text by the source line each came from, and
// the edited document's runs that match one exactly take that line's text.
// False when the result would not reload as doc.
func keepLines(src string, doc *Document) (string, bool) {
	const none = -1
	// A text that was canonical keeps its lines as the canonical form.
	if src == "" {
		return doc.ToCanonical(), true
	}
	now := doc.emitMarked()
	nowText := now.out.String()
	p := newParser()
	p.trackDropped = true
	loadedDoc := p.parse(src, doc.strictness)
	loaded := loadedDoc.emitMarked()
	loadedText := loaded.out.String()
	if nowText == loadedText {
		return src, true
	}
	bom, body := "", src
	if strings.HasPrefix(src, "\ufeff") {
		bom, body = "\ufeff", src[len("\ufeff"):]
	}
	var lines []string
	for pos := 0; pos < len(body); {
		next := lineEnd(body, pos)
		lines = append(lines, body[pos:next])
		pos = next
	}
	n := len(lines)
	line := func(l int) string { return lines[l-1] }
	blank := func(l int) bool { return trimWsp(strings.TrimRight(line(l), "\n")) == "" }
	indent := func(l int) string { return leadingWS(line(l)) }
	// The lines each source line stands for: its own, through the end of a raw
	// block or a stacked list. Ranges that overlap, as a list taken up again
	// further down, run together, and each line in a run counts as the run's
	// first line, which stands for the whole run.
	own := make([]int, n+2)
	owner := make([]int, n+2)
	for k := range own {
		own[k], owner[k] = k, k
	}
	for _, e := range loadedDoc.ends {
		if l := e[0]; l <= n {
			own[l] = maxInt(own[l], minInt(e[1], n))
		}
	}
	end := append([]int(nil), own...)
	first, reach := 0, 0
	for k := 1; k <= n; k++ {
		if k <= reach {
			owner[k] = first
		} else {
			first = k
		}
		reach = maxInt(reach, own[k])
		end[first] = reach
	}
	wasRuns, isRuns := unitsOf(loaded, loadedText), unitsOf(now, nowText)
	was, is := groupUnits(wasRuns, owner), groupUnits(isRuns, owner)
	// Each source line's group in the loaded text, and the lines it stands for,
	// through its last run's.
	at := make([]int, n+2)
	for k := range at {
		at[k] = none
	}
	for i, g := range was {
		if g.line != 0 && g.line <= n {
			at[g.line] = i
			for _, r := range wasRuns[g.partFrom:g.partTo] {
				if r.line != 0 && r.line <= n {
					end[g.line] = maxInt(end[g.line], end[owner[r.line]])
				}
			}
		}
	}
	var claimed []int
	for l := 1; l <= n; l++ {
		if at[l] != none {
			claimed = append(claimed, l)
		}
	}
	// The first group after each one's lines, for telling two that sat next to
	// each other.
	next := make([]int, n+2)
	for _, l := range claimed {
		k := sort.Search(len(claimed), func(c int) bool { return claimed[c] > end[l] })
		next[l] = n + 1
		if k < len(claimed) {
			next[l] = claimed[k]
		}
	}
	// A line no group stands for, as a repeat the load folded away, goes out
	// only as it was written, between two kept groups or at either end. One
	// that is not blank and is left out makes the save fall back, since every
	// line no edit touched has to come back (20260925c item 1).
	left := make([]bool, n+2)
	for k := 1; k <= n; k++ {
		left[k] = !blank(k)
	}
	for _, l := range claimed {
		for k := l; k <= minInt(end[l], n); k++ {
			left[k] = false
		}
	}
	// A repeat the load folded away goes when the edits took every line under
	// it, and the blank lines above it go along: the field is still written
	// where it first was. A remove writes no line the document did not write
	// before (2026100115323232).
	present := make([]bool, n+2)
	for _, r := range isRuns {
		if r.line != 0 && r.line <= n {
			present[owner[r.line]] = true
		}
	}
	tagged := make([]bool, n+2)
	for _, r := range wasRuns {
		if r.line != 0 && r.line <= n {
			tagged[owner[r.line]] = true
		}
	}
	dropped := make([]bool, n+2)
	for _, k := range loadedDoc.dropped {
		if k <= n {
			dropped[k] = true
		}
	}
	released := make([]bool, n+2)
	for h := n; h >= 1; h-- {
		if !left[h] || dropped[h] {
			continue
		}
		anyUnder, allGone := false, true
		for k := h + 1; k <= n; k++ {
			if blank(k) {
				continue
			}
			// A line in a raw body or a stacked list is under h when the line
			// it belongs to is, whatever its own indent.
			o := owner[k]
			i := indent(k)
			if o == k && !(len(i) > len(indent(h)) && strings.HasPrefix(i, indent(h))) {
				break
			}
			anyUnder = true
			gone := released[k] || (tagged[o] && !present[o])
			if !gone {
				allGone = false
				break
			}
		}
		if anyUnder && allGone {
			left[h] = false
			released[h] = true
		}
	}
	// New lines end the way most of the file's lines do.
	eol := majorityEol(body)
	// One level of the source's indent: the one most blocks use for a line
	// one level in, each block counted once, by its first such line. A tie
	// goes to one tab when that is among them, else to the block first in the
	// file, so one odd block does not set it (2026100115403386). Failing that,
	// the first indented line, a list element or a fence.
	var firsts []int
	for _, u := range wasRuns {
		if u.line != 0 && u.line <= n && tabs(loadedText[u.start:]) == 1 && indent(u.line) != "" {
			firsts = append(firsts, u.line)
		}
	}
	sort.Ints(firsts)
	type stepCount struct {
		step  string
		count int
	}
	var steps []stepCount
	top, block, k := 0, -1, 1
	for _, l := range firsts {
		for ; k <= l; k++ {
			if owner[k] == k && !blank(k) && indent(k) == "" && !strings.HasPrefix(line(k), "#") {
				top = k
			}
		}
		if block == top {
			continue
		}
		block = top
		found := false
		for i := range steps {
			if steps[i].step == indent(l) {
				steps[i].count++
				found = true
				break
			}
		}
		if !found {
			steps = append(steps, stepCount{indent(l), 1})
		}
	}
	most := 0
	for _, sc := range steps {
		most = maxInt(most, sc.count)
	}
	step := ""
	for _, sc := range steps {
		if sc.count == most && sc.step == "\t" {
			step = "\t"
		}
	}
	for _, sc := range steps {
		if step == "" && sc.count == most {
			step = sc.step
		}
	}
	for l := 1; step == "" && l <= n; l++ {
		if !blank(l) {
			step = indent(l)
		}
	}
	if step == "" {
		step = "\t"
	}
	var out strings.Builder
	out.Grow(len(src) + len(nowText)/8)
	out.WriteString(bom)
	breakLine := func() {
		if out.Len() > len(bom) && !strings.HasSuffix(out.String(), "\n") {
			out.WriteString(eol)
		}
	}
	// Which source lines went out as written. Every line the load dropped
	// has to, or the save falls back: a rewritten group can span one, as a
	// stacked list over a refused element (20260926 item 1).
	wrote := make([]bool, n+2)
	// The lines no group stands for that sat right after a kept group, when
	// the group that followed it then does not follow it now. They go out
	// before the next source group, a new line not indented past them, or the
	// end. A new line indented past them goes first, since one written under
	// a dropped line would be dropped with it. A line the load dropped comes
	// back this way.
	flush := func(from, to int) {
		// The blank lines among them stay, up to the last one written.
		last := 0
		for k := minInt(to, n+1) - 1; k >= from; k-- {
			if left[k] {
				last = k
				break
			}
		}
		for k := from; k < to; k++ {
			if left[k] {
				out.WriteString(line(k))
				wrote[k] = true
				left[k] = false
			} else if k < last && blank(k) {
				out.WriteString(line(k))
			}
		}
	}
	indents := []*string{new(string)}
	// The line of the group just written while it is a source one, and the end
	// of the last source group met, kept or not.
	prev, reach := 0, 0
	// The last kept group whose following lines are still to go out.
	owed := 0
	for i, u := range is {
		l := u.line
		known := l != 0 && l <= n && at[l] != none
		if known {
			// The canonical form writes this above a source line that sat above
			// it: blocks folded together from two places, or a selector's child
			// under an earlier block. Keeping some of the lines would move the
			// others, so the save falls back.
			if l <= reach {
				return "", false
			}
			reach = end[l]
		}
		same := known && loadedText[was[at[l]].start:was[at[l]].end] == nowText[u.start:u.end]
		splicedAt, spliced, didSplice := 0, "", false
		if known && !same {
			splicedAt, spliced, didSplice = spliceGroup(lines, loaded, loadedText, wasRuns, was[at[l]], now, nowText, isRuns, u)
		}
		kept := same || didSplice
		// The blank lines above a group stay while it has a blank before it.
		// The canonical form can write that blank inside a kept group, as a
		// dotted line's child's, while the source has it above.
		blanksStay := u.blanks > 0
		for _, r := range isRuns[u.partFrom+1 : u.partTo] {
			blanksStay = blanksStay || (kept && r.blanks > 0)
		}
		// Between two groups that stay next to each other, the source's own
		// lines: a repeat the load folded away stays, and so do the blank lines.
		// The same before the first group. Before any other group from the
		// source, its own blank lines.
		breakLine()
		depth := tabs(nowText[u.start:u.end])
		pay := false
		if owed != 0 {
			if known {
				pay = !(kept && prev == owed && next[prev] == l)
			} else {
				ind := indentFor(indents, depth, step)
				for k := end[owed] + 1; k < next[owed]; k++ {
					if left[k] {
						pay = len(ind) <= len(indent(k)) || !strings.HasPrefix(ind, indent(k))
						break
					}
				}
			}
		}
		if pay {
			flush(end[owed]+1, next[owed])
			breakLine()
			owed = 0
		}
		if known {
			owed = 0
		}
		switch {
		case i == 0:
			if kept && len(claimed) > 0 && claimed[0] == l {
				for k := 1; k < l; k++ {
					out.WriteString(line(k))
					wrote[k] = true
					left[k] = false
				}
			}
		case kept && prev != 0 && next[prev] == l:
			blanks := false
			// A blank line above a source line written here stays with it.
			last := 0
			for k := end[prev] + 1; k < l; k++ {
				blanks = blanks || blank(k)
				if !blank(k) {
					last = k
				}
			}
			for k := end[prev] + 1; k < l; k++ {
				if blanksStay || !blank(k) || k < last {
					out.WriteString(line(k))
					wrote[k] = true
					left[k] = false
				}
			}
			if !blanks {
				for k := 0; k < u.blanks; k++ {
					out.WriteString(eol)
				}
			}
		case known && blanksStay && l > 1 && blank(l-1):
			k := l - 1
			for k > 1 && blank(k-1) {
				k--
			}
			for ; k < l; k++ {
				out.WriteString(line(k))
			}
		default:
			for k := 0; k < u.blanks; k++ {
				out.WriteString(eol)
			}
		}
		if kept {
			// A spliced line's value replaces the lines it took, as a stacked
			// list's elements.
			for k := l; k <= end[l]; k++ {
				if didSplice && k == splicedAt {
					out.WriteString(spliced)
					k = own[k]
				} else {
					out.WriteString(line(k))
					wrote[k] = true
				}
			}
			// A line kept as written holds no level's indent.
			if !strings.HasPrefix(nowText[u.start+depth:], " ") {
				indents = noteIndent(indents, depth, indent(wasRuns[was[at[l]].partFrom].line))
			}
			prev = l
			owed = l
		} else {
			// A binding the edits rewrote keeps its line's indent and name.
			from := u.start
			if known && u.partTo-u.partFrom == 1 {
				first := lineEnd(nowText, u.start)
				if t, ok := authoredHead(line(l), nowText[u.start:first-1]); ok {
					out.WriteString(t)
					// A changed line keeps its own line ending.
					ownEol := eolOf(line(l))
					if ownEol == "" {
						ownEol = eol
					}
					out.WriteString(ownEol)
					indents = noteIndent(indents, depth, indent(l))
					from = first
				}
			}
			indents = writeRun(&out, now, nowText, from, u.end, indents, step, eol)
			prev = 0
		}
	}
	if owed != 0 {
		breakLine()
		flush(end[owed]+1, n+1)
	}
	// The blank lines the source ends with stay at the end.
	breakLine()
	tail := 1
	for _, l := range claimed {
		tail = maxInt(tail, end[l]+1)
	}
	allBlank := true
	for k := tail; k <= n; k++ {
		allBlank = allBlank && blank(k)
	}
	if out.Len() > len(bom) && allBlank {
		for k := tail; k <= n; k++ {
			out.WriteString(line(k))
		}
	}
	for _, missed := range left {
		if missed {
			return "", false
		}
	}
	for _, k := range loadedDoc.dropped {
		if !wrote[k] {
			return "", false
		}
	}
	text := out.String()
	// So does a last line with no newline. The line that ends the text now
	// can be one kept with the other line ending.
	if body != "" && !strings.HasSuffix(body, "\n") {
		text = text[:len(text)-len(eolOf(text))]
	}
	// The reload has to be the document, and it may not load with an error the
	// source did not have: a child the edits gave an element list that stayed
	// stacked reads back the same and is E001 (20260925b item 1). A line the
	// load dropped went out as written, and the reload has to drop each one
	// again: one that now binds, even to the same document, reads differently
	// from how the file had it.
	back := newParser().parse(text, doc.strictness)
	if back.lost == loadedDoc.lost && back.ToCanonical() == nowText && errorsWithin(back, loadedDoc) {
		return text, true
	}
	return "", false
}

// dropBanners takes the info block out of leads, from the lone "##" above its
// "This config file format is SHCL." line to the next lone "##", and each
// version line Migrate stamped, with the note under it. A block with no
// closing "##" ends after its last line written the block's way. A Schema line
// in a block stays, and so does any other comment around one, even written
// right against it. It returns how many came off, and whether the last one
// had a blank above it with no line after it to take that blank.
func dropBanners(leads *[]lead) (int, bool) {
	ls := *leads
	inRun := func(l lead) bool { return strings.HasPrefix(l.text, "##") && !l.blankBefore }
	keep := make([]lead, 0, len(ls))
	removed, owed, prevKept := 0, false, false
	for i := 0; i < len(ls); {
		start, end := i, i+1
		switch {
		case ls[i].text == bannerTitle:
			if prevKept && !ls[i].blankBefore && ls[i-1].text == "##" {
				keep = keep[:len(keep)-1]
				start = i - 1
			}
			closed := false
			for k := end; k < len(ls) && inRun(ls[k]); k++ {
				if ls[k].text == "##" {
					end, closed = k+1, true
					break
				}
			}
			for !closed && end < len(ls) && inRun(ls[end]) &&
				(strings.HasPrefix(ls[end].text, "##    ") || ls[end].text == bannerName) {
				end++
			}
		case strings.HasPrefix(ls[i].text, FormatLineHead):
			if end < len(ls) && inRun(ls[end]) && ls[end].text == MigratedLine {
				end++
			}
		default:
			keep = append(keep, ls[i])
			prevKept = true
			i++
			continue
		}
		// The blank that set the block off moves to whatever followed it, so
		// the lines around it stay apart. A Schema line in the block is the
		// author's and stays, with the blank.
		at := len(keep)
		for _, l := range ls[start:end] {
			if strings.HasPrefix(l.text, SchemaLineHead) {
				keep = append(keep, l)
			}
		}
		switch {
		case at < len(keep):
			keep[at].blankBefore = ls[start].blankBefore
		case end < len(ls):
			ls[end].blankBefore = ls[end].blankBefore || ls[start].blankBefore
		default:
			owed = ls[start].blankBefore
		}
		removed++
		prevKept = false
		i = end
	}
	if removed > 0 {
		// What followed a block steps up to fit the run.
		restep(keep)
		*leads = keep
	}
	return removed, owed
}

// errorsWithin: each error code d loads with, of loaded with at least as
// often.
func errorsWithin(d, of *Document) bool {
	codes := func(d *Document) []string {
		var c []string
		for _, x := range d.diags {
			if x.Severity == SeverityError {
				c = append(c, x.Code)
			}
		}
		sort.Strings(c)
		return c
	}
	mine, theirs := codes(d), codes(of)
	j := 0
	for _, c := range mine {
		for j < len(theirs) && theirs[j] < c {
			j++
		}
		if j == len(theirs) || theirs[j] != c {
			return false
		}
		j++
	}
	return true
}

// writeTrailing writes an inline comment, canonically two spaces before the `#`.
func writeTrailing(out *strings.Builder, trailing string) {
	if trailing != "" {
		out.WriteString("  ")
		out.WriteString(trailing)
	}
}

// emitChildren emits a sibling run. The parent walk already knows whether an
// earlier same-name sibling is empty (the raw same-line-fence hazard), so one
// seen-empties set here replaces a per-child rescan of the whole run.
func (d *Document) emitChildren(kids []int, depth int, e *emit) {
	empties := map[string]bool{}
	for pos, c := range kids {
		n := &d.arena[c]
		wm := n.value.kind == vRaw && empties[n.name]
		if n.value.isEmpty() {
			empties[n.name] = true
		}
		d.emitNode(c, pos, depth, wm, e)
	}
}

func (d *Document) emitNode(idx, pos, depth int, wouldMerge bool, e *emit) {
	d.emitLine(idx, pos, depth, wouldMerge, e)
	d.emitChildren(d.arena[idx].children, depth+1, e)
	e.near(idx, pos)
	// Comments this block owns with no child to take them, one deeper.
	pushLeads(e, d.arena[idx].inside(), depth+1, idx, siteInside, 0)
	// Comments that hung on this block after its last child.
	pushLeads(e, d.arena[idx].after(), depth, idx, siteAfter, 0)
}

func (d *Document) emitLine(idx, pos, depth int, wouldMerge bool, e *emit) {
	node := &d.arena[idx]
	e.near(idx, pos)
	pad := strings.Repeat("\t", depth)
	out := &e.out
	// Same-line fence spelling can't have an inline comment (an unbalanced
	// quote in the info-string could hide the `#` on reparse), so its trailing
	// comment joins the leading lines instead; the flag comes from the parent's
	// walk. Each blank rides its own comment (or the binding line), never as
	// the first output line.
	pushLeads(e, node.leading(), depth, idx, siteLeading, 0)
	// The kept line just written opens this block on a reload.
	if headsBlock(node) {
		e.bound(depth)
		e.near(idx, pos)
		return
	}
	if node.blankBefore && out.Len() > 0 {
		out.WriteByte('\n')
	}
	e.mark(node.line)
	if wouldMerge && node.trailing() != "" {
		out.WriteString(pad)
		out.WriteString(node.trailing())
		out.WriteByte('\n')
	}
	out.WriteString(pad)
	out.WriteString(emitName(node.name))
	out.WriteByte(':')
	e.bound(depth)
	e.near(idx, pos)
	switch {
	case node.value.kind == vEmpty:
		e.span(out.Len())
		writeTrailing(out, node.trailing())
		out.WriteByte('\n')
	case node.value.kind == vCell && stacks(node):
		// Stacked, with the kept lines where they sat.
		writeTrailing(out, node.trailing())
		out.WriteByte('\n')
		among := node.among()
		next := 0
		for i := range node.value.els {
			from := next
			for next < len(among) && among[next].before <= i {
				next++
			}
			for j := from; j < next; j++ {
				pushLeads(e, []lead{among[j].lead}, depth+1, idx, siteAmong, j)
			}
			column := pad + "\t"
			out.WriteString(column)
			out.WriteString("* ")
			out.WriteString(emitElement(&node.value.els[i]))
			out.WriteByte('\n')
			e.placed(column)
		}
		for j := next; j < len(among); j++ {
			pushLeads(e, []lead{among[j].lead}, depth+1, idx, siteAmong, j)
		}
	case node.value.kind == vCell:
		at := out.Len()
		out.WriteByte(' ')
		out.WriteString(emitCell(node.value.els))
		e.span(at)
		writeTrailing(out, node.trailing())
		out.WriteByte('\n')
	default:
		// Child-indent spelling is canonical: bare name line, fenced block one
		// level deeper, verbatim content. Exception: if an earlier same-name
		// sibling is empty, the bare `name:` header would merge into it on
		// reparse and the fence would fill that instance instead - so use the
		// same-line spelling there.
		r := node.value.raw
		if wouldMerge {
			out.WriteByte(' ')
		} else {
			writeTrailing(out, node.trailing())
			out.WriteByte('\n')
		}
		bodyPad := pad + "\t"
		fence := strings.Repeat(string(rune(r.fenceChar)), r.fenceLen)
		if !wouldMerge {
			out.WriteString(bodyPad)
		}
		out.WriteString(emitFenceLine(r))
		out.WriteByte('\n')
		body := out.Len()
		if r.content != "" {
			for _, l := range strings.Split(r.content, "\n") {
				if l != "" {
					out.WriteString(bodyPad)
				}
				out.WriteString(l)
				out.WriteByte('\n')
			}
		}
		end := out.Len()
		out.WriteString(bodyPad)
		out.WriteString(fence)
		out.WriteByte('\n')
		if e.lines {
			e.bodies = append(e.bodies, [3]int{body, end, depth + 1})
		}
	}
}

// escapeName emits a stored (escape-resolved) name in a spelling that reads
// back as the same name: bare when it can be, else quoted with the escapes
// applyEscapes undoes. This is a true inverse of the name parse, which quoteText
// is not - that one picks a quote style to AVOID escaping and never escapes a
// backslash, which is right for a value (stored in its escaped spelling) and
// wrong for a name (stored resolved).
func escapeName(name string) string {
	return escapeNameAs(name, RulesCurrent)
}

// escapeNameAs is escapeName for a reader of rules: under 2.x an invisible
// character is written as it is, since 2.x kept a \u as written.
func escapeNameAs(name string, rules Rules) string {
	if name != "" {
		bare := true
		for _, c := range name {
			if !isBareNameChar(c) {
				bare = false
				break
			}
		}
		if bare {
			return name
		}
	}
	var out strings.Builder
	out.WriteByte('"')
	for i := 0; i < len(name); i++ {
		switch name[i] {
		case '\\':
			out.WriteString(`\\`)
		case '"':
			out.WriteString(`\"`)
		case '\t':
			out.WriteString(`\t`)
		case '\n':
			out.WriteString(`\n`)
		default:
			if r, n, ok := invisibleAt(name, i); ok && rules == RulesCurrent {
				writeUnicodeEscape(&out, r)
				i += n - 1
			} else {
				out.WriteByte(name[i])
			}
		}
	}
	out.WriteByte('"')
	return out.String()
}

func emitName(name string) string {
	return escapeName(name)
}

// QuoteSegment quotes one path segment so it can be spliced into a lookup
// path: a bare name passes through, anything else comes back quoted and
// escaped in the form the path scanner accepts. Splicing user-typed text into
// a path without this is path injection - a dotted name silently reads as
// nesting. Same spelling Paths and the canonical emitter produce.
func QuoteSegment(name string) string {
	return emitName(name)
}

// diagName is a field name for a diagnostic message: put the way the
// emitter would write it, so a name with a line break, a dot or a quote
// cannot pose as something it is not - a raw `a.b` reads exactly like `a`
// nesting `b`, and a raw line break splits one diagnostic across two.
func diagName(name string) string {
	return emitName(name)
}

// diagElement is one element of a value, written for a diagnostic message:
// the emitter's inline spelling, so a value with a line break cannot split
// one diagnostic across two.
func diagElement(e *element) string {
	return emitElement(e)
}

// diagValue is a value for a diagnostic message. Only a cell reaches this
// today, from the H001 hint; a raw block has no one-line form worth
// suggesting.
func diagValue(v *value) string {
	if v.kind != vCell {
		return v.display()
	}
	parts := make([]string, len(v.els))
	for i := range v.els {
		parts[i] = diagElement(&v.els[i])
	}
	return strings.Join(parts, ", ")
}

// h001Head is the single H001 wording site: the hint builder and the schema
// suppressor both come here, so the suppressor matches the exact head the
// builder emitted - never a re-parse of free prose. (The leaf name cannot
// ride on Diagnostic itself: consumers build Diagnostic literals, so its
// field set is frozen.)
func h001Head(name string) string {
	shown := diagName(name)
	return fmt.Sprintf("'%s' repeats as a bare leaf - did you mean '%s: ", shown, shown)
}

// SuppressDeclaredRepeats drops the H001 hints a schema disavows: a field
// whose declared repeat upper bound is above 1 repeats BY DESIGN (repetition
// is its instance mechanism), so the repeated-bare-leaf hint is structurally a
// false positive there and trains users to ignore hints. Matching is by leaf
// name - the filter consumers were hand-rolling - which errs toward quiet, for
// a hint. Used by `check --schema` and LoadAndValidate; call it wherever doc
// diagnostics and a schema meet. Returns the filtered slice as a fresh
// allocation and never disturbs the input (the reference filters its list in
// place behind &mut; a Go return reads as a copy, so it must behave as one).
func SuppressDeclaredRepeats(schema *Document, diags []Diagnostic) []Diagnostic {
	names := disavowedNames(schema, func(c *constraint) bool { return c.repeat != nil && c.repeat[1] > 1 })
	if len(names) == 0 {
		return append([]Diagnostic(nil), diags...)
	}
	heads := make([]string, len(names))
	for i, n := range names {
		heads[i] = h001Head(n)
	}
	// Filter into a fresh slice: the input commonly IS the document's own
	// diagnostics list, so filtering in place would corrupt the caller's data.
	kept := make([]Diagnostic, 0, len(diags))
	for _, d := range diags {
		if d.Code == "H001" {
			drop := false
			for _, h := range heads {
				if strings.HasPrefix(d.Message, h) {
					drop = true
					break
				}
			}
			if drop {
				continue
			}
		}
		kept = append(kept, d)
	}
	return kept
}

// ReadFile is the file tier's read half on its own: the text of path with
// FileClean, or "" with the status that says why not - FileNotFound, or
// FileUnreadable for everything else (permissions, a directory, bad encoding,
// or a file past maxBytes; 0 is no cap). LoadFile is this plus a parse. A
// consumer that needs the exact bytes it last saw - to tell its own save coming
// back as a change notification from somebody else's edit - or a bound on how
// much it will read before a parse, calls this and parses the text itself.
func ReadFile(path string, maxBytes int) (string, FileStatus) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", FileNotFound
		}
		return "", FileUnreadable
	}
	defer f.Close()
	// One byte past the cap is read, so a file exactly at it passes and one
	// over is caught without trusting a length from Stat.
	var r io.Reader = f
	if maxBytes > 0 {
		// Saturating: a cap given as the type maximum must not wrap to a
		// negative limit and read nothing.
		limit := int64(maxBytes)
		if limit < math.MaxInt64 {
			limit++
		}
		r = io.LimitReader(f, limit)
	}
	data, err := io.ReadAll(r)
	if err != nil || (maxBytes > 0 && len(data) > maxBytes) {
		return "", FileUnreadable
	}
	// Reading succeeds on any bytes here, unlike the reference's read-to-string
	// and python's decoding open - so bad encoding needs its own test, or a
	// binary file loads Clean, reads back mangled, and a later save writes the
	// mangled version over the original.
	if !utf8.Valid(data) {
		return "", FileUnreadable
	}
	return string(data), FileClean
}

// WriteFileAtomic is the file tier's write mechanism (also what the CLI's
// `--write` uses): a temp file in the same dir, then a rename over the
// target, so an interrupted write can never truncate the config it rewrites.
// The data is synced before the rename so a crash cannot publish an empty file.
//
// A rename publishes a new inode, so the target is resolved through symlinks
// first (otherwise a linked-in config gets replaced by a regular file and the
// real one is left stale) and the original's mode is copied onto the temp file
// (otherwise a 600 config comes back at whatever the umask allows). Other hard
// links to the old inode cannot survive a rename and keep the old content.
// The i/o failures wrap rather than flatten, so a caller can tell a permission
// failure from a full disk with errors.Is instead of matching on prose.
func WriteFileAtomic(file, data string) error {
	if namesADirectory(file) {
		return fmt.Errorf("%s: is a directory", file)
	}
	target, terr := resolveTarget(file)
	if terr != nil {
		return fmt.Errorf("%s: %w", file, terr)
	}
	dir := filepath.Dir(target)
	base := filepath.Base(target)
	// At most the first 64 bytes of the name, cut where a character starts, so the
	// temp's own length is fixed. Keeping the whole name put the temp over the
	// filesystem's 255 bytes at a target name in the low 240s - and the exact
	// cut-off moved with the width of the process id, so the same file saved on one
	// machine and failed on another. Bytes, not characters: 64 characters of four
	// bytes each put it back over. A truncated name can collide; the exclusive
	// create and the eight attempts already answer that.
	if len(base) > tmpNameBytes {
		cut := tmpNameBytes
		for cut > 0 && !utf8.RuneStart(base[cut]) {
			cut--
		}
		base = base[:cut]
	}
	// Exclusive create: the name is predictable, so anything already sitting
	// there - including a symlink someone else planted - must make this fail
	// rather than be written through. Retry past a stale collision, then give
	// up; refusing to write beats writing somewhere unintended.
	// A file that already exists keeps its own mode, so its temp is born private
	// and the real mode goes on below - the copy is never briefly readable to
	// anyone the original was not. A file that does not exist yet has no mode to
	// preserve, so it takes the one an ordinary create would: 0666 narrowed by
	// the umask, like every other file the user's tools produce.
	existing, existErr := os.Stat(target)
	// Only a regular file is replaced. A rename over a FIFO or a device node
	// swaps it for a regular file at exit 0. Save outcomes in design.md is the
	// rule for what a save does with each thing it can find at the path.
	if existErr == nil && !existing.Mode().IsRegular() {
		if existing.IsDir() {
			return fmt.Errorf("%s: is a directory", file)
		}
		return fmt.Errorf("%s: not a regular file", file)
	}
	// os.Stat cannot see a reserved name with no device behind it; see
	// notADiskFile.
	if notADiskFile(target) {
		return fmt.Errorf("%s: not a regular file", file)
	}
	born := os.FileMode(0o600)
	if existErr != nil {
		born = 0o666
	}
	// Windows: a read-only file cannot be replaced, and a read-only temp cannot
	// be removed after a failure, so the attribute comes off the target for the
	// publish and goes back on the new file after it - the same outcome as
	// POSIX, where the rename never needed the file writable. Hidden and system
	// ride back the same way: ReplaceFile's documented preserve list does not
	// include the basic attributes, and the rename fallback keeps nothing, so
	// a hidden config came back visible.
	readOnly := runtime.GOOS == "windows" && existErr == nil && existing.Mode().Perm()&0o200 == 0
	var carried uint32
	if existErr == nil {
		carried = carriedAttrs(existing)
	}
	var f *os.File
	var tmp string
	var last error
	for attempt := 0; attempt < 8; attempt++ {
		tmp = filepath.Join(dir, "."+base+".tmp"+strconv.Itoa(os.Getpid())+"."+strconv.Itoa(attempt))
		from := ""
		if existErr == nil {
			from = target
		}
		h, oerr := createTemp(from, tmp, born)
		if oerr == nil {
			f = h
			break
		}
		last = oerr
	}
	if f == nil {
		return fmt.Errorf("%s: cannot create temporary file: %w", file, last)
	}
	var err error
	if _, werr := f.WriteString(data); werr != nil {
		err = werr
	} else {
		err = f.Sync()
	}
	// On the handle, so umask cannot narrow it the way it narrows a create
	// mode, and after the data, because a write by anyone but root clears
	// setuid/setgid. Best effort: a filesystem that cannot store the mode is
	// not a reason to fail a write that otherwise succeeded. The whole mode
	// goes, setuid/setgid/sticky included, as an editor's rewrite would keep
	// it.
	if err == nil && existErr == nil && runtime.GOOS != "windows" {
		// The group first, because a chown clears setuid/setgid on most
		// systems. Best effort like the mode: a caller who is not in the old
		// group keeps its own, which is what it had before this. The owner is
		// not copied - see the file tier in spec.md.
		if gid, ok := statGID(existing); ok {
			_ = f.Chown(-1, gid)
		}
		_ = f.Chmod(existing.Mode())
	}
	// The sync above is what forces the data out, so a close error here is the
	// unlikely tail of it - but a write error that only surfaces on close would
	// otherwise publish a truncated temp file over the target.
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp) // the write error is the one to report
		return fmt.Errorf("%s: %w", file, err)
	}
	if readOnly {
		setReadOnly(target, false)
	}
	// Nothing was at the path when the save started, so nothing that turns up
	// before the publish is written over. A failed replace decides for itself
	// whether the temp file can go, since on windows it may be all that is left.
	publish := publishFile
	if existErr != nil {
		publish = publishNewFile
	}
	rerr := publish(tmp, target)
	if carried != 0 {
		restoreAttrs(target, carried) // whether or not the publish went through
	}
	if readOnly {
		setReadOnly(target, true) // whether or not the publish went through
	}
	if rerr != nil {
		if existErr != nil {
			_ = os.Remove(tmp) // the publish error is the one to report
		}
		return fmt.Errorf("%s: %w", file, rerr)
	}
	syncDir(dir)
	return nil
}

// namesADirectory reports a path that names a directory rather than a file: it
// ends in a separator, or its last component is `.` or `..`. The OS refuses to
// open such a path as a regular file, but a path cleanup drops the trailing
// separator first, so a save through `f/.` used to rewrite `f`.
func namesADirectory(file string) bool {
	if file == "" {
		return false
	}
	sep := func(c byte) bool { return c == '/' || (runtime.GOOS == "windows" && c == '\\') }
	if sep(file[len(file)-1]) {
		return true
	}
	i := len(file)
	for i > 0 && !sep(file[i-1]) {
		i--
	}
	last := file[i:]
	return last == "." || last == ".."
}

// resolveTarget is the path a save actually rewrites. A symlink is followed so
// the write goes through it; EvalSymlinks does that but needs the target to
// exist, so a dangling link is walked by hand and the file is created where it
// points. A path that is no link at all is a plain create at the path as given.
// A link cycle is an error: silently creating a regular file in its place
// would be the exact replacement the symlink walk exists to avoid.
func resolveTarget(file string) (string, error) {
	if p, err := filepath.EvalSymlinks(file); err == nil {
		return p, nil
	}
	p := file
	for hop := 0; hop < 40; hop++ {
		next, err := os.Readlink(p)
		if err != nil {
			break
		}
		// A link whose text ends in a separator, `.` or `..` can only reach a
		// directory, and the kernel refuses to create a file through it.
		if namesADirectory(next) {
			return "", errors.New("is a directory")
		}
		if filepath.IsAbs(next) {
			p = next
		} else {
			p = rawDir(p) + string(filepath.Separator) + next
		}
	}
	if _, err := os.Readlink(p); err == nil {
		return "", errors.New("too many levels of symbolic links")
	}
	if dir, err := filepath.EvalSymlinks(rawDir(p)); err == nil {
		return filepath.Join(dir, filepath.Base(p)), nil
	}
	return p, nil
}

// rawDir is the directory half of p as written. filepath.Dir cleans it, and a
// clean cancels `lnk/..` as text where the kernel follows lnk first, so a link
// holding `..` reached through a linked directory was created somewhere else.
func rawDir(p string) string {
	vol := filepath.VolumeName(p)
	i := len(p)
	for i > len(vol) && !os.IsPathSeparator(p[i-1]) {
		i--
	}
	switch {
	case i == len(vol) && vol == "":
		return "."
	case i == len(vol):
		return vol
	case i == len(vol)+1:
		return p[:i] // the root keeps its separator
	}
	return p[:i-1]
}

// statGID reads the group off a stat result. syscall.Stat_t does not exist on
// windows, and this file has to compile there, so the field is read through
// reflect rather than splitting the file per platform.
func statGID(fi os.FileInfo) (int, bool) {
	v := reflect.ValueOf(fi.Sys())
	if v.Kind() == reflect.Ptr {
		if v.IsNil() {
			return 0, false
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return 0, false
	}
	g := v.FieldByName("Gid")
	if !g.IsValid() || !g.CanUint() {
		return 0, false
	}
	return int(g.Uint()), true
}

// setReadOnly toggles the windows read-only attribute, which is all Chmod
// controls there.
func setReadOnly(path string, on bool) {
	if m, err := os.Stat(path); err == nil {
		mode := m.Mode().Perm() | 0o200
		if on {
			mode &^= 0o222
		}
		// Best effort, like the mode on POSIX. The caller has nothing better to
		// do with a file whose attribute will not move.
		_ = os.Chmod(path, mode)
	}
}

// publishFile moves the finished temp file over the target. Rename is atomic
// within a filesystem, which is all POSIX needs. The windows build swaps this
// out for one that goes through ReplaceFile (shcl_windows.go): a rename there
// publishes a brand-new file and leaves the destination's ACLs, attributes and
// named streams behind.
//
// A hook rather than a build-tagged pair so that this file still compiles and
// works on its own - the drop-in story is the whole point of the single file,
// and a tree that took the module gets the better windows publish anyway.
//
// A failure removes the temp file, except where nothing is left at the target.
var publishFile = func(tmp, target string) error {
	err := os.Rename(tmp, target)
	if err != nil {
		_ = os.Remove(tmp) // the rename error is the one to report
	}
	return err
}

// publishNewFile is the publish for a save that found nothing at the path, which
// must not replace a file that turned up since. A hard link fails on anything at
// the target, so the check and the publish are one step, and the temp name comes
// off after. The save has gone through by then, so a temp name that will not
// come off is left rather than failing it. A filesystem with no hard links gets
// a check and a rename, which leaves only that short gap. The windows build
// moves without the replace flag instead.
var publishNewFile = func(tmp, target string) error {
	lerr := os.Link(tmp, target)
	if lerr == nil {
		_ = os.Remove(tmp)
		return nil
	}
	if errors.Is(lerr, os.ErrExist) {
		return os.ErrExist
	}
	if _, serr := os.Lstat(target); serr == nil {
		return os.ErrExist
	}
	return os.Rename(tmp, target)
}

// carriedAttrs is the attribute bits a publish will not keep by itself
// - hidden and system on windows, nothing anywhere else - and restoreAttrs
// turns them back on afterwards. Hooks for the same reason publishFile is.
var carriedAttrs = func(os.FileInfo) uint32 { return 0 }

var restoreAttrs = func(string, uint32) {}

// createTemp is the exclusive create of a save's temp file. The windows build
// swaps in one that gives the temp the DACL of the file at from
// (shcl_windows.go).
var createTemp = func(_, tmp string, perm os.FileMode) (*os.File, error) {
	return os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, perm)
}

// notADiskFile says whether something is at the path and is not a disk file: a
// windows device name. POSIX has no such thing at a path, so the default answers
// false and the windows build swaps this out. os.Stat already reports a device
// it can open, which covers CON and NUL, but a reserved name with no device
// behind it - COM1 on a box with no serial port - is not there to stat, and a
// save must still refuse it rather than leave the answer to the publish.
var notADiskFile = func(string) bool { return false }

// syncDir fsyncs the directory a save published into. The Sync on the file only
// covered the file; the rename is a directory change, so without this a power
// cut right after a save can lose the publish and leave the old content. Best
// effort - windows has no directory fsync, and a filesystem that refuses one is
// not a reason to fail a write that already succeeded.
func syncDir(dir string) {
	if d, derr := os.Open(dir); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
}

// FileStatus is what LoadFile found: the four cases a consumer's own load
// path otherwise confuses. FileClean and FileHadErrors both have a usable
// document; FileNotFound and FileUnreadable come back with an empty one.
type FileStatus int

const (
	FileClean     FileStatus = iota // read and parsed, no error diagnostics (hints allowed)
	FileHadErrors                   // read and parsed, but error diagnostics are present
	FileNotFound                    // no file at the path
	// exists but could not be read (permissions, a directory, bad encoding,
	// past a ReadFile cap)
	FileUnreadable
)

// String names the file status, so logging one reads as a case rather than a
// number.
func (s FileStatus) String() string {
	switch s {
	case FileClean:
		return "Clean"
	case FileHadErrors:
		return "HadErrors"
	case FileNotFound:
		return "NotFound"
	case FileUnreadable:
		return "Unreadable"
	}
	return "Clean"
}

// LoadFile is the file tier's load half: read and parse path at Standard.
// Never fails - the document always comes back usable (empty when the file
// could not be read), and the status separates the four cases consumers
// otherwise confuse: absent, present-but-unreadable, parsed with errors,
// clean.
func LoadFile(path string) (*Document, FileStatus) {
	return LoadFileWith(path, Standard)
}

// LoadFileWith is LoadFile at a chosen strictness. A strict-failing file
// reports FileHadErrors; the recover-and-continue document still comes back.
func LoadFileWith(path string, level Strictness) (*Document, FileStatus) {
	text, st := ReadFile(path, 0)
	if st != FileClean {
		return newParser().parse("", level), st
	}
	doc := newParser().parse(text, level)
	for _, d := range doc.diags {
		if d.Severity == SeverityError {
			return doc, FileHadErrors
		}
	}
	return doc, FileClean
}

// SaveRefused is the error SaveFile returns when the lost-content gate fires.
// It is its own type so a caller can tell a refusal from a write failure with
// errors.As rather than by matching on the message: a refusal is the caller's
// to reverse (SaveFileLossy is the override), a write failure is the disk's
// answer.
type SaveRefused struct {
	Path string
	Lost int // lines/values the save would delete (see LostCount)
}

// Error states the refusal with the path and the count, so a log line says
// which file and how much a lossy save would drop.
func (e *SaveRefused) Error() string {
	return fmt.Sprintf("%s: refusing to save: this write would delete %d line(s)/value(s) "+
		"from the file (see diagnostics; SaveFileLossy overrides)", e.Path, e.Lost)
}

// SaveFile is the file tier's save half: write this document's canonical text
// to path through WriteFileAtomic, so an interrupted save can never truncate
// the config it rewrites - the same mechanics the CLI's `--write` uses.
// Refuses when the write would delete content from the file (see
// LostCount); SaveFileLossy writes anyway. A refusal comes back as
// *SaveRefused, a write failure as the wrapped i/o error.
func (d *Document) SaveFile(path string) error {
	if lost := d.LostCount(); lost > 0 {
		return &SaveRefused{Path: path, Lost: lost}
	}
	return WriteFileAtomic(path, d.ToCanonical())
}

// SaveFileLossy is SaveFile without the lost-content gate: writes even when
// the write deletes content from the file. The caller owns that choice. It
// never returns *SaveRefused - the gate is the one thing it skips.
func (d *Document) SaveFileLossy(path string) error {
	return WriteFileAtomic(path, d.ToCanonical())
}

// disavowedNames returns the leaf names of the schema entries pick accepts,
// top-level fields and every fragment's fields alike. Read through the built
// schema, so the names are the ones validation will use (escapes resolved)
// and an entry whose key faulted disavows nothing.
func disavowedNames(schema *Document, pick func(*constraint) bool) []string {
	def, _ := buildSchema(schema)
	var names []string
	all := [][]constraint{def.cons}
	for _, fcs := range def.frags {
		all = append(all, fcs)
	}
	for _, list := range all {
		for i := range list {
			c := &list[i]
			if !pick(c) || len(c.segs) == 0 {
				continue
			}
			// Name wildcard: no single leaf name to disavow.
			if seg := c.segs[len(c.segs)-1]; !seg.star {
				names = append(names, seg.name)
			}
		}
	}
	return names
}

// h002Head is the single H002 wording site: the merge hint and the schema
// suppressor both come here, same discipline as h001Head.
func h002Head(name string) string {
	return fmt.Sprintf("merged with '%s' at ", diagName(name))
}

// SuppressDeclaredReopens drops the H002 hints a schema disavows: a section
// whose entry declares `reopen: true` is MEANT to be written in parts, so the
// merge hint is structurally a false positive there. Matching is by leaf
// name, same as the H001 suppressor, and it errs toward quiet, for a hint.
// Used by `check --schema` and LoadAndValidate; call it wherever doc
// diagnostics and a schema meet. Returns a fresh slice like the H001 one.
func SuppressDeclaredReopens(schema *Document, diags []Diagnostic) []Diagnostic {
	names := disavowedNames(schema, func(c *constraint) bool { return c.reopen })
	if len(names) == 0 {
		return append([]Diagnostic(nil), diags...)
	}
	heads := make([]string, len(names))
	for i, n := range names {
		heads[i] = h002Head(n)
	}
	kept := make([]Diagnostic, 0, len(diags))
	for _, d := range diags {
		if d.Code == "H002" {
			drop := false
			for _, h := range heads {
				if strings.HasPrefix(d.Message, h) {
					drop = true
					break
				}
			}
			if drop {
				continue
			}
		}
		kept = append(kept, d)
	}
	return kept
}

// needsQuotes reports minimal quoting: bare unless a reserved character (or
// lookalike hazard) forces it.
func needsQuotes(t string) bool {
	needs := t == ""
	if !needs {
		for i, c := range t {
			switch c {
			case ' ', '\t', '\n', ',', ':', '#', '"', '\'', '[', ']':
				needs = true
			default:
				_, _, needs = invisibleAt(t, i)
			}
			if needs {
				break
			}
		}
	}
	// Edge whitespace still has to force quotes, for the carriage return: it is
	// a blank, so a piece ending in one loses it to the reload. Space and tab
	// are already in the list above. The test is the whole Unicode whitespace
	// set rather than those three, which only ever adds quoting - the parser
	// itself trims no wider than is_wsp, so a leading no-break space is
	// content. Edges only: interior whitespace is never trimmed and quoting it
	// would move bytes.
	if !needs && t != "" {
		r, _ := utf8.DecodeRuneInString(t)
		l, _ := utf8.DecodeLastRuneInString(t)
		if unicode.IsSpace(r) || unicode.IsSpace(l) {
			needs = true
		}
	}
	if !needs {
		if _, _, _, ok := fenceOpen(t); ok {
			needs = true
		}
	}
	return needs
}

// emitElement adds one thing to minimal quoting: an author-quoted element keeps
// its quotes unless the text reads as one of SHCL's own data formats - quoting
// those is just spelling (readers type the value either way), but quoting a
// plain string is the escape and must survive canonicalization. This clause
// only ever adds quoting, so a bare emit stays safe.
func emitElement(e *element) string {
	t := e.text
	if needsQuotes(t) || (e.quoted && !isDataFormat(e)) {
		return quoteText(t)
	}
	return t
}

// newElement builds an element no source wrote. It counts as quoted when
// canonical output will quote it, so a read gives the same answer before a
// save as after one.
func newElement(text string) element {
	return element{text: text, quoted: needsQuotes(text)}
}

// isDataFormat reports whether the text reads as an int, float, bool, or
// datetime at standard strictness - fixed there deliberately, so canonical
// form cannot vary with the load strictness. A number with a leading zero does
// not count: quotes are how a file says the zeros matter, as in a zip code.
func isDataFormat(e *element) bool {
	// One pass over the bytes before any coercion. At Standard the int, float
	// and datetime forms all require at least one ASCII digit; the only formats
	// that do not are the boolean words, and the longest of those is "false".
	// An ordinary quoted string fails both tests, so emit stops running four
	// full coercions on every quoted element it writes.
	hasDigit := false
	for i := 0; i < len(e.text); i++ {
		if e.text[i] >= '0' && e.text[i] <= '9' {
			hasDigit = true
			break
		}
	}
	if !hasDigit {
		t := strings.TrimSpace(e.text)
		if len(t) > 5 {
			return false
		}
		_, ok := parseBoolText(t, Standard)
		return ok
	}
	if !leadingZero(strings.TrimSpace(e.text)) {
		if _, ok := parseIntText(e, Standard); ok {
			return true
		}
		if _, ok := parseFloatText(e, Standard); ok {
			return true
		}
	}
	if _, ok := parseBoolText(e.text, Standard); ok {
		return true
	}
	if _, ok := ParseDateTime(e.text); ok {
		return true
	}
	return false
}

// leadingZero reports a zero followed by another digit, after any sign: `007`,
// `-012`, `00.5`.
func leadingZero(t string) bool {
	if t != "" && (t[0] == '+' || t[0] == '-') {
		t = t[1:]
	}
	return len(t) > 1 && t[0] == '0' && t[1] >= '0' && t[1] <= '9'
}

// quoteText quotes a logical string so the tokenizer reads it back as the
// same string. Single quotes are literal, so they are the spelling for text
// holding a double quote or a backslash; double quotes have the escapes, so
// they are the spelling for a line break, a tab, an invisible character, or
// text holding both quote kinds.
func quoteText(t string) string {
	return quoteTextAs(t, RulesCurrent)
}

// quoteTextAs is quoteText for a reader of rules, as in quoteDoubleAs.
func quoteTextAs(t string, rules Rules) string {
	control := strings.ContainsAny(t, "\n\t") || (rules == RulesCurrent && hasInvisible(t))
	if !control && !strings.Contains(t, "'") && strings.ContainsAny(t, "\"\\") {
		return "'" + t + "'"
	}
	return quoteDoubleAs(t, rules)
}

// quoteDoubleAs is the double-quoted spelling for a reader of rules. The two
// read it alike, except a \u escape, which 2.x kept as written, so for 2.x an
// invisible character goes in as it is.
func quoteDoubleAs(t string, rules Rules) string {
	out := quoteDoubleWith(t, rules, false)
	// Written `\t` or `\n`, a path is E024 on the reload, and a `\u` escape
	// reads the same. 2.x kept one as written, so for 2.x a tab goes in as it
	// is, and a line break has no spelling: migrate counts that one lost.
	if spellsPathEscape(out) {
		return quoteDoubleWith(t, rules, true)
	}
	return out
}

// spellsPathEscape reports a double-quoted spelling that would be E024.
func spellsPathEscape(quoted string) bool {
	return pathLike(&Piece{Start: 1, End: len(quoted) - 1, Quote: QuoteDouble}, quoted)
}

func quoteDoubleWith(t string, rules Rules, path bool) string {
	// Bytes: every escape written here is ASCII, and a continuation byte is
	// none of them, so the rest of the text copies through untouched. A
	// character invisible names is decoded first.
	var out strings.Builder
	out.Grow(len(t) + 2)
	out.WriteByte('"')
	for i := 0; i < len(t); i++ {
		switch t[i] {
		case '\\':
			out.WriteString("\\\\")
		case '"':
			out.WriteString("\\\"")
		case '\n', '\t':
			switch {
			case path && rules == RulesCurrent:
				writeUnicodeEscape(&out, rune(t[i]))
			case path && t[i] == '\t':
				out.WriteByte(t[i])
			case t[i] == '\n':
				out.WriteString("\\n")
			default:
				out.WriteString("\\t")
			}
		default:
			if r, n, ok := invisibleAt(t, i); ok && rules == RulesCurrent {
				writeUnicodeEscape(&out, r)
				i += n - 1
			} else {
				out.WriteByte(t[i])
			}
		}
	}
	out.WriteByte('"')
	return out.String()
}

// ---------------------------------------------------------------------------
// The write side's one rule: what is written has to read back
// ---------------------------------------------------------------------------
//
// A setter builds its text through the emitter and reads it back with the
// tokenizer before the document is touched. If the read does not give the
// value it was handed, the write is refused and nothing changes. No setter
// decides for itself what a quote, a `#`, a comma or a carriage return means:
// twelve review items were one setter's private rule disagreeing with the
// parser's. The typed setters keep their own render-and-parse-back on top,
// since a float or a datetime has to read back as that type and not merely as
// the same text.

// emitCell is the value half of a binding line, the way emitLine writes it.
func emitCell(els []element) string {
	var out strings.Builder
	for i := range els {
		if i > 0 {
			out.WriteString(", ")
		}
		out.WriteString(emitElement(&els[i]))
	}
	return out.String()
}

// emitFenceLine is the opening fence line of a raw block: the fence run, then
// the info string behind a space when it would otherwise extend the run.
func emitFenceLine(r *rawValue) string {
	var out strings.Builder
	out.WriteString(strings.Repeat(string(rune(r.fenceChar)), r.fenceLen))
	if r.info != "" {
		if r.info[0] == r.fenceChar {
			out.WriteByte(' ')
		}
		out.WriteString(r.info)
	}
	return out.String()
}

// nextElement is the next piece of a tokenized value the load would keep,
// from *i: an empty bare slot is dropped, so it is skipped here too.
func nextElement(els []Piece, i *int) *Piece {
	for *i < len(els) {
		p := &els[*i]
		*i++
		if p.Quote != QuoteNone || p.End > p.Start {
			return p
		}
	}
	return nil
}

// valueHalf scans text as a line's value half, behind the colon a field line
// puts there. It returns the line the token spans index into.
func valueHalf(text string, out *Tokens) string {
	line := ":" + text
	TokenizeValue(line, 1, RulesCurrent, out)
	return line
}

// valueReadsBack is true when a value comes back off the page as itself. A Go
// string can hold any bytes and a document is UTF-8, so text that is not valid
// UTF-8 is refused here, the one gate every setter passes through: saved, it
// would fail the next load of the whole file.
func valueReadsBack(v *value) bool {
	switch v.kind {
	case vEmpty:
		return true
	case vCell:
		text := emitCell(v.els)
		if strings.Contains(text, "\n") || !utf8.ValidString(text) {
			return false
		}
		var tok Tokens
		line := valueHalf(text, &tok)
		if tok.Comment >= 0 {
			return false
		}
		// Compared against the pieces rather than against a rebuilt value: a
		// bulk write runs this per set, and the text is right there.
		at := 0
		for i := range v.els {
			p := nextElement(tok.Elements, &at)
			if p == nil || !pieceIs(p, line, v.els[i].text) {
				return false
			}
		}
		return nextElement(tok.Elements, &at) == nil
	default:
		r := v.raw
		line := emitFenceLine(r)
		if strings.Contains(line, "\n") || !utf8.ValidString(line) || !utf8.ValidString(r.content) {
			return false
		}
		var tok Tokens
		TokenizeValue(line, 0, RulesCurrent, &tok)
		ch, length, info, ok := fenceOpen(line[tok.Value[0]:tok.Value[1]])
		if !ok || ch != r.fenceChar || length != r.fenceLen || info != r.info {
			return false
		}
		// A body line ending in a carriage return loses it to the load's
		// line-end trim, and one spelling the closing fence would end the
		// block early.
		for _, l := range strings.Split(r.content, "\n") {
			if strings.HasSuffix(l, "\r") || isFenceClose(l, r.fenceChar, r.fenceLen) {
				return false
			}
		}
		return true
	}
}

// nameReadsBack is true when a field name comes back off a line as itself.
func nameReadsBack(name string) bool {
	text := escapeName(name)
	if strings.Contains(text, "\n") || !utf8.ValidString(text) {
		return false
	}
	var tok Tokens
	Tokenize(text, ':', false, RulesCurrent, &tok)
	return tok.Fault < 0 && len(tok.Segments) == 1 && tok.Segments[0].Selector == nil &&
		pieceIs(&tok.Segments[0].Name, text, name)
}

// commentLine is the comment line this text is written as, or ok=false when it
// has no spelling. A `#` is added when the text has none. The load trims
// every line's end, so the trimmed text is what gets written; text holding a
// line break is refused rather than cut down to its first line.
func commentLine(text string) (string, bool) {
	if strings.Contains(text, "\n") || !utf8.ValidString(text) {
		return "", false
	}
	t := trimEndWS(text)
	var line string
	switch {
	case strings.HasPrefix(t, "#"):
		line = t
	case t == "":
		line = "#"
	default:
		line = "# " + t
	}
	var tok Tokens
	TokenizeValue(line, 0, RulesCurrent, &tok)
	if tok.Comment != 0 || trimEndWS(line) != line {
		return "", false
	}
	return line, true
}

// ---------------------------------------------------------------------------
// Accessor: path resolution
// ---------------------------------------------------------------------------

type resolvedKind int

const (
	resNone resolvedKind = iota
	resOne
	resMany
	// resSlots (wildcard): one slot per instance, in file order; negative =
	// the sub-path did not reach one node (-1 missing, -2 ambiguous).
	resSlots
)

type resolved struct {
	kind  resolvedKind
	one   int
	many  []int
	slots []int
}

func (d *Document) nameIndex() *nameIndex {
	if idx := d.index.Load(); idx != nil {
		return idx
	}
	d.indexMu.Lock()
	defer d.indexMu.Unlock()
	if idx := d.index.Load(); idx != nil {
		return idx
	}
	idx := &nameIndex{
		first:    map[uint64]int{},
		last:     map[uint64]int{},
		nextSame: make([]int, len(d.arena)),
	}
	for i := range idx.nextSame {
		idx.nextSame[i] = nilNode
	}
	// From the root, not across the arena: a removed subtree's nodes are still
	// there with their child lists intact, so an arena walk indexes every node
	// the document ever held. Chains stay in file order - a chain is one
	// parent's same-named children, and each parent's are appended in order.
	stack := []int{root}
	for len(stack) > 0 {
		p := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		for _, c := range d.arena[p].children {
			idx.append(nameKey(p, d.arena[c].name), c)
			stack = append(stack, c)
		}
	}
	d.index.Store(idx)
	return idx
}

func (d *Document) childrenNamed(parent int, name string) []int {
	idx := d.nameIndex()
	var out []int
	c, hit := idx.first[nameKey(parent, name)]
	if !hit {
		c = nilNode
	}
	for c != nilNode {
		if d.arena[c].name == name && d.arena[c].parent == parent {
			out = append(out, c)
		}
		c = idx.nextSame[c]
	}
	return out
}

// group: a sub-path reaching several nodes joins the slot list instead of
// becoming one ambiguous slot. Reads want the slot per instance, so they leave
// it off; Remove and Exists want every node behind the wildcard.
func (d *Document) resolveFrom(start []int, segs []segment, group bool) resolved {
	cur := append([]int(nil), start...)
	for i := range segs {
		seg := &segs[i]
		var next []int
		for _, n := range cur {
			if seg.star {
				next = append(next, d.arena[n].children...)
			} else {
				next = append(next, d.childrenNamed(n, seg.name)...)
			}
		}
		if seg.star {
			// Name wildcard: same per-slot split as `[*]`, over every child.
			rest := segs[i+1:]
			slots := make([]int, 0, len(next))
			for _, inst := range next {
				if len(rest) == 0 {
					slots = append(slots, inst)
					continue
				}
				r := d.resolveFrom([]int{inst}, rest, group)
				switch {
				case r.kind == resOne:
					slots = append(slots, r.one)
				case r.kind == resNone:
					slots = append(slots, -1)
				case r.kind == resSlots:
					// A wildcard after a wildcard: the inner slots join the
					// outer list, so the two compose into one flat run of
					// leaves rather than one unreadable slot.
					slots = append(slots, r.slots...)
				case r.kind == resMany && group:
					slots = append(slots, r.many...)
				default:
					slots = append(slots, -2)
				}
			}
			return resolved{kind: resSlots, slots: slots}
		}
		switch {
		case seg.sel == nil:
			cur = next
		case seg.sel.kind == selByValue:
			want := seg.sel.value
			var filtered []int
			for _, c := range next {
				if dispKey(&d.arena[c].value) == want && (!seg.sel.quoted || singleScalar(&d.arena[c].value)) {
					filtered = append(filtered, c)
				}
			}
			cur = filtered
		case seg.sel.kind == selByIndex:
			if seg.sel.index < uint64(len(next)) {
				cur = []int{next[seg.sel.index]}
			} else {
				cur = nil
			}
		default:
			// Wildcard: remaining path resolves per-instance; slots stay aligned.
			rest := segs[i+1:]
			slots := make([]int, 0, len(next))
			for _, inst := range next {
				if len(rest) == 0 {
					slots = append(slots, inst)
					continue
				}
				r := d.resolveFrom([]int{inst}, rest, group)
				switch {
				case r.kind == resOne:
					slots = append(slots, r.one)
				case r.kind == resNone:
					slots = append(slots, -1)
				case r.kind == resSlots:
					// A wildcard after a wildcard: the inner slots join the
					// outer list, so the two compose into one flat run of
					// leaves rather than one unreadable slot.
					slots = append(slots, r.slots...)
				case r.kind == resMany && group:
					slots = append(slots, r.many...)
				default:
					slots = append(slots, -2)
				}
			}
			return resolved{kind: resSlots, slots: slots}
		}
	}
	switch len(cur) {
	case 0:
		return resolved{kind: resNone}
	case 1:
		return resolved{kind: resOne, one: cur[0]}
	}
	return resolved{kind: resMany, many: cur}
}

func (d *Document) resolve(path string) (resolved, bool) {
	return d.resolveMode(path, false)
}

// resolveGroup is resolve with every node behind a wildcard slot in the list,
// for the callers that act on the whole match rather than read one value per
// instance.
func (d *Document) resolveGroup(path string) (resolved, bool) {
	return d.resolveMode(path, true)
}

func (d *Document) resolveMode(path string, group bool) (resolved, bool) {
	scan, err := scanLookup(path)
	if err != nil || scan.hasValue {
		return resolved{}, false // a query has no value part
	}
	return d.resolveFrom([]int{root}, scan.segments, group), true
}

// Count returns the instance count at a path (0 when nothing matches).
func (d *Document) Count(path string) int {
	r, ok := d.resolve(path)
	if !ok {
		return 0
	}
	switch r.kind {
	case resOne:
		return 1
	case resMany:
		return len(r.many)
	case resSlots:
		return len(r.slots)
	}
	return 0
}

// Paths returns every field path in the document, in file order, deduplicated -
// a query recipe for tooling. A segment that is not bare-name-safe is emitted
// quoted and escaped - the form the path scanner accepts - so each path is a
// well-formed lookup path and nothing in the document is hidden.
func (d *Document) Paths() []string {
	var out []string
	seen := map[string]bool{}
	type ent struct {
		node   int
		prefix string
	}
	var stack []ent
	top := d.arena[root].children
	for i := len(top) - 1; i >= 0; i-- {
		stack = append(stack, ent{top[i], ""})
	}
	for len(stack) > 0 {
		e := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		seg := emitName(d.arena[e.node].name)
		path := seg
		if e.prefix != "" {
			path = e.prefix + "." + seg
		}
		if !seen[path] {
			seen[path] = true
			out = append(out, path)
		}
		kids := d.arena[e.node].children
		for i := len(kids) - 1; i >= 0; i-- {
			stack = append(stack, ent{kids[i], path})
		}
	}
	return out
}

// Line returns the 1-based source line of the binding at a path, for consumer
// checks the schema cannot express. 0 when the path does not resolve to
// exactly one node, or the node was writer-built. Merged instances cite the
// first binding's line, matching diagnostics.
func (d *Document) Line(path string) int {
	r, ok := d.resolve(path)
	if !ok || r.kind != resOne {
		return 0
	}
	return d.arena[r.one].line
}

// AuthoredName is the field name at a path exactly as the author wrote it
// (case unfolded, outer quotes stripped), so a message can echo `SYMBOLS` when
// the file said SYMBOLS. Escape sequences stay as written too: a name is
// stored, compared and emitted with its escapes RESOLVED, so this is the one
// call that hands the source spelling back - which is what an as-authored
// accessor is for. Resolution mirrors Line(): empty when the path does not resolve to
// exactly one node. Merged instances keep the first binding's spelling; a
// writer-built node keeps the spelling the setter's path used.
func (d *Document) AuthoredName(path string) string {
	r, ok := d.resolve(path)
	if !ok || r.kind != resOne {
		return ""
	}
	return d.arena[r.one].authored()
}

// Lines is the plural Line(): 1-based source lines at a path, in file order,
// so a repeated field - the case that most wants a citable line - yields
// every binding's. Wildcard slots that did not resolve stay in the list as 0,
// and a writer-built node is 0, so indices keep matching Count().
func (d *Document) Lines(path string) []int {
	r, ok := d.resolve(path)
	if !ok {
		return nil
	}
	switch r.kind {
	case resOne:
		return []int{d.arena[r.one].line}
	case resMany:
		out := make([]int, 0, len(r.many))
		for _, n := range r.many {
			out = append(out, d.arena[n].line)
		}
		return out
	case resSlots:
		out := make([]int, 0, len(r.slots))
		for _, s := range r.slots {
			if s >= 0 {
				out = append(out, d.arena[s].line)
			} else {
				out = append(out, 0)
			}
		}
		return out
	}
	return nil
}

// Children returns the child field names under a path, in file order,
// duplicates included - the "what keys are in this section?" question Paths()
// (deduplicated, path-shaped) cannot answer. "" enumerates the top level. A
// path with several instances lists the children of each in turn, the way a
// dotted path reaches all of them. Names come back as stored; QuoteSegment()
// makes one splice-safe in a path.
func (d *Document) Children(path string) []string {
	nodes := []int{root}
	if strings.TrimSpace(path) != "" {
		r, ok := d.resolve(path)
		if !ok {
			return nil
		}
		switch r.kind {
		case resOne:
			nodes = []int{r.one}
		case resMany:
			nodes = r.many
		case resSlots:
			nodes = nodes[:0]
			for _, n := range r.slots {
				if n >= 0 {
					nodes = append(nodes, n)
				}
			}
		default:
			return nil
		}
	}
	var out []string
	for _, n := range nodes {
		for _, c := range d.arena[n].children {
			out = append(out, d.arena[c].name)
		}
	}
	if out == nil {
		out = []string{}
	}
	return out
}

// InstancePaths is Paths() one instance at a time: every binding's path in
// file order, with `[#i]` on each segment whose name repeats under its
// parent, so each path reads exactly one node and a repeated block is walked
// instance by instance. Segments are written as Paths() writes them.
func (d *Document) InstancePaths() []string {
	var out []string
	type ent struct {
		node   int
		prefix string
	}
	stack := []ent{{root, ""}}
	for len(stack) > 0 {
		e := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if e.node != root {
			out = append(out, e.prefix)
		}
		kids := d.arena[e.node].children
		total := map[string]int{}
		for _, c := range kids {
			total[d.arena[c].name]++
		}
		at := map[string]int{}
		paths := make([]ent, 0, len(kids))
		for _, c := range kids {
			name := d.arena[c].name
			path := emitName(name)
			if e.prefix != "" {
				path = e.prefix + "." + path
			}
			if total[name] > 1 {
				path += "[#" + strconv.Itoa(at[name]) + "]"
				at[name]++
			}
			paths = append(paths, ent{c, path})
		}
		for i := len(paths) - 1; i >= 0; i-- {
			stack = append(stack, paths[i])
		}
	}
	return out
}

// Instances returns the instance values at a path, in file order. Wildcard
// slots that did not resolve stay in the list as "" so indices keep matching
// Count().
func (d *Document) Instances(path string) []string {
	r, ok := d.resolve(path)
	if !ok {
		return nil
	}
	switch r.kind {
	case resOne:
		return []string{d.arena[r.one].value.display()}
	case resMany:
		out := make([]string, 0, len(r.many))
		for _, n := range r.many {
			out = append(out, d.arena[n].value.display())
		}
		return out
	case resSlots:
		out := make([]string, 0, len(r.slots))
		for _, s := range r.slots {
			if s >= 0 {
				out = append(out, d.arena[s].value.display())
			} else {
				out = append(out, "")
			}
		}
		return out
	}
	return nil
}

// ---------------------------------------------------------------------------
// Writer: typed emit, defaults, comments, structural edits
// ---------------------------------------------------------------------------
// The reverse of the Accessor. A setter builds the canonical stored text for a
// typed value (the inverse of the matching read) and places it at a path,
// creating intermediate nodes on the way. Reads and ToCanonical walk children
// slices, so mutating the arena directly is enough - the parser's child map is
// already gone and is not maintained here.

func boolText(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

// literalValue reads text as the value half of a line, for the setters that
// take value syntax rather than data: whatever a file line means with this
// text is what gets stored, so a trailing blank comes off and a # outside
// quotes ends the value exactly as they would in a file. What is refused is
// what a file reports as an error, since a setter has no diagnostic to report
// it with: a line break, which no file line can hold, an unterminated quote
// (E017), bracket text (E019, the line kept verbatim - writing it as a
// two-element array holding `[1` and `2]` would be a different wrong answer),
// an unknown escape in double quotes (E023), and a Windows path in double
// quotes holding a `\t` or `\n` escape (E024).
func literalValue(text string) (value, bool) {
	if strings.Contains(text, "\n") {
		return value{}, false
	}
	var tok Tokens
	line := valueHalf(text, &tok)
	for i := range tok.Elements {
		if tok.Elements[i].Quote == QuoteOpen {
			return value{}, false
		}
	}
	if strings.HasPrefix(line[tok.Value[0]:], "[") {
		return value{}, false
	}
	if _, bad := badEscape(&tok, line, true); bad {
		return value{}, false
	}
	if anyPathLike(&tok, line) {
		return value{}, false
	}
	return cellOfTokens(&tok, line), true
}

func cellOf(text string) value {
	return value{kind: vCell, els: []element{newElement(text)}}
}

// chooseFence picks a backtick fence long enough that no content line closes it.
func chooseFence(content string) (byte, int) {
	maxrun := 0
	for _, line := range strings.Split(content, "\n") {
		t := strings.Trim(line, " \t")
		if t != "" && strings.Trim(t, "`") == "" && len(t) > maxrun {
			maxrun = len(t)
		}
	}
	if maxrun+1 < 3 {
		return '`', 3
	}
	return '`', maxrun + 1
}

// arrayCell builds an inline-array value; the empty array is an empty value.
func arrayCell(texts []string) value {
	if len(texts) == 0 {
		return value{kind: vEmpty}
	}
	els := make([]element, len(texts))
	for i, t := range texts {
		els[i] = newElement(t)
	}
	return value{kind: vCell, els: els}
}

// New returns a fresh document with no bindings - the start point for
// schema-driven generation. Set values, then ToCanonical().
func New() *Document {
	return Parse("")
}

func (d *Document) newChild(parent int, name, nameSrc string, v value) int {
	// A list written stacked would get the child after its elements, which
	// reloads as E001, so it goes inline.
	if stacks(&d.arena[parent]) {
		unstack(&d.arena[parent])
	}
	idx := len(d.arena)
	// Hand-written files separate top-level sections with a blank line;
	// writer-built ones do the same (the emitter never blanks line 1).
	d.arena = append(d.arena, nodeData{
		name: name, nameSrc: spelled(name, nameSrc), value: v, parent: parent,
		blankBefore: parent == root,
	})
	d.arena[parent].children = append(d.arena[parent].children, idx)
	if ix := d.index.Load(); ix != nil {
		ix.append(nameKey(parent, name), idx)
	}
	// Kept lines that end the block stay where they were, so the new field
	// goes after the last of them, as a reload files them. The comments
	// after it stay at the end, and so does a kept line the settle wrote as
	// a comment, since a reload reads it as one.
	var tail *[]lead
	if parent == root {
		tail = &d.orphans
	} else if t := d.arena[parent].trivia; t != nil {
		tail = &t.inside
	}
	if tail != nil {
		k := len(*tail) - 1
		for k >= 0 && strings.HasPrefix((*tail)[k].text, "#") {
			k--
		}
		if k >= 0 {
			lines := append([]lead(nil), (*tail)[:k+1]...)
			*tail = append([]lead(nil), (*tail)[k+1:]...)
			restep(*tail)
			d.arena[idx].trivMut().leading = lines
		}
	}
	settleBlock(d.arena, parent, len(d.arena[parent].children)-1)
	return idx
}

// WriteReason reports why a write at this path would fail - the reason behind
// a setter's bare false, so a consumer's error message need not guess.
// Writable means the same validation place() runs would pass; nothing is
// created.
func (d *Document) WriteReason(path string) WriteReason {
	scan, err := scanLookup(path)
	if err != nil {
		return BadPath
	}
	r, _ := d.probeWrite(scan)
	return r
}

// probeWrite is the validation walk WriteReason and place share. The returned
// trail records where each segment ended up - -1 from the point the path falls
// off the existing tree - so place can create from exactly there instead of
// scanning the path and walking the tree a second time.
func (d *Document) probeWrite(scan pathScan) (WriteReason, []int) {
	if scan.hasValue {
		return ValueInPath, nil
	}
	if len(scan.segments) == 0 {
		return BadPath, nil
	}
	// Writer side of the load-time nesting cap: never create deeper.
	if len(scan.segments) > MaxDepth {
		return TooDeep, nil
	}
	// The probe walk place() validates with: once it falls off the existing
	// tree, a later `[#k]` can never match (fresh intermediates are created
	// childless), so an index segment past that point is unresolvable.
	trail := make([]int, 0, len(scan.segments))
	probe, alive := root, true
	for i := range scan.segments {
		seg := &scan.segments[i]
		if seg.star {
			return Wildcard, nil
		}
		switch {
		case seg.sel == nil:
			if alive {
				alive = false
				if m := d.childrenNamed(probe, seg.name); len(m) > 0 {
					probe, alive = m[0], true
				}
			}
		case seg.sel.kind == selByValue:
			if alive {
				want := seg.sel.value
				alive = false
				for _, c := range d.childrenNamed(probe, seg.name) {
					if dispKey(&d.arena[c].value) == want && (!seg.sel.quoted || singleScalar(&d.arena[c].value)) {
						probe, alive = c, true
						break
					}
				}
			}
		case seg.sel.kind == selByIndex:
			if !alive {
				return NoSuchIndex, nil
			}
			matches := d.childrenNamed(probe, seg.name)
			if seg.sel.index >= uint64(len(matches)) {
				return NoSuchIndex, nil
			}
			probe = matches[seg.sel.index]
		default:
			return Wildcard, nil
		}
		if alive {
			trail = append(trail, probe)
		} else {
			trail = append(trail, -1)
		}
	}
	return Writable, trail
}

// place walks (creating as needed) to the node a write targets. A trailing name
// with no selector hits the first same-named instance (or a new one); a [value]
// selector selects the matching instance or creates it; [#k] must already
// exist. ok=false means the path is unusable for a write (WriteReason says
// why). Validation runs first, so a doomed path leaves no half-created
// intermediates behind.
func (d *Document) place(path string) (int, bool) {
	scan, err := scanLookup(path)
	if err != nil {
		return 0, false
	}
	reason, trail := d.probeWrite(scan)
	if reason != Writable {
		return 0, false
	}
	// Nothing is created until every segment the write would create is known
	// to read back: the name through the name escaper, an instance selector
	// as the value it binds.
	for i := range scan.segments {
		if trail[i] >= 0 {
			continue
		}
		seg := &scan.segments[i]
		if !nameReadsBack(seg.name) {
			return 0, false
		}
		if seg.sel != nil && seg.sel.kind == selByValue {
			v := cellOf(seg.sel.value)
			if !valueReadsBack(&v) {
				return 0, false
			}
		}
	}
	cur := root
	for i := range scan.segments {
		seg := &scan.segments[i]
		// The probe already resolved every segment that exists; only the tail
		// it fell off has anything to create.
		if trail[i] >= 0 {
			cur = trail[i]
			continue
		}
		switch {
		case seg.sel == nil:
			cur = d.newChild(cur, seg.name, seg.nameSrc, value{kind: vEmpty})
		case seg.sel.kind == selByValue:
			cur = d.newChild(cur, seg.name, seg.nameSrc, cellOf(seg.sel.value))
		default:
			// Unreachable: probeWrite refuses a wildcard outright and an
			// unresolvable index, so neither reaches an empty trail slot.
			return 0, false
		}
	}
	return cur, true
}

func (d *Document) setValue(path string, v value) bool {
	if !valueReadsBack(&v) {
		return false
	}
	if d.probe {
		return true
	}
	idx, ok := d.place(path)
	if !ok {
		return false
	}
	if headsBlock(&d.arena[idx]) {
		d.commentOutHead(idx, path)
	}
	d.arena[idx].value = v
	d.arena[idx].src = nil // written value has no source spelling
	// No longer the list the lines among its elements sat in.
	unstack(&d.arena[idx])
	// An empty binding or a raw block can put a fence after an empty sibling
	// of its name.
	fenceSide := v.kind == vEmpty || v.kind == vRaw
	parent, name := d.arena[idx].parent, d.arena[idx].name
	d.collapseDup(idx)
	if fenceSide {
		d.settleFenceName(parent, name)
	}
	settleFirstBlank(d.arena, d.orphans)
	d.resettleKept()
	return true
}

// commentOutHead: a setter on a field a kept line opened writes that line as
// a comment, with a note giving why and when, so the file is left with one
// line for the field (design.md, Kept lines under edits). The line is a
// comment from here on, as a reload reads it, so it is no longer owed.
func (d *Document) commentOutHead(idx int, path string) {
	t := d.arena[idx].trivMut()
	if len(t.leading) == 0 {
		return
	}
	l := &t.leading[len(t.leading)-1]
	// A line refused for its value alone never takes a raw body, but one
	// that did could not be commented out as one line.
	if strings.Contains(l.text, "\n") {
		return
	}
	var tok Tokens
	Tokenize(l.text, ':', false, RulesCurrent, &tok)
	code, msg, bad := lineFault(&tok, l.text)
	if !bad {
		return
	}
	// The reason, without the advice after it.
	why, _, _ := strings.Cut(msg, ";")
	l.text = fmt.Sprintf("%s  ## commented out by shcl when setting %s, %s: %s %s",
		commented(l.text), noteText(path), noteStamp(), code, why)
	l.line = 0
	l.kept = false
	if d.keptOwed > 0 {
		d.keptOwed--
	}
}

// collapseDup: a written value may now collide with a same-named sibling under
// the in-file merge rule; fold the pair the way a reparse would (earlier
// sibling survives, later one folds children and trivia in) so Writer output
// stays a formatter fixpoint.
func (d *Document) collapseDup(node int) {
	parent := d.arena[node].parent
	me := &d.arena[node]
	other := -1
	for _, c := range d.childrenNamed(parent, me.name) {
		o := &d.arena[c]
		if c != node && mergeEq(o.name, &o.value, me.name, &me.value) {
			other = c
			break
		}
	}
	if other < 0 {
		return
	}
	pos := func(n int) int {
		for i, c := range d.arena[parent].children {
			if c == n {
				return i
			}
		}
		return int(^uint(0) >> 1)
	}
	survivor, loser := other, node
	if pos(node) < pos(other) {
		survivor, loser = node, other
	}
	moved := append([]int(nil), d.arena[loser].children...)
	foldNodeInto(d.arena, survivor, loser)
	keep := d.arena[parent].children[:0]
	for _, c := range d.arena[parent].children {
		if c != loser {
			keep = append(keep, c)
		}
	}
	d.arena[parent].children = keep
	settleBlock(d.arena, parent, 1)
	if ix := d.index.Load(); ix != nil {
		ix.unlink(nameKey(parent, d.arena[loser].name), loser)
		for _, k := range moved {
			name := d.arena[k].name
			ix.unlink(nameKey(loser, name), k)
			ix.append(nameKey(survivor, name), k)
		}
	}
	d.foldDupsBelow(survivor)
}

// settleFenceName is the write-side twin of settleFenceTrailing: only the
// written name's instances can change, and walking them off the index keeps a
// write off the rest of the block.
func (d *Document) settleFenceName(parent int, name string) {
	seenEmpty := false
	for _, c := range d.childrenNamed(parent, name) {
		nd := &d.arena[c]
		if seenEmpty && nd.value.kind == vRaw && nd.trailing() != "" {
			trailingToLeading(nd)
		} else if seenEmpty && stacks(nd) {
			unstack(nd)
		} else if nd.value.isEmpty() {
			seenEmpty = true
		}
	}
}

// foldDupsBelow: folding moves the loser's children up a level, where they can
// collide with the survivor's own. The parser's fold is depth-first for the
// same reason; only a node that just received children can hold a new pair.
func (d *Document) foldDupsBelow(start int) {
	stack := []int{start}
	for len(stack) > 0 {
		parent := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		kids := d.arena[parent].children
		d.arena[parent].children = nil
		first := make(map[uint64]slot, len(kids))
		keep := make([]int, 0, len(kids))
		for _, c := range kids {
			h := mergeHash(d.arena[c].name, &d.arena[c].value)
			if survivor, ok := slotFirstMatch(first, h, func(x int) bool {
				return mergeEq(d.arena[x].name, &d.arena[x].value, d.arena[c].name, &d.arena[c].value)
			}); ok {
				moved := append([]int(nil), d.arena[c].children...)
				foldNodeInto(d.arena, survivor, c)
				if ix := d.index.Load(); ix != nil {
					ix.unlink(nameKey(parent, d.arena[c].name), c)
					for _, k := range moved {
						name := d.arena[k].name
						ix.unlink(nameKey(c, name), k)
						ix.append(nameKey(survivor, name), k)
					}
				}
				stack = append(stack, survivor)
			} else {
				slotInsert(first, h, c)
				keep = append(keep, c)
			}
		}
		d.arena[parent].children = keep
		settleBlock(d.arena, parent, 1)
	}
}

// Exists is true when the path resolves to at least one real node.
func (d *Document) Exists(path string) bool {
	r, ok := d.resolveGroup(path)
	if !ok {
		return false
	}
	switch r.kind {
	case resOne, resMany:
		return true
	case resSlots:
		for _, s := range r.slots {
			if s >= 0 {
				return true
			}
		}
	}
	return false
}

// Remove deletes the node(s) at a path (with their subtrees); returns how many.
// Lines kept as written beside a node stay where they were, and a field opened
// only by the lines under it goes with the last of them.
// A removed node's storage is not reclaimed, so a process that adds and removes in a loop grows by a few hundred bytes a pair. Reloading the canonical text gives it back.
func (d *Document) Remove(path string) int {
	r, ok := d.resolveGroup(path)
	if !ok {
		return 0
	}
	var targets []int
	switch r.kind {
	case resOne:
		targets = []int{r.one}
	case resMany:
		targets = r.many
	case resSlots:
		for _, s := range r.slots {
			if s >= 0 {
				targets = append(targets, s)
			}
		}
	}
	// Mark first, rebuild each touched child list once. Dropping one target at
	// a time rebuilt the same list once per target, which is quadratic when a
	// path matches many siblings.
	type pair struct{ node, parent int }
	pairs := make([]pair, 0, len(targets))
	for _, t := range targets {
		p := d.arena[t].parent
		// A node already marked would pass dead into the rebuild below as an
		// index, so skip it rather than trust resolve never to name one twice.
		if p == dead {
			continue
		}
		if d.keptOwed > 0 {
			d.keptOwed -= d.taken(t)
			if d.keptOwed < 0 {
				d.keptOwed = 0
			}
		}
		if ix := d.index.Load(); ix != nil {
			ix.unlink(nameKey(p, d.arena[t].name), t)
		}
		d.arena[t].parent = dead
		pairs = append(pairs, pair{t, p})
	}
	// Rebuilding a list puts back the parent of every node it drops, so a mark
	// still standing is also the answer to "has this parent been done yet" -
	// no separate pass to dedupe the parents.
	for _, pr := range pairs {
		if d.arena[pr.node].parent != dead {
			continue
		}
		kids := d.arena[pr.parent].children[:0]
		var left []lead
		for _, c := range d.arena[pr.parent].children {
			if d.arena[c].parent == dead {
				d.arena[c].parent = pr.parent
				left = append(left, besideKept(&d.arena[c])...)
			} else {
				if len(left) > 0 {
					d.leaveAbove(c, left)
					left = nil
				}
				kids = append(kids, c)
			}
		}
		d.arena[pr.parent].children = kids
		if len(left) > 0 {
			d.leaveLast(pr.parent, left)
		}
	}
	// A field opened only by the lines under it goes with the last of them,
	// and its own kept line stays where it was (escblock).
	open := make([]int, 0, len(pairs))
	for _, pr := range pairs {
		open = append(open, pr.parent)
	}
	for len(open) > 0 {
		p := open[len(open)-1]
		open = open[:len(open)-1]
		if p == root || len(d.arena[p].children) != 0 || !openedByKept(&d.arena[p]) || !d.live(p) {
			continue
		}
		pp := d.arena[p].parent
		t := d.arena[p].trivMut()
		left := t.leading
		for _, l := range t.inside {
			l.depth++
			left = append(left, l)
		}
		left = append(left, t.after...)
		t.leading, t.inside, t.after = nil, nil, nil
		if ix := d.index.Load(); ix != nil {
			ix.unlink(nameKey(pp, d.arena[p].name), p)
		}
		kids := d.arena[pp].children
		at := 0
		for k, c := range kids {
			if c == p {
				at = k
				break
			}
		}
		d.arena[pp].children = append(kids[:at:at], kids[at+1:]...)
		if at < len(d.arena[pp].children) {
			d.leaveAbove(d.arena[pp].children[at], left)
		} else {
			d.leaveLast(pp, left)
		}
		open = append(open, pp)
	}
	settleFirstBlank(d.arena, d.orphans)
	d.resettleKept()
	return len(targets)
}

// leaveAbove puts lines a remove left above the sibling that followed them.
func (d *Document) leaveAbove(node int, left []lead) {
	t := d.arena[node].trivMut()
	t.leading = append(left, t.leading...)
	restep(t.leading)
}

// leaveLast puts lines a remove left after the last of parent's children: the
// document's footer at the top, else after the last child left, else inside
// the block. A misplaced line has no level there, so a reload files it with
// the next binding line, and the comments after it go along; kept field lines
// still go to the block.
func (d *Document) leaveLast(parent int, left []lead) {
	if parent == root {
		d.orphans = append(left, d.orphans...)
		restep(d.orphans)
		return
	}
	var below []lead
	for at := range left {
		if strings.HasPrefix(left[at].text, " ") || strings.HasPrefix(left[at].text, "\t") {
			rest := append([]lead(nil), left[at:]...)
			left = left[:at:at]
			for _, l := range rest {
				if isField(l.text) {
					left = append(left, l)
				} else {
					below = append(below, l)
				}
			}
			break
		}
	}
	if len(left) > 0 {
		// Stacked with no kept line among the elements is gone on a reload, so
		// it may not decide how these lines are written.
		d.arena[parent].starList = stacks(&d.arena[parent])
		var t *trivia
		if kids := d.arena[parent].children; len(kids) > 0 {
			t = d.arena[kids[len(kids)-1]].trivMut()
			t.after = append(t.after, left...)
			restep(t.after)
		} else {
			t = d.arena[parent].trivMut()
			t.inside = append(t.inside, left...)
			restep(t.inside)
		}
	}
	if len(below) > 0 {
		d.leaveBelow(parent, below)
	}
}

// leaveBelow puts lines a remove left right after node's block: above the
// next binding line, or the footer when there is none.
func (d *Document) leaveBelow(node int, left []lead) {
	at := node
	for at != root {
		up := d.arena[at].parent
		kids := d.arena[up].children
		for k, c := range kids {
			if c == at && k+1 < len(kids) {
				d.leaveAbove(kids[k+1], left)
				return
			}
		}
		at = up
	}
	d.orphans = append(left, d.orphans...)
	restep(d.orphans)
}

// live: still in the tree, each node up to root in its parent's list. A
// removed node keeps its parent link, so the link alone does not say.
func (d *Document) live(node int) bool {
	for node != root {
		p := d.arena[node].parent
		if p == dead {
			return false
		}
		found := false
		for _, c := range d.arena[p].children {
			if c == node {
				found = true
				break
			}
		}
		if !found {
			return false
		}
		node = p
	}
	return true
}

// SetComment attaches a leading comment line to the node at a path (creating an
// empty node if absent, so a section can be annotated). A missing '#' is added,
// and trailing whitespace comes off the way the load takes it, so text that is
// blank leaves a bare '#'. Text holding a line break is refused: a comment is
// one line, and keeping only the first would drop the rest with nothing to say
// so.
func (d *Document) SetComment(path, text string) bool {
	line, ok := commentLine(text)
	if !ok {
		return false
	}
	idx, ok := d.place(path)
	if !ok {
		return false
	}
	// The node's own blank moves above its first comment; otherwise the blank
	// would separate the comment from what it annotates. Above the first one
	// already there, when there is one.
	nd := &d.arena[idx]
	l := plainLead(line)
	t := nd.trivMut()
	if nd.blankBefore {
		nd.blankBefore = false
		if len(t.leading) > 0 {
			t.leading[0].blankBefore = true
		} else {
			l.blankBefore = true
		}
	}
	t.leading = append(t.leading, l)
	settleFirstBlank(d.arena, d.orphans)
	d.resettleKept()
	return true
}

// Comments returns the comment lines above the node(s) at a path, the ones
// ClearComments takes, in file order, each from its '#' on. A program can tell
// its own comment from one a user wrote there, and SetComment puts a line it
// gave back as it was. Empty when the path reaches nothing.
func (d *Document) Comments(path string) []string {
	r, ok := d.resolveGroup(path)
	if !ok {
		return nil
	}
	var targets []int
	switch r.kind {
	case resOne:
		targets = []int{r.one}
	case resMany:
		targets = r.many
	case resSlots:
		for _, s := range r.slots {
			if s >= 0 {
				targets = append(targets, s)
			}
		}
	}
	var out []string
	for _, t := range targets {
		tr := d.arena[t].trivia
		if tr == nil {
			continue
		}
		for _, l := range tr.leading {
			if l.isComment() {
				out = append(out, l.text)
			}
		}
	}
	return out
}

// ClearComments takes off the comment lines above the node(s) at a path, the
// lines SetComment adds to, so a program can replace a comment rather than
// stack another one on it. Which lines those are is where the load put them:
// everything between the node and the binding line before it, so a heading
// written for a group of fields goes too. A comment on the node's own line
// stays, and so does a line kept as written for being malformed. Returns how
// many lines came off, 0 when the path reaches nothing.
func (d *Document) ClearComments(path string) int {
	r, ok := d.resolveGroup(path)
	if !ok {
		return 0
	}
	var targets []int
	switch r.kind {
	case resOne:
		targets = []int{r.one}
	case resMany:
		targets = r.many
	case resSlots:
		for _, s := range r.slots {
			if s >= 0 {
				targets = append(targets, s)
			}
		}
	}
	cleared := 0
	for _, t := range targets {
		nd := &d.arena[t]
		tr := nd.trivia
		if tr == nil {
			continue
		}
		before := len(tr.leading)
		// The blank above the run is the one that separates it from what comes
		// before, so it stays with whatever is now first.
		blank := before > 0 && tr.leading[0].blankBefore
		kept := tr.leading[:0]
		for _, l := range tr.leading {
			if !l.isComment() {
				kept = append(kept, l)
			}
		}
		tr.leading = kept
		gone := before - len(kept)
		if gone == 0 {
			continue
		}
		cleared += gone
		// A kept line left in the run may have sat under a comment that went.
		restep(kept)
		if len(kept) > 0 {
			kept[0].blankBefore = kept[0].blankBefore || blank
		} else {
			nd.blankBefore = nd.blankBefore || blank
		}
	}
	if cleared > 0 {
		settleFirstBlank(d.arena, d.orphans)
		d.resettleKept()
	}
	return cleared
}

// SetBanner puts the info block (GenBanner) at the end of the document, or
// with on false just takes it off. An old block comes off first, found by its
// "This config file format is SHCL." line, never by its links or Legal line,
// which a later release may word differently. It runs from the lone "##"
// above that line to the next one, so a "##" comment of the file's own stays,
// even written right against it. A version line Migrate stamped comes off
// too, with the note under it. Both are looked for in the footer and above
// every field but the first one and its first child down, since a field added
// below one by hand takes it as its comment. A block at the top of the file is
// left alone. A dotted first line hangs it on its last name, which a saved file
// writes as the first field's first child, so a block there is left alone too,
// however it got there. The library save never adds the block by itself; this
// is for a program that wants it in a file it writes. Returns how many old
// blocks came off.
func (d *Document) SetBanner(on bool) int {
	removed := 0
	// The first line's comments are the top of the file, on the first node
	// down, as a dotted line puts them on its last name.
	var top []int
	for n := root; len(d.arena[n].children) > 0; {
		n = d.arena[n].children[0]
		top = append(top, n)
	}
	stack := append([]int(nil), d.arena[root].children...)
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = append(stack[:len(stack)-1], d.arena[n].children...)
		first := false
		for _, t := range top {
			first = first || t == n
		}
		tr := d.arena[n].trivia
		if first || tr == nil {
			continue
		}
		gone, blank := dropBanners(&tr.leading)
		if gone > 0 {
			removed += gone
			d.arena[n].blankBefore = d.arena[n].blankBefore || blank
		}
	}
	gone, _ := dropBanners(&d.orphans)
	removed += gone
	if on {
		open := len(d.orphans) > 0 || len(d.arena[root].children) > 0
		for n, line := range strings.Split(strings.TrimSuffix(GenBanner, "\n"), "\n") {
			l := plainLead(line)
			l.blankBefore = n == 0 && open
			d.orphans = append(d.orphans, l)
		}
	}
	settleFirstBlank(d.arena, d.orphans)
	d.resettleKept()
	return removed
}

// SetInt binds an integer at path, creating the path as needed; false = path
// not writable (WriteReason says why - same for every setter). Worth checking
// rather than assuming: an ignored false means the save that follows writes a
// document missing the edit, and reports success doing it.
func (d *Document) SetInt(path string, v int64) bool {
	return d.setValue(path, cellOf(strconv.FormatInt(v, 10)))
}

// SetFloat binds a float at path, in the canonical shortest spelling. An
// infinity or a NaN has no spelling the reader accepts, so it fails the write
// rather than binding a value that cannot read back.
func (d *Document) SetFloat(path string, v float64) bool {
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return false
	}
	return d.setValue(path, cellOf(FormatFloat(v)))
}

// SetBool binds true/false at path.
func (d *Document) SetBool(path string, v bool) bool {
	return d.setValue(path, cellOf(boolText(v)))
}

// SetString binds a string at path, escaped so it reads back exactly. A Go
// string can hold any bytes, and a document is UTF-8, so text that is not
// valid UTF-8 fails the write rather than being stored with a replacement
// character per bad byte and reported as written - the same refusal SetFloat
// gives an infinity and SetDateTime a month of 13.
func (d *Document) SetString(path, v string) bool {
	return d.setValue(path, cellOf(v))
}

// SetDateTime binds a datetime at path, in its canonical spelling. The
// struct's fields are public and have no invariant, so a value the reader
// would refuse (month 13, a fraction with no seconds, an empty struct) fails
// the write rather than binding text that cannot read back.
func (d *Document) SetDateTime(path string, v DateTime) bool {
	if !datetimeReadsBack(v) {
		return false
	}
	return d.setValue(path, cellOf(v.String()))
}

// SetEmpty binds an empty value at path (distinct from the empty string).
func (d *Document) SetEmpty(path string) bool {
	return d.setValue(path, value{kind: vEmpty})
}

// SetRaw binds a raw block at path, picking a fence longer than any content line.
// The info-string is stored as a fence line would read it back (trimmed the way
// the load trims one); one that would not read back whole - it holds a line
// break, or a `#`, which reads as a comment - fails the write, as does a body
// line ending in CR, since the load takes the trailing CR run off every line.
func (d *Document) SetRaw(path, content, info string) bool {
	info = trimWsp(info)
	fc, fl := chooseFence(content)
	return d.setValue(path, value{kind: vRaw, raw: &rawValue{content: content, info: info, fenceChar: fc, fenceLen: fl}})
}

// SetIntArray binds an inline integer array at path.
func (d *Document) SetIntArray(path string, v []int64) bool {
	texts := make([]string, len(v))
	for i, x := range v {
		texts[i] = strconv.FormatInt(x, 10)
	}
	return d.setValue(path, arrayCell(texts))
}

// SetFloatArray binds an inline float array at path.
func (d *Document) SetFloatArray(path string, v []float64) bool {
	for _, x := range v {
		if math.IsInf(x, 0) || math.IsNaN(x) {
			return false
		}
	}
	texts := make([]string, len(v))
	for i, x := range v {
		texts[i] = FormatFloat(x)
	}
	return d.setValue(path, arrayCell(texts))
}

// SetBoolArray binds an inline bool array at path.
func (d *Document) SetBoolArray(path string, v []bool) bool {
	texts := make([]string, len(v))
	for i, x := range v {
		texts[i] = boolText(x)
	}
	return d.setValue(path, arrayCell(texts))
}

// SetStringArray binds an inline string array at path, per-element escaped.
func (d *Document) SetStringArray(path string, v []string) bool {
	texts := make([]string, len(v))
	copy(texts, v)
	return d.setValue(path, arrayCell(texts))
}

// SetDateTimeArray binds an inline datetime array at path.
func (d *Document) SetDateTimeArray(path string, v []DateTime) bool {
	for _, x := range v {
		if !datetimeReadsBack(x) {
			return false
		}
	}
	texts := make([]string, len(v))
	for i, x := range v {
		texts[i] = x.String()
	}
	return d.setValue(path, arrayCell(texts))
}

// Default (only-if-absent) forms - the "emit defaults" half of the Writer.
// A path that already resolves writes nothing and reports what a write there
// would: the path's verdict, so a wildcard is refused whether or not its slots
// happen to resolve, and the value's, which the same setter gives on the probe
// document.

// setDefault runs set on the path when nothing is there yet, and otherwise
// answers with the path's verdict and the value's.
func (d *Document) setDefault(path string, set func(*Document, string) bool) bool {
	if !d.Exists(path) {
		return set(d, path)
	}
	if d.WriteReason(path) != Writable {
		return false
	}
	if d.probeDoc == nil {
		d.probeDoc = New()
		d.probeDoc.probe = true
	}
	return set(d.probeDoc, "v")
}

// SetIntDefault is SetInt only when path has no node yet.
func (d *Document) SetIntDefault(path string, v int64) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetInt(p, v) })
}

// SetFloatDefault is SetFloat only when path has no node yet.
func (d *Document) SetFloatDefault(path string, v float64) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetFloat(p, v) })
}

// SetBoolDefault is SetBool only when path has no node yet.
func (d *Document) SetBoolDefault(path string, v bool) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetBool(p, v) })
}

// SetLiteral binds text at path as value syntax rather than as data: "80, 443"
// becomes a two-element array where SetString would store one string that has
// to be quoted. This is how a caller holding value text - a config line, a
// user's --set argument - writes it without knowing its shape first. Fails on
// text that could not be one line's value (see literalValue).
func (d *Document) SetLiteral(path, text string) bool {
	v, ok := literalValue(text)
	if !ok {
		return false
	}
	return d.setValue(path, v)
}

// SetLiteralDefault is SetLiteral only when path has no node yet.
func (d *Document) SetLiteralDefault(path, text string) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetLiteral(p, text) })
}

// SetStringDefault is SetString only when path has no node yet.
func (d *Document) SetStringDefault(path, v string) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetString(p, v) })
}

// SetDateTimeDefault is SetDateTime only when path has no node yet.
func (d *Document) SetDateTimeDefault(path string, v DateTime) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetDateTime(p, v) })
}

// SetRawDefault is SetRaw only when path has no node yet.
func (d *Document) SetRawDefault(path, content, info string) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetRaw(p, content, info) })
}

// SetIntArrayDefault is SetIntArray only when path has no node yet.
func (d *Document) SetIntArrayDefault(path string, v []int64) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetIntArray(p, v) })
}

// SetFloatArrayDefault is SetFloatArray only when path has no node yet.
func (d *Document) SetFloatArrayDefault(path string, v []float64) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetFloatArray(p, v) })
}

// SetBoolArrayDefault is SetBoolArray only when path has no node yet.
func (d *Document) SetBoolArrayDefault(path string, v []bool) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetBoolArray(p, v) })
}

// SetStringArrayDefault is SetStringArray only when path has no node yet.
func (d *Document) SetStringArrayDefault(path string, v []string) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetStringArray(p, v) })
}

// SetDateTimeArrayDefault is SetDateTimeArray only when path has no node yet.
func (d *Document) SetDateTimeArrayDefault(path string, v []DateTime) bool {
	return d.setDefault(path, func(e *Document, p string) bool { return e.SetDateTimeArray(p, v) })
}

// ---------------------------------------------------------------------------
// Layered loading: overlay a higher-priority document onto a lower one.
// ---------------------------------------------------------------------------

// Merge overlays over (a higher-priority layer) onto d (the lower one).
// Container instances merge by (name, value) exactly like the in-file rule; a
// leaf name present in over replaces d's same-named children at that scope -
// provided those base children are leaves too - so scalars, arrays, and raw
// blocks get real override while a bare section header merges instead of
// wiping. over-only nodes are appended. Comment trivia rides with each node.
// Load(defaults, site, user) is a left fold of this: each later file overlaid
// on the earlier ones.
//
// The fold is not associative: (A+B)+C and A+(B+C) differ where a bare header
// meets an overridden leaf, so a cached upper pair is not the same document the
// CLI's left fold produces. d keeps its own strictness, so a value from a
// stricter layer reads with d's coercion. And a replaced node is kept until the
// document is dropped: this costs a pass over the touched scopes plus an index
// rebuild on the next read.
//
// A document merged onto itself is left as it is. The walk reads over while it
// writes d, so the same document on both sides duplicated lines.
func (d *Document) Merge(over *Document) {
	if over == d {
		return
	}
	d.index.Store(nil)
	d.source = nil
	d.lost += over.lost
	d.keptOwed += over.keptOwed
	// The layer's own kept lines were modeled against its own tree.
	fresh := over.kept
	d.kept = d.kept || over.kept
	// Only a block the overlay visited can have a changed child list or
	// comments; the rest was settled when it was built. Settling the whole
	// tree made every merge cost the document (20260924 item 6). A block's
	// settle writes only below it, so the order does not matter.
	var touched []int
	d.overlay(root, over, root, &touched)
	for _, n := range touched {
		settleBlock(d.arena, n, 1)
	}
	// Layers commonly share a footer; keeping one copy of each keeps a
	// stack of files from repeating it once per layer. Only the lines
	// already here count: a layer's own repeats are its content.
	had := len(d.orphans)
	// A repeat skipped here may be the line the next one sat under, and a
	// reload puts a comment at most one level past the comment or kept field
	// line before it, so none goes deeper than that.
	room := 0
	for k := len(d.orphans) - 1; k >= 0; k-- {
		if !strings.HasPrefix(d.orphans[k].text, " ") && !strings.HasPrefix(d.orphans[k].text, "\t") {
			room = d.orphans[k].depth + 1
			break
		}
	}
	// A kept line with kept lines under it goes in whole, so none of them
	// lands under some other line.
	whole := make([]bool, len(over.orphans))
	prev := -1
	for i := range over.orphans {
		if !isField(over.orphans[i].text) {
			continue
		}
		if prev >= 0 && over.orphans[i].depth > 0 {
			whole[prev] = true
			whole[i] = true
		}
		prev = i
	}
	for i, o := range over.orphans {
		seen := false
		for _, e := range d.orphans[:had] {
			if !whole[i] && e.text == o.text && e.depth == o.depth {
				seen = true
				break
			}
		}
		if !seen {
			if strings.HasPrefix(o.text, "#") {
				if o.depth > room {
					o.depth = room
				}
				room = o.depth + 1
			} else if isField(o.text) {
				room = o.depth + 1
			}
			d.orphans = append(d.orphans, o)
		} else if o.isKeptLine() {
			// The table lets the dedup skip a footer line the base has.
			if d.keptOwed > 0 {
				d.keptOwed--
			}
		}
	}
	settleFirstBlank(d.arena, d.orphans)
	if fresh {
		d.settleKept()
	} else {
		d.resettleKept()
	}
}

// One grouping pass over each side, then a single children rebuild: the old
// shape re-filtered the over side per distinct name and re-scanned (and
// re-keyed) the base side per over node - three O(K^2) terms at one parent,
// plus a full vector rebuild per replaced name.

// adoptTrivia: a matched instance keeps the base node, so the over side's
// comments have to move onto it or they are lost. Same rule as an in-file
// merge: leading concatenates in layer order, first trailing wins.
func (d *Document) adoptTrivia(base int, over *Document, ok int) {
	st := over.arena[ok].trivia
	if st == nil {
		return
	}
	bt := d.arena[base].trivMut()
	// append copies the lead values, so the merged doc never shares a
	// backing array with over, which the caller may still mutate.
	bt.leading = append(bt.leading, st.leading...)
	if st.trailing != "" {
		if bt.trailing == "" {
			bt.trailing = st.trailing
		} else {
			bt.leading = append(bt.leading, plainLead(st.trailing))
		}
	}
	bt.after = append(bt.after, st.after...)
	bt.inside = append(bt.inside, st.inside...)
	bt.among = append(bt.among, st.among...)
	sort.SliceStable(bt.among, func(i, j int) bool { return bt.among[i].before < bt.among[j].before })
}

func (d *Document) overlay(baseParent int, over *Document, overParent int, touched *[]int) {
	*touched = append(*touched, baseParent)
	overKids := over.arena[overParent].children
	// Over side: name -> node bucket, in first-appearance order.
	var order []string
	type overKid struct{ pos, node int }
	groups := map[string][]overKid{}
	for pos, k := range overKids {
		n := over.arena[k].name
		if _, seen := groups[n]; !seen {
			order = append(order, n)
		}
		groups[n] = append(groups[n], overKid{pos, k})
	}
	// Base side, one pass: does the name have a container instance, and
	// which child has each (name, key) - every key computed once. The
	// list is cloned because the splices below rewrite it as they go.
	baseKids := append([]int(nil), d.arena[baseParent].children...)
	hasContainer := map[string]bool{}
	byName := map[string][]int{}
	// Keyed on the hash of (name, merge key) and verified on a hit, so no
	// key text is built per child on either side.
	byKey := make(map[uint64]slot, len(baseKids))
	find := func(h uint64, name string, v *value) (int, bool) {
		return slotFirstMatch(byKey, h, func(x int) bool {
			return mergeEq(d.arena[x].name, &d.arena[x].value, name, v)
		})
	}
	for _, b := range baseKids {
		name := d.arena[b].name
		hasContainer[name] = hasContainer[name] || len(d.arena[b].children) > 0
		byName[name] = append(byName[name], b)
		h := mergeHash(name, &d.arena[b].value)
		if _, dup := find(h, name, &d.arena[b].value); !dup {
			slotInsert(byKey, h, b)
		}
	}
	// Decide per name. A name whose over-side nodes are all leaves is an
	// override - but only when the base side of the group is leaf-shaped
	// too. Against a base container, a childless over-node is a wrapper
	// mention, not a leaf, so it falls through to the instance merge: a
	// bare section header in a higher layer never wipes the subtree below.
	// Replaced groups splice in the rebuild; everything appended (unmatched
	// instances, and replaced names base never had) keeps the over file's
	// order, which the per-name pass here would otherwise regroup.
	replace := map[string][]int{}
	var appended []overKid
	emptyVal := &value{kind: vEmpty}
	for _, name := range order {
		group := groups[name]
		overLeafy := true
		for _, k := range group {
			if len(over.arena[k.node].children) > 0 {
				overLeafy = false
				break
			}
		}
		baseContainer, inBase := hasContainer[name]
		if overLeafy && !baseContainer {
			clones := make([]int, len(group))
			for i, ok := range group {
				clones[i] = d.cloneSubtree(over, ok.node, baseParent)
			}
			if inBase {
				// The replaced leaf's comments go with it, which the spec
				// allows; a content-malformed line retained on it is content
				// the parser promised to keep, so those move onto the
				// replacement. A comment starts with `#`, a retained line
				// never does.
				// Off the index, not a scan of every base child: N leaves
				// overridden by the same N names made this quadratic
				// (20260918b item 58).
				var kept []lead
				for _, b := range byName[name] {
					nd := &d.arena[b]
					// The leaf's own comments are the ones a remove would
					// take: above it those after its last kept line, below
					// it those before its first. The rest sit with a kept
					// line beside it and stay. A settled line counts as
					// the comment a reload reads it as.
					leading := nd.leading()
					above := 0
					for k := len(leading) - 1; k >= 0; k-- {
						if !strings.HasPrefix(leading[k].text, "#") {
							above = k + 1
							break
						}
					}
					after := nd.after()
					below := len(after)
					for k, l := range after {
						if !strings.HasPrefix(l.text, "#") {
							below = k
							break
						}
					}
					kept = append(kept, leading[:above]...)
					among := make([]lead, 0, len(nd.among()))
					for _, a := range nd.among() {
						among = append(among, a.lead)
					}
					for _, list := range [][]lead{leading[above:], among, nd.inside(), after[:below]} {
						for _, l := range list {
							if !strings.HasPrefix(l.text, "#") {
								kept = append(kept, l)
							} else if l.kept {
								// A settled one goes with the leaf's comments
								// (decided 2026-09-28), so it is no longer owed.
								if d.keptOwed > 0 {
									d.keptOwed--
								}
							}
						}
					}
					kept = append(kept, after[below:]...)
				}
				if len(kept) > 0 {
					t := d.arena[clones[0]].trivMut()
					t.leading = append(kept, t.leading...)
					// Comments from two sources now share one run.
					restep(t.leading)
				}
				replace[name] = clones
			} else {
				for i, ok := range group {
					appended = append(appended, overKid{ok.pos, clones[i]})
				}
			}
		} else {
			for _, k := range group {
				ok := k.node
				ov := &over.arena[ok].value
				hk := mergeHash(name, ov)
				target, found := find(hk, name, ov)
				// A raw block in the higher layer fills a same-named empty
				// binding below, exactly as a fence line fills one inside a
				// single file. Without it, merging two documents and parsing
				// them run together disagree: both bindings survive here and
				// fold there, so the merged output is not a formatter fixpoint.
				if !found && ov.kind == vRaw {
					he := mergeHash(name, emptyVal)
					if b, hit := find(he, name, emptyVal); hit {
						d.arena[b].value = cloneValue(ov)
						slotRemove(byKey, he, b)
						slotInsert(byKey, hk, b)
						target, found = b, true
					}
				}
				if found {
					// A stacked spelling no kept line holds is gone on a reload,
					// so it may not decide how the lines the other layer brings
					// are written (20260926 item 4).
					stacked := stacks(&d.arena[target]) || stacks(&over.arena[ok])
					d.adoptTrivia(target, over, ok)
					d.arena[target].starList = stacked
					d.overlay(target, over, ok, touched)
				} else {
					c := d.cloneSubtree(over, ok, baseParent)
					appended = append(appended, overKid{k.pos, c})
				}
			}
		}
	}
	if len(replace) == 0 && len(appended) == 0 {
		return
	}
	// Rebuild once: each replaced group goes to its name's first original
	// position (dropped nodes stay in the arena, unreferenced - reads and
	// emit walk children from the root), appends go at the end.
	newKids := make([]int, 0, len(baseKids)+len(appended))
	spliced := map[string]bool{}
	for _, b := range baseKids {
		name := d.arena[b].name
		if clones, rep := replace[name]; rep {
			if !spliced[name] {
				spliced[name] = true
				newKids = append(newKids, clones...)
			}
		} else {
			newKids = append(newKids, b)
		}
	}
	sort.Slice(appended, func(i, j int) bool { return appended[i].pos < appended[j].pos })
	for _, k := range appended {
		newKids = append(newKids, k.node)
	}
	d.arena[baseParent].children = newKids
}

// cloneValue copies the value's storage too - a struct copy would share the
// els backing array (and the raw block) with `over`, and the clone must
// survive `over` being released.
func cloneValue(v *value) value {
	cv := *v
	cv.els = append([]element(nil), cv.els...)
	if cv.raw != nil {
		r := *cv.raw
		cv.raw = &r
	}
	return cv
}

// cloneTrivia deep-copies a trivia sidecar (nil stays nil).
func cloneTrivia(t *trivia) *trivia {
	if t == nil {
		return nil
	}
	c := trivia{
		leading:  append([]lead(nil), t.leading...),
		trailing: t.trailing,
		after:    append([]lead(nil), t.after...),
		inside:   append([]lead(nil), t.inside...),
		among:    append([]amongLead(nil), t.among...),
	}
	return &c
}

// cloneSubtree deep-copies over's subtree at oi into d's arena under parent.
func (d *Document) cloneSubtree(over *Document, oi, parent int) int {
	src := over.arena[oi]
	cv := cloneValue(&src.value)
	var srcCopy *string
	if src.src != nil {
		s := *src.src
		srcCopy = &s
	}
	nd := nodeData{
		name:        src.name,
		nameSrc:     src.nameSrc,
		value:       cv,
		parent:      parent,
		line:        src.line,
		starList:    src.starList,
		starMixed:   src.starMixed,
		trivia:      cloneTrivia(src.trivia),
		blankBefore: src.blankBefore,
		srcSet:      src.srcSet,
		src:         srcCopy,
	}
	idx := len(d.arena)
	d.arena = append(d.arena, nd)
	for _, ok := range over.arena[oi].children {
		c := d.cloneSubtree(over, ok, idx)
		d.arena[idx].children = append(d.arena[idx].children, c)
	}
	return idx
}

// ---------------------------------------------------------------------------
// Coercion ("intelligent but safe"; Loose re-admits a closed list of tricks)
// ---------------------------------------------------------------------------

var currencyRunes = []rune{
	'$', '¢', '£', '¤', '¥', '₩', '₪', '₫', '€', '₭', '₮', '₱', '₲', '₴', '₹', '₺', '₼', '₽', '₾', '₿',
}

// stripCurrency is the remainder after a leading currency symbol, with the
// space a person writes after one taken off - `$ 1200` reached the int path's
// thousands branch, which trims, and the float path's shape test, which does
// not.
func stripCurrency(t string) string {
	r, size := utf8.DecodeRuneInString(t)
	for _, c := range currencyRunes {
		if r == c {
			return strings.TrimLeftFunc(t[size:], unicode.IsSpace)
		}
	}
	return t
}

func parseIntText(e *element, level Strictness) (int64, bool) {
	t := strings.TrimSpace(e.text)
	if level == Loose {
		t = stripCurrency(t)
	}
	// Plain decimal.
	body := stripSign(t)
	if body != "" && allDigits(body) {
		v, err := strconv.ParseInt(t, 10, 64)
		return v, err == nil
	}
	// Hex, octal and binary.
	neg := false
	prefixed := t
	if strings.HasPrefix(t, "-") {
		neg = true
		prefixed = t[1:]
	} else {
		prefixed = strings.TrimPrefix(t, "+")
	}
	if radix, digits, ok := radixBody(prefixed); ok {
		// Parse the magnitude as u64, then range-check against the sign, so the
		// negative math.MinInt64 magnitude (0x8000000000000000) reads like its
		// decimal spelling instead of overflowing a signed parse.
		m, err := strconv.ParseUint(digits, radix, 64)
		if err != nil {
			return 0, false
		}
		if neg {
			if m == uint64(math.MaxInt64)+1 {
				return math.MinInt64, true
			}
			if m <= uint64(math.MaxInt64) {
				return -int64(m), true
			}
			return 0, false
		}
		if m <= uint64(math.MaxInt64) {
			return int64(m), true
		}
		return 0, false
	}
	// Thousands separators, only inside quotes (bare commas are reserved).
	if e.quoted && strings.Contains(t, ",") {
		signBody := stripSign(t)
		groups := strings.Split(signBody, ",")
		wellFormed := len(groups) > 1 && groups[0] != "" && len(groups[0]) <= 3 && allDigits(groups[0])
		if wellFormed {
			for _, g := range groups[1:] {
				if len(g) != 3 || !allDigits(g) {
					wellFormed = false
					break
				}
			}
		}
		if wellFormed {
			v, err := strconv.ParseInt(strings.ReplaceAll(t, ",", ""), 10, 64)
			return v, err == nil
		}
	}
	// Loose: a float (including %) rounds, half away from zero.
	if level == Loose {
		if f, ok := parseFloatText(e, level); ok {
			r := math.Round(f)
			// math.MaxInt64 has no exact float64 - it rounds up to 2^63 - so
			// the top bound is 2^63 itself, exclusively. MinInt64 is exact.
			if r >= float64(math.MinInt64) && r < 9223372036854775808.0 {
				return int64(r), true
			}
		}
	}
	return 0, false
}

func floatShapeOK(t string) bool {
	body := stripSign(t)
	if body == "" {
		return false
	}
	mantissa := body
	if idx := strings.IndexAny(body, "eE"); idx >= 0 {
		mantissa = body[:idx]
		xb := stripSign(body[idx+1:])
		if xb == "" || !allDigits(xb) {
			return false
		}
	}
	intPart, fracPart := mantissa, ""
	if d := strings.IndexByte(mantissa, '.'); d >= 0 {
		intPart, fracPart = mantissa[:d], mantissa[d+1:]
	}
	if intPart == "" && fracPart == "" {
		return false
	}
	return allDigits(intPart) && allDigits(fracPart)
}

func parseFloatText(e *element, level Strictness) (float64, bool) {
	t := strings.TrimSpace(e.text)
	percent := false
	if level == Loose {
		t = stripCurrency(t)
		if inner, ok := strings.CutSuffix(t, "%"); ok {
			t = trimEndWS(inner)
			percent = true
		}
	}
	var v float64
	if floatShapeOK(t) {
		f, err := strconv.ParseFloat(t, 64)
		if err != nil {
			// Underflow keeps the reference's parse result (0). Overflow is an
			// infinity, which no double holds and no setter can write back:
			// BadType, like a text that is not a number at all.
			var ne *strconv.NumError
			if !errors.As(err, &ne) || ne.Err != strconv.ErrRange || math.IsInf(f, 0) {
				return 0, false
			}
		}
		v = f
	} else {
		// An integer is a valid float on read (incl. hex, octal, binary and quoted thousands).
		el := element{text: t, quoted: e.quoted}
		if n, ok := parseIntTextNoLoose(&el); ok {
			v = float64(n)
		} else if w, ok := parseIntTextWide(&el); ok {
			v = w
		} else {
			return 0, false
		}
	}
	if percent {
		v /= 100.0
	}
	return v, true
}

// parseIntTextNoLoose: integer forms only (no Loose float fallback) - used by
// the float path so the two can't recurse into each other.
func parseIntTextNoLoose(e *element) (int64, bool) {
	return parseIntText(e, Standard)
}

// radixBody returns the digits after a `0x`, `0o` or `0b` prefix, either
// case, with their radix. A bare leading zero is decimal, so `0o` is the one
// way to write an octal mode.
func radixBody(t string) (int, string, bool) {
	if len(t) < 3 || t[0] != '0' {
		return 0, "", false
	}
	var radix int
	switch t[1] {
	case 'x', 'X':
		radix = 16
	case 'o', 'O':
		radix = 8
	case 'b', 'B':
		radix = 2
	default:
		return 0, "", false
	}
	digits := t[2:]
	for i := 0; i < len(digits); i++ {
		if d := hexDigit(digits[i]); d < 0 || d >= radix {
			return 0, "", false
		}
	}
	return radix, digits, true
}

// parseIntTextWide reads the integer spellings the plain float parse does not -
// hex, octal, binary and quoted thousands - past the int64 range, as a double:
// a float read is bounded by the double, not by the integer type. A prefixed
// number goes in digit by digit in the double, so every binding rounds the
// same way; the spellings mirror parseIntText.
func parseIntTextWide(e *element) (float64, bool) {
	t := strings.TrimSpace(e.text)
	neg := false
	body := t
	if strings.HasPrefix(t, "-") {
		neg = true
		body = t[1:]
	} else if strings.HasPrefix(t, "+") {
		body = t[1:]
	}
	var v float64
	if radix, digits, ok := radixBody(body); ok {
		for i := 0; i < len(digits); i++ {
			v = v*float64(radix) + float64(hexDigit(digits[i]))
		}
	} else if e.quoted && strings.Contains(body, ",") {
		groups := strings.Split(body, ",")
		wellFormed := len(groups) > 1 && groups[0] != "" && len(groups[0]) <= 3 && allDigits(groups[0])
		if wellFormed {
			for _, g := range groups[1:] {
				if len(g) != 3 || !allDigits(g) {
					wellFormed = false
					break
				}
			}
		}
		if !wellFormed {
			return 0, false
		}
		f, err := strconv.ParseFloat(strings.ReplaceAll(body, ",", ""), 64)
		if err != nil {
			return 0, false
		}
		v = f
	} else {
		return 0, false
	}
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return 0, false
	}
	if neg {
		v = -v
	}
	return v, true
}

// hexDigit is the value of one ASCII hex digit, or -1.
func hexDigit(b byte) int {
	switch {
	case b >= '0' && b <= '9':
		return int(b - '0')
	case b >= 'a' && b <= 'f':
		return int(b-'a') + 10
	case b >= 'A' && b <= 'F':
		return int(b-'A') + 10
	}
	return -1
}

func parseBoolText(t string, level Strictness) (bool, bool) {
	s := asciiLower(strings.TrimSpace(t))
	switch s {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	if level == Strict {
		return false, false
	}
	switch s {
	case "yes", "on", "1":
		return true, true
	case "no", "off", "0":
		return false, true
	}
	if level == Loose {
		switch s {
		case "t", "y", "enable", "enabled":
			return true, true
		case "f", "n", "disable", "disabled":
			return false, true
		}
	}
	return false, false
}

// ---------------------------------------------------------------------------
// Durations and sizes: a number with a unit, or a bare number whose unit the
// field name or the caller gives
// ---------------------------------------------------------------------------

// DurationUnit is the unit a duration read gives a bare number, when the
// field name gives none. DurationNone asks for none. Smallest first.
type DurationUnit int

const (
	DurationNone DurationUnit = iota
	DurationMillis
	DurationSeconds
	DurationMinutes
	DurationHours
	DurationDays
)

func (u DurationUnit) millis() uint64 {
	switch u {
	case DurationMillis:
		return 1
	case DurationSeconds:
		return 1_000
	case DurationMinutes:
		return 60_000
	case DurationHours:
		return 3_600_000
	case DurationDays:
		return 86_400_000
	}
	return 0
}

// Spelling is the unit as a value has it: ms, s, m, h or d.
func (u DurationUnit) Spelling() string {
	switch u {
	case DurationMillis:
		return "ms"
	case DurationSeconds:
		return "s"
	case DurationMinutes:
		return "m"
	case DurationHours:
		return "h"
	case DurationDays:
		return "d"
	}
	return ""
}

// DurationUnitFromSpelling is the unit a value spelling names, lower case
// only; ok is false for anything else.
func DurationUnitFromSpelling(s string) (DurationUnit, bool) {
	switch s {
	case "ms":
		return DurationMillis, true
	case "s":
		return DurationSeconds, true
	case "m":
		return DurationMinutes, true
	case "h":
		return DurationHours, true
	case "d":
		return DurationDays, true
	}
	return DurationNone, false
}

// SizeUnit is the unit a size read gives a bare number, when the field name
// gives none. SizeNone asks for none. SizeKilo to SizeTera are powers of 1024
// unless the read asks for decimal; SizeKibi to SizeTebi always are.
type SizeUnit int

const (
	SizeNone SizeUnit = iota
	SizeBytes
	SizeKilo
	SizeMega
	SizeGiga
	SizeTera
	SizeKibi
	SizeMebi
	SizeGibi
	SizeTebi
)

func (u SizeUnit) bytes(decimal bool) uint64 {
	k := uint64(1024)
	if decimal {
		k = 1000
	}
	switch u {
	case SizeBytes:
		return 1
	case SizeKilo:
		return k
	case SizeMega:
		return k * k
	case SizeGiga:
		return k * k * k
	case SizeTera:
		return k * k * k * k
	case SizeKibi:
		return 1 << 10
	case SizeMebi:
		return 1 << 20
	case SizeGibi:
		return 1 << 30
	case SizeTebi:
		return 1 << 40
	}
	return 0
}

// Spelling is the unit as a value has it: B, KB, MB, GB, TB, KiB, MiB, GiB
// or TiB.
func (u SizeUnit) Spelling() string {
	switch u {
	case SizeBytes:
		return "B"
	case SizeKilo:
		return "KB"
	case SizeMega:
		return "MB"
	case SizeGiga:
		return "GB"
	case SizeTera:
		return "TB"
	case SizeKibi:
		return "KiB"
	case SizeMebi:
		return "MiB"
	case SizeGibi:
		return "GiB"
	case SizeTebi:
		return "TiB"
	}
	return ""
}

// SizeUnitFromSpelling is the unit a value spelling names. Letter case is
// read, since Mb is megabits to most readers; kB is the one other spelling
// taken.
func SizeUnitFromSpelling(s string) (SizeUnit, bool) {
	switch s {
	case "B":
		return SizeBytes, true
	case "KB", "kB":
		return SizeKilo, true
	case "MB":
		return SizeMega, true
	case "GB":
		return SizeGiga, true
	case "TB":
		return SizeTera, true
	case "KiB":
		return SizeKibi, true
	case "MiB":
		return SizeMebi, true
	case "GiB":
		return SizeGibi, true
	case "TiB":
		return SizeTebi, true
	}
	return SizeNone, false
}

// durationMaxMs is the longest duration a read gives, in milliseconds: Go's
// time.Duration range, so every binding holds every duration another reads.
const durationMaxMs = 9_223_372_036_854

// unitName is a field name ending and the unit it gives.
type unitName[U any] struct {
	end  string
	unit U
}

// durationNames are the field name endings that give a bare number its
// unit, after a `-` or `_`. min, m and s are left out: `retries-min` is a
// minimum, and a trailing s is usually a plural. A capitalized word
// (`timeoutMs`) is not a boundary, since names fold to lower case and fmt
// writes them folded.
var durationNames = []unitName[DurationUnit]{
	{"ms", DurationMillis}, {"sec", DurationSeconds}, {"seconds", DurationSeconds},
	{"minutes", DurationMinutes}, {"hours", DurationHours}, {"days", DurationDays},
}

var sizeNames = []unitName[SizeUnit]{
	{"bytes", SizeBytes}, {"kb", SizeKilo}, {"mb", SizeMega}, {"gb", SizeGiga}, {"tb", SizeTera},
	{"kib", SizeKibi}, {"mib", SizeMebi}, {"gib", SizeGibi}, {"tib", SizeTebi},
}

// nameUnit is the unit a field name ends in, from table: the ending, in any
// letter case, after a `-` or `_`. The zero unit, DurationNone or SizeNone,
// when it ends in none.
func nameUnit[U any](name string, table []unitName[U]) U {
	for _, e := range table {
		at := len(name) - len(e.end)
		if at > 0 && strings.EqualFold(name[at:], e.end) && (name[at-1] == '-' || name[at-1] == '_') {
			return e.unit
		}
	}
	var none U
	return none
}

// decimalAt reads a decimal number at the start of s: digits, then a point
// and more digits if there is a point. It returns the two digit runs and
// where the number ended.
func decimalAt(s string) (string, string, int, bool) {
	i := 0
	for i < len(s) && isASCIIDigit(s[i]) {
		i++
	}
	if i == 0 {
		return "", "", 0, false
	}
	if i >= len(s) || s[i] != '.' {
		return s[:i], "", i, true
	}
	j := i + 1
	for j < len(s) && isASCIIDigit(s[j]) {
		j++
	}
	if j == i+1 {
		return "", "", 0, false
	}
	return s[:i], s[i+1 : j], j, true
}

// scaled is int.frac times scale, exactly. ok is false when that is not a
// whole number or does not fit, so 1.5s is 1500 ms and 0.0001s is refused.
// At most 18 digits after the point count, which keeps the sum in 64 bits:
// the fraction's share is below scale, and dividing out their common factor
// first gets it without a wider product.
func scaled(intDigits, fracDigits string, scale uint64) (uint64, bool) {
	intDigits = strings.TrimLeft(intDigits, "0")
	fracDigits = strings.TrimRight(fracDigits, "0")
	if len(intDigits) > 19 || len(fracDigits) > 18 {
		return 0, false
	}
	var whole uint64
	if intDigits != "" {
		w, err := strconv.ParseUint(intDigits, 10, 64)
		if err != nil {
			return 0, false
		}
		whole = w
	}
	hi, total := bits.Mul64(whole, scale)
	if hi != 0 {
		return 0, false
	}
	if fracDigits != "" {
		part, err := strconv.ParseUint(fracDigits, 10, 64)
		if err != nil {
			return 0, false
		}
		den := uint64(1)
		for range fracDigits {
			den *= 10
		}
		a, b := scale, den
		for b != 0 {
			a, b = b, a%b
		}
		step := den / a
		if part%step != 0 {
			return 0, false
		}
		sum, carry := bits.Add64(total, part/step*(scale/a), 0)
		if carry != 0 {
			return 0, false
		}
		total = sum
	}
	return total, true
}

// parseDurationText is a duration in whole milliseconds, and the units the
// text used: parts such as `1h 30m`, largest unit first and each once,
// with blanks allowed between a number and its unit and between parts. A
// bare number takes bare, and is not ok without one. No sign.
func parseDurationText(t string, bare DurationUnit) (int64, []DurationUnit, bool) {
	t = trimWsp(t)
	if i, f, end, ok := decimalAt(t); ok && end == len(t) {
		if bare == DurationNone {
			return 0, nil, false
		}
		ms, ok := scaled(i, f, bare.millis())
		if !ok || ms > durationMaxMs {
			return 0, nil, false
		}
		return int64(ms), nil, true
	}
	rest := t
	var total uint64
	var units []DurationUnit
	for rest != "" {
		i, f, end, ok := decimalAt(rest)
		if !ok {
			return 0, nil, false
		}
		rest = strings.TrimLeftFunc(rest[end:], isWsp)
		n := 0
		for n < len(rest) && isASCIIAlpha(rest[n]) {
			n++
		}
		unit, ok := DurationUnitFromSpelling(rest[:n])
		if !ok || (len(units) > 0 && units[len(units)-1] <= unit) {
			return 0, nil, false
		}
		v, ok := scaled(i, f, unit.millis())
		if !ok {
			return 0, nil, false
		}
		sum, carry := bits.Add64(total, v, 0)
		if carry != 0 {
			return 0, nil, false
		}
		total = sum
		units = append(units, unit)
		rest = strings.TrimLeftFunc(rest[n:], isWsp)
	}
	if len(units) == 0 || total > durationMaxMs {
		return 0, nil, false
	}
	return int64(total), units, true
}

// parseSizeText is a size in whole bytes, and the unit the text used: a
// number, blanks allowed, then a unit. A bare number takes bare, and is not
// ok without one. No sign.
func parseSizeText(t string, bare SizeUnit, decimal bool) (int64, SizeUnit, bool) {
	t = trimWsp(t)
	i, f, end, ok := decimalAt(t)
	if !ok {
		return 0, SizeNone, false
	}
	rest := strings.TrimLeftFunc(t[end:], isWsp)
	unit := SizeNone
	if rest != "" {
		if unit, ok = SizeUnitFromSpelling(rest); !ok {
			return 0, SizeNone, false
		}
	}
	use := unit
	if use == SizeNone {
		use = bare
	}
	if use == SizeNone {
		return 0, SizeNone, false
	}
	n, ok := scaled(i, f, use.bytes(decimal))
	if !ok || n > math.MaxInt64 {
		return 0, SizeNone, false
	}
	return int64(n), unit, true
}

// unitNamed says whether a name ends in a duration or size unit. Asked before
// a value's text is built for unitClash, since most names do not.
func unitNamed(name string) bool {
	return nameUnit(name, durationNames) != DurationNone || nameUnit(name, sizeNames) != SizeNone
}

// unitClash is a value in another unit than the one its field name ends in
// (H005), as `timeout-ms: 5s`. The value's unit is the one read, so this is a
// hint.
func unitClash(name, text string) (string, bool) {
	said := func(v, n string) string {
		return "value is in " + v + " and the name says " + n + "; the value's unit is the one read"
	}
	if nu := nameUnit(name, durationNames); nu != DurationNone {
		if _, units, ok := parseDurationText(text, DurationNone); ok {
			has := false
			for _, u := range units {
				if u == nu {
					has = true
				}
			}
			if !has {
				return said(units[0].Spelling(), nu.Spelling()), true
			}
		}
	}
	if nu := nameUnit(name, sizeNames); nu != SizeNone {
		if _, vu, ok := parseSizeText(text, SizeNone, false); ok && vu != SizeNone && vu != nu {
			return said(vu.Spelling(), nu.Spelling()), true
		}
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Date/time (closed whitelist; shape match, then calendar validation)
// ---------------------------------------------------------------------------

var months = map[string]int{
	"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
	"jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
	"january": 1, "february": 2, "march": 3, "april": 4, "june": 6,
	"july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
}

func monthFromName(s string) (int, bool) {
	m, ok := months[asciiLower(s)]
	return m, ok
}

func daysInMonth(y, m int) int {
	switch m {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	case 2:
		if (y%4 == 0 && y%100 != 0) || y%400 == 0 {
			return 29
		}
		return 28
	}
	return 0
}

func validDate(y, m, d int) bool {
	return m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m)
}

// The Atoi error discards through this date cluster are safe: every input is
// length-bounded and allDigits-checked first, so Atoi cannot fail on it.
func parseYear4(s string) (int, bool) {
	if len(s) != 4 || !allDigits(s) {
		return 0, false
	}
	y, _ := strconv.Atoi(s)
	return y, true
}

func parseNum2(s string) (int, bool) {
	if (len(s) != 1 && len(s) != 2) || !allDigits(s) {
		return 0, false
	}
	n, _ := strconv.Atoi(s)
	return n, true
}

func parseDatePart(s string) (y, m, d int, ok bool) {
	s = strings.TrimSpace(s)
	// Compact 8-digit YYYYMMDD.
	if len(s) == 8 && allDigits(s) {
		y, _ = strconv.Atoi(s[:4])
		m, _ = strconv.Atoi(s[4:6])
		d, _ = strconv.Atoi(s[6:8])
		if validDate(y, m, d) {
			return y, m, d, true
		}
		return 0, 0, 0, false
	}
	// Space-separated named-month forms; a comma may follow the day in "Mon DD, YYYY".
	toks := strings.Fields(s)
	if len(toks) == 3 {
		if mo, found := monthFromName(toks[0]); found {
			// The day is DD, like every other form's: a plain integer parse
			// takes a leading '+' and any number of leading zeros, which the
			// whitelist does not list and the delimited spellings refuse.
			dv, ok1 := parseNum2(strings.TrimSuffix(toks[1], ","))
			yv, ok2 := parseYear4(toks[2])
			if ok1 && ok2 && validDate(yv, mo, dv) {
				return yv, mo, dv, true
			}
			return 0, 0, 0, false
		}
		if mo, found := monthFromName(toks[1]); found {
			dv, ok1 := parseNum2(toks[0])
			yv, ok2 := parseYear4(toks[2])
			if ok1 && ok2 && validDate(yv, mo, dv) {
				return yv, mo, dv, true
			}
			return 0, 0, 0, false
		}
		return 0, 0, 0, false
	}
	if len(toks) != 1 {
		return 0, 0, 0, false
	}
	// Delimited forms: one of - / . used uniformly.
	var delim byte
	nDelims := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '-' || s[i] == '/' || s[i] == '.' {
			if delim == 0 {
				delim = s[i]
			}
			nDelims++
		}
	}
	if delim == 0 {
		return 0, 0, 0, false
	}
	parts := strings.Split(s, string(rune(delim)))
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return 0, 0, 0, false
	}
	// The delimiter must be uniform: no other delimiter chars anywhere.
	if nDelims != 2 {
		return 0, 0, 0, false
	}
	if len(parts[0]) == 4 && allDigits(parts[0]) {
		// Year-first all-numeric.
		y, _ = strconv.Atoi(parts[0])
		mv, ok1 := parseNum2(parts[1])
		dv, ok2 := parseNum2(parts[2])
		if ok1 && ok2 && validDate(y, mv, dv) {
			return y, mv, dv, true
		}
		return 0, 0, 0, false
	}
	if mo, found := monthFromName(parts[0]); found {
		dv, ok1 := parseNum2(parts[1])
		yv, ok2 := parseYear4(parts[2])
		if ok1 && ok2 && validDate(yv, mo, dv) {
			return yv, mo, dv, true
		}
		return 0, 0, 0, false
	}
	if mo, found := monthFromName(parts[1]); found {
		dv, ok1 := parseNum2(parts[0])
		yv, ok2 := parseYear4(parts[2])
		if ok1 && ok2 && validDate(yv, mo, dv) {
			return yv, mo, dv, true
		}
		return 0, 0, 0, false
	}
	return 0, 0, 0, false // everything else (MM/DD/YYYY, 2-digit years, epoch) is rejected by decision
}

// parseTimePart: time with optional meridiem, fraction, zone:
// `H:MM[:SS[.f+]][ AM|PM][Z|+HH:MM]`.
func parseTimePart(s string) (h, mi, sec int, hasSec bool, frac string, zone *Zone, ok bool) {
	t := strings.TrimSpace(s)
	// Zone suffix first (only valid after a time).
	if rest, cut := strings.CutSuffix(t, "Z"); cut {
		zone = &Zone{Kind: ZoneUTC}
		t = trimEndWS(rest)
	} else if rest, cut := strings.CutSuffix(t, "z"); cut {
		zone = &Zone{Kind: ZoneUTC}
		t = trimEndWS(rest)
	} else if len(t) >= 6 {
		tail := t[len(t)-6:]
		sign := tail[0]
		if (sign == '+' || sign == '-') &&
			isASCIIDigit(tail[1]) && isASCIIDigit(tail[2]) && tail[3] == ':' &&
			isASCIIDigit(tail[4]) && isASCIIDigit(tail[5]) {
			hh := int(tail[1]-'0')*10 + int(tail[2]-'0')
			mm := int(tail[4]-'0')*10 + int(tail[5]-'0')
			if hh <= 23 && mm <= 59 {
				off := hh*60 + mm
				if sign == '-' {
					off = -off
				}
				zone = &Zone{Kind: ZoneOffset, OffsetMinutes: off}
				t = trimEndWS(t[:len(t)-6])
			}
		}
	}
	// Meridiem: mandatory minutes already implied by the H:MM shape; dotted
	// a.m. is rejected (the '.' fails the digit checks below).
	var meridiem *bool // nil = none, otherwise true = PM
	lower := asciiLower(t)
	if rest, cut := strings.CutSuffix(lower, "am"); cut {
		am := false
		meridiem = &am
		t = t[:len(trimEndWS(rest))]
	} else if rest, cut := strings.CutSuffix(lower, "pm"); cut {
		pm := true
		meridiem = &pm
		t = t[:len(trimEndWS(rest))]
	}
	t = trimEndWS(t)
	// Fraction: only after seconds, '.' delimiter, 1-9 digits.
	hms := t
	if idx := strings.IndexByte(t, '.'); idx >= 0 {
		f := t[idx+1:]
		if f == "" || len(f) > 9 || !allDigits(f) {
			return 0, 0, 0, false, "", nil, false
		}
		frac = f
		hms = t[:idx]
	}
	parts := strings.Split(hms, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, 0, 0, false, "", nil, false
	}
	if frac != "" && len(parts) != 3 {
		return 0, 0, 0, false, "", nil, false // fraction can only follow HH:MM:SS
	}
	hRaw, ok1 := parseNum2(parts[0])
	if !ok1 {
		return 0, 0, 0, false, "", nil, false
	}
	if len(parts[1]) != 2 {
		return 0, 0, 0, false, "", nil, false
	}
	mi, ok1 = parseNum2(parts[1])
	if !ok1 {
		return 0, 0, 0, false, "", nil, false
	}
	if len(parts) == 3 {
		if len(parts[2]) != 2 {
			return 0, 0, 0, false, "", nil, false
		}
		sec, ok1 = parseNum2(parts[2])
		if !ok1 {
			return 0, 0, 0, false, "", nil, false
		}
		hasSec = true
	}
	if mi > 59 || (hasSec && sec > 59) {
		return 0, 0, 0, false, "", nil, false
	}
	if meridiem == nil {
		if hRaw > 23 {
			return 0, 0, 0, false, "", nil, false
		}
		h = hRaw
	} else {
		if hRaw < 1 || hRaw > 12 {
			return 0, 0, 0, false, "", nil, false
		}
		switch {
		case !*meridiem && hRaw == 12:
			h = 0
		case !*meridiem:
			h = hRaw
		case hRaw == 12:
			h = 12
		default:
			h = hRaw + 12
		}
	}
	return h, mi, sec, hasSec, frac, zone, true
}

// datetimeReadsBack reports whether a datetime's canonical spelling reads
// back as the same value: the setter's inverse-of-the-read promise, checked
// by making the round trip.
func datetimeReadsBack(v DateTime) bool {
	back, ok := ParseDateTime(v.String())
	if !ok || (v.Zone == nil) != (back.Zone == nil) || (v.Zone != nil && *v.Zone != *back.Zone) {
		return false
	}
	v.Zone, back.Zone = nil, nil
	return v == back
}

// ParseDateTime is the whole-value date/time parse per the whitelist.
// ok=false means BadType.
func ParseDateTime(text string) (DateTime, bool) {
	t := strings.TrimSpace(text)
	if t == "" {
		return DateTime{}, false
	}
	if colon := strings.IndexByte(t, ':'); colon >= 0 {
		// Scan back over the 1-2 hour digits to find where the time starts.
		k := colon
		for k > 0 && isASCIIDigit(t[k-1]) && colon-k < 2 {
			k--
		}
		if k == colon {
			return DateTime{}, false // ':' with no hour digits before it
		}
		if k == 0 {
			// Time-only value.
			h, mi, sec, hasSec, frac, zone, ok := parseTimePart(t)
			if !ok {
				return DateTime{}, false
			}
			return DateTime{HasTime: true, Hour: h, Minute: mi, HasSeconds: hasSec, Second: sec, Frac: frac, Zone: zone}, true
		}
		// Combined: one separator char between date and time.
		sep, sepLen := utf8.DecodeLastRuneInString(t[:k])
		switch sep {
		case 'T', 't', ' ', '_', '-', '/', '.':
		default:
			return DateTime{}, false
		}
		y, mo, d, okd := parseDatePart(t[:k-sepLen])
		if !okd {
			return DateTime{}, false
		}
		h, mi, sec, hasSec, frac, zone, ok := parseTimePart(t[k:])
		if !ok {
			return DateTime{}, false
		}
		return DateTime{
			HasDate: true, Year: y, Month: mo, Day: d,
			HasTime: true, Hour: h, Minute: mi, HasSeconds: hasSec, Second: sec,
			Frac: frac, Zone: zone,
		}, true
	}
	// Date-only.
	y, mo, d, ok := parseDatePart(t)
	if !ok {
		return DateTime{}, false
	}
	return DateTime{HasDate: true, Year: y, Month: mo, Day: d}, true
}

// ---------------------------------------------------------------------------
// Accessor: typed reads
// ---------------------------------------------------------------------------

// nodeAt returns the single node at a path, or the failing status.
func (d *Document) nodeAt(path string) (int, Status) {
	r, ok := d.resolve(path)
	if !ok {
		return -1, NotFound
	}
	switch r.kind {
	case resNone:
		return -1, NotFound
	case resMany, resSlots:
		return -1, Multiple
	}
	return r.one, Good
}

// rawOf is a read's Raw: the verbatim source value text when the value came
// from one source line, else the display form (writer-built, stacked list, raw
// block - shapes with no one-line source spelling).
func (d *Document) rawOf(n int) string {
	if s := d.arena[n].src; s != nil {
		return *s
	}
	return d.arena[n].value.display()
}

func scalarElement(v *value) (*element, Status) {
	switch {
	case v.kind == vEmpty:
		return nil, Empty
	case v.kind == vRaw:
		return nil, BadType
	case len(v.els) == 1:
		return &v.els[0], Good
	}
	return nil, BadType // an array is not one scalar
}

func readScalar[T any](d *Document, path string, coerce func(*element) (T, bool)) Read[T] {
	var zero T
	n, st := d.nodeAt(path)
	if n < 0 {
		return Read[T]{Value: zero, Status: st}
	}
	v := &d.arena[n].value
	raw := d.rawOf(n)
	line := d.arena[n].line
	el, est := scalarElement(v)
	if el == nil {
		return Read[T]{Value: zero, Status: est, Raw: &raw}.at(line, false)
	}
	if val, ok := coerce(el); ok {
		return Read[T]{Value: val, Status: Good, Raw: &raw}.at(line, el.quoted)
	}
	return Read[T]{Value: zero, Status: BadType, Raw: &raw}.at(line, el.quoted)
}

// ReadInt is the full-tier integer read at path, coerced per the document's strictness.
func (d *Document) ReadInt(path string) Read[int64] {
	lvl := d.strictness
	return readScalar(d, path, func(e *element) (int64, bool) { return parseIntText(e, lvl) })
}

// ReadFloat is the full-tier float read at path, coerced per the document's strictness.
func (d *Document) ReadFloat(path string) Read[float64] {
	lvl := d.strictness
	return readScalar(d, path, func(e *element) (float64, bool) { return parseFloatText(e, lvl) })
}

// ReadBool is the full-tier bool read at path, coerced per the document's strictness.
func (d *Document) ReadBool(path string) Read[bool] {
	lvl := d.strictness
	return readScalar(d, path, func(e *element) (bool, bool) { return parseBoolText(e.text, lvl) })
}

// ReadDateTime is the full-tier datetime read at path.
func (d *Document) ReadDateTime(path string) Read[DateTime] {
	return readScalar(d, path, func(e *element) (DateTime, bool) { return ParseDateTime(e.text) })
}

// readNamed is readScalar with the node's name, for the reads whose bare
// number takes its unit from the name.
func readNamed[T any](d *Document, path string, coerce func(*element, string) (T, bool)) Read[T] {
	n, st := d.nodeAt(path)
	if n < 0 {
		var zero T
		return Read[T]{Value: zero, Status: st}
	}
	name := d.arena[n].name
	return readScalar(d, path, func(e *element) (T, bool) { return coerce(e, name) })
}

// ReadDuration is the full-tier duration read at path, in whole milliseconds:
// `500ms`, `30s`, `1h 30m`, `2d`. A bare number takes its unit from the field
// name when the name ends in one (`timeout-ms`, `delay_seconds`), else from
// unit, and is BadType with neither.
func (d *Document) ReadDuration(path string, unit DurationUnit) Read[time.Duration] {
	return readNamed(d, path, func(e *element, name string) (time.Duration, bool) {
		bare := nameUnit(name, durationNames)
		if bare == DurationNone {
			bare = unit
		}
		ms, _, ok := parseDurationText(e.text, bare)
		return time.Duration(ms) * time.Millisecond, ok
	})
}

// ReadSize is the full-tier size read at path, in whole bytes: `512MB`,
// `1.5 GiB`. A bare number takes its unit the way a duration does. KB to TB
// are powers of 1024 unless decimal is set.
func (d *Document) ReadSize(path string, unit SizeUnit, decimal bool) Read[int64] {
	return readNamed(d, path, func(e *element, name string) (int64, bool) {
		bare := nameUnit(name, sizeNames)
		if bare == SizeNone {
			bare = unit
		}
		n, _, ok := parseSizeText(e.text, bare, decimal)
		return n, ok
	})
}

// ReadString reads any value as a string: a raw block yields its content, an
// array its canonical inline text. Escapes are applied.
func (d *Document) ReadString(path string) Read[string] {
	n, st := d.nodeAt(path)
	if n < 0 {
		return Read[string]{Status: st}
	}
	v := &d.arena[n].value
	raw := d.rawOf(n)
	line := d.arena[n].line
	switch {
	case v.kind == vEmpty:
		return Read[string]{Status: Empty, Raw: &raw}.at(line, false)
	case v.kind == vRaw:
		return Read[string]{Value: v.raw.content, Status: Good, Raw: &raw}.at(line, false)
	case len(v.els) == 1:
		return Read[string]{Value: v.els[0].text, Status: Good, Raw: &raw}.at(line, v.els[0].quoted)
	}
	// Canonical inline form (quoting + escapes intact), so the string
	// re-parses to the same array - not the bare display join.
	parts := make([]string, len(v.els))
	for k := range v.els {
		parts[k] = emitElement(&v.els[k])
	}
	return Read[string]{Value: strings.Join(parts, ", "), Status: Good, Raw: &raw}.at(line, false)
}

// ReadRaw reads raw-block content verbatim. Non-block values are BadType.
func (d *Document) ReadRaw(path string) Read[string] {
	n, st := d.nodeAt(path)
	if n < 0 {
		return Read[string]{Status: st}
	}
	v := &d.arena[n].value
	raw := d.rawOf(n)
	line := d.arena[n].line
	switch v.kind {
	case vRaw:
		return Read[string]{Value: v.raw.content, Status: Good, Raw: &raw}.at(line, false)
	case vEmpty:
		return Read[string]{Status: Empty, Raw: &raw}.at(line, false)
	}
	return Read[string]{Status: BadType, Raw: &raw}.at(line, false)
}

// ReadRawInfo reads the advisory info-string of a raw block ("" when absent).
func (d *Document) ReadRawInfo(path string) Read[string] {
	n, st := d.nodeAt(path)
	if n < 0 {
		return Read[string]{Status: st}
	}
	v := &d.arena[n].value
	raw := d.rawOf(n)
	line := d.arena[n].line
	// An empty binding has no block, so no info string: `Empty`, the same as a `read_raw` on it. Only a value that is there and is not a block is a type mismatch.
	if v.kind == vRaw {
		return Read[string]{Value: v.raw.info, Status: Good, Raw: &raw}.at(line, false)
	}
	if v.kind == vEmpty {
		return Read[string]{Status: Empty, Raw: &raw}.at(line, false)
	}
	return Read[string]{Status: BadType, Raw: &raw}.at(line, false)
}

func readArray[T any](d *Document, path string, coerce func(*element) (T, bool)) Read[[]T] {
	var zero T
	// Wildcard paths: one slot per instance, missing sub-paths keep their slot
	// (spec: never silently dropped). Each slot reads like a scalar of the
	// target type and records its own status; the aggregate is the worst one.
	r, ok := d.resolve(path)
	if !ok {
		return Read[[]T]{Value: []T{}, Status: NotFound}
	}
	switch r.kind {
	case resSlots:
		out := make([]T, 0, len(r.slots))
		sts := make([]Status, 0, len(r.slots))
		for _, slot := range r.slots {
			if slot == -1 {
				out = append(out, zero)
				sts = append(sts, NotFound)
				continue
			}
			if slot < 0 {
				out = append(out, zero)
				sts = append(sts, Multiple)
				continue
			}
			el, est := scalarElement(&d.arena[slot].value)
			if el == nil {
				out = append(out, zero)
				sts = append(sts, est)
				continue
			}
			val, cst := coerced(coerce, el)
			out = append(out, val)
			sts = append(sts, cst)
		}
		// No slots at all means the wildcard's parent is not there, so the
		// path did not resolve - Empty is for a node that is.
		status := NotFound
		if len(sts) > 0 {
			status = Good
			for _, s := range sts {
				if s > status {
					status = s
				}
			}
		}
		return Read[[]T]{Value: out, Status: status, Slots: sts}
	case resNone:
		return Read[[]T]{Value: []T{}, Status: NotFound}
	case resMany:
		return Read[[]T]{Value: []T{}, Status: Multiple}
	}
	v := &d.arena[r.one].value
	raw := d.rawOf(r.one)
	line := d.arena[r.one].line
	switch v.kind {
	case vEmpty:
		return Read[[]T]{Value: []T{}, Status: Empty, Raw: &raw}.at(line, false)
	case vRaw:
		return Read[[]T]{Value: []T{}, Status: BadType, Raw: &raw}.at(line, false)
	}
	out := make([]T, 0, len(v.els))
	sts := make([]Status, 0, len(v.els))
	status := Good
	for i := range v.els {
		val, cst := coerced(coerce, &v.els[i])
		out = append(out, val)
		sts = append(sts, cst)
		if cst > status {
			status = cst
		}
	}
	// A one-element cell has a single scalar element, so the flag means the
	// same thing here as on the scalar read of the same node.
	return Read[[]T]{Value: out, Status: status, Raw: &raw, Slots: sts}.at(line, len(v.els) == 1 && v.els[0].quoted)
}

// ReadIntArray is the full-tier integer-array read at path (per-slot statuses in Slots).
func (d *Document) ReadIntArray(path string) Read[[]int64] {
	lvl := d.strictness
	return readArray(d, path, func(e *element) (int64, bool) { return parseIntText(e, lvl) })
}

// ReadFloatArray is the full-tier float-array read at path.
func (d *Document) ReadFloatArray(path string) Read[[]float64] {
	lvl := d.strictness
	return readArray(d, path, func(e *element) (float64, bool) { return parseFloatText(e, lvl) })
}

// ReadBoolArray is the full-tier bool-array read at path.
func (d *Document) ReadBoolArray(path string) Read[[]bool] {
	lvl := d.strictness
	return readArray(d, path, func(e *element) (bool, bool) { return parseBoolText(e.text, lvl) })
}

// ReadDateTimeArray is the full-tier datetime-array read at path.
func (d *Document) ReadDateTimeArray(path string) Read[[]DateTime] {
	return readArray(d, path, func(e *element) (DateTime, bool) { return ParseDateTime(e.text) })
}

// ReadStringArray is the full-tier string-array read at path, escapes applied per element.
func (d *Document) ReadStringArray(path string) Read[[]string] {
	return readArray(d, path, func(e *element) (string, bool) { return e.text, true })
}

// Full tier, status form: the value is only meaningful when the status is
// Good. Empty still comes back as non-Good here; use Read* to also get the
// empty value.

// GetInt is ReadInt reduced to (value, status).
func (d *Document) GetInt(path string) (int64, Status) {
	r := d.ReadInt(path)
	return r.Value, r.Status
}

// GetFloat is ReadFloat reduced to (value, status).
func (d *Document) GetFloat(path string) (float64, Status) {
	r := d.ReadFloat(path)
	return r.Value, r.Status
}

// GetBool is ReadBool reduced to (value, status).
func (d *Document) GetBool(path string) (bool, Status) {
	r := d.ReadBool(path)
	return r.Value, r.Status
}

// GetString is ReadString reduced to (value, status).
func (d *Document) GetString(path string) (string, Status) {
	r := d.ReadString(path)
	return r.Value, r.Status
}

// GetRaw is ReadRaw reduced to (value, status).
func (d *Document) GetRaw(path string) (string, Status) {
	r := d.ReadRaw(path)
	return r.Value, r.Status
}

// GetRawInfo is ReadRawInfo reduced to (value, status).
func (d *Document) GetRawInfo(path string) (string, Status) {
	r := d.ReadRawInfo(path)
	return r.Value, r.Status
}

// GetDateTime is ReadDateTime reduced to (value, status).
func (d *Document) GetDateTime(path string) (DateTime, Status) {
	r := d.ReadDateTime(path)
	return r.Value, r.Status
}

// GetDuration is ReadDuration reduced to (value, status).
func (d *Document) GetDuration(path string, unit DurationUnit) (time.Duration, Status) {
	r := d.ReadDuration(path, unit)
	return r.Value, r.Status
}

// GetSize is ReadSize reduced to (value, status).
func (d *Document) GetSize(path string, unit SizeUnit, decimal bool) (int64, Status) {
	r := d.ReadSize(path, unit, decimal)
	return r.Value, r.Status
}

// The array forms of the same reduction. The status is the whole read's, so a
// partially-resolved array reports non-Good with the resolved slots still in
// the value; the per-slot statuses are the Read*Array tier's Slots.

// GetIntArray is ReadIntArray reduced to (value, status).
func (d *Document) GetIntArray(path string) ([]int64, Status) {
	r := d.ReadIntArray(path)
	return r.Value, r.Status
}

// GetFloatArray is ReadFloatArray reduced to (value, status).
func (d *Document) GetFloatArray(path string) ([]float64, Status) {
	r := d.ReadFloatArray(path)
	return r.Value, r.Status
}

// GetBoolArray is ReadBoolArray reduced to (value, status).
func (d *Document) GetBoolArray(path string) ([]bool, Status) {
	r := d.ReadBoolArray(path)
	return r.Value, r.Status
}

// GetStringArray is ReadStringArray reduced to (value, status).
func (d *Document) GetStringArray(path string) ([]string, Status) {
	r := d.ReadStringArray(path)
	return r.Value, r.Status
}

// GetDateTimeArray is ReadDateTimeArray reduced to (value, status).
func (d *Document) GetDateTimeArray(path string) ([]DateTime, Status) {
	r := d.ReadDateTimeArray(path)
	return r.Value, r.Status
}

// Convenience tier: one value, one call-site fallback, no status to inspect.
// The fallback is returned unless the read is Good (matching the reference's
// get_int(path).unwrap_or(def)), so an empty/missing/bad/ambiguous read can
// never masquerade as a real zero. Array forms fall back to the whole default
// array; per-slot substitution is the ReadIntArray tier or the CLI --default.

// GetIntOr is the integer at path, or def when the read is not Good.
func (d *Document) GetIntOr(path string, def int64) int64 {
	if r := d.ReadInt(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetFloatOr is the float at path, or def when the read is not Good.
func (d *Document) GetFloatOr(path string, def float64) float64 {
	if r := d.ReadFloat(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetBoolOr is the bool at path, or def when the read is not Good.
func (d *Document) GetBoolOr(path string, def bool) bool {
	if r := d.ReadBool(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetStringOr is the string at path, or def when the read is not Good.
func (d *Document) GetStringOr(path string, def string) string {
	if r := d.ReadString(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetRawOr is the raw-block content at path, or def when the read is not Good.
func (d *Document) GetRawOr(path string, def string) string {
	if r := d.ReadRaw(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetRawInfoOr is the raw block's info-string at path, or def when the read is
// not Good.
func (d *Document) GetRawInfoOr(path string, def string) string {
	if r := d.ReadRawInfo(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetDateTimeOr is the datetime at path, or def when the read is not Good.
func (d *Document) GetDateTimeOr(path string, def DateTime) DateTime {
	if r := d.ReadDateTime(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetDurationOr is the duration at path, or def when the read is not Good.
func (d *Document) GetDurationOr(path string, unit DurationUnit, def time.Duration) time.Duration {
	if r := d.ReadDuration(path, unit); r.Status == Good {
		return r.Value
	}
	return def
}

// GetSizeOr is the size at path, or def when the read is not Good.
func (d *Document) GetSizeOr(path string, unit SizeUnit, decimal bool, def int64) int64 {
	if r := d.ReadSize(path, unit, decimal); r.Status == Good {
		return r.Value
	}
	return def
}

// GetIntArrayOr is the integer array at path, or def when the read is not Good.
func (d *Document) GetIntArrayOr(path string, def []int64) []int64 {
	if r := d.ReadIntArray(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetFloatArrayOr is the float array at path, or def when the read is not Good.
func (d *Document) GetFloatArrayOr(path string, def []float64) []float64 {
	if r := d.ReadFloatArray(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetBoolArrayOr is the bool array at path, or def when the read is not Good.
func (d *Document) GetBoolArrayOr(path string, def []bool) []bool {
	if r := d.ReadBoolArray(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetStringArrayOr is the string array at path, or def when the read is not Good.
func (d *Document) GetStringArrayOr(path string, def []string) []string {
	if r := d.ReadStringArray(path); r.Status == Good {
		return r.Value
	}
	return def
}

// GetDateTimeArrayOr is the datetime array at path, or def when the read is not Good.
func (d *Document) GetDateTimeArrayOr(path string, def []DateTime) []DateTime {
	if r := d.ReadDateTimeArray(path); r.Status == Good {
		return r.Value
	}
	return def
}

// ---------------------------------------------------------------------------
// Validator: schema-as-SHCL
// ---------------------------------------------------------------------------
// The schema is an ordinary parsed document: a flat list of `field: <path>`
// instances whose children are the constraints (closed vocabulary - see
// spec.md "Schema validation"). Validation reuses the accessor's path scan and
// the typed coercions, so document strictness composes for free. Schema faults
// (V09x) come first and the surviving constraints still check the document;
// the unknown-field sweep skips only when a fault cost a path spelling. One
// line-number space per result.

var schemaTypes = []string{
	"int",
	"float",
	"bool",
	"string",
	"datetime",
	"raw",
	"duration",
	"size",
	"int-array",
	"float-array",
	"bool-array",
	"string-array",
	"datetime-array",
}

type allowedKind int

const (
	allowInts allowedKind = iota
	allowFloats
	allowBools
	allowDates
	allowStrings
)

// The allowed set, pre-coerced at schema-build time into the constraint's type
// space so per-node checks are a plain contains.
type allowedSet struct {
	kind   allowedKind
	ints   []int64
	floats []float64
	bools  []bool
	dates  []DateTime
	strs   []string
}

type constraint struct {
	path     string // as written in the schema; message text only
	segs     []segment
	ty       string // member of schemaTypes; "" = untyped
	required bool
	allowed  *allowedSet
	minI     *int64
	maxI     *int64
	minF     *float64
	maxF     *float64
	// duration and size: the unit a bare number takes when the field name
	// gives none, base 10 for KB to TB, and the bounds as the schema wrote
	// them, since minI and maxI hold them in milliseconds or bytes.
	unitD        DurationUnit
	unitS        SizeUnit
	decimal      bool
	minText      *string
	maxText      *string
	repeat       *[2]uint64
	reopen       bool   // H002 suppressor only; validation ignores it
	inherits     string // fragment mounted at this path (subtree shape); "" = none
	inheritsLine int    // schema line of the `inherits` key, for V095
	// Generator-only (`shcl init`): validation ignores both.
	desc        *string // `desc`, a one-line description
	defaultText *string // `default`, emitted as an inline value
}

// An interpreted schema: the top-level constraints plus the named fragments
// their `inherits` keys can mount.
type schemaDef struct {
	cons  []constraint
	frags map[string][]constraint
	// False when a fault cost the schema a path spelling (unreadable `field:`
	// path, or a mount naming no declared fragment). Key-level faults keep
	// their entry's chain, so only these two classes can turn declared fields
	// into false unknowns - the sweep runs unless one of them happened.
	pathsComplete bool
}

// coerced is one slot of an array read: the coerced value, or the type's zero
// with BadType.
func coerced[T any](coerce func(*element) (T, bool), el *element) (T, Status) {
	if v, ok := coerce(el); ok {
		return v, Good
	}
	var zero T
	return zero, BadType
}

func vdiag(out *[]Diagnostic, line int, code, msg string) {
	*out = append(*out, Diagnostic{Line: line, Severity: SeverityError, Message: msg, Code: code})
}

// singleText is one scalar constraint value (escapes applied), or not.
func singleText(v *value) (string, bool) {
	if v.kind == vCell && len(v.els) == 1 {
		return v.els[0].text, true
	}
	return "", false
}

// sameMoment reports two datetimes naming the same moment, whatever the
// spelling. The struct mirrors what was written, so 12:00:00Z and
// 12:00:00+00:00 are different values field by field while naming one time, and
// 12:00:00 and 12:00:00.0 differ only in written precision. A [value] selector
// matches on text, but an allowed set is about the value, so it compares here.
// An absent zone is local and matches no zone at all - that is the one spelling
// difference that is a real difference.
func sameMoment(a, b DateTime) bool {
	offset := func(z *Zone) (int, bool) {
		if z == nil {
			return 0, false
		}
		if z.Kind == ZoneUTC {
			return 0, true
		}
		return z.OffsetMinutes, true
	}
	ao, ahas := offset(a.Zone)
	bo, bhas := offset(b.Zone)
	if ahas != bhas || a.HasDate != b.HasDate || a.HasTime != b.HasTime {
		return false
	}
	if a.HasSeconds != b.HasSeconds || a.Second != b.Second {
		return false
	}
	if strings.TrimRight(a.Frac, "0") != strings.TrimRight(b.Frac, "0") {
		return false
	}
	if !ahas {
		a.Zone, b.Zone = nil, nil
		a.Frac, b.Frac = "", ""
		return a == b
	}
	// Zoned values are instants: the written clock less its offset, the date
	// carrying the day wrap. A time alone lives on a 24-hour cycle.
	minutes := func(dt DateTime, off int) int64 {
		hm := int64(dt.Hour*60 + dt.Minute - off)
		if dt.HasDate {
			return daysFromCivil(dt.Year, dt.Month, dt.Day)*1440 + hm
		}
		return ((hm % 1440) + 1440) % 1440
	}
	return minutes(a, ao) == minutes(b, bo)
}

// daysFromCivil is the day count since 1970-01-01, negative before it.
func daysFromCivil(y, m, d int) int64 {
	if m <= 2 {
		y--
	}
	yy := int64(y)
	era := yy / 400
	if yy < 0 && yy%400 != 0 {
		era--
	}
	yoe := yy - era*400
	doy := (153*int64((m+9)%12)+2)/5 + int64(d) - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// buildSchema interprets a parsed schema document into constraints and
// fragments, plus any schema faults (V09x, schema-file lines). Whatever parsed
// cleanly is kept even when faults are present - a broken key drops that key,
// a broken field drops that field - so a caller can still check the document
// against the surviving constraints.
func buildSchema(schema *Document) (schemaDef, []Diagnostic) {
	var faults []Diagnostic
	var cons []constraint
	frags := map[string][]constraint{}
	pathsComplete := true
	for _, f := range schema.arena[root].children {
		node := &schema.arena[f]
		switch node.name {
		case "field":
			if c, ok := parseField(schema, f, &faults); ok {
				cons = append(cons, c)
			} else {
				pathsComplete = false
			}
		case "fragment":
			name, ok := singleText(&node.value)
			if !ok || name == "" {
				vdiag(&faults, node.line, "V094", "bad schema fragment")
				continue
			}
			// Two `fragment` blocks of one name never reach here: the parse
			// merges them into one node and reports H002. Kept as a guard in
			// case that changes, which is why no case pins it.
			if _, dup := frags[name]; dup {
				vdiag(&faults, node.line, "V094", fmt.Sprintf("bad schema fragment '%s': duplicate", diagName(name)))
				continue
			}
			var fcs []constraint
			for _, k := range schema.arena[f].children {
				kid := &schema.arena[k]
				if kid.name == "field" {
					if c, ok := parseField(schema, k, &faults); ok {
						fcs = append(fcs, c)
					} else {
						pathsComplete = false
					}
				} else {
					vdiag(&faults, kid.line, "V094", fmt.Sprintf("bad schema fragment '%s': unknown key '%s'", diagName(name), diagName(kid.name)))
				}
			}
			frags[name] = fcs
		default:
			vdiag(&faults, node.line, "V090", fmt.Sprintf("unknown schema key '%s'", diagName(node.name)))
		}
	}
	// Every mount must name a declared fragment; cycles (self or mutual) are
	// legal - expansion is demand-driven against a finite document.
	checkMount := func(c *constraint) {
		if c.inherits == "" {
			return
		}
		if _, ok := frags[c.inherits]; !ok {
			vdiag(&faults, c.inheritsLine, "V095", fmt.Sprintf("unknown schema fragment '%s'", diagName(c.inherits)))
			pathsComplete = false
		}
	}
	for i := range cons {
		checkMount(&cons[i])
	}
	for _, fcs := range frags {
		for i := range fcs {
			checkMount(&fcs[i])
		}
	}
	// One constraint per line in practice, so line order = file order.
	sort.SliceStable(faults, func(i, j int) bool { return faults[i].Line < faults[j].Line })
	return schemaDef{cons: cons, frags: frags, pathsComplete: pathsComplete}, faults
}

// parseField turns one `field:` instance (top-level or inside a fragment) into
// a constraint. ok=false = faults were reported and the constraint is dropped.
func parseField(schema *Document, f int, faults *[]Diagnostic) (constraint, bool) {
	node := &schema.arena[f]
	path, ok := singleText(&node.value)
	if !ok {
		vdiag(faults, node.line, "V093", "bad schema path")
		return constraint{}, false
	}
	scan, err := scanLookup(path)
	if err != nil || scan.hasValue {
		vdiag(faults, node.line, "V093", fmt.Sprintf("bad schema path: %s", schemaText(path)))
		return constraint{}, false
	}
	c := constraint{path: path, segs: scan.segments}
	// Deferred so `min: 1` may precede `type: int` in the file.
	var required *bool
	reopenSeen := false
	allowedAt := -1
	defaultAt := -1
	minAt := -1
	maxAt := -1
	unitAt := -1
	decimalKeyAt := -1
	for _, k := range schema.arena[f].children {
		kid := &schema.arena[k]
		if kid.value.isEmpty() {
			continue // dangling key: treated as absent
		}
		switch kid.name {
		case "type":
			t, ok := singleText(&kid.value)
			if ok {
				t = asciiLower(t)
			}
			switch {
			case ok && containsString(schemaTypes, t):
				if c.ty != "" {
					vdiag(faults, kid.line, "V092", "bad schema constraint 'type'")
				} else {
					c.ty = t
				}
			case ok:
				vdiag(faults, kid.line, "V091", fmt.Sprintf("unknown schema type '%s'", schemaText(t)))
			default:
				vdiag(faults, kid.line, "V092", "bad schema constraint 'type'")
			}
		case "required":
			t, ok := singleText(&kid.value)
			var b bool
			if ok {
				b, ok = parseBoolText(t, Standard)
			}
			if ok && required == nil {
				required = &b
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'required'")
			}
		// Consumed by the H002 suppressor; validation itself ignores it, but
		// a bad value still faults so a typo cannot silently disavow nothing.
		case "reopen":
			t, ok := singleText(&kid.value)
			var b bool
			if ok {
				b, ok = parseBoolText(t, Standard)
			}
			if ok && !reopenSeen {
				reopenSeen = true
				c.reopen = b
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'reopen'")
			}
		case "allowed":
			if kid.value.kind == vCell && allowedAt < 0 {
				allowedAt = k
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'allowed'")
			}
		case "min":
			if kid.value.kind == vCell && len(kid.value.els) == 1 && minAt < 0 {
				minAt = k
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'min'")
			}
		case "max":
			if kid.value.kind == vCell && len(kid.value.els) == 1 && maxAt < 0 {
				maxAt = k
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'max'")
			}
		case "unit":
			if kid.value.kind == vCell && len(kid.value.els) == 1 && unitAt < 0 {
				unitAt = k
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'unit'")
			}
		case "decimal":
			t, ok := singleText(&kid.value)
			var b bool
			if ok {
				b, ok = parseBoolText(t, Standard)
			}
			if ok && decimalKeyAt < 0 {
				decimalKeyAt = k
				c.decimal = b
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'decimal'")
			}
		case "repeat":
			if kid.value.kind == vCell && c.repeat == nil && (len(kid.value.els) == 1 || len(kid.value.els) == 2) {
				lo, okLo := parseIndex(kid.value.els[0].text)
				hi, okHi := parseIndex(kid.value.els[len(kid.value.els)-1].text)
				if okLo && okHi && lo <= hi {
					c.repeat = &[2]uint64{lo, hi}
				} else {
					vdiag(faults, kid.line, "V092", "bad schema constraint 'repeat'")
				}
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'repeat'")
			}
		case "inherits":
			t, ok := singleText(&kid.value)
			if ok && t != "" && c.inherits == "" {
				c.inherits = t
				c.inheritsLine = kid.line
			} else {
				vdiag(faults, kid.line, "V092", "bad schema constraint 'inherits'")
			}
		// Generator-only (`shcl init`); validation ignores both. First
		// occurrence wins (a merged schema could have two).
		case "desc":
			// A comma in a sentence makes the value several elements, and the
			// comment is prose: take them all, kept as written.
			if c.desc == nil && kid.value.kind == vCell {
				parts := make([]string, len(kid.value.els))
				for i := range kid.value.els {
					parts[i] = kid.value.els[i].text
				}
				t := strings.Join(parts, ", ")
				c.desc = &t
			}
		case "default":
			if c.defaultText == nil {
				if t, ok := emitValueInline(&kid.value); ok {
					c.defaultText = &t
				}
				defaultAt = k
			}
		default:
			vdiag(faults, kid.line, "V090", fmt.Sprintf("unknown schema key '%s'", diagName(kid.name)))
		}
	}
	// A raw block has no inline spelling, so a `default` that is one cannot reach
	// a generated line - it used to be dropped and the field emitted with no
	// value at all - and a `default` under `type: raw` goes out inline and then
	// fails its own type check.
	if defaultAt >= 0 {
		kid := &schema.arena[defaultAt]
		rawTyped := c.ty == "raw"
		if kid.value.kind == vRaw || (rawTyped && c.defaultText != nil) {
			vdiag(faults, kid.line, "V092", "bad schema constraint 'default'")
		}
	}
	if required != nil {
		c.required = *required
	}
	base := strings.TrimSuffix(c.ty, "-array")
	if base == "" {
		base = "string"
	}
	// `unit` and `decimal` belong to the types that read a bare number in one,
	// and a unit has to be one that type takes.
	if unitAt >= 0 {
		kid := &schema.arena[unitAt]
		t, _ := singleText(&kid.value)
		switch base {
		case "duration":
			c.unitD, _ = DurationUnitFromSpelling(t)
		case "size":
			c.unitS, _ = SizeUnitFromSpelling(t)
		}
		if c.unitD == DurationNone && c.unitS == SizeNone {
			vdiag(faults, kid.line, "V092", "bad schema constraint 'unit'")
		}
	}
	if decimalKeyAt >= 0 && base != "size" {
		vdiag(faults, schema.arena[decimalKeyAt].line, "V092", "bad schema constraint 'decimal'")
		c.decimal = false
	}
	// A duration or size bound is read the way the document's value is: its
	// own unit, then the field name's, then the schema's `unit`. A path that
	// ends in `*` has no one name to give it.
	name := ""
	if n := len(c.segs); n > 0 && !c.segs[n-1].star {
		name = c.segs[n-1].name
	}
	quantity := func(e *element) (int64, bool) {
		switch base {
		case "duration":
			bare := nameUnit(name, durationNames)
			if bare == DurationNone {
				bare = c.unitD
			}
			v, _, ok := parseDurationText(e.text, bare)
			return v, ok
		case "size":
			bare := nameUnit(name, sizeNames)
			if bare == SizeNone {
				bare = c.unitS
			}
			v, _, ok := parseSizeText(e.text, bare, c.decimal)
			return v, ok
		}
		return 0, false
	}
	if allowedAt >= 0 {
		kid := &schema.arena[allowedAt]
		els := kid.value.els
		// Schema values are read at Standard; only the document's values
		// coerce at the document's strictness.
		set := &allowedSet{}
		ok := true
		switch base {
		case "int":
			set.kind = allowInts
			for i := range els {
				v, o := parseIntText(&els[i], Standard)
				if !o {
					ok = false
					break
				}
				set.ints = append(set.ints, v)
			}
		case "float":
			set.kind = allowFloats
			for i := range els {
				v, o := parseFloatText(&els[i], Standard)
				if !o {
					ok = false
					break
				}
				set.floats = append(set.floats, v)
			}
		case "bool":
			set.kind = allowBools
			for i := range els {
				v, o := parseBoolText(els[i].text, Standard)
				if !o {
					ok = false
					break
				}
				set.bools = append(set.bools, v)
			}
		case "datetime":
			set.kind = allowDates
			for i := range els {
				v, o := ParseDateTime(els[i].text)
				if !o {
					ok = false
					break
				}
				set.dates = append(set.dates, v)
			}
		// A raw body has no element space to enumerate, and a duration or
		// size is bounded with min and max rather than listed.
		case "raw", "duration", "size":
			ok = false
		default:
			set.kind = allowStrings
			for i := range els {
				set.strs = append(set.strs, els[i].text)
			}
		}
		if ok {
			c.allowed = set
		} else {
			vdiag(faults, kid.line, "V092", "bad schema constraint 'allowed'")
		}
	}
	for _, mm := range []struct {
		at    int
		isMin bool
	}{{minAt, true}, {maxAt, false}} {
		if mm.at < 0 {
			continue
		}
		kid := &schema.arena[mm.at]
		el := &kid.value.els[0]
		key := "max"
		if mm.isMin {
			key = "min"
		}
		switch base {
		case "int":
			if v, ok := parseIntText(el, Standard); ok {
				if mm.isMin {
					c.minI = &v
				} else {
					c.maxI = &v
				}
			} else {
				vdiag(faults, kid.line, "V092", fmt.Sprintf("bad schema constraint '%s'", key))
			}
		case "float":
			if v, ok := parseFloatText(el, Standard); ok {
				if mm.isMin {
					c.minF = &v
				} else {
					c.maxF = &v
				}
			} else {
				vdiag(faults, kid.line, "V092", fmt.Sprintf("bad schema constraint '%s'", key))
			}
		case "duration", "size":
			if v, ok := quantity(el); ok {
				t := el.text
				if mm.isMin {
					c.minI, c.minText = &v, &t
				} else {
					c.maxI, c.maxText = &v, &t
				}
			} else {
				vdiag(faults, kid.line, "V092", fmt.Sprintf("bad schema constraint '%s'", key))
			}
		default:
			vdiag(faults, kid.line, "V092", fmt.Sprintf("bad schema constraint '%s'", key))
		}
	}
	// A lower bound above the upper one admits nothing, so every value fails
	// twice and the schema, not the config, is what has to change. Reported at
	// the max line. The range goes, not the field: a key-level fault keeps its
	// entry, so the path still legalizes its name chain for the unknown-field
	// sweep, and the document is not told off twice per value for a range it
	// could never have satisfied.
	crossed := (c.minI != nil && c.maxI != nil && *c.minI > *c.maxI) ||
		(c.minF != nil && c.maxF != nil && *c.minF > *c.maxF)
	if crossed {
		line := schema.arena[f].line
		if maxAt >= 0 {
			line = schema.arena[maxAt].line
		}
		vdiag(faults, line, "V092", "bad schema constraint 'max'")
		c.minI, c.maxI, c.minF, c.maxF = nil, nil, nil, nil
		c.minText, c.maxText = nil, nil
	}
	return c, true
}

func containsString(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

// emitValueInline re-emits a schema `default`/`allowed` value as an inline value
// (minimal quoting, array elements joined by ", "). ok=false for empty or raw -
// neither has a usable one-line form. Used by the generator, not the validator.
func emitValueInline(v *value) (string, bool) {
	if v.kind != vCell {
		return "", false
	}
	return emitCell(v.els), true
}

// ---------------------------------------------------------------------------
// Schema-driven generation: a schema + the Writer -> a commented starter config.
// ---------------------------------------------------------------------------

func allowedJoin(a *allowedSet) string {
	var parts []string
	switch a.kind {
	case allowInts:
		for _, x := range a.ints {
			parts = append(parts, strconv.FormatInt(x, 10))
		}
	case allowFloats:
		for _, x := range a.floats {
			parts = append(parts, FormatFloat(x))
		}
	case allowBools:
		for _, x := range a.bools {
			if x {
				parts = append(parts, "true")
			} else {
				parts = append(parts, "false")
			}
		}
	case allowDates:
		for _, x := range a.dates {
			parts = append(parts, x.String())
		}
	case allowStrings:
		parts = append(parts, a.strs...)
	}
	return strings.Join(parts, ", ")
}

// genAnnotation is the `# type, ...` line summarizing a constraint, ASCII only.
func genAnnotation(c *constraint, tyname string) string {
	parts := []string{tyname}
	if c.unitD != DurationNone {
		parts[0] = tyname + " in " + c.unitD.Spelling()
	} else if c.unitS != SizeNone {
		parts[0] = tyname + " in " + c.unitS.Spelling()
	}
	if c.decimal {
		parts = append(parts, "KB to TB in powers of 1000")
	}
	if c.allowed != nil {
		parts = append(parts, "one of: "+allowedJoin(c.allowed))
	}
	// The bounds are their own part of the annotation line, not an alternative
	// to `allowed`. A field can have both, and the validator enforces both. A
	// duration or size bound reads the way the schema wrote it.
	switch {
	case c.minText != nil || c.maxText != nil:
		switch {
		case c.minText != nil && c.maxText != nil:
			parts = append(parts, *c.minText+"-"+*c.maxText)
		case c.minText != nil:
			parts = append(parts, ">= "+*c.minText)
		default:
			parts = append(parts, "<= "+*c.maxText)
		}
	case c.minI != nil || c.maxI != nil:
		switch {
		case c.minI != nil && c.maxI != nil:
			parts = append(parts, fmt.Sprintf("%d-%d", *c.minI, *c.maxI))
		case c.minI != nil:
			parts = append(parts, fmt.Sprintf(">= %d", *c.minI))
		default:
			parts = append(parts, fmt.Sprintf("<= %d", *c.maxI))
		}
	case c.minF != nil || c.maxF != nil:
		switch {
		case c.minF != nil && c.maxF != nil:
			parts = append(parts, FormatFloat(*c.minF)+"-"+FormatFloat(*c.maxF))
		case c.minF != nil:
			parts = append(parts, ">= "+FormatFloat(*c.minF))
		default:
			parts = append(parts, "<= "+FormatFloat(*c.maxF))
		}
	}
	if c.repeat != nil {
		if c.repeat[0] == c.repeat[1] {
			parts = append(parts, fmt.Sprintf("repeat %d", c.repeat[0]))
		} else {
			parts = append(parts, fmt.Sprintf("repeat %d-%d", c.repeat[0], c.repeat[1]))
		}
	}
	if c.required {
		parts = append(parts, "required")
	}
	return strings.Join(parts, ", ")
}

// genDefaultText: a default with a literal newline cannot sit on a value
// line; the quoted escaped spelling reads back to the same string.
func genDefaultText(v string) string {
	if !strings.Contains(v, "\n") {
		return v
	}
	var s strings.Builder
	s.WriteByte('"')
	for _, ch := range v {
		switch ch {
		case '\\':
			s.WriteString("\\\\")
		case '"':
			s.WriteString("\\\"")
		case '\n':
			s.WriteString("\\n")
		case '\t':
			s.WriteString("\\t")
		default:
			s.WriteRune(ch)
		}
	}
	s.WriteByte('"')
	return s.String()
}

// Generate emits a commented, typed starter config from a schema (`shcl init
// --schema`). Paths that must exist (required, or a repeat lower bound of 1+)
// are live (their `default`, or an empty value); optional paths are commented
// out so the file is valid and minimal as-is. Prose the generator writes is
// `##` and a commented-out setting is `# `, so the two read apart; both are
// ordinary comments to the language, and nothing reads them back.
// A must-exist wildcard path whose
// parent gets materialized by another live line is generated too, in dotted
// form - otherwise the file would fail the very schema that produced it - and
// remaining wildcard or `[#N]` paths (which cannot be materialized) are listed
// in a trailing comment block. A path whose last segment selects by value is
// written without that selector when it has a `default`, since a value after
// the selector would be ignored: `env[prod]` with `default: prod` is
// `env: prod`. The output always loads clean and validates
// clean against its schema, except a repeat lower bound of 2+ (identical
// generated lines would merge, so the shortfall is reported). The promise is
// checked against the finished text, both its load and its validation, so a
// line that does not load, or a schema whose own `default` breaks its field's
// constraints, is a fault (V097) instead of a starter config that fails the
// first time it is checked. A footer naming
// the format and pointing at the spec is written last unless noBanner; the
// flag is negative so leaving it alone writes the footer. faults != nil =
// schema faults (V09x), same as Validate / check --schema.
func Generate(schema *Document, noBanner bool) (string, []Diagnostic) {
	// Generation lays the whole schema out, so unlike validation it has no
	// safe partial mode: any fault fails it.
	def, faults := buildSchema(schema)
	if len(faults) > 0 {
		return "", faults
	}
	cons, cuts := expandMounts(&def)
	if len(cons) > genMaxFields {
		msg := fmt.Sprintf("schema expands past %d fields; fragments mounted at more than one path multiply", genMaxFields)
		return "", []Diagnostic{{Line: 0, Severity: SeverityError, Message: msg, Code: "V096"}}
	}
	mustExist := func(c *constraint) bool {
		return c.required || (c.repeat != nil && c.repeat[0] >= 1)
	}
	hasWild := func(c *constraint) bool {
		for _, s := range c.segs {
			if s.sel != nil && s.sel.kind == selWildcard {
				return true
			}
		}
		return false
	}
	// `[#N]` needs a pre-existing instance and its `#` would start a comment on
	// a binding line. A path deeper than a document may nest cannot be generated
	// either: the line would draw E016 on the way back in. A newline in a name
	// or a by-value selector is writable, since both are written escaped.
	// The reason doubles as the predicate, so the refusal below can never name a
	// path for a reason generation did not act on.
	whyUnwritable := func(c *constraint) string {
		if len(c.segs) > MaxDepth {
			return "nests past the depth cap"
		}
		for _, s := range c.segs {
			if s.sel != nil && s.sel.kind == selByIndex {
				return "a [#N] selector needs an instance that does not exist yet"
			}
			if s.star {
				return "a * name segment has no name to write"
			}
		}
		return ""
	}
	unwritable := func(c *constraint) bool { return whyUnwritable(c) != "" }
	// Live concrete paths materialize instances; decide which must-exist
	// wildcards get filled (their first-wildcard parent chain is a prefix of
	// some live path). Fixpoint: a fill can materialize another's parent.
	namesOf := func(segs []segment) []string {
		names := make([]string, len(segs))
		for j, s := range segs {
			names[j] = s.name
		}
		return names
	}
	isPrefix := func(p, parent []string) bool {
		if len(p) < len(parent) {
			return false
		}
		for j := range parent {
			if p[j] != parent[j] {
				return false
			}
		}
		return true
	}
	var live [][]string
	for i := range cons {
		c := &cons[i]
		if !hasWild(c) && !unwritable(c) && mustExist(c) {
			live = append(live, namesOf(c.segs))
		}
	}
	fill := make([]bool, len(cons))
	for {
		changed := false
		for i := range cons {
			c := &cons[i]
			if fill[i] || !hasWild(c) || unwritable(c) || !mustExist(c) {
				continue
			}
			k := 0
			for j, s := range c.segs {
				if s.sel != nil && s.sel.kind == selWildcard {
					k = j
					break
				}
			}
			parent := namesOf(c.segs[:k+1])
			// A wildcard in the last segment needs no other line to
			// materialize its parent: the line generated from it is that
			// instance.
			if k+1 == len(c.segs) {
				fill[i] = true
				live = append(live, namesOf(c.segs))
				changed = true
				continue
			}
			for _, p := range live {
				if isPrefix(p, parent) {
					fill[i] = true
					live = append(live, namesOf(c.segs))
					changed = true
					break
				}
			}
		}
		if !changed {
			break
		}
	}
	// A live line with a value materializes an instance with that value,
	// and a dotted child names the empty-valued instance instead - so `srv:
	// web` followed by `srv.port:` is two `srv` nodes, and the child never
	// ends up where the schema looks. Any line under such a parent selects it
	// by its value: `srv[web].port:`.
	// A filled wildcard emits a valued line of its own, so it belongs here too.
	// First wins, as the line it selects does: of two lines on one path the
	// first spelling is the one written, and its value is the instance.
	parentValues := map[string]string{}
	for i := range cons {
		c := &cons[i]
		if (!hasWild(c) || fill[i]) && !unwritable(c) && mustExist(c) && c.defaultText != nil {
			key := namesKey(namesOf(c.segs))
			if _, ok := parentValues[key]; !ok {
				parentValues[key] = *c.defaultText
			}
		}
	}
	// A commented line under a commented valued parent has the same problem
	// once both are uncommented, so it selects the parent's default too. A
	// live line keeps the dotted form under a commented parent: selecting by
	// value would make the optional parent exist.
	commentedValues := make(map[string]string, len(parentValues))
	for k, v := range parentValues {
		commentedValues[k] = v
	}
	for i := range cons {
		c := &cons[i]
		if !hasWild(c) && !unwritable(c) && !mustExist(c) && c.defaultText != nil {
			key := namesKey(namesOf(c.segs))
			if _, ok := commentedValues[key]; !ok {
				commentedValues[key] = *c.defaultText
			}
		}
	}
	// A path that cannot be written at all belongs in the trailing note, but one
	// that must exist can never be satisfied from there: the self-check would
	// then report the document as missing a path, which points at the config
	// rather than at the schema line that cannot be generated. A repeat lower
	// bound of 2 or more is the one documented shortfall - the line is emitted
	// once and the count reported - so it is not this fault.
	// Every such path is named, not just the first: fixing one only to be
	// refused over the next tells nobody how much is wrong.
	var blocked []Diagnostic
	for i := range cons {
		c := &cons[i]
		cannotSatisfy := c.required || (c.repeat != nil && c.repeat[0] == 1)
		if cannotSatisfy && unwritable(c) && !hasWild(c) {
			msg := "required path cannot be generated: " + schemaText(c.path) +
				" (" + whyUnwritable(c) + ")"
			blocked = append(blocked, Diagnostic{Line: 0, Severity: SeverityError, Message: msg, Code: "V097"})
		}
	}
	if len(blocked) > 0 {
		return "", blocked
	}
	var b strings.Builder
	var wild [][2]string
	// Dropping a trailing `[*]` can render the same line a concrete sibling
	// already wrote; the first spelling wins. A line from a dropped `[value]`
	// selector is its own instance, so two of them with different values are
	// both written: `env[prod]` and `env[dev]` are two `env` lines. Each path
	// maps to nil once a plain line wrote it, or to the values written so far.
	emitted := map[string]map[string]bool{}
	// A child whose valued parent has no selector spelling cannot be written.
	var unspellable []Diagnostic
	// One block per generated line - its desc, annotation and binding - with
	// the path's names, so the blocks can be laid out in tree order below.
	type genBlock struct {
		names []string
		text  string
	}
	var blocks []genBlock
	// An optional field's line goes out commented, with the constraint it came
	// from, since the self-check below cannot see a comment.
	type genCommented struct {
		cons int
		line string
	}
	var commented []genCommented
	for i := range cons {
		c := &cons[i]
		tyname := c.ty
		if tyname == "" {
			tyname = "any"
		}
		if unwritable(c) || (hasWild(c) && !fill[i]) {
			wild = append(wild, [2]string{schemaText(c.path), tyname})
			continue
		}
		// A filled wildcard emits in dotted form, targeting the materialized
		// instance - by its value when the materializing line has one.
		// Rebuilt from the parsed segments, not by cutting text out of the
		// path: the same path can be written several ways, and only the
		// segments say what it means. Otherwise the schema's own spelling.
		values := parentValues
		if !mustExist(c) {
			values = commentedValues
		}
		underValuedParent := false
		for k := 1; k < len(c.segs); k++ {
			if _, ok := values[namesKey(namesOf(c.segs[:k]))]; ok && c.segs[k-1].sel == nil {
				underValuedParent = true
				break
			}
		}
		// A name with a newline has no verbatim spelling on a binding line;
		// the segment renderer escapes it, so such a path goes through there
		// whether or not it was filled.
		// A value after a last-segment selector is ignored, so a default there
		// goes on the bare path: the line materializes the instance, and
		// validation below decides whether the default names the one selected.
		last := c.segs[len(c.segs)-1].sel
		selectsByValue := c.defaultText != nil && last != nil && last.kind == selByValue
		// The schema's own spelling is kept when a file line reads it back as
		// the same path. A selector body holding a `#` is fine in a lookup and
		// opens a comment on a file line, so that one goes through the renderer.
		path, spelled := c.path, true
		if selectsByValue {
			segs := append([]segment(nil), c.segs...)
			segs[len(segs)-1].sel = nil
			path, spelled = genPathText(segs, values)
		} else if fill[i] || underValuedParent || !pathReadsBack(c.path, c.segs) {
			path, spelled = genPathText(c.segs, values)
		}
		if !spelled {
			unspellable = append(unspellable, Diagnostic{Line: 0, Severity: SeverityError, Code: "V097",
				Message: "required path cannot be generated: " + schemaText(c.path) + " (its parent's value has no selector spelling)"})
			continue
		}
		dval := ""
		if c.defaultText != nil {
			dval = *c.defaultText
		}
		if vals, ok := emitted[path]; !ok {
			if selectsByValue {
				emitted[path] = map[string]bool{dval: true}
			} else {
				emitted[path] = nil
			}
		} else if vals == nil || !selectsByValue || vals[dval] {
			continue
		} else {
			vals[dval] = true
		}
		var block strings.Builder
		if c.desc != nil {
			for _, line := range strings.Split(*c.desc, "\n") {
				if line == "" {
					block.WriteString("##")
				} else {
					block.WriteString("## ")
				}
				block.WriteString(line)
				block.WriteByte('\n')
			}
		}
		block.WriteString("## ")
		// The annotation is a comment: a newline smuggled in via an allowed
		// string value must not break out of it.
		block.WriteString(schemaText(genAnnotation(c, tyname)))
		block.WriteByte('\n')
		prefix := "# "
		if mustExist(c) {
			prefix = ""
		}
		if c.defaultText != nil {
			line := path + ": " + genDefaultText(*c.defaultText) + "\n"
			block.WriteString(prefix)
			block.WriteString(line)
			if !mustExist(c) {
				commented = append(commented, genCommented{i, line})
			}
		} else {
			line := path + ":\n"
			block.WriteString(prefix)
			block.WriteString(line)
			if !mustExist(c) {
				commented = append(commented, genCommented{i, line})
			}
		}
		blocks = append(blocks, genBlock{namesOf(c.segs), block.String()})
	}
	// Tree order, first appearance first. A schema may list `a.host.srv`
	// before `a`, and emitted as listed with another field between them,
	// `a: x` re-opens `a` and the load hints it (H002) - in the one file meant
	// to show the format at its cleanest. Every prefix is ranked by where it
	// first appears, so a parent's block comes before its children's, siblings
	// keep schema order, and a schema already in tree order is unchanged.
	rank := map[string]int{}
	for _, bl := range blocks {
		for k := 1; k <= len(bl.names); k++ {
			key := namesKey(bl.names[:k])
			if _, ok := rank[key]; !ok {
				rank[key] = len(rank)
			}
		}
	}
	// A parent's key is a prefix of its children's, and a shorter key sorts
	// first; the sort is stable, so two blocks on one path keep their order.
	keys := make([][]int, len(blocks))
	for i, bl := range blocks {
		for k := 1; k <= len(bl.names); k++ {
			keys[i] = append(keys[i], rank[namesKey(bl.names[:k])])
		}
	}
	order := make([]int, len(blocks))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(x, y int) bool {
		kx, ky := keys[order[x]], keys[order[y]]
		for j := 0; j < len(kx) && j < len(ky); j++ {
			if kx[j] != ky[j] {
				return kx[j] < ky[j]
			}
		}
		return len(kx) < len(ky)
	})
	for n, i := range order {
		if n > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(blocks[i].text)
	}
	// Cycle-cut mounts last: their "type" column names the fragment that
	// belongs at the path.
	wild = append(wild, cuts...)
	if len(wild) > 0 {
		if len(blocks) > 0 {
			b.WriteByte('\n')
		}
		b.WriteString("## Paths needing an instance name (not generated):\n")
		for _, w := range wild {
			fmt.Fprintf(&b, "##   %s   %s\n", w[0], w[1])
		}
	}
	if len(unspellable) > 0 {
		return "", unspellable
	}
	if !noBanner {
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(GenBanner)
	}
	// The output promises to validate clean against the schema that produced
	// it, so check that here rather than trusting each branch above. A
	// `default` outside its own field's constraints is the schema's fault, and
	// the author should hear about it instead of getting a starter config that
	// fails the first time it is checked. The one sanctioned shortfall is a
	// V007 for a repeat lower bound of 2+: generating that many identical
	// lines merges them into one. A lower bound of 1 is a must-exist path
	// like any other, so its V007 is a fault.
	// The load comes first, in the order check --schema prints: a line that
	// does not load is refused even when validation happens to pass without it.
	text := b.String()
	gdoc := Parse(text)
	var bad []Diagnostic
	for _, d := range gdoc.diags {
		if d.Severity == SeverityError {
			bad = append(bad, Diagnostic{
				Line:     0,
				Severity: SeverityError,
				Code:     "V097",
				Message:  "generated text does not load: " + d.Code + " " + d.Message,
			})
		}
	}
	for _, d := range gdoc.Validate(schema) {
		if d.Severity == SeverityError && !(d.Code == "V007" && v007Sanctioned(d.Message)) {
			bad = append(bad, Diagnostic{
				Line:     0,
				Severity: SeverityError,
				Code:     "V097",
				Message:  "generated value fails the schema that produced it: " + d.Message,
			})
		}
	}
	// A commented default fails the same check once someone uncomments it. Each
	// line is read back alone and only its value is checked: uncommenting every
	// line at once would pair a valued parent with a dotted child, which names
	// a second instance, and fault a schema whose lines each work. The value is
	// found through the field's own path, the way validation finds it, so a
	// default naming another instance than the path selects is caught here
	// as it is for a required field.
	for _, cm := range commented {
		one := Parse(cm.line)
		for _, d := range one.diags {
			if d.Severity == SeverityError {
				bad = append(bad, Diagnostic{
					Line:     0,
					Severity: SeverityError,
					Code:     "V097",
					Message:  "generated text does not load: " + d.Code + " " + d.Message,
				})
			}
		}
		if len(one.arena[root].children) == 0 {
			continue
		}
		var ctxs []vContext
		one.vContexts([]int{root}, cons[cm.cons].segs, 0, &ctxs)
		var nodes []int
		for _, cx := range ctxs {
			nodes = append(nodes, cx.found...)
		}
		if len(nodes) == 0 {
			bad = append(bad, Diagnostic{
				Line:     0,
				Severity: SeverityError,
				Code:     "V097",
				Message:  "generated value fails the schema that produced it: default does not name the instance its path selects: " + schemaText(cons[cm.cons].path),
			})
			continue
		}
		var found []Diagnostic
		for _, n := range nodes {
			one.vNode(&cons[cm.cons], n, &found)
		}
		for _, d := range found {
			if d.Severity == SeverityError {
				bad = append(bad, Diagnostic{
					Line:     0,
					Severity: SeverityError,
					Code:     "V097",
					Message:  "generated value fails the schema that produced it: " + d.Message,
				})
			}
		}
	}
	if len(bad) > 0 {
		return "", bad
	}
	return text, nil
}

// genMaxFields is the ceiling on how many fields one schema may expand to.
// Fragments that mount each other at more than one path multiply, so a short
// schema can otherwise ask for more output than the machine can hold; past
// this the generator reports a schema fault rather than running until
// something breaks.
const genMaxFields = 10000

// GenBanner is the footer telling whoever opens the generated file what the
// format is and where its spec lives. It is output, so every binding emits
// these bytes exactly; the Legal line names SHCL as its subject so it cannot
// be read as a claim over the config it sits in. Exported because a program
// that creates a config file of its own writes the same block, and a second
// copy of a byte-for-byte contract drifts.
const GenBanner = "##\n" +
	"## This config file format is SHCL.\n" +
	"## \"Simple Hierarchical Config Language\"\n" +
	"##    Format   3\n" +
	"##    Home     https://github.com/yottacore/shcl\n" +
	"##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n" +
	"##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n" +
	"##\n"

// v007Sanctioned reports whether a V007 from the self-check is the sanctioned
// kind: its message ends `: N not in LO..HI`, and LO is 2 or more.
func v007Sanctioned(message string) bool {
	i := strings.LastIndex(message, " not in ")
	if i < 0 {
		return false
	}
	lo, _, _ := strings.Cut(message[i+len(" not in "):], "..")
	n, err := strconv.ParseUint(lo, 10, 64)
	return err == nil && n >= 2
}

// namesKey joins segment names for the parent-value map, each length-prefixed
// so no name content can make two different prefixes read the same.
func namesKey(names []string) string {
	var b strings.Builder
	for _, n := range names {
		b.WriteString(strconv.Itoa(len(n)))
		b.WriteByte(':')
		b.WriteString(n)
	}
	return b.String()
}

// genSelectorText is the selector body that picks out the instance a line
// `name: v` makes, or false when no body can. It is built from the elements
// the reader takes out of that line's value, and each candidate is scanned
// back the way a file line is scanned, so none of the scanner's rules is
// copied here to go stale. That copy was the cause twice: an all-digit body
// past 64 bits, and a quoted array element written as the body. One element
// tries the spelling it was written in first; an array has only the bare
// body, since a quoted selector matches one element only, and a bare one the
// elements joined.
func genSelectorText(v string) (string, bool) {
	spelled := genDefaultText(v)
	var tok Tokens
	TokenizeValue(spelled, 0, RulesCurrent, &tok)
	els := make([]string, len(tok.Elements))
	for k := range tok.Elements {
		els[k] = pieceText(&tok.Elements[k], spelled)
	}
	display := strings.Join(els, ", ")
	type try struct {
		body, text string
		quoted     bool
	}
	var tries []try
	if len(els) == 1 {
		if q := tok.Elements[0].Quote; q == QuoteSingle || q == QuoteDouble {
			tries = append(tries, try{spelled[tok.Value[0]:tok.Value[1]], els[0], true})
		}
		tries = append(tries, try{display, display, false}, try{quoteText(els[0]), els[0], true})
	} else {
		tries = append(tries, try{display, display, false})
	}
	for _, t := range tries {
		if selectorReadsBack(t.body, t.text, t.quoted) {
			return t.body, true
		}
	}
	return "", false
}

// selectorReadsBack reports whether body between brackets on a file line
// reads back as a value selector for text, quoted or bare as asked.
func selectorReadsBack(body, text string, quoted bool) bool {
	line := "x[" + body + "]:"
	// The tokenizer reads one line and never sees a line end, so text with a
	// real line break would read back here and then be written across two lines,
	// which is not the same path. A file line cannot hold one, so refuse and let
	// the escaped spelling be tried instead.
	if strings.ContainsAny(line, "\n\r") {
		return false
	}
	var tok Tokens
	Tokenize(line, ':', false, RulesCurrent, &tok)
	if selectorOpenQuote(&tok) || tok.Comment >= 0 {
		return false
	}
	ps, err := pathOf(&tok, line)
	if err != nil || len(ps.segments) != 1 {
		return false
	}
	sel := ps.segments[0].sel
	return sel != nil && sel.kind == selByValue && sel.value == text && sel.quoted == quoted
}

// pathReadsBack reports whether a schema path written on a file line reads
// back as the same segments. A lookup path takes spellings a file line does
// not.
func pathReadsBack(path string, segs []segment) bool {
	line := path + ":"
	// The tokenizer reads one line and never sees a line end, so text with a
	// real line break would read back here and then be written across two lines,
	// which is not the same path. A file line cannot hold one, so refuse and let
	// the escaped spelling be tried instead.
	if strings.ContainsAny(line, "\n\r") {
		return false
	}
	var tok Tokens
	Tokenize(line, ':', false, RulesCurrent, &tok)
	if selectorOpenQuote(&tok) || tok.Comment >= 0 {
		return false
	}
	ps, err := pathOf(&tok, line)
	if err != nil || len(ps.segments) != len(segs) {
		return false
	}
	for k, a := range ps.segments {
		b := segs[k]
		if a.name != b.name || a.star != b.star || (a.sel == nil) != (b.sel == nil) {
			return false
		}
		if a.sel != nil && *a.sel != *b.sel {
			return false
		}
	}
	return true
}

// genPathText renders parsed segments back as a dotted path, dropping
// wildcard selectors (a generated line targets the one instance it
// materializes) and quoting a name that needs it, so the result is a path the
// scanner reads back the same. A segment whose prefix names a live line
// with a value selects that instance by the value, in place of a wildcard
// or a bare name. False when a selector has no spelling a file line reads
// back.
func genPathText(segs []segment, parentValues map[string]string) (string, bool) {
	var out strings.Builder
	names := make([]string, 0, len(segs))
	for i, s := range segs {
		if i > 0 {
			out.WriteByte('.')
		}
		if s.star {
			out.WriteByte('*')
		} else {
			out.WriteString(emitName(s.name))
		}
		names = append(names, s.name)
		if v, ok := parentValues[namesKey(names)]; ok && i+1 < len(segs) && (s.sel == nil || s.sel.kind != selByValue) {
			body, ok := genSelectorText(v)
			if !ok {
				return "", false
			}
			out.WriteByte('[')
			out.WriteString(body)
			out.WriteByte(']')
			continue
		}
		if s.sel != nil {
			switch s.sel.kind {
			case selByValue:
				// The body as the schema meant it: a quoted one stays quoted,
				// and a bare one goes bare when a file line reads it back.
				text, quotedBody := s.sel.value, quoteText(s.sel.value)
				var body string
				switch {
				case !s.sel.quoted && selectorReadsBack(text, text, false):
					body = text
				case selectorReadsBack(quotedBody, text, true):
					body = quotedBody
				default:
					return "", false
				}
				out.WriteByte('[')
				out.WriteString(body)
				out.WriteByte(']')
			case selByIndex:
				fmt.Fprintf(&out, "[#%d]", s.sel.index)
			case selWildcard:
			}
		}
	}
	return out.String(), true
}

// expandMounts inlines every fragment mount into a flat constraint list,
// depth-first in schema order, each field's path and segments prefixed by its
// mount's. A mount whose fragment is already expanding (a cycle) stops there
// and is returned as (path, fragment name) for the trailing not-generated
// block.
func expandMounts(def *schemaDef) ([]constraint, [][2]string) {
	var out []constraint
	var cuts [][2]string
	var stack []string
	var walk func(list []constraint, atPath string, atSegs []segment, mounted bool)
	walk = func(list []constraint, atPath string, atSegs []segment, mounted bool) {
		for i := range list {
			cc := list[i]
			if mounted {
				cc.path = atPath + "." + list[i].path
				// Fresh backing array per clone: appending to a shared one
				// would let sibling clones stomp each other's segments.
				segs := make([]segment, 0, len(atSegs)+len(list[i].segs))
				segs = append(segs, atSegs...)
				segs = append(segs, list[i].segs...)
				cc.segs = segs
			}
			path := cc.path
			segs := cc.segs
			if len(out) > genMaxFields {
				return
			}
			out = append(out, cc)
			if fr := list[i].inherits; fr != "" {
				onStack := false
				for _, x := range stack {
					if x == fr {
						onStack = true
						break
					}
				}
				// A chain long enough to outrun the stack, or a mount that
				// re-enters, stops here and is noted instead of expanded.
				if onStack || len(stack) >= MaxDepth {
					cuts = append(cuts, [2]string{schemaText(path), schemaText(fr)})
				} else if fcs, ok := def.frags[fr]; ok {
					stack = append(stack, fr)
					walk(fcs, path, segs, true)
					stack = stack[:len(stack)-1]
				}
			}
		}
	}
	walk(def.cons, "", nil, false)
	return out, cuts
}

// editDistance is the Levenshtein distance capped at cap, for the "did you
// mean" prose (never the code): anything past the cap comes back as cap + 1.
// Only the band |i - j| <= cap of the table is computed, so a pair costs
// linear time in the names' length, and a length gap past the cap needs no
// table at all.
func editDistance(a, b string, cap int) int {
	ar := []rune(a)
	br := []rune(b)
	inf := cap + 1
	if absDiff(len(ar), len(br)) > cap {
		return inf
	}
	prev := make([]int, len(br)+1)
	cur := make([]int, len(br)+1)
	for j := range prev {
		prev[j] = minInt(j, inf)
		cur[j] = inf
	}
	for i := 1; i <= len(ar); i++ {
		cur[0] = minInt(i, inf)
		lo := maxInt(i-cap, 1)
		hi := minInt(i+cap, len(br))
		if lo > 1 {
			cur[lo-1] = inf
		}
		rowMin := cur[0]
		for j := lo; j <= hi; j++ {
			cost := 1
			if ar[i-1] == br[j-1] {
				cost = 0
			}
			cur[j] = minInt(min3(prev[j]+1, cur[j-1]+1, prev[j-1]+cost), inf)
			rowMin = minInt(rowMin, cur[j])
		}
		if hi < len(br) {
			cur[hi+1] = inf
		}
		// No cell in a later row can come back under this row's minimum.
		if rowMin > cap {
			return inf
		}
		prev, cur = cur, prev
	}
	return prev[len(br)]
}

func absDiff(a, b int) int {
	if a > b {
		return a - b
	}
	return b - a
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func min3(a, b, c int) int {
	if b < a {
		a = b
	}
	if c < a {
		a = c
	}
	return a
}

// Validate checks this document against a schema document (itself plain SHCL -
// spec.md "Schema validation"). An empty result means the document conforms.
// Diagnostic lines are document lines (0 = document scope); schema faults
// (V09x, schema-file lines) come first, and the surviving constraints still
// check the document. The unknown-field sweep runs too, unless a fault cost
// the schema a path spelling (an unreadable `field:` path, or a mount naming
// no declared fragment) - only those can turn declared fields into false
// unknowns; a key-level fault keeps its entry's chain.
// The H001/H002 hints a schema disavows are NOT dropped by this call: they
// live on the parse's diagnostics, which validation does not touch. Parse then
// validate and they are still there - apply SuppressDeclaredRepeats /
// SuppressDeclaredReopens yourself, or use LoadAndValidate, which runs both
// for you.
func (d *Document) Validate(schema *Document) []Diagnostic {
	def, faults := buildSchema(schema)
	out := faults
	// One mount set for the whole schema: two top-level paths can resolve to
	// the same node and mount the same fragment there, and the spec says each
	// fragment runs once per node.
	mounted := make(map[fragMount]bool)
	for i := range def.cons {
		d.vCheckFrom(&def.cons[i], &def, root, 0, &out, mounted)
	}
	if def.pathsComplete {
		d.vUnknown(&def, &out)
	}
	return out
}

type vContext struct {
	anchor int
	found  []int
}

// vContexts collects resolution contexts: the whole document for a plain path;
// each enclosing instance for the part of a path after a wildcard. required/
// repeat evaluate per context (anchor line 0 = document scope), so
// `server[*].port` + required means a port under EACH server - vacuously true
// with no servers.
func (d *Document) vContexts(start []int, segs []segment, anchor int, out *[]vContext) {
	cur := start
	for i, seg := range segs {
		var next []int
		for _, n := range cur {
			if seg.star {
				next = append(next, d.arena[n].children...)
			} else {
				next = append(next, d.childrenNamed(n, seg.name)...)
			}
		}
		if seg.star {
			// Name wildcard: same per-instance split as `[*]`, any child name.
			rest := segs[i+1:]
			if len(rest) == 0 {
				*out = append(*out, vContext{anchor: anchor, found: next})
			} else {
				for _, inst := range next {
					d.vContexts([]int{inst}, rest, d.arena[inst].line, out)
				}
			}
			return
		}
		if seg.sel == nil {
			cur = next
			continue
		}
		switch seg.sel.kind {
		case selByValue:
			want := seg.sel.value
			cur = nil
			for _, c := range next {
				if dispKey(&d.arena[c].value) == want && (!seg.sel.quoted || singleScalar(&d.arena[c].value)) {
					cur = append(cur, c)
				}
			}
		case selByIndex:
			// Compare in uint64 like the sibling sites: int() of a huge index
			// wraps negative and the bounds check would pass straight into a panic.
			if seg.sel.index < uint64(len(next)) {
				cur = []int{next[seg.sel.index]}
			} else {
				cur = nil
			}
		case selWildcard:
			rest := segs[i+1:]
			if len(rest) == 0 {
				*out = append(*out, vContext{anchor: anchor, found: next})
			} else {
				for _, inst := range next {
					d.vContexts([]int{inst}, rest, d.arena[inst].line, out)
				}
			}
			return
		}
	}
	*out = append(*out, vContext{anchor: anchor, found: cur})
}

// fragMount keys one (fragment, node) pair; a struct key, not a joined
// string, so a fragment name containing the separator cannot collide.
type fragMount struct {
	fr string
	n  int
}

// A mounted fragment's fields run per resolved node, right after that node's
// own checks, in fragment order - depth-first, so diagnostic order stays
// derivable. Termination is structural: every mount descends at least one
// document level, and the document is finite.
func (d *Document) vCheckFrom(
	c *constraint, def *schemaDef, start, anchor0 int, out *[]Diagnostic, mounted map[fragMount]bool,
) {
	var ctxs []vContext
	d.vContexts([]int{start}, c.segs, anchor0, &ctxs)
	for _, ctx := range ctxs {
		if c.required && len(ctx.found) == 0 {
			vdiag(out, ctx.anchor, "V002", fmt.Sprintf("required path missing: %s", schemaText(c.path)))
		}
		if c.repeat != nil {
			n := uint64(len(ctx.found))
			if n < c.repeat[0] || n > c.repeat[1] {
				vdiag(out, ctx.anchor, "V007", fmt.Sprintf("instance count out of bounds at '%s': %d not in %d..%d",
					schemaText(c.path), n, c.repeat[0], c.repeat[1]))
			}
		}
		for _, n := range ctx.found {
			d.vNode(c, n, out)
			if c.inherits != "" {
				if fcs, ok := def.frags[c.inherits]; ok {
					// Two constraints can resolve to the same node and mount the
					// same fragment there. The second mount would repeat the
					// first's work and its diagnostics, and repeating it per
					// level is what makes a recursive schema cost double per
					// document level, so each pair is done once.
					key := fragMount{fr: c.inherits, n: n}
					if !mounted[key] {
						mounted[key] = true
						for i := range fcs {
							d.vCheckFrom(&fcs[i], def, n, d.arena[n].line, out, mounted)
						}
					}
				}
			}
		}
	}
}

func (d *Document) vNode(c *constraint, n int, out *[]Diagnostic) {
	node := &d.arena[n]
	line := node.line
	base := strings.TrimSuffix(c.ty, "-array")
	isArray := strings.HasSuffix(c.ty, "-array")
	wrong := func() {
		vdiag(out, line, "V003", fmt.Sprintf("wrong type at '%s': value is not a valid %s", schemaText(c.path), c.ty))
	}
	switch node.value.kind {
	// Empty passes everything; required already counted it as present.
	case vEmpty:
	case vRaw:
		// A raw block satisfies `raw` and scalar `string` (any value reads as a
		// string); every other kind is a type miss.
		if c.ty != "" && (base != "raw" && base != "string" || isArray) {
			wrong()
			return
		}
		if c.allowed != nil && c.allowed.kind == allowStrings {
			if !containsString(c.allowed.strs, node.value.raw.content) {
				vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(node.value.raw.content)))
			}
		}
	case vCell:
		els := node.value.els
		if base == "raw" {
			wrong()
			return
		}
		// A scalar kind on a multi-element value is the array-where-one-scalar-
		// expected miss - except string, which reads arrays.
		if c.ty != "" && !isArray && base != "string" && len(els) > 1 {
			wrong()
			return
		}
		switch base {
		case "int":
			vals := make([]int64, 0, len(els))
			for i := range els {
				v, ok := parseIntText(&els[i], d.strictness)
				if !ok {
					wrong()
					return
				}
				vals = append(vals, v)
			}
			if c.allowed != nil && c.allowed.kind == allowInts {
				for i, v := range vals {
					if !containsInt(c.allowed.ints, v) {
						vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
			if c.minI != nil {
				if i := firstIntBelow(vals, *c.minI); i >= 0 {
					vdiag(out, line, "V005", fmt.Sprintf("value below min %d at '%s': %s", *c.minI, schemaText(c.path), oneLine(els[i].text)))
				}
			}
			if c.maxI != nil {
				if i := firstIntAbove(vals, *c.maxI); i >= 0 {
					vdiag(out, line, "V006", fmt.Sprintf("value above max %d at '%s': %s", *c.maxI, schemaText(c.path), oneLine(els[i].text)))
				}
			}
		case "float":
			vals := make([]float64, 0, len(els))
			for i := range els {
				v, ok := parseFloatText(&els[i], d.strictness)
				if !ok {
					wrong()
					return
				}
				vals = append(vals, v)
			}
			if c.allowed != nil && c.allowed.kind == allowFloats {
				for i, v := range vals {
					if !containsFloat(c.allowed.floats, v) {
						vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
			if c.minF != nil {
				if i := firstFloatBelow(vals, *c.minF); i >= 0 {
					vdiag(out, line, "V005", fmt.Sprintf("value below min %s at '%s': %s", FormatFloat(*c.minF), schemaText(c.path), oneLine(els[i].text)))
				}
			}
			if c.maxF != nil {
				if i := firstFloatAbove(vals, *c.maxF); i >= 0 {
					vdiag(out, line, "V006", fmt.Sprintf("value above max %s at '%s': %s", FormatFloat(*c.maxF), schemaText(c.path), oneLine(els[i].text)))
				}
			}
		case "bool":
			vals := make([]bool, 0, len(els))
			for i := range els {
				v, ok := parseBoolText(els[i].text, d.strictness)
				if !ok {
					wrong()
					return
				}
				vals = append(vals, v)
			}
			if c.allowed != nil && c.allowed.kind == allowBools {
				for i, v := range vals {
					if !containsBool(c.allowed.bools, v) {
						vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
		case "datetime":
			vals := make([]DateTime, 0, len(els))
			for i := range els {
				v, ok := ParseDateTime(els[i].text)
				if !ok {
					wrong()
					return
				}
				vals = append(vals, v)
			}
			if c.allowed != nil && c.allowed.kind == allowDates {
				for i, v := range vals {
					if !containsDate(c.allowed.dates, v) {
						vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
		// A bare number takes its unit from the field name first, as the read
		// does, then the schema's `unit`.
		case "duration", "size":
			vals := make([]int64, 0, len(els))
			for i := range els {
				var v int64
				var ok bool
				if base == "duration" {
					bare := nameUnit(node.name, durationNames)
					if bare == DurationNone {
						bare = c.unitD
					}
					v, _, ok = parseDurationText(els[i].text, bare)
				} else {
					bare := nameUnit(node.name, sizeNames)
					if bare == SizeNone {
						bare = c.unitS
					}
					v, _, ok = parseSizeText(els[i].text, bare, c.decimal)
				}
				if !ok {
					wrong()
					return
				}
				vals = append(vals, v)
			}
			if c.allowed != nil && c.allowed.kind == allowInts {
				for i, v := range vals {
					if !containsInt(c.allowed.ints, v) {
						vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
			if c.minI != nil && c.minText != nil {
				for i, v := range vals {
					if v < *c.minI {
						vdiag(out, line, "V005", fmt.Sprintf("value below min %s at '%s': %s", oneLine(*c.minText), schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
			if c.maxI != nil && c.maxText != nil {
				for i, v := range vals {
					if v > *c.maxI {
						vdiag(out, line, "V006", fmt.Sprintf("value above max %s at '%s': %s", oneLine(*c.maxText), schemaText(c.path), oneLine(els[i].text)))
						break
					}
				}
			}
		default:
			// string kind or untyped: every element coerces; only the allowed
			// set can fail, in logical-string space.
			if c.allowed != nil && c.allowed.kind == allowStrings {
				for i := range els {
					s := els[i].text
					if !containsString(c.allowed.strs, s) {
						vdiag(out, line, "V004", fmt.Sprintf("value not allowed at '%s': %s", schemaText(c.path), oneLine(s)))
						break
					}
				}
			}
		}
	}
}

func containsInt(xs []int64, v int64) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func containsFloat(xs []float64, v float64) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func containsBool(xs []bool, v bool) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func containsDate(xs []DateTime, v DateTime) bool {
	for _, x := range xs {
		if sameMoment(x, v) {
			return true
		}
	}
	return false
}

// The four range scans return the offending index, or -1, so the diagnostic can
// name the value the reference's position() names.

func firstIntBelow(xs []int64, lo int64) int {
	for i, x := range xs {
		if x < lo {
			return i
		}
	}
	return -1
}

func firstIntAbove(xs []int64, hi int64) int {
	for i, x := range xs {
		if x > hi {
			return i
		}
	}
	return -1
}

func firstFloatBelow(xs []float64, lo float64) int {
	for i, x := range xs {
		if x < lo {
			return i
		}
	}
	return -1
}

func firstFloatAbove(xs []float64, hi float64) int {
	for i, x := range xs {
		if x > hi {
			return i
		}
	}
	return -1
}

// vUnknown is the unknown-field sweep: a schema path legalizes its name chain
// and every prefix (selectors ignored). Only the topmost unknown node is
// reported; its subtree is implied unknown and skipped.
func (d *Document) vUnknown(def *schemaDef, out *[]Diagnostic) {
	cons := def.cons
	// Chains below a fragment mount only match by descending the mounts.
	hasMounts := false
	for i := range cons {
		if cons[i].inherits != "" {
			hasMounts = true
			break
		}
	}
	legal := map[string]bool{}
	// Sibling names per parent chain, built once (schema order): vSuggest
	// used to rebuild every chain per unknown field, which bit hardest on
	// the wholesale-unmatched documents the feature exists for.
	siblings := map[string]*suggestNames{}
	// Paths with a `*` segment can't live in the exact-chain hash; they
	// match element-wise (a star matches any one name, prefixes included).
	var starPats [][]segment
	for i := range cons {
		for _, s := range cons[i].segs {
			if s.star {
				starPats = append(starPats, cons[i].segs)
				break
			}
		}
		chain := ""
		for _, s := range cons[i].segs {
			if s.star {
				break // no sibling entry for '*'; deeper chains are pattern-only
			}
			if siblings[chain] == nil {
				siblings[chain] = &suggestNames{seen: map[string]bool{}}
			}
			siblings[chain].push(s.name)
			chain = chainPush(chain, s.name)
			legal[chain] = true
		}
	}
	// Both element-wise matchers below used to scan their whole list per
	// document node, which is quadratic once the schema and the document grow
	// together. A path can only match a chain whose first part its own first
	// segment accepts, so one bucket lookup replaces the scan.
	starIdx := firstIndex(starPats)
	setIdx := map[string]firstIdx{}
	if hasMounts {
		// Keyed the way chainPartsLegal's dead set is: "" for the top-level
		// list, otherwise the fragment name.
		segsOf := func(cs []constraint) [][]segment {
			out := make([][]segment, len(cs))
			for i := range cs {
				out[i] = cs[i].segs
			}
			return out
		}
		setIdx[""] = firstIndex(segsOf(cons))
		for name, fcs := range def.frags {
			setIdx[name] = firstIndex(segsOf(fcs))
		}
	}
	type frame struct {
		node  int
		chain string
		shown string
	}
	var stack []frame
	kids := d.arena[root].children
	for i := len(kids) - 1; i >= 0; i-- {
		stack = append(stack, frame{node: kids[i]})
	}
	for len(stack) > 0 {
		fr := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		node := &d.arena[fr.node]
		chain := chainPush(fr.chain, node.name)
		seg := diagName(node.name)
		shown := seg
		if fr.shown != "" {
			shown = fr.shown + "." + seg
		}
		if !legal[chain] && !starLegal(starPats, starIdx, chain) && !(hasMounts && chainLegal(cons, def.frags, setIdx, chain)) {
			hint := vSuggest(siblings, fr.chain, node.name)
			vdiag(out, node.line, "V001", fmt.Sprintf("unknown field '%s'%s", shown, hint))
			continue
		}
		for i := len(node.children) - 1; i >= 0; i-- {
			stack = append(stack, frame{node: node.children[i], chain: chain, shown: shown})
		}
	}
}

// chainPush appends a segment to a chain key. Chain keys join segments
// length-prefixed (`<len>:<name>`), not with a bare NUL: NUL is legal in a
// quoted name, so a single field named "x\x00y" would impersonate the
// two-segment path x.y. Same injectivity reasoning as the merge key's cell
// encoding - and like it, the length unit is each binding's native one
// (bytes here), because only injectivity matters.
func chainPush(chain, name string) string {
	return chain + strconv.Itoa(len(name)) + ":" + name
}

// chainParts decodes a chain key back into its segments. Total: bails at the
// first shape the encoder can't have produced.
func chainParts(chain string) []string {
	var parts []string
	i := 0
	for i < len(chain) {
		n := 0
		for i < len(chain) && chain[i] >= '0' && chain[i] <= '9' {
			n = n*10 + int(chain[i]-'0')
			i++
		}
		if i >= len(chain) || chain[i] != ':' || i+1+n > len(chain) {
			break
		}
		i++
		parts = append(parts, chain[i:i+n])
		i += n
	}
	return parts
}

// starLegal is the element-wise chain match against the star-bearing schema
// paths: a `*` segment matches any one name, and every prefix of a path is
// legal.
func starLegal(pats [][]segment, idx firstIdx, chain string) bool {
	if len(pats) == 0 {
		return false
	}
	parts := chainParts(chain)
	for _, pi := range idx.candidates(parts[0]) {
		p := pats[pi]
		if len(p) < len(parts) {
			continue
		}
		ok := true
		for i, seg := range parts {
			if !p[i].star && p[i].name != seg {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// chainLegal is chain legality through fragment mounts: the general matcher -
// element-wise like starLegal (stars wild, prefixes legal), and when a mount's
// whole path matched with chain left over, the remainder is retried against
// the mounted fragment's fields. Terminates: every descent consumes >= 1 part.
func chainLegal(cons []constraint, frags map[string][]constraint, setIdx map[string]firstIdx, chain string) bool {
	parts := chainParts(chain)
	dead := map[chainState]bool{}
	return chainPartsLegal(cons, "", frags, setIdx, parts, 0, dead)
}

// firstIdx buckets schema paths by what their first segment accepts. A path
// can only match a chain whose first part is that segment's name, or anything
// at all when the segment is `*`, so a lookup plus the star bucket is the whole
// candidate set. Values are positions in the list the index was built from.
// Both callers ask "does any of these match", so bucket order cannot reach the
// answer.
type firstIdx struct {
	byName map[string][]int
	stars  []int
}

func (ix firstIdx) candidates(part string) []int {
	named := ix.byName[part]
	if len(ix.stars) == 0 {
		return named
	}
	out := make([]int, 0, len(named)+len(ix.stars))
	return append(append(out, named...), ix.stars...)
}

func firstIndex(paths [][]segment) firstIdx {
	ix := firstIdx{byName: map[string][]int{}}
	for i, segs := range paths {
		// A pathless entry keeps its old place in every candidate set: the
		// scan it replaces looked at one, and what it then did is unchanged.
		if len(segs) > 0 && !segs[0].star {
			ix.byName[segs[0].name] = append(ix.byName[segs[0].name], i)
		} else {
			ix.stars = append(ix.stars, i)
		}
	}
	return ix
}

// chainState: a fragment and how many parts are consumed on entry. One that
// has failed is not walked again - two mounts of the same fragment at the same
// depth used to be walked both, which is 2^depth on a chain that ends unknown.
type chainState struct {
	set string
	at  int
}

func chainPartsLegal(cons []constraint, set string, frags map[string][]constraint, setIdx map[string]firstIdx, parts []string, at int, dead map[chainState]bool) bool {
	if dead[chainState{set, at}] {
		return false
	}
	rest := parts[at:]
	// The recursion only descends with parts left over, and the sweep never
	// asks about an empty chain, so rest always has a first part to look up.
	cand, ok := setIdx[set]
	var order []int
	if ok {
		order = cand.candidates(rest[0])
	} else {
		order = make([]int, len(cons))
		for i := range cons {
			order[i] = i
		}
	}
	for _, ci := range order {
		c := &cons[ci]
		n := len(c.segs)
		k := len(rest)
		if n < k {
			k = n
		}
		matched := true
		for j := 0; j < k; j++ {
			if !c.segs[j].star && c.segs[j].name != rest[j] {
				matched = false
				break
			}
		}
		if !matched {
			continue
		}
		if len(rest) <= n {
			return true
		}
		if c.inherits != "" {
			if fcs, ok := frags[c.inherits]; ok && chainPartsLegal(fcs, c.inherits, frags, setIdx, parts, at+n, dead) {
				return true
			}
		}
	}
	dead[chainState{set, at}] = true
	return false
}

// vSuggest finds the closest legal sibling name (same parent chain, schema
// order, edit distance <= 2) as "; did you mean 'x'?" - or nothing. Prose
// only, never contract.
func vSuggest(siblings map[string]*suggestNames, parentChain, name string) string {
	names := siblings[parentChain]
	if names == nil {
		return ""
	}
	best, ok := names.closest(name)
	if !ok {
		return ""
	}
	return fmt.Sprintf("; did you mean '%s'?", diagName(best))
}

// suggestNames is the legal names under one parent chain, each once, in
// schema order. Every unknown field used to be compared with every sibling,
// and the list held one copy per schema field, so a document whose names all
// miss cost the schema times the document (20260918b item 10). Past the first
// few queries on a chain, each name of up to suggestIndexed characters is
// filed under every spelling it has with up to two characters deleted. Two
// names within edit distance 2 share such a spelling, so a query checks only
// the names its own spellings find. A longer name keeps the scan, filtered by
// length.
type suggestNames struct {
	names   []string
	seen    map[string]bool
	queries int
	index   map[uint64][]int
	long    []int
	// The query that last looked at each name, so a name found under several
	// spellings is measured once.
	stamp []int
}

const suggestIndexed = 16

// suggestScans is how many queries the scan answers before a chain gets its
// index. A few typos in a large section should not pay for indexing it.
const suggestScans = 16

func (sn *suggestNames) push(name string) {
	if !sn.seen[name] {
		sn.seen[name] = true
		sn.names = append(sn.names, name)
	}
}

func (sn *suggestNames) closest(name string) (string, bool) {
	sn.queries++
	bestDist, bestIdx := -1, -1
	consider := func(i int) {
		dist := editDistance(name, sn.names[i], 2)
		if dist <= 2 && (bestDist < 0 || dist < bestDist || (dist == bestDist && i < bestIdx)) {
			bestDist, bestIdx = dist, i
		}
	}
	if sn.queries <= suggestScans {
		for i := range sn.names {
			consider(i)
		}
	} else {
		if sn.index == nil {
			sn.index = map[uint64][]int{}
			for i, n := range sn.names {
				cs := []rune(n)
				if len(cs) > suggestIndexed {
					sn.long = append(sn.long, i)
					continue
				}
				deletionSpellings(cs, func(h uint64) {
					list := sn.index[h]
					if len(list) == 0 || list[len(list)-1] != i {
						sn.index[h] = append(list, i)
					}
				})
			}
			sn.stamp = make([]int, len(sn.names))
		}
		q := []rune(name)
		if len(q) <= suggestIndexed+2 {
			deletionSpellings(q, func(h uint64) {
				for _, i := range sn.index[h] {
					if sn.stamp[i] != sn.queries {
						sn.stamp[i] = sn.queries
						consider(i)
					}
				}
			})
		}
		for _, i := range sn.long {
			if absDiff(utf8.RuneCountInString(sn.names[i]), len(q)) <= 2 {
				consider(i)
			}
		}
	}
	if bestIdx < 0 {
		return "", false
	}
	return sn.names[bestIdx], true
}

// deletionSpellings calls f with the hash of each spelling of cs with none,
// one or two of its characters deleted. The same spelling can come up more
// than once.
func deletionSpellings(cs []rune, f func(uint64)) {
	hash := func(skipA, skipB int) uint64 {
		h := newFnv()
		var buf [utf8.UTFMax]byte
		for k, c := range cs {
			if k != skipA && k != skipB {
				n := utf8.EncodeRune(buf[:], c)
				for _, b := range buf[:n] {
					h.byte(b)
				}
			}
		}
		return h.h
	}
	f(hash(-1, -1))
	for a := range cs {
		f(hash(a, -1))
		for b := a + 1; b < len(cs); b++ {
			f(hash(a, b))
		}
	}
}
