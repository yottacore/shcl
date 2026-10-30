// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Heap growth over many rounds of load, read, set, save, merge and validate
// across the corpus, the C side of the Rust, Go and Python soaks. Nothing is
// kept from one round to the next, so the heap after round 2N should be the
// heap after round N. Round N, not round 0: the first rounds fill stdio's
// buffers and the locale cache. soak-c.bash runs it under heaptrack for the
// report, and glibc's own count of the bytes in use is what's judged, so it
// needs glibc and a build without ASan, whose allocator glibc can't see.
// argv[1] is the corpus root, argv[2] the scratch dir for the saves.

#define _POSIX_C_SOURCE 200809L // opendir and readdir under -std=c11

#define SHCL_IMPLEMENTATION
#include "shcl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif

#if defined(__has_feature)
#	if __has_feature(address_sanitizer)
#		define SOAK_NO_MALLINFO 1
#	endif
#endif
#if defined(__SANITIZE_ADDRESS__) || !defined(__GLIBC__)
#	define SOAK_NO_MALLINFO 1
#endif

// Growth from round N to round 2N that still passes. Measured at 0 bytes
// here, round after round; a leak of 10 bytes per case per round is over it.
#define SOAK_MARGIN ((size_t)4096)
#define SOAK_ROUNDS 3

typedef struct { char *input, *layer, *schema; size_t layer_n, schema_n; } soak_case;

static char *soak_join(const char *a, const char *b) {
	size_t na = strlen(a), nb = strlen(b);
	char *p = malloc(na + nb + 2);
	if (!p) { fprintf(stderr, "FAIL soak: out of memory\n"); exit(2); }
	memcpy(p, a, na); p[na] = '/'; memcpy(p + na + 1, b, nb + 1);
	return p;
}

// The text, or NULL when there's no such file.
static char *soak_slurp(const char *path, size_t *n) {
	shcl_file_status st;
	char *text = shcl_read_file(path, 0, n, &st);
	return st == SHCL_FILE_CLEAN ? text : (free(text), NULL);
}

static int soak_by_name(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static size_t soak_corpus(const char *root, soak_case **out) {
	DIR *dir = opendir(root);
	if (!dir) { fprintf(stderr, "FAIL soak: can't open the corpus at %s\n", root); exit(2); }
	char **names = NULL;
	size_t n = 0, cap = 0;
	struct dirent *e;
	while ((e = readdir(dir))) {
		if (e->d_name[0] == '.') continue;
		if (n == cap) {
			cap = cap ? cap * 2 : 256;
			char **grown = realloc(names, cap * sizeof *names);
			if (!grown) { fprintf(stderr, "FAIL soak: out of memory\n"); exit(2); }
			names = grown;
		}
		names[n++] = soak_join(root, e->d_name);
	}
	closedir(dir);
	if (n) qsort(names, n, sizeof *names, soak_by_name);
	soak_case *cases = calloc(n ? n : 1, sizeof *cases);
	if (!cases) { fprintf(stderr, "FAIL soak: out of memory\n"); exit(2); }
	size_t k = 0;
	for (size_t i = 0; i < n; i++) {
		char *input = soak_join(names[i], "input.shcl");
		FILE *f = fopen(input, "rb");
		if (!f) { free(input); free(names[i]); continue; }
		fclose(f);
		char *lp = soak_join(names[i], "layer1.shcl"), *sp = soak_join(names[i], "schema.shcl");
		cases[k].input = input;
		cases[k].layer = soak_slurp(lp, &cases[k].layer_n);
		cases[k].schema = soak_slurp(sp, &cases[k].schema_n);
		free(lp); free(sp); free(names[i]);
		k++;
	}
	free(names);
	*out = cases;
	return k;
}

#ifdef SHCL_SOAK_BAIT
// soak-c.bash's bait: a document kept for the whole run that every case adds
// a field to, so the heap grows every round and the soak has to say so.
static shcl_doc *soak_hoard;
static size_t soak_hoarded;
#endif

static void soak_round(const soak_case *cases, size_t n, const char *save_to) {
	for (size_t i = 0; i < n; i++) {
		const soak_case *c = &cases[i];
		shcl_file_status st;
		shcl_doc *d = shcl_load_file(c->input, &st);
		if (!d) { fprintf(stderr, "FAIL soak: %s: load %s\n", c->input, shcl_file_status_name(st)); exit(1); }
		shcl_str *paths = NULL;
		size_t np = shcl_paths(d, &paths);
		for (size_t j = 0; j < np; j++) {
			(void)shcl_read_string(d, paths[j].p, paths[j].n);
			(void)shcl_read_int(d, paths[j].p, paths[j].n);
			(void)shcl_read_children(d, paths[j].p, paths[j].n);
		}
		(void)shcl_set_string(d, "soak.name", 9, "round", 5);
		(void)shcl_set_int(d, "soak.count", 10, 42);
		(void)shcl_save_file(d, save_to, NULL);
		int kept = 0;
		(void)shcl_save_file_keep_lines(d, save_to, &kept, NULL);
		if (c->layer) {
			shcl_doc *over = shcl_parse(c->layer, c->layer_n);
			if (over) { shcl_merge(d, over); shcl_free(over); }
		}
		if (c->schema) {
			shcl_str text = shcl_to_canonical(d);
			shcl_doc *v = shcl_load_and_validate(text.p, text.n, c->schema, c->schema_n, SHCL_STANDARD);
			shcl_free(v);
		}
#ifdef SHCL_SOAK_BAIT
		char name[48];
		int nn = snprintf(name, sizeof name, "hoard.f%zu", soak_hoarded++);
		if (soak_hoard && nn > 0) (void)shcl_set_int(soak_hoard, name, (size_t)nn, 1);
#endif
		shcl_free(d);
	}
}

// One status line, with its test ID, as conformance.c prints them.
static const char *open_id, *open_name;
static void test_id(const char *id, const char *name) { open_id = id; open_name = name; }
static void test_id_end(const char *status) {
	printf("%-4s %s c %s\n", status, open_id, open_name);
	fflush(stdout);
}

int main(int argc, char **argv) {
	test_id("de57v", "soak_heap_settles");
	// The clock every runner pins, as conformance.c does.
#ifdef _WIN32
	_putenv_s("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT");
#else
	setenv("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT", 1);
#endif
#ifdef SOAK_NO_MALLINFO
	(void)argc; (void)argv;
	fprintf(stderr, "soak: needs glibc's heap stats, which an ASan build or another libc hides\n");
	test_id_end("SKIP");
	return 0;
#else
	const char *root = argc > 1 ? argv[1] : "project/conformance";
	const char *scratch = argc > 2 ? argv[2] : ".";
	const char *report = getenv("SHCL_SOAK_REPORT");
	soak_case *cases = NULL;
	size_t n = soak_corpus(root, &cases);
	if (n < 100) {
		fprintf(stderr, "FAIL soak: the corpus walk found %zu cases\n", n);
		test_id_end("FAIL");
		for (size_t i = 0; i < n; i++) { free(cases[i].input); free(cases[i].layer); free(cases[i].schema); }
		free(cases);
		return 1;
	}
	char *save_to = soak_join(scratch, "soak.shcl");
#ifdef SHCL_SOAK_BAIT
	soak_hoard = shcl_new();
#endif
	size_t at[2 * SOAK_ROUNDS];
	for (int r = 0; r < 2 * SOAK_ROUNDS; r++) {
		soak_round(cases, n, save_to);
		struct mallinfo2 mi = mallinfo2();
		at[r] = mi.uordblks + mi.hblkhd;
	}
	size_t grew = at[2 * SOAK_ROUNDS - 1] > at[SOAK_ROUNDS - 1] ? at[2 * SOAK_ROUNDS - 1] - at[SOAK_ROUNDS - 1] : 0;
	// codeql[cpp/world-writable-file-creation] the soak's report, made the way fopen makes any file
	FILE *out = report ? fopen(report, "w") : NULL;
	if (report && !out) fprintf(stderr, "soak: can't write %s\n", report);
	FILE *sinks[2] = { stdout, out };
	for (int s = 0; s < 2; s++) {
		FILE *f = sinks[s];
		if (!f || (s == 0 && grew <= SOAK_MARGIN)) continue;
		fprintf(f, "c soak: %zu cases, %d rounds, margin %zu bytes\nround\tin_use_bytes\n", n, 2 * SOAK_ROUNDS, SOAK_MARGIN);
		for (int r = 0; r < 2 * SOAK_ROUNDS; r++) fprintf(f, "%d\t%zu\n", r + 1, at[r]);
		fprintf(f, "grew %zu bytes from round %d to round %d\n", grew, SOAK_ROUNDS, 2 * SOAK_ROUNDS);
	}
	if (out) fclose(out);
	remove(save_to);
	free(save_to);
	for (size_t i = 0; i < n; i++) { free(cases[i].input); free(cases[i].layer); free(cases[i].schema); }
	free(cases);
#ifdef SHCL_SOAK_BAIT
	shcl_free(soak_hoard);
#endif
	if (grew > SOAK_MARGIN) {
		fprintf(stderr, "FAIL soak: the heap grew %zu bytes from round %d to round %d, past the %zu margin\n", grew, SOAK_ROUNDS, 2 * SOAK_ROUNDS, SOAK_MARGIN);
		test_id_end("FAIL");
		return 1;
	}
	test_id_end("PASS");
	return 0;
#endif
}
