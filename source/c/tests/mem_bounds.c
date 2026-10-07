// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Allocation bounds the corpus cannot see. A capped parse must not hold what
// it is about to refuse, and a read-only loop over a long-lived document must
// stay flat once shcl_reads_release has run. Its own translation unit because
// the counting allocator is global to the file.

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Nested rather than one expression: gcc 12 parses the whole #if line before it
   short-circuits, and refuses __has_feature(...) where the macro is undefined. */
#if defined(__has_feature)
#	if __has_feature(address_sanitizer)
#		define SHCL_UNDER_ASAN 1
#	endif
#endif
#if defined(__SANITIZE_ADDRESS__)
#	define SHCL_UNDER_ASAN 1
#endif

static size_t allocated = 0;
static void *counting_malloc(size_t n) { allocated += n; return malloc(n); }
static void *counting_calloc(size_t a, size_t b) { allocated += a * b; return calloc(a, b); }
static void *counting_realloc(void *p, size_t n) { allocated += n; return realloc(p, n); }

#define malloc counting_malloc
#define calloc counting_calloc
#define realloc counting_realloc
#define SHCL_IMPLEMENTATION
#include "shcl.h"
#undef malloc
#undef calloc
#undef realloc

static size_t arena_bytes(const ShclArena *a) {
	size_t n = 0;
	for (const ShclBlock *b = a->head; b; b = b->next) n += b->used;
	return n;
}

// What the arena holds from the system, used or not: a reset gives nothing
// back from the block it keeps.
static size_t arena_caps(const ShclArena *a) {
	size_t n = 0;
	for (const ShclBlock *b = a->head; b; b = b->next) n += b->cap;
	return n;
}

// Whether p points into one of the arena's blocks.
static int arena_holds(const ShclArena *a, const void *p) {
	for (const ShclBlock *b = a->head; b; b = b->next) {
		const char *base = (const char *)(b + 1);
		if ((const char *)p >= base && (const char *)p < base + b->cap) return 1;
	}
	return 0;
}

static int failures = 0;
// Wall time in milliseconds: clock() is CPU time, and on windows it ticks in
// whole milliseconds, too coarse for a ratio of two runs.
#ifdef _WIN32
#include <windows.h>
static double wall_ms(void) {
	LARGE_INTEGER f, c;
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&c);
	return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}
#else
static double wall_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}
#endif

static void fail(const char *what) { fprintf(stderr, "FAIL mem_bounds: %s\n", what); failures++; }

/* The pipeline's status line for this file's one test, with its test ID. */
static const char *open_id, *open_name;
static void test_id(const char *id, const char *name) { open_id = id; open_name = name; }
static int test_id_end(int failed) {
	printf("%-4s %s c %s\n", failed ? "FAIL" : "ok", open_id, open_name);
	fflush(stdout);
	return failed ? 1 : 0;
}

int main(void) {
	test_id("EoezJiG", "mem_bounds");
	// Element cap: 200k elements on one line, refused at a cap of 8. The
	// refused line used to be built in full first, so the cap saved nothing.
	size_t reps = 200000, tlen = 6 + reps * 3 + 9;
	char *text = (char *)malloc(tlen + 1);
	memcpy(text, "arr: [", 6);
	for (size_t i = 0; i < reps; i++) memcpy(text + 6 + i * 3, "1, ", 3);
	memcpy(text + 6 + reps * 3, "1]\nok: 5\n", 10);
	size_t before = allocated;
	shcl_doc *d = shcl_parse_limited(text, tlen, SHCL_STANDARD, 0, 8, 0);
	size_t capped = allocated - before;
	if (!d || shcl_lost_count(d) != 1 || shcl_get_int_or(d, "ok", 2, 0) != 5) fail("capped parse: wrong result");
	shcl_free(d);
	before = allocated;
	d = shcl_parse_limited(text, tlen, SHCL_STANDARD, 0, 0, 0);
	size_t uncapped = allocated - before;
	shcl_read_i64_arr ra = shcl_read_int_array(d, "arr", 3);
	if (ra.status != SHCL_GOOD || ra.n != reps + 1) fail("uncapped parse: wrong result");
	shcl_free(d);
	printf("mem_bounds: element cap: capped %zu, uncapped %zu, text %zu\n", capped, uncapped, tlen);
	if (capped > tlen * 8) fail("a capped parse held the array it refused");
	free(text);

	// Diagnostic cap: the stacked spelling refuses each element line past the
	// cap on its own, and every refusal is a diagnostic. With the element cap
	// alone, 200k refused lines cost more than the elements they refused; the
	// diagnostic cap is what bounds that, and an unlisted message must not
	// stay in the document either.
	tlen = 5 + reps * 5;
	text = (char *)malloc(tlen + 1);
	memcpy(text, "arr:\n", 5);
	for (size_t i = 0; i < reps; i++) memcpy(text + 5 + i * 5, "\t* 1\n", 5);
	before = allocated;
	d = shcl_parse_limited(text, tlen, SHCL_STANDARD, 0, 8, 100);
	size_t dcapped = allocated - before;
	if (!d || shcl_diag_count(d) != 101 || shcl_lost_count(d) != reps - 8) fail("diagnostic-capped parse: wrong result");
	shcl_free(d);
	printf("mem_bounds: diagnostic cap: %zu for text %zu\n", dcapped, tlen);
	if (dcapped > tlen * 8) fail("a diagnostic-capped parse held its unlisted diagnostics");
	free(text);

	// The parser borrows the scratch arena for its lines vector, per-parent
	// maps, stack and pending lists - about ten times the input. It used to sit
	// there until the first resolve, so a parsed document nobody read kept
	// all of it.
	tlen = 0;
	text = (char *)malloc(reps * 24 + 1);
	for (size_t i = 0; i < 20000; i++) tlen += (size_t)sprintf(text + tlen, "sect%zu:\n\tk: %zu\n", i, i);
	d = shcl_parse(text, tlen);
	size_t leftover = d ? arena_bytes(&d->scratch) : 0;
	printf("mem_bounds: parse scratch: %zu bytes left for text %zu\n", leftover, tlen);
	if (!d || shcl_get_int_or(d, "sect19999.k", 11, -1) != 19999) fail("scratch check: wrong result");
	if (leftover > 4096) fail("a parse left its temporaries in the scratch arena");
	shcl_free(d);
	free(text);

	// A read-only loop over a long-lived document, with shcl_reads_release
	// between passes, must stay flat: every read call, including the two that
	// take no path and so never pass through the path lookup's scratch reset.
	// shcl_paths grew the document 11 KB per call before the reset.
	ShclSB sb = {0}; ShclArena tmp = {0};
	for (int i = 0; i < 60; i++) { char line[48]; snprintf(line, sizeof line, "group%d:\n\ta: 1\n\tb: [x, y]\n", i); sb_puts(&tmp, &sb, line); }
	d = shcl_parse(sb.data, sb.len);
	arena_free(&tmp);
	if (!d) { fail("document for the read loop did not parse"); return test_id_end(failures); }
	// One call per loop: a path read anywhere in the same loop resets scratch
	// on the next call's behalf and hides a call that does not reset it.
	for (int which = 0; which < 4; which++) {
		size_t grew = 0;
		for (int pass = 0; pass < 2; pass++) {
			// The first pass warms every arena; growth is judged on the second.
			if (pass == 1) before = allocated;
			for (int i = 0; i < 2000; i++) {
				size_t got = 0;
				if (which == 0) { shcl_str *paths; got = shcl_paths(d, &paths); }
				else if (which == 1) { shcl_str *kids; got = shcl_children(d, "group7", 6, &kids); }
				else if (which == 2) got = shcl_read_string_array(d, "group7.b", 8).n;
				else got = shcl_to_canonical(d).n != 0;
				if (got != (size_t[]){180, 2, 2, 1}[which]) { fail("read loop: wrong result"); break; }
				shcl_reads_release(d);
			}
		}
		grew = allocated - before;
		printf("mem_bounds: read loop %d: %zu bytes over 2000 released passes\n", which, grew);
		if (grew > 4096) fail("a released read loop grew the document");
	}
	shcl_free(d);

	// The datetime reads split their text in the document arena, which nothing
	// resets, so a long-running reader grew without bound where the int read
	// stayed flat. One read per loop, for the same reason as above.
	{
		const char *dtext = "t: 2026-01-02 03:04:05.123456 +01:30\nts: [\"Jan 02 2026\", 2026-01-03T04:05:06.5Z, 20260104]\n";
		d = shcl_parse(dtext, strlen(dtext));
		if (!d) { fail("document for the datetime loop did not parse"); return test_id_end(failures); }
		for (int which = 0; which < 2; which++) {
			size_t arena0 = 0;
			for (int pass = 0; pass < 2; pass++) {
				if (pass == 1) { before = allocated; arena0 = arena_bytes(&d->arena); }
				for (int i = 0; i < 20000; i++) {
					int ok = which == 0 ? shcl_read_datetime(d, "t", 1).status == SHCL_GOOD : shcl_read_datetime_array(d, "ts", 2).n == 3;
					if (!ok) { fail("datetime loop: wrong result"); break; }
					shcl_reads_release(d);
				}
			}
			size_t agrew = arena_bytes(&d->arena) - arena0, grew = allocated - before;
			printf("mem_bounds: datetime loop %d: arena +%zu, %zu bytes allocated over 20000 released reads\n", which, agrew, grew);
			if (agrew != 0 || grew > 4096) fail("a datetime read grew the document");
		}
		shcl_free(d);
	}

	// A setter encodes into the document arena before the path is validated, so
	// a refused write used to cost the document the whole encoded value, for as
	// long as it lived.
	d = shcl_parse("a: 1\n", 5);
	size_t held = arena_bytes(&d->arena);
	size_t big = 4u * 1024 * 1024;
	char *blob = (char *)malloc(big);
	memset(blob, 'x', big);
	if (shcl_set_string(d, "a[*]", 4, blob, big)) fail("refused setter: the wildcard write was accepted");
	for (int i = 0; i < 5; i++) if (shcl_set_raw(d, "a[*]", 4, blob, big, "", 0)) fail("refused setter: the raw write was accepted");
	for (int i = 0; i < 10000; i++) if (shcl_set_int(d, "a[*]", 4, i)) fail("refused setter: the int write was accepted");
	size_t after = arena_bytes(&d->arena);
	printf("mem_bounds: refused writes: arena %zu -> %zu over 24 MB refused\n", held, after);
	if (after > held + 4096) fail("a refused setter kept the value it encoded");
	if (shcl_get_int_or(d, "a", 1, -1) != 1) fail("refused setter: the document changed");
	shcl_free(d);

	// The paths above are refused by the path, and w_place resets scratch. A
	// value refusal is checked in scratch too, and used to leave it there.
	d = shcl_parse("a: 1\n", 5);
	size_t mib = 1024u * 1024;
	memset(blob, 'x', mib);
	blob[mib / 2] = '#';
	char *lit = (char *)malloc(mib);
	memset(lit, 'y', mib);
	lit[0] = '"';
	for (int i = 0; i < 200; i++) {
		if (shcl_set_raw(d, "r", 1, "body", 4, blob, mib)) fail("refused setter: a raw info string holding # was accepted");
		if (shcl_set_literal(d, "l", 1, lit, mib)) fail("refused setter: an unterminated literal was accepted");
	}
	size_t scap = 0;
	for (const ShclBlock *b = d->scratch.head; b; b = b->next) scap += b->cap;
	printf("mem_bounds: value refusals: scratch %zu bytes after 400 refused MiB values\n", scap);
	if (scap > 64 * mib) fail("a value refusal kept its working set in scratch");
	shcl_free(d);
	free(lit);
	free(blob);

	// Generation used to copy its output into the schema's own arena before
	// checking it, so a refused call kept the text it never returned and a
	// succeeding one could never be released.
	const char *badschema = "field: server.port\n\ttype: int\n\trequired: yes\n\tmin: 1\n\tmax: 10\n\tdefault: 99\n";
	d = shcl_parse(badschema, strlen(badschema));
	held = arena_bytes(&d->arena);
	int gok = 1;
	for (int i = 0; i < 200; i++) { shcl_str t = shcl_generate(d, 1, &gok); if (gok || t.n) fail("refused generation returned something"); }
	printf("mem_bounds: refused generation: arena %zu -> %zu, %zu diagnostic(s)\n", held, arena_bytes(&d->arena), shcl_diag_count(d));
	if (arena_bytes(&d->arena) > held + 200 * 256) fail("a refused generation kept its output");
	if (shcl_diag_count(d) != 1) fail("generation faults accumulated across calls");
	shcl_free(d);
	// A schema that does not build: its build faults were pushed by the call
	// and dropped by code, V096 and V097 only, so each call added one more copy
	// (20260918b item 24). A schema diagnostic of the document's own stays.
	const char *nobuild = "field: srv\n\trepeat: 0..5\nbad line\n";
	d = shcl_parse(nobuild, strlen(nobuild));
	size_t own_diags = shcl_diag_count(d);
	for (int i = 0; i < 50; i++) { shcl_str t = shcl_generate(d, 1, &gok); if (gok || t.n) fail("a schema that does not build generated"); }
	printf("mem_bounds: unbuilt generation: %zu diagnostic(s) of its own, %zu after 50 calls\n", own_diags, shcl_diag_count(d));
	if (shcl_diag_count(d) != own_diags + 1) fail("schema build faults accumulated across generate calls");
	if (own_diags < 1 || strcmp(shcl_diag_code(d, 0), "E014") != 0) fail("the schema's own diagnostic was dropped");
	shcl_free(d);
	// The hint filters build the schema they read, and used to build it in the
	// schema's own arena, so a program holding one schema grew it per call.
	{
		const char *hschema = "field: item\n\trepeat: [0, 5]\nfield: sect\n\treopen: true\n";
		const char *htext = "item: a\nsect:\n\tk: 1\nother: 1\nitem: b\nsect:\n\tj: 2\n";
		shcl_doc *hs = shcl_parse(hschema, strlen(hschema));
		size_t sheld = arena_bytes(&hs->arena), dgrew = 0;
		for (int i = 0; i < 2000; i++) {
			shcl_doc *hd = shcl_parse(htext, strlen(htext));
			size_t dheld = arena_bytes(&hd->arena);
			if (shcl_diag_count(hd) != 2) { fail("hint filter: the document lost its hints before the filter"); shcl_free(hd); break; }
			shcl_suppress_declared_repeats(hs, hd);
			shcl_suppress_declared_reopens(hs, hd);
			dgrew += arena_bytes(&hd->arena) - dheld;
			if (shcl_diag_count(hd) != 0) fail("hint filter: a declared hint stayed");
			shcl_free(hd);
		}
		printf("mem_bounds: hint filter: schema arena %zu -> %zu, documents +%zu over 2000 calls\n", sheld, arena_bytes(&hs->arena), dgrew);
		if (arena_bytes(&hs->arena) != sheld || dgrew != 0) fail("a hint filter kept its working set in a document it does not own");
		shcl_free(hs);
	}
	d = shcl_parse("field: a\n\trequired: yes\n", 24);
	held = arena_bytes(&d->arena);
	for (int i = 0; i < 200; i++) { shcl_str t = shcl_generate(d, 1, &gok); if (!gok || !t.n) fail("generation failed"); shcl_reads_release(d); }
	printf("mem_bounds: released generation: arena %zu -> %zu\n", held, arena_bytes(&d->arena));
	if (arena_bytes(&d->arena) > held + 4096) fail("a released generation still grew the document");
	shcl_free(d);

	// The name index used to be rebuilt by walking the arena, which still holds
	// every node a set-and-remove cycle ever made - so the first read after a
	// merge grew with the number of edits, not with the document. Timed against
	// the same document with no dead nodes; the ratio is what matters, since an
	// absolute figure would be a machine constant.
	{
		double t[2];
		for (int churned = 0; churned < 2; churned++) {
			shcl_doc *cd = shcl_parse("g:\n\tk: 1\n", 9);
			/* A subtree per cycle, not a leaf. A removed leaf leaves its
			   parent's list, so the old walk only stepped over it and cost
			   three times a sound build. A removed subtree keeps its own list,
			   and the old walk indexed every dead child. */
			if (churned) for (int i = 0; i < 50000; i++) if (!shcl_set_int(cd, "g.tmp.x", 7, i) || shcl_remove(cd, "g.tmp", 5) != 1) { fail("churn cycle: set or remove refused"); break; }
			/* A second document, as the other three runners use. Merging one
			   onto itself returns before the index is dropped, so both sides
			   built the index once and timed 1999 hash lookups. */
			shcl_doc *ov = shcl_parse("g:\n\tk: 1\n", 9);
			double c0 = wall_ms();
			for (int i = 0; i < 2000; i++) { shcl_merge(cd, ov); if (shcl_get_int_or(cd, "g.k", 3, -1) != 1) fail("index walk: wrong result"); }
			t[churned] = wall_ms() - c0;
			shcl_free(ov);
			shcl_free(cd);
		}
		printf("mem_bounds: index rebuild: %.1f ms fresh, %.1f ms after 50k set+remove\n", t[0], t[1]);
		/* A ratio between two timings says nothing under a sanitizer, which
		   costs per allocation rather than per node walked. The plain build in
		   the test stage is where this is judged. */
#ifdef SHCL_UNDER_ASAN
		printf("mem_bounds: index rebuild ratio not judged under a sanitizer\n");
#else
		/* A generous ratio on purpose: the chain array is still sized by the
		   arena, which is a memset the walk cannot avoid. What the bound
		   catches is the walk itself going over every dead node. Two thousand
		   merges put that cost well past the constant term a shared runner
		   needs. On windows the allocator hands a freed 800 KB block back to
		   the system and faults it in again on the next rebuild, which the
		   hosted runner measured at half a second over two thousand merges;
		   the defect is seconds.
		   A clock that cannot resolve the fresh side leaves the ratio with no
		   denominator. That used to skip the judgment. The constant term alone
		   is an absolute figure on whatever machine is running, so it gets
		   room rather than being skipped. */
		{
			double bound = t[0] <= 0.0 ? 3000.0 : t[0] * 25 + 1000;
			if (t[1] > bound) fail("the index rebuild walks nodes the document no longer holds");
		}
#endif
	}

	/* A merge settles the comments of the blocks it visited, not of the whole
	   tree: a whole-tree pass made each small merge cost the document, and a
	   caller folding many layers onto a big one paid it every time. Timed
	   against the same merges with the big block left out. Same fixture in
	   every runner. */
	{
		double t[2];
		size_t cap = 3000000, len = 0;
		char *mtext = (char *)malloc(cap);
		if (!mtext) { fail("merge fixture: no memory"); return test_id_end(failures); }
		for (int withbig = 0; withbig < 2; withbig++) {
			len = (size_t)snprintf(mtext, cap, "g:\n\tk: 1\n");
			if (withbig) {
				len += (size_t)snprintf(mtext + len, cap - len, "big:\n");
				for (int i = 0; i < 100000; i++) len += (size_t)snprintf(mtext + len, cap - len, "\tc%d: %d\n", i, i);
			}
			shcl_doc *md = shcl_parse(mtext, len);
			shcl_doc *ov = shcl_parse("g:\n\tk: 1\n", 9);
			double c0 = wall_ms();
			for (int i = 0; i < 2000; i++) shcl_merge(md, ov);
			t[withbig] = wall_ms() - c0;
			if (shcl_get_int_or(md, "g.k", 3, -1) != 1) fail("merge fixture: wrong result");
			shcl_free(ov);
			shcl_free(md);
		}
		free(mtext);
		printf("mem_bounds: merge settle: %.1f ms alone, %.1f ms beside a 100k-child block\n", t[0], t[1]);
#ifdef SHCL_UNDER_ASAN
		printf("mem_bounds: merge settle ratio not judged under a sanitizer\n");
#else
		// The same bound as the index fixture above: the defect is a walk over
		// a hundred thousand nodes per merge, seconds past the constant term.
		{
			double bound = t[0] <= 0.0 ? 3000.0 : t[0] * 25 + 1000;
			if (t[1] > bound) fail("the merge settles blocks it never touched");
		}
#endif
	}

	/* A misplaced line kept as written made every edit and merge re-emit the
	   whole document to settle it, even one far from the line. Timed against
	   the same steps on the same document without the line. Same fixture in
	   every runner. Edits first, since a merge drops the name index and the
	   edit after it would rebuild it over the whole document either way. */
	{
		double t[2];
		size_t cap = 3000000, len = 0;
		char *ktext = (char *)malloc(cap);
		if (!ktext) { fail("kept-line fixture: no memory"); return test_id_end(failures); }
		for (int kept = 0; kept < 2; kept++) {
			len = (size_t)snprintf(ktext, cap, "g:\n\tk: 1\nbig:\n");
			for (int i = 0; i < 100000; i++) len += (size_t)snprintf(ktext + len, cap - len, "\tc%d: %d\n", i, i);
			if (kept) len += (size_t)snprintf(ktext + len, cap - len, " x: y\n");
			shcl_doc *kd = shcl_parse(ktext, len);
			shcl_doc *ov = shcl_parse("g:\n\tj: 1\n", 9);
			double c0 = wall_ms();
			for (int i = 0; i < 500; i++) if (!shcl_set_int(kd, "g.k", 3, i)) fail("kept-line fixture: set refused");
			for (int i = 0; i < 500; i++) shcl_merge(kd, ov);
			t[kept] = wall_ms() - c0;
			if (shcl_get_int_or(kd, "g.k", 3, -1) != 499) fail("kept-line fixture: wrong result");
			shcl_str canon = shcl_to_canonical(kd);
			int tail = canon.n >= 7 && memcmp(canon.p + canon.n - 7, "\n x: y\n", 7) == 0;
			if (tail != kept) fail("kept-line fixture: the kept line is not where the fixture put it");
			shcl_free(ov);
			shcl_free(kd);
		}
		free(ktext);
		printf("mem_bounds: kept-line settle: %.1f ms without the line, %.1f ms with it\n", t[0], t[1]);
#ifdef SHCL_UNDER_ASAN
		printf("mem_bounds: kept-line settle ratio not judged under a sanitizer\n");
#else
		{
			double bound = t[0] <= 0.0 ? 3000.0 : t[0] * 25 + 1000;
			if (t[1] > bound) fail("each edit and merge settles the whole document");
		}
#endif
	}

	// shcl_authored_name hands back the stored spelling, which lives in the
	// document's own arena - so it outlives shcl_reads_release, where the header
	// used to promise the shorter read-arena lifetime.
	{
		shcl_doc *ad = shcl_parse("SYMBOLS: 3\n", 11);
		shcl_str an = shcl_authored_name(ad, "symbols", 7);
		if (an.n != 7 || memcmp(an.p, "SYMBOLS", 7) != 0) fail("authored_name: wrong spelling");
		shcl_reads_release(ad);
		if (an.n != 7 || memcmp(an.p, "SYMBOLS", 7) != 0) fail("authored_name did not survive a read release");
		shcl_free(ad);
	}

	// A merge rebuilt the parent's child list in the document arena: first with
	// a builder whose every doubling step was abandoned there, then with an
	// exact-sized copy that still left the whole old list behind - 420 KB per
	// merge on a 40000-key parent, against the spec's "about a megabyte" for
	// five hundred. The list is rewritten in place now when it fits, so a leaf
	// override costs its cloned node and little else. A string value climbed
	// from 32 bytes the same way once; it is opened at its own size.
	{
		size_t keys = 20000, cap = keys * 24 + 16, tl = 0;
		char *txt = (char *)malloc(cap);
		for (size_t i = 0; i < keys; i++) tl += (size_t)sprintf(txt + tl, "k%zu: %zu\n", i, i);
		shcl_doc *base = shcl_parse(txt, tl);
		shcl_doc *over = shcl_parse("k0: 9\nk1: 8\nk2: 7\nk3: 6\nk4: 5\nk5: 4\nk6: 3\nk7: 2\n", 48);
		size_t start = arena_bytes(&base->arena);
		for (int i = 0; i < 200; i++) shcl_merge(base, over);
		size_t per = (arena_bytes(&base->arena) - start) / 200;
		printf("mem_bounds: merge: %zu bytes per merge of 8 leaves onto %zu keys (list is %zu)\n", per, keys, keys * sizeof(size_t));
		if (shcl_get_int_or(base, "k0", 2, -1) != 9 || shcl_get_int_or(base, "k7", 2, -1) != 2) fail("merge: wrong result");
		// Eight cloned nodes and their values, nothing list-sized.
		if (per > 4096) fail("a merge retained the parent's whole child list");
		shcl_free(over); shcl_free(base); free(txt);
	}
	// Remove's mark-and-rebuild work vectors were pushed on the document arena,
	// which nothing resets, so removing n same-named leaves left two n-sized
	// vectors plus their regrow garbage behind until shcl_compact.
	{
		size_t n = 20000, cap = n * 16 + 16, tl = 0;
		char *txt = (char *)malloc(cap);
		for (size_t i = 0; i < n; i++) tl += (size_t)sprintf(txt + tl, "k: %zu\n", i);
		d = shcl_parse(txt, tl);
		held = arena_bytes(&d->arena);
		size_t gone = shcl_remove(d, "k", 1);
		size_t grew = arena_bytes(&d->arena) - held;
		printf("mem_bounds: remove: %zu bytes to remove %zu of %zu instances\n", grew, gone, n);
		if (gone != n || shcl_count(d, "k", 1) != 0) fail("remove: wrong result");
		// Nothing target-sized: the three vectors are 480 KB between them.
		if (grew > 8192) fail("a remove retained its work vectors in the document arena");
		shcl_free(d); free(txt);
	}
	{
		big = 4u * 1024 * 1024;
		blob = (char *)malloc(big);
		memset(blob, 'x', big);
		d = shcl_parse("a: 1\n", 5);
		held = arena_bytes(&d->arena);
		if (!shcl_set_string(d, "a", 1, blob, big)) fail("set_string of a large value failed");
		size_t grew = arena_bytes(&d->arena) - held;
		printf("mem_bounds: set_string: %zu bytes for a %zu-byte value\n", grew, big);
		// The builder is opened at the value's own size, so the only slack is
		// the arena's block rounding. A doubling climb costs a multiple.
		if (grew > big + 65536) fail("a string value cost more than its own size");
		shcl_free(d);
		free(blob);
	}

	// A write goes into a bump arena and the value it replaced stays behind, so
	// a loop rewriting one field grows the document until shcl_free. Compaction
	// is the way out: the rebuilt document holds what it now contains and no
	// more, and reads the same.
	d = shcl_parse("group:\n\tkey: 1\n\tother: x\n", 26);
	size_t fresh = arena_bytes(&d->arena);
	for (int i = 0; i < 100000; i++) shcl_set_int(d, "group.key", 9, i);
	size_t grown = arena_bytes(&d->arena);
	shcl_str want = shcl_to_canonical(d);
	char *wcopy = (char *)malloc(want.n); memcpy(wcopy, want.p, want.n); size_t wn = want.n;
	shcl_compact(d);
	size_t compacted = arena_bytes(&d->arena);
	shcl_str got = shcl_to_canonical(d);
	printf("mem_bounds: writes: fresh %zu, after 100k rewrites %zu, compacted %zu\n", fresh, grown, compacted);
	if (grown < 1000000) fail("the rewrite loop did not grow the arena (the test measures nothing)");
	// The replaced value and little else: the path scan once stayed behind
	// too, about a kilobyte per call.
	if ((grown - fresh) / 100000 > 256) fail("a setter kept its path scan in the document arena");
	if (compacted > fresh * 2 + 4096) fail("compaction did not give the replaced values back");
	if (got.n != wn || memcmp(got.p, wcopy, wn) != 0 || shcl_get_int_or(d, "group.key", 9, -1) != 99999) fail("compaction changed the document");
	free(wcopy);
	shcl_free(d);

	// A default form on a present path writes nothing, but judges the value in
	// its probe document's scratch, and the reset after kept the newest block -
	// the one that grew for the value. One 4 MB string default held 12 MB until
	// shcl_free, and the array form 40.
	{
		big = (size_t)4 << 20;
		blob = (char *)malloc(big);
		memset(blob, 'x', big);
		d = shcl_parse("b: 1\n", 5);
		const char *arr[2] = {blob, blob};
		size_t lens[2] = {big, big};
		if (!shcl_set_string_default(d, "b", 1, blob, big)) fail("default probe: the string was refused");
		if (!shcl_set_string_array_default(d, "b", 1, arr, lens, 2)) fail("default probe: the array was refused");
		held = arena_caps(&d->arena) + arena_caps(&d->scratch) + arena_caps(&d->reads);
		if (d->probe_doc) held += arena_caps(&d->probe_doc->arena) + arena_caps(&d->probe_doc->scratch) + arena_caps(&d->probe_doc->reads);
		printf("mem_bounds: default probe: %zu bytes held after two 4 MB defaults\n", held);
		if (held > 1024 * 1024) fail("a default form that wrote nothing kept the value's working set");
		if (shcl_get_int_or(d, "b", 1, -1) != 1) fail("default probe: the document changed");
		shcl_free(d);
		free(blob);
	}

	// A tokens struct handed a second document grows in that one's read arena.
	// Its arrays stayed in the first one's, so freeing the first and tokenizing
	// again wrote into freed memory. The header asks for a zero between
	// documents; this is the guard for a caller who forgets, while both live.
	{
		shcl_doc *da = shcl_parse("a: 1\n", 5), *db = shcl_parse("b: 2\n", 5);
		shcl_tokens t;
		memset(&t, 0, sizeof t);
		shcl_tokenize(da, "a.b: 1, 2", 9, ':', 0, SHCL_RULES_CURRENT, &t);
		shcl_tokenize(db, "x.y.z: 3, 4, 5", 14, ':', 0, SHCL_RULES_CURRENT, &t);
		if (!arena_holds(&db->reads, t.segments) || !arena_holds(&db->reads, t.elements)) fail("tokens kept growing in another document's arena");
		shcl_free(da);
		shcl_tokenize(db, "p.q.r.s: 6, 7, 8, 9", 19, ':', 0, SHCL_RULES_CURRENT, &t);
		if (t.nseg != 4 || t.nelem != 4 || t.elements[3].start != 18) fail("tokens reused across documents: wrong result");
		shcl_free(db);
	}

	if (failures) return test_id_end(failures);
	printf("mem_bounds: OK\n");
	return test_id_end(failures);
}
