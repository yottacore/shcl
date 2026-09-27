// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// An allocation failure must not end the process. Every allocator here fails
// once a budget runs out; a parse or a validate that cannot finish comes back
// NULL, with nothing leaked and SHCL_OOM never reached. Its own translation
// unit because the allocator swap is global to the file - the same reason
// oom_hook.c has one.

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long budget = 1L << 30;
static void *failing_malloc(size_t n) { if (--budget < 0) return NULL; return malloc(n); }
static void *failing_calloc(size_t a, size_t b) { if (--budget < 0) return NULL; return calloc(a, b); }
static void *failing_realloc(void *p, size_t n) { if (--budget < 0) return NULL; return realloc(p, n); }

// The default exits; this one says which path got there first and then does the
// same, because a hook that returns is documented as broken.
#define SHCL_OOM() do { fprintf(stderr, "FAIL oom_recover: SHCL_OOM reached\n"); exit(1); } while (0)

#define malloc failing_malloc
#define calloc failing_calloc
#define realloc failing_realloc
#define SHCL_IMPLEMENTATION
#include "shcl.h"
#undef malloc
#undef calloc
#undef realloc

static int failures = 0;
static void fail(const char *what) { fprintf(stderr, "FAIL oom_recover: %s\n", what); failures++; }

// A document big enough that the parse takes many allocations, so the budgets
// below land in the middle of one rather than only at its edges.
static char *sample(size_t *len) {
	size_t cap = 64 * 1024;
	char *t = (char *)malloc(cap);
	size_t n = 0;
	n += (size_t)snprintf(t + n, cap - n, "group:\n");
	for (int i = 0; i < 400; i++) n += (size_t)snprintf(t + n, cap - n, "\tkey%d: value number %d\n", i, i);
	*len = n;
	return t;
}

// The same document indented with four spaces, which is not its canonical
// form, so a load that keeps the text keeps a copy of it.
static char *spaced(const char *text, size_t len, size_t *out) {
	char *t = (char *)malloc(len * 4 + 1);
	size_t n = 0;
	for (size_t i = 0; i < len; i++) {
		if (text[i] == '\t') { memcpy(t + n, "    ", 4); n += 4; }
		else t[n++] = text[i];
	}
	*out = n;
	return t;
}

// A finished keep-lines load gives its own text back on a save with no edit.
static void check_kept(shcl_doc *d, const char *text, size_t len, const char *what) {
	int kept = 0;
	shcl_str t = shcl_to_text_keep_lines(d, &kept);
	if (!kept || t.n != len || memcmp(t.p, text, len) != 0) fail(what);
}

// A schema for half of it, with a constraint on every field it names. Half so
// the unknown-key sweep at the end of a validate has work to do as well. The
// one-field schema this replaced took eight allocations end to end, so the
// walk a budget could run out in was one field long.
static char *schema(size_t *len) {
	size_t cap = 64 * 1024;
	char *t = (char *)malloc(cap);
	size_t n = 0;
	for (int i = 0; i < 200; i++)
		n += (size_t)snprintf(t + n, cap - n, "field: group.key%d\n\ttype: string\n\trequired: yes\n\tmin: 1\n\tmax: 100\n", i);
	*len = n;
	return t;
}

/* The pipeline's status line for this file's one test, with its test ID. */
static const char *open_id, *open_name;
static void test_id(const char *id, const char *name) { open_id = id; open_name = name; }
static int test_id_end(int failed) {
	printf("%-4s %s c %s\n", failed ? "FAIL" : "ok", open_id, open_name);
	fflush(stdout);
	return failed ? 1 : 0;
}

int main(void) {
	test_id("EoaFuVP", "oom_recover");
	size_t len; char *text = sample(&len);

	// Every budget short of the whole parse must come back NULL, and the ones
	// past it must read right. Nothing in between may crash or exit.
	int sawNull = 0, sawDoc = 0;
	for (long b = 0; b < 400; b++) {
		budget = b;
		shcl_doc *d = shcl_parse(text, len);
		budget = 1L << 30;
		if (!d) { sawNull = 1; continue; }
		sawDoc = 1;
		// Read something only a finished parse can produce. An int read of a
		// string field answers with its fallback on a whole document and on a
		// truncated one alike, so it could not tell the two apart - which is
		// what this line is here for.
		shcl_str *kids = NULL;
		size_t nk = shcl_children(d, "group", 5, &kids);
		if (nk != 400 || kids[399].n != 6 || memcmp(kids[399].p, "key399", 6) != 0) fail("a parse that finished came back short");
		shcl_free(d);
	}
	if (!sawNull) fail("no budget was tight enough to fail a parse");
	if (!sawDoc) fail("no budget was loose enough to finish a parse");

	// A load is the same call plus a read, so it reports the same way.
	{
		// A mingw binary's fopen does not translate /tmp, and windows hosts do
		// not all have a C:\tmp for it to land in.
		const char *dir = getenv("TMPDIR");
		if (!dir) dir = getenv("TMP");
		if (!dir) dir = getenv("TEMP");
		if (!dir) dir = "/tmp";
		char path[512];
		snprintf(path, sizeof path, "%s/shcl-oom-recover.shcl", dir);
		FILE *f = fopen(path, "wb");
		if (!f) fail("could not write the fixture");
		else {
			fwrite(text, 1, len, f); fclose(f);
			int sawNullL = 0;
			for (long b = 0; b < 400; b++) {
				budget = b;
				shcl_file_status st = SHCL_FILE_CLEAN;
				shcl_doc *d = shcl_load_file(path, &st);
				budget = 1L << 30;
				if (!d) sawNullL = 1; else shcl_free(d);
			}
			if (!sawNullL) fail("no budget was tight enough to fail a load");
			remove(path);
		}
	}

	// The loads that keep the text copy it and parse it once more to see
	// whether it is canonical, all behind a recovery point of their own.
	{
		size_t klen; char *ktext = spaced(text, len, &klen);
		int sawNullK = 0, sawDocK = 0;
		for (long b = 0; b < 400; b++) {
			budget = b;
			shcl_doc *d = shcl_parse_keep_lines(ktext, klen, SHCL_STANDARD);
			budget = 1L << 30;
			if (!d) { sawNullK = 1; continue; }
			sawDocK = 1;
			check_kept(d, ktext, klen, "a keep-lines parse that finished did not keep its text");
			shcl_free(d);
		}
		if (!sawNullK) fail("no budget was tight enough to fail a keep-lines parse");
		if (!sawDocK) fail("no budget was loose enough to finish a keep-lines parse");

		const char *dir = getenv("TMPDIR");
		if (!dir) dir = getenv("TMP");
		if (!dir) dir = getenv("TEMP");
		if (!dir) dir = "/tmp";
		char path[512];
		snprintf(path, sizeof path, "%s/shcl-oom-recover-keep.shcl", dir);
		FILE *f = fopen(path, "wb");
		if (!f) fail("could not write the keep-lines fixture");
		else {
			fwrite(ktext, 1, klen, f); fclose(f);
			int sawNullL = 0, sawDocL = 0;
			for (long b = 0; b < 400; b++) {
				budget = b;
				shcl_file_status st = SHCL_FILE_CLEAN;
				shcl_doc *d = shcl_load_file_keep_lines(path, SHCL_STANDARD, &st);
				budget = 1L << 30;
				if (!d) { sawNullL = 1; continue; }
				sawDocL = 1;
				check_kept(d, ktext, klen, "a keep-lines load that finished did not keep its text");
				shcl_free(d);
			}
			if (!sawNullL) fail("no budget was tight enough to fail a keep-lines load");
			if (!sawDocL) fail("no budget was loose enough to finish a keep-lines load");
			remove(path);
		}
		free(ktext);
	}

	// Validation reports the same way its parse does.
	{
		size_t slen; char *sch = schema(&slen);
		shcl_doc *d = shcl_parse(text, len);
		shcl_doc *s = shcl_parse(sch, slen);
		if (!d || !s) fail("the unbudgeted parses failed");
		else {
			// The same bound the parse and load sweeps use. It is well past
			// what a validate costs, which is the point: a budget that runs
			// out anywhere must come back NULL, and one loose enough to finish
			// must be in the sweep, or the tight ones prove nothing about a
			// path the call otherwise takes.
			int sawNullV = 0, sawVal = 0;
			for (long b = 0; b < 400; b++) {
				budget = b;
				shcl_validation *v = shcl_validate(d, s);
				budget = 1L << 30;
				if (!v) sawNullV = 1; else { sawVal = 1; shcl_validation_free(v); }
			}
			if (!sawNullV) fail("no budget was tight enough to fail a validate");
			if (!sawVal) fail("no budget was loose enough to finish a validate");
		}
		shcl_free(s); shcl_free(d);
		free(sch);
	}

	free(text);
	if (failures == 0) printf("oom_recover: ok\n");
	return test_id_end(failures);
}
