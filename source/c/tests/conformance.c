// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Conformance-corpus runner for the C binding. Same corpus every shipped binding
// must pass; column meanings live in project/conformance/README.md. Exit nonzero
// on any miss. Corpus root is argv[1] (default project/conformance, run from the
// repo root as cicd does).

#define _POSIX_C_SOURCE 200809L // strdup, opendir/readdir under -std=c11

// A consumer's own type names must survive the header: its internal typedefs
// are Shcl-prefixed, so these deliberately common names prove no collision
// remains (the public shcl_* surface is separate and unchanged).
typedef int Arena, Node, Value, Element, Str, Parser, Diag, Segment, Selector, Slot;

#define SHCL_IMPLEMENTATION
#include "shcl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <errno.h>
#include <dirent.h>
#ifdef _WIN32
#include <direct.h>   // _mkdir - windows' mkdir takes no mode argument
#include <sddl.h>     // the DACL fixture compares DACLs as SDDL
#else
#include <sys/stat.h>   // the file-mode fixture stats and chmods for itself
#include <pthread.h>    // the small-stack validate fixture
#include <unistd.h>     // sysconf, for the smallest stack this platform allows
#endif

// Temp root for the file-tier fixture. TMPDIR is the POSIX spelling; windows
// sets TEMP/TMP and has no /tmp to fall back on.
static const char *tmp_root(void) {
	const char *v;
	if ((v = getenv("TMPDIR")) && *v) return v;
	if ((v = getenv("TEMP")) && *v) return v;
	if ((v = getenv("TMP")) && *v) return v;
	return "/tmp";
}

#ifdef _WIN32
/* The fixture's own tree goes past MAX_PATH, and the narrow calls refuse such a
   path the same way the library used to - so its setup and teardown use the
   long-path prefix too. Forward slashes are not allowed after it. */
static wchar_t *long_wide(const char *p) {
	char buf[1200];
	int n = snprintf(buf, sizeof buf, "\\\\?\\%s", p);
	for (int i = 4; i < n; i++) if (buf[i] == '/') buf[i] = '\\';
	return shcl_widen(buf);
}
static void mkdir_long(const char *p) {
	wchar_t *w = long_wide(p);
	if (w) { CreateDirectoryW(w, NULL); free(w); }
}
static void remove_long(const char *p) {
	wchar_t *w = long_wide(p);
	if (w) { DeleteFileW(w); free(w); }
}
static void rmdir_long(const char *p) {
	wchar_t *w = long_wide(p);
	if (w) { RemoveDirectoryW(w); free(w); }
}
#endif

static int nfail = 0;
static void fail(const char *at, const char *msg) { fprintf(stderr, "FAIL %s: %s\n", at, msg); nfail++; }

/* One status line per test, with its test ID, for the pipeline's console. A
   fixture is open from its test_id() to the next one or to test_id_end(), and
   failed if anything was charged to nfail while it was open. */
static const char *open_id, *open_name;
static int open_fails, open_skipped;
static void test_line(const char *status, const char *id, const char *name) {
	printf("%-4s %s c %s\n", status, id, name);
	fflush(stdout);
}
static void test_id_end(void) {
	if (open_id) test_line(nfail > open_fails ? "FAIL" : open_skipped ? "skip" : "ok", open_id, open_name);
	open_id = NULL;
}
static void test_id(const char *id, const char *name) {
	test_id_end();
	open_id = id; open_name = name; open_fails = nfail; open_skipped = 0;
}
#ifdef _WIN32
// The open fixture could not run here. Only the windows link fixtures skip.
static void test_skip(void) { open_skipped = 1; }
#endif

/* The setter round-trip fixture works on documents of a few dozen bytes, so
   the canonical text is copied onto the stack rather than left in a read
   arena two documents deep. */
#define SOUP_BUF 128
static void soup_text(shcl_doc *d, char *out, size_t *n) {
	shcl_str c = shcl_to_canonical(d);
	if (c.n > SOUP_BUF) { fail("setters_read_back", "canonical text longer than the fixture buffer"); *n = 0; return; }
	memcpy(out, c.p, c.n); *n = c.n;
}
/* The failing input named as bytes: it is mostly punctuation and blanks.
   A kind below zero is the name half, which has no setter number. */
static void soup_fail(const char *msg, int kind, const char *in, size_t n) {
	fprintf(stderr, "FAIL setters_read_back: %s (", msg);
	if (kind >= 0) fprintf(stderr, "setter %d, ", kind);
	fprintf(stderr, "input");
	for (size_t i = 0; i < n; i++) fprintf(stderr, " %02x", (unsigned char)in[i]);
	fprintf(stderr, ")\n");
	nfail++;
}
/* One setter of the round-trip fixture, by number, so the shared document
   takes exactly what the one-off did. */
static int soup_set(shcl_doc *d, int kind, const char *p, size_t pn, const char *in, size_t inn) {
	switch (kind) {
	case 0: return shcl_set_string(d, p, pn, in, inn);
	case 1: return shcl_set_literal(d, p, pn, in, inn);
	case 2: return shcl_set_comment(d, p, pn, in, inn);
	case 3: return shcl_set_raw(d, p, pn, in, inn, "t", 1);
	case 4: return shcl_set_raw(d, p, pn, "body", 4, in, inn);
	default: { const char *av[2]; size_t al[2]; av[0] = "x"; al[0] = 1; av[1] = in; al[1] = inn; return shcl_set_string_array(d, p, pn, av, al, 2); }
	}
}
// Substring search over a length-delimited buffer (memmem is GNU-only).
static int contains(const char *p, size_t n, const char *needle) {
	size_t m = strlen(needle);
	if (m > n) return 0;
	for (size_t i = 0; i + m <= n; i++) if (memcmp(p + i, needle, m) == 0) return 1;
	return 0;
}

// realloc that never returns NULL: on OOM, free the old block and exit 2.
static void *xrealloc(void *p, size_t n) {
	void *q = realloc(p, n);
	if (!q) { free(p); fprintf(stderr, "out of memory\n"); exit(2); }
	return q;
}

static char *read_file(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) { *len = 0; return NULL; }
	char *buf = NULL; size_t cap = 0, n = 0, r; char chunk[65536];
	while ((r = fread(chunk, 1, sizeof chunk, f)) > 0) { if (n + r > cap) { cap = (n + r) * 2; buf = xrealloc(buf, cap); } memcpy(buf + n, chunk, r); n += r; }
	fclose(f);
	if (!buf) buf = xrealloc(NULL, 1);
	*len = n; return buf;
}

// Bytes the document arena holds, for the retention fixture.
static size_t arena_bytes(const ShclArena *a) {
	size_t n = 0;
	for (const ShclBlock *b = a->head; b; b = b->next) n += b->used;
	return n;
}

// Append s to *out with \n and \t escaped, as the corpus writes raw newlines.
static void tsv_escape(const char *s, size_t n, char **out, size_t *olen, size_t *ocap) {
	for (size_t i = 0; i < n; i++) {
		const char *rep = NULL;
		if (s[i] == '\n') rep = "\\n"; else if (s[i] == '\t') rep = "\\t";
		size_t add = rep ? 2 : 1;
		if (*olen + add + 1 > *ocap) { *ocap = (*olen + add + 1) * 2; *out = xrealloc(*out, *ocap); }
		if (rep) { (*out)[(*olen)++] = rep[0]; (*out)[(*olen)++] = rep[1]; }
		else (*out)[(*olen)++] = s[i];
	}
	(*out)[*olen] = '\0';
}

static shcl_strictness parse_level(const char *s) {
	if (!s || !*s || !strcmp(s, "standard")) return SHCL_STANDARD;
	if (!strcmp(s, "loose")) return SHCL_LOOSE;
	if (!strcmp(s, "strict")) return SHCL_STRICT;
	fprintf(stderr, "unknown level '%s' in reads.tsv\n", s); exit(2);
}

// Renders a scalar/array read into a malloc'd string (caller frees); sets *st,
// and for array kinds the per-slot statuses (arena memory, freed with the doc).
// A |-joined string of shcl_str values, the shape the reads.tsv list kinds
// compare against. Caller frees.
static char *join_pipe(const shcl_str *v, size_t n) {
	size_t jc = 8, jl = 0;
	char *joined = xrealloc(NULL, jc); joined[0] = '\0';
	for (size_t i = 0; i < n; i++) {
		if (i) { if (jl + 2 > jc) { jc = jl + 2; joined = xrealloc(joined, jc); } joined[jl++] = '|'; joined[jl] = '\0'; }
		if (jl + v[i].n + 1 > jc) { jc = jl + v[i].n + 1; joined = xrealloc(joined, jc); }
		memcpy(joined + jl, v[i].p, v[i].n); jl += v[i].n; joined[jl] = '\0';
	}
	return joined;
}

static char *scalar_read(shcl_doc *d, const char *kind, const char *q, size_t qn, shcl_status *st, const shcl_status **slots, size_t *nslots) {
	*slots = NULL; *nslots = 0;
	char *out = xrealloc(NULL, 8); memset(out, 0, 8); size_t olen = 0, ocap = 8; char nb[SHCL_FLOAT_BUF];
	#define AS_STR(P, N) do { if ((N) + 1 > ocap) { ocap = (N) + 1; out = xrealloc(out, ocap); } memcpy(out, (P), (N)); out[(N)] = '\0'; olen = (N); } while (0)
	if (!strcmp(kind, "int")) { shcl_read_i64 r = shcl_read_int(d, q, qn); *st = r.status; int k = snprintf(nb, sizeof nb, "%" PRId64, r.value); AS_STR(nb, (size_t)k); }
	else if (!strcmp(kind, "float")) { shcl_read_f64 r = shcl_read_float(d, q, qn); *st = r.status; size_t k = shcl_format_float(r.value, nb); AS_STR(nb, k); }
	else if (!strcmp(kind, "bool")) { shcl_read_bool r = shcl_read_bool_(d, q, qn); *st = r.status; AS_STR(r.value ? "true" : "false", r.value ? 4u : 5u); }
	else if (!strcmp(kind, "datetime")) { shcl_read_dt r = shcl_read_datetime(d, q, qn); *st = r.status; size_t k = shcl_datetime_str(&r.value, nb); AS_STR(nb, k); }
	else if (!strcmp(kind, "string")) { shcl_read_str r = shcl_read_string(d, q, qn); *st = r.status; tsv_escape(r.value.p, r.value.n, &out, &olen, &ocap); }
	else if (!strcmp(kind, "raw")) { shcl_read_str r = shcl_read_raw(d, q, qn); *st = r.status; tsv_escape(r.value.p, r.value.n, &out, &olen, &ocap); }
	else if (!strcmp(kind, "rawinfo")) { shcl_read_str r = shcl_read_raw_info(d, q, qn); *st = r.status; tsv_escape(r.value.p, r.value.n, &out, &olen, &ocap); }
	else if (!strcmp(kind, "int[]")) { shcl_read_i64_arr r = shcl_read_int_array(d, q, qn); *st = r.status; *slots = r.statuses; *nslots = r.n; for (size_t i = 0; i < r.n; i++) { if (i) tsv_escape("|", 1, &out, &olen, &ocap); int k = snprintf(nb, sizeof nb, "%" PRId64, r.values[i]); tsv_escape(nb, (size_t)k, &out, &olen, &ocap); } }
	else if (!strcmp(kind, "float[]")) { shcl_read_f64_arr r = shcl_read_float_array(d, q, qn); *st = r.status; *slots = r.statuses; *nslots = r.n; for (size_t i = 0; i < r.n; i++) { if (i) tsv_escape("|", 1, &out, &olen, &ocap); size_t k = shcl_format_float(r.values[i], nb); tsv_escape(nb, k, &out, &olen, &ocap); } }
	else if (!strcmp(kind, "bool[]")) { shcl_read_bool_arr r = shcl_read_bool_array(d, q, qn); *st = r.status; *slots = r.statuses; *nslots = r.n; for (size_t i = 0; i < r.n; i++) { if (i) tsv_escape("|", 1, &out, &olen, &ocap); const char *b = r.values[i] ? "true" : "false"; tsv_escape(b, strlen(b), &out, &olen, &ocap); } }
	else if (!strcmp(kind, "datetime[]")) { shcl_read_dt_arr r = shcl_read_datetime_array(d, q, qn); *st = r.status; *slots = r.statuses; *nslots = r.n; for (size_t i = 0; i < r.n; i++) { if (i) tsv_escape("|", 1, &out, &olen, &ocap); size_t k = shcl_datetime_str(&r.values[i], nb); tsv_escape(nb, k, &out, &olen, &ocap); } }
	else if (!strcmp(kind, "string[]")) { shcl_read_str_arr r = shcl_read_string_array(d, q, qn); *st = r.status; *slots = r.statuses; *nslots = r.n; for (size_t i = 0; i < r.n; i++) { if (i) tsv_escape("|", 1, &out, &olen, &ocap); tsv_escape(r.values[i].p, r.values[i].n, &out, &olen, &ocap); } }
	else if (!strncmp(kind, "duration", 8) || !strncmp(kind, "size", 4)) {
		/* duration[@UNIT] or size[@UNIT][+decimal]: the unit a bare number
		   takes, and KB to TB in powers of 1000. */
		size_t kn = strlen(kind);
		int decimal = kn > 8 && !strcmp(kind + kn - 8, "+decimal");
		if (decimal) kn -= 8;
		const char *at = memchr(kind, '@', kn);
		const char *unit = at ? at + 1 : "";
		size_t un = at ? (size_t)(kind + kn - unit) : 0;
		int64_t v;
		if (kind[0] == 'd') { shcl_read_i64 r = shcl_read_duration(d, q, qn, un ? shcl_duration_unit_of(unit, un) : SHCL_DURATION_NONE); *st = r.status; v = r.value; }
		else { shcl_read_i64 r = shcl_read_size(d, q, qn, un ? shcl_size_unit_of(unit, un) : SHCL_SIZE_NONE, decimal); *st = r.status; v = r.value; }
		int k = snprintf(nb, sizeof nb, "%" PRId64, v); tsv_escape(nb, (size_t)k, &out, &olen, &ocap);
	}
	else { fprintf(stderr, "unknown type '%s'\n", kind); exit(2); }
	#undef AS_STR
	return out;
}

// ops-value unescape (\n \t \\); out >= inlen. Returns length.
static size_t cf_unescape(const char *in, size_t inlen, char *out) {
	size_t w = 0;
	for (size_t i = 0; i < inlen; i++) {
		if (in[i] != '\\' || i + 1 >= inlen) { out[w++] = in[i]; continue; }
		char c = in[++i];
		if (c == 'n') out[w++] = '\n';
		else if (c == 't') out[w++] = '\t';
		else if (c == '\\') out[w++] = '\\';
		else { out[w++] = '\\'; out[w++] = c; }
	}
	return w;
}

// Reference-equivalent op-value gates (same grammar the CLI applies): sign +
// ASCII digits + i64 range for ints; the Rust f64 FromStr grammar for floats
// (overflow yields +-inf, not an error).
static int cf_i64(const char *p, size_t n, int64_t *out) {
	size_t i = 0;
	if (i < n && (p[i] == '+' || p[i] == '-')) i++;
	if (i == n) return 0;
	for (size_t k = i; k < n; k++) if (p[k] < '0' || p[k] > '9') return 0;
	char *b = (char *)xrealloc(NULL, n + 1); memcpy(b, p, n); b[n] = 0;
	errno = 0; char *end; long long v = strtoll(b, &end, 10);
	int ok = *end == 0 && errno != ERANGE;
	free(b);
	if (!ok) return 0;
	*out = (int64_t)v; return 1;
}
static int cf_ci_eq(const char *p, size_t n, const char *kw) {
	size_t kn = strlen(kw);
	if (n != kn) return 0;
	for (size_t i = 0; i < n; i++) { char c = p[i]; if (c >= 'A' && c <= 'Z') c += 32; if (c != kw[i]) return 0; }
	return 1;
}
static int cf_f64(const char *p, size_t n, double *out) {
	size_t i = 0;
	if (i < n && (p[i] == '+' || p[i] == '-')) i++;
	if (!(cf_ci_eq(p + i, n - i, "inf") || cf_ci_eq(p + i, n - i, "infinity") || cf_ci_eq(p + i, n - i, "nan"))) {
		size_t d1 = 0, d2 = 0;
		while (i < n && p[i] >= '0' && p[i] <= '9') { i++; d1++; }
		if (i < n && p[i] == '.') { i++; while (i < n && p[i] >= '0' && p[i] <= '9') { i++; d2++; } }
		if (d1 + d2 == 0) return 0;
		if (i < n && (p[i] == 'e' || p[i] == 'E')) {
			i++;
			if (i < n && (p[i] == '+' || p[i] == '-')) i++;
			size_t d3 = 0;
			while (i < n && p[i] >= '0' && p[i] <= '9') { i++; d3++; }
			if (d3 == 0) return 0;
		}
		if (i != n) return 0;
	}
	/* strtod follows the locale's decimal point, and the gate runs this under a
	   comma-decimal one. An op file writes a float with '.', same as a
	   document, so translate before the call - the library does the same at its
	   own two conversion sites. */
	const char *dp = localeconv()->decimal_point;
	size_t dn = (dp && *dp) ? strlen(dp) : 1;
	if (!dp || !*dp) dp = ".";
	char *b = (char *)xrealloc(NULL, n * dn + 1);
	size_t j = 0;
	for (size_t k = 0; k < n; k++) {
		if (p[k] == '.') { memcpy(b + j, dp, dn); j += dn; }
		else b[j++] = p[k];
	}
	b[j] = 0;
	*out = strtod(b, NULL);
	free(b);
	return isfinite(*out) ? 1 : 0;
}
// Exactly `true` or `false`; anything else is rejected, like a bad int.
static int cf_bool(const char *p, int *out) {
	if (!strcmp(p, "true")) { *out = 1; return 1; }
	if (!strcmp(p, "false")) { *out = 0; return 1; }
	return 0;
}

// Apply one write-ops line (NUL-terminated, tab-split in place) via the library
// Writer, with the CLI's value gates. A "-default" suffix means "only if
// absent"; values gate first, like the reference. Returns 0 ok, 1 rejected.
static int try_apply_op_c(shcl_doc *d, char *line) {
	size_t cap = 8, nf = 0; char **f = (char **)xrealloc(NULL, cap * sizeof *f);
	f[nf++] = line;
	for (char *p = line; *p; p++) if (*p == '\t') { *p = '\0'; if (nf == cap) { cap *= 2; f = (char **)xrealloc(f, cap * sizeof *f); } f[nf++] = p + 1; }
	char *op = f[0];
	const char *path = nf > 1 ? f[1] : ""; size_t plen = nf > 1 ? strlen(f[1]) : 0;
	const char *v = nf > 2 ? f[2] : ""; size_t vn = nf > 2 ? strlen(f[2]) : 0;
	size_t an = nf > 2 ? nf - 2 : 0;
	size_t oplen = strlen(op);
	int only_absent = 0, rc = 0, wrote = 1;
	if (oplen >= 8 && !strcmp(op + oplen - 8, "-default")) {
		only_absent = 1;
		op[oplen - 8] = '\0';
	}
	// A default op is the library's default form, so a path that is already
	// there still has its value and its path judged the way a write would.
	#define SET(fn, ...) (only_absent ? fn##_default(d, path, plen, __VA_ARGS__) : fn(d, path, plen, __VA_ARGS__))
	if (!strcmp(op, "int")) { int64_t x; if (!cf_i64(v, vn, &x)) rc = 1; else wrote = SET(shcl_set_int, x); }
	else if (!strcmp(op, "float")) { double x; if (!cf_f64(v, vn, &x)) rc = 1; else wrote = SET(shcl_set_float, x); }
	else if (!strcmp(op, "bool")) { int x; if (!cf_bool(v, &x)) rc = 1; else wrote = SET(shcl_set_bool, x); }
	else if (!strcmp(op, "literal")) { wrote = SET(shcl_set_literal, v, vn); }
	else if (!strcmp(op, "string")) { char *b = (char *)xrealloc(NULL, vn ? vn : 1); size_t m = cf_unescape(v, vn, b); wrote = SET(shcl_set_string, b, m); free(b); }
	else if (!strcmp(op, "datetime")) { shcl_datetime dt; ShclStr sv; sv.p = v; sv.n = vn; if (!parse_datetime(&d->arena, sv, &dt)) rc = 1; else wrote = SET(shcl_set_datetime, &dt); }
	else if (!strcmp(op, "int-array")) {
		int64_t *a = (int64_t *)xrealloc(NULL, (an ? an : 1) * sizeof *a);
		for (size_t i = 0; i < an && !rc; i++) if (!cf_i64(f[2 + i], strlen(f[2 + i]), &a[i])) rc = 1;
		if (!rc) wrote = SET(shcl_set_int_array, a, an);
		free(a);
	}
	else if (!strcmp(op, "float-array")) {
		double *a = (double *)xrealloc(NULL, (an ? an : 1) * sizeof *a);
		for (size_t i = 0; i < an && !rc; i++) if (!cf_f64(f[2 + i], strlen(f[2 + i]), &a[i])) rc = 1;
		if (!rc) wrote = SET(shcl_set_float_array, a, an);
		free(a);
	}
	else if (!strcmp(op, "bool-array")) {
		int *a = (int *)xrealloc(NULL, (an ? an : 1) * sizeof *a);
		for (size_t i = 0; i < an && !rc; i++) if (!cf_bool(f[2 + i], &a[i])) rc = 1;
		if (!rc) wrote = SET(shcl_set_bool_array, a, an);
		free(a);
	}
	else if (!strcmp(op, "string-array")) {
		char **sv = (char **)xrealloc(NULL, (an ? an : 1) * sizeof *sv); size_t *sl = (size_t *)xrealloc(NULL, (an ? an : 1) * sizeof *sl);
		sv[0] = NULL; sl[0] = 0; // silence -Wmaybe-uninitialized for the an==0 call
		for (size_t i = 0; i < an; i++) { size_t L = strlen(f[2 + i]); char *b = (char *)xrealloc(NULL, L ? L : 1); sl[i] = cf_unescape(f[2 + i], L, b); sv[i] = b; }
		wrote = SET(shcl_set_string_array, (const char *const *)sv, sl, an);
		for (size_t i = 0; i < an; i++) free(sv[i]);
		free(sv); free(sl);
	}
	else if (!strcmp(op, "datetime-array")) {
		shcl_datetime *a = (shcl_datetime *)xrealloc(NULL, (an ? an : 1) * sizeof *a);
		for (size_t i = 0; i < an && !rc; i++) { ShclStr sv; sv.p = f[2 + i]; sv.n = strlen(f[2 + i]); if (!parse_datetime(&d->arena, sv, &a[i])) rc = 1; }
		if (!rc) wrote = SET(shcl_set_datetime_array, a, an);
		free(a);
	}
	else if (!strcmp(op, "raw")) { const char *cont = nf > 3 ? f[3] : ""; size_t cn = nf > 3 ? strlen(f[3]) : 0; char *b = (char *)xrealloc(NULL, cn ? cn : 1); size_t m = cf_unescape(cont, cn, b); wrote = SET(shcl_set_raw, b, m, v, vn); free(b); }
	else if (!strcmp(op, "empty") && !only_absent) wrote = shcl_set_empty(d, path, plen);
	else if (!strcmp(op, "comment") && !only_absent) { char *b = (char *)xrealloc(NULL, vn ? vn : 1); size_t m = cf_unescape(v, vn, b); wrote = shcl_set_comment(d, path, plen, b, m); free(b); }
	else if (!strcmp(op, "remove") && !only_absent) shcl_remove(d, path, plen);
	else if (!strcmp(op, "clear-comments") && !only_absent) shcl_clear_comments(d, path, plen);
	else if (!strcmp(op, "banner") && !only_absent) {
		if (!strcmp(path, "on") || !strcmp(path, "off")) shcl_set_banner(d, !strcmp(path, "on"));
		else rc = 1;
	}
	else rc = 2; // no such op here: a misspelled bad-ops row is a fixture bug
	if (rc == 0 && !wrote) rc = 1;
	#undef SET
	free(f);
	return rc;
}

// Good-path wrapper: the op must apply.
static void apply_op_c(shcl_doc *d, char *line) {
	if (try_apply_op_c(d, line)) { fprintf(stderr, "write op rejected: %s\n", line); nfail++; }
}

static int cmp_str(const void *a, const void *b) { return strcmp(*(const char *const *)a, *(const char *const *)b); }

// The load diagnostics of a document at Standard, written the way `check`
// prints them: one line per diagnostic, then the summary. malloc'd; *len gets
// the length.
static char *diag_text(shcl_doc *d, size_t *len) {
	size_t ndiag = shcl_diag_count(d), nerr = 0;
	char *dj = xrealloc(NULL, 64); size_t jl = 0, jc = 64;
	for (size_t i = 0; i < ndiag; i++) {
		if (shcl_diag_severity(d, i) == SHCL_SEV_ERROR) nerr++;
		char ln[128]; int w = snprintf(ln, sizeof ln, "line %zu: %s: %s\n", shcl_diag_line(d, i), shcl_diag_severity(d, i) == SHCL_SEV_ERROR ? "Error" : "Hint", shcl_diag_code(d, i));
		if (jl + (size_t)w + 1 > jc) { jc = (jl + (size_t)w + 1) * 2; dj = xrealloc(dj, jc); }
		memcpy(dj + jl, ln, (size_t)w); jl += (size_t)w;
	}
	char sum[96]; int sw;
	if (nerr) sw = snprintf(sum, sizeof sum, "failed: %zu diagnostic(s), %zu error(s)\n", ndiag, nerr);
	else sw = snprintf(sum, sizeof sum, "ok (%zu diagnostic(s))\n", ndiag);
	if (jl + (size_t)sw + 1 > jc) { jc = jl + (size_t)sw + 1; dj = xrealloc(dj, jc); }
	memcpy(dj + jl, sum, (size_t)sw); jl += (size_t)sw;
	*len = jl;
	return dj;
}

// Splits raw TSV/text buffer into an array of NUL-terminated lines (in place).
static size_t split_lines(char *buf, size_t n, char ***out) {
	size_t cap = 16, cnt = 0; char **lines = xrealloc(NULL, cap * sizeof *lines);
	size_t start = 0;
	for (size_t i = 0; i <= n; i++) if (i == n || buf[i] == '\n') {
		if (cnt == cap) { cap *= 2; lines = xrealloc(lines, cap * sizeof *lines); }
		buf[i] = '\0'; lines[cnt++] = buf + start; start = i + 1;
	}
	*out = lines; return cnt;
}

#ifndef _WIN32
// Runs one validation and reports back through the return value, so a stack
// overflow inside it is a crashed run rather than a quiet pass.
static void *validate_on_small_stack(void *unused) {
	(void)unused;
	const char *doc = "port: 8080\n";
	const char *sch = "field: port\n\ttype: int\n\trequired: yes\n";
	shcl_doc *d = shcl_parse(doc, strlen(doc));
	shcl_doc *s = shcl_parse(sch, strlen(sch));
	shcl_validation *v = shcl_validate(d, s);
	size_t n = shcl_validation_count(v);
	shcl_validation_free(v);
	shcl_free(s);
	shcl_free(d);
	return n == 0 ? (void *)1 : NULL;
}
#endif

#ifdef _WIN32
static int text_is(const char *path, const char *want) {
	size_t n; char *t = read_file(path, &n);
	int same = t && n == strlen(want) && memcmp(t, want, n) == 0;
	free(t);
	return same;
}

static void seed(const char *path, const char *text) {
	FILE *f = fopen(path, "wb");
	if (!f || fputs(text, f) == EOF || fclose(f) != 0) fail("publish", "seed write failed");
}

static int there(const char *path) { return GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES; }

static DWORD WINAPI close_later(LPVOID hold) {
	Sleep(20);
	CloseHandle((HANDLE)hold);
	return 0;
}

// A save always puts its temp file beside the target, so these call the
// publish directly.
static void publish_failures(void) {
	char dir[256], x[272], y[272], target[300], tmp[300], backup[300], cmd[700];
	wchar_t wtarget[320], wtmp[320];
	snprintf(dir, sizeof dir, "%s\\shcl-publish-%ld", tmp_root(), (long)getpid());
	snprintf(x, sizeof x, "%s\\x", dir);
	snprintf(y, sizeof y, "%s\\y", dir);
	if (_mkdir(dir) != 0 || _mkdir(x) != 0 || _mkdir(y) != 0) fail("publish", "mkdir failed");
	// Taking add-file away from the target's folder, with the temp file in
	// another, lets ReplaceFile move the old file out to the backup and then
	// refuses the new one its place: error 1177, with nothing at the target.
	// Neither the move nor putting the old file back can get in either.
	snprintf(target, sizeof target, "%s\\t.shcl", y);
	snprintf(tmp, sizeof tmp, "%s\\.t.shcl.tmp1.0", x);
	snprintf(backup, sizeof backup, "%s\\.t.shcl.bak1.0", x);
	seed(target, "old\n");
	seed(tmp, "new\n");
	MultiByteToWideChar(CP_UTF8, 0, target, -1, wtarget, 320);
	MultiByteToWideChar(CP_UTF8, 0, tmp, -1, wtmp, 320);
	snprintf(cmd, sizeof cmd, "icacls \"%s\" /deny *S-1-1-0:(WD) >nul", y);
	if (system(cmd) != 0) fail("publish", "icacls deny failed");
	// The hosted runner's administrator is let through anyway, and the case
	// cannot be set up there.
	char probe[300], probed[300];
	snprintf(probe, sizeof probe, "%s\\probe", x);
	snprintf(probed, sizeof probed, "%s\\probe", y);
	seed(probe, "");
	int let_in = MoveFileExA(probe, probed, 0) != 0;
	int published = let_in ? 0 : shcl_publish_file(wtmp, wtarget);
	snprintf(cmd, sizeof cmd, "icacls \"%s\" /remove:d *S-1-1-0 >nul", y);
	if (system(cmd) != 0) fail("publish", "icacls remove failed");
	remove(probe); remove(probed);
	if (let_in) printf("conformance: skipping the failed-publish fixture (a move into a denied folder went through)\n");
	else if (published) fail("publish", "the publish went through");
	else if (text_is(target, "old\n")) {
		if (there(tmp)) fail("publish", "the temp file was left");
	} else {
		if (there(target)) fail("publish", "target holds neither text");
		if (!text_is(backup, "old\n")) fail("publish", "the old file is not at the backup name");
		if (!text_is(tmp, "new\n")) fail("publish", "the new text is not in the temp file");
	}
	remove(target); remove(tmp); remove(backup);
	// Anything holding the temp file open without delete sharing fails the
	// replace and the move both, the way a scanner looking at a fresh file
	// does. A hold that ends in a few milliseconds must not fail the save.
	snprintf(target, sizeof target, "%s\\t.shcl", x);
	snprintf(backup, sizeof backup, "%s\\.t.shcl.bak1.0", x);
	seed(target, "old\n");
	seed(tmp, "new\n");
	MultiByteToWideChar(CP_UTF8, 0, target, -1, wtarget, 320);
	HANDLE hold = CreateFileW(wtmp, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	if (hold == INVALID_HANDLE_VALUE) fail("publish", "could not hold the temp file open");
	HANDLE freer = CreateThread(NULL, 0, close_later, hold, 0, NULL);
	if (!freer) fail("publish", "thread failed");
	if (!shcl_publish_file(wtmp, wtarget)) fail("publish", "a brief hold failed the publish");
	if (freer) { WaitForSingleObject(freer, INFINITE); CloseHandle(freer); }
	if (!text_is(target, "new\n")) fail("publish", "a brief hold: the target was not replaced");
	if (there(tmp) || there(backup)) fail("publish", "a brief hold: the temp or the backup was left behind");
	remove(target); remove(tmp); remove(backup);
	rmdir(x); rmdir(y); rmdir(dir);
}

// The file's DACL as SDDL into out. 0 when it cannot be read.
static int dacl_sddl(const char *path, char *out, size_t cap) {
	wchar_t *w = shcl_widen(path);
	if (!w) return 0;
	DWORD need = 0;
	GetFileSecurityW(w, DACL_SECURITY_INFORMATION, NULL, 0, &need);
	PSECURITY_DESCRIPTOR sd = need ? malloc(need) : NULL;
	char *s = NULL;
	int ok = sd && GetFileSecurityW(w, DACL_SECURITY_INFORMATION, sd, need, &need)
		&& ConvertSecurityDescriptorToStringSecurityDescriptorA(sd, SDDL_REVISION_1, DACL_SECURITY_INFORMATION, &s, NULL)
		&& strlen(s) < cap;
	if (ok) strcpy(out, s);
	if (s) LocalFree(s);
	free(sd);
	free(w);
	return ok;
}

static int under_wine(void) {
	HMODULE m = GetModuleHandleW(L"ntdll.dll");
	return m && GetProcAddress(m, "wine_get_version") != NULL;
}

typedef struct { const char *path; volatile LONG stop; char last[2048]; } DaclPoll;

static DWORD WINAPI dacl_poller(LPVOID arg) {
	DaclPoll *p = (DaclPoll *)arg;
	char got[sizeof p->last];
	while (!InterlockedCompareExchange(&p->stop, 0, 0))
		if (dacl_sddl(p->path, got, sizeof got)) memcpy(p->last, got, sizeof got);
	return 0;
}

// A save over a file whose DACL is narrower than its directory's must not put
// the new text under the directory's. Holding the target without delete
// sharing fails the publish on every try, which keeps the temp file there long
// enough for a poller to read its DACL. Same fixture in every runner.
static void temp_takes_the_targets_dacl(void) {
	if (under_wine()) {
		printf("conformance: skipping the temp-file DACL fixture (wine keeps no ACLs)\n");
		test_skip();
		return;
	}
	char dir[256], target[300], tmp[320], want[2048], got[2048], cmd[800];
	const char *user = getenv("USERNAME");
	snprintf(dir, sizeof dir, "%s\\shcl-dacl-%ld", tmp_root(), (long)getpid());
	if (_mkdir(dir) != 0) fail("dacl", "mkdir failed");
	snprintf(cmd, sizeof cmd, "icacls \"%s\" /grant *S-1-5-32-545:(OI)(CI)(R) >nul", dir);
	if (system(cmd) != 0) fail("dacl", "icacls on the directory failed");
	const char *names[2] = { "a.shcl", "b.shcl" }, *prefixes[2] = { "D:P", "D:AI" };
	char acls[2][300];
	snprintf(acls[0], sizeof acls[0], "/inheritance:r /grant:r \"%s:(F)\"", user ? user : "");
	snprintf(acls[1], sizeof acls[1], "/grant *S-1-5-19:(R)");
	for (int i = 0; i < 2; i++) {
		snprintf(target, sizeof target, "%s\\%s", dir, names[i]);
		snprintf(tmp, sizeof tmp, "%s\\.%s.tmp%ld.0", dir, names[i], (long)getpid());
		seed(target, "a: 1\n");
		// The precision keeps gcc from sizing acls[i] as the whole array.
		snprintf(cmd, sizeof cmd, "icacls \"%s\" %.*s >nul", target, (int)sizeof acls[i] - 1, acls[i]);
		if (system(cmd) != 0) fail("dacl", "icacls on the file failed");
		if (!dacl_sddl(target, want, sizeof want) || strncmp(want, prefixes[i], strlen(prefixes[i])) != 0) {
			fprintf(stderr, "FAIL dacl: %s: the fixture did not take: %s\n", names[i], want);
			nfail++;
			continue;
		}
		wchar_t *wt = shcl_widen(target);
		HANDLE hold = wt ? CreateFileW(wt, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL) : INVALID_HANDLE_VALUE;
		free(wt);
		if (hold == INVALID_HANDLE_VALUE) { fail("dacl", "hold failed"); continue; }
		DaclPoll poll = { tmp, 0, "" };
		HANDLE poller = CreateThread(NULL, 0, dacl_poller, &poll, 0, NULL);
		if (!poller) fail("dacl", "thread failed");
		int saved = shcl_write_file_atomic(target, "a: 2\n", 5);
		InterlockedExchange(&poll.stop, 1);
		if (poller) { WaitForSingleObject(poller, INFINITE); CloseHandle(poller); }
		CloseHandle(hold);
		if (saved) fail("dacl", "a save over a held file went through");
		if (!poll.last[0]) fail("dacl", "the temp file was never seen");
		else if (strcmp(poll.last, want) != 0) {
			fprintf(stderr, "FAIL dacl: %s: the temp file's DACL is %s, want %s\n", names[i], poll.last, want);
			nfail++;
		}
		DIR *dd = opendir(dir); const struct dirent *de;
		while (dd && (de = readdir(dd)))
			if (strstr(de->d_name, ".tmp") || strstr(de->d_name, ".bak")) {
				fprintf(stderr, "FAIL dacl: %s: left behind: %s\n", names[i], de->d_name);
				nfail++;
			}
		if (dd) closedir(dd);
		if (!shcl_write_file_atomic(target, "a: 2\n", 5)) fail("dacl", "a save over an unheld file failed");
		if (!dacl_sddl(target, got, sizeof got) || strcmp(got, want) != 0) {
			fprintf(stderr, "FAIL dacl: %s: the saved file's DACL is %s, want %s\n", names[i], got, want);
			nfail++;
		}
	}
	char fresh[300], plain[300], b[300];
	snprintf(fresh, sizeof fresh, "%s\\n.shcl", dir);
	snprintf(plain, sizeof plain, "%s\\p.shcl", dir);
	snprintf(b, sizeof b, "%s\\b.shcl", dir);
	if (!shcl_write_file_atomic(fresh, "a: 2\n", 5)) fail("dacl", "a save to a new file failed");
	seed(plain, "a: 2\n");
	if (!dacl_sddl(plain, want, sizeof want)) fail("dacl", "the plain file's DACL could not be read");
	else if (!dacl_sddl(fresh, got, sizeof got) || strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL dacl: a new file's DACL is %s, want %s\n", got, want);
		nfail++;
	}
	size_t fn = 0, bn = 0;
	char *ft = read_file(fresh, &fn), *bt = read_file(b, &bn);
	if (!ft || !bt || fn != bn || memcmp(ft, bt, fn) != 0) fail("dacl", "an overwrite and a create wrote different bytes");
	free(ft); free(bt);
	// With no DACL to copy, the create still goes through, with the
	// directory's.
	char copied[300], missing[300];
	snprintf(copied, sizeof copied, "%s\\c.shcl", dir);
	snprintf(missing, sizeof missing, "%s\\missing.shcl", dir);
	wchar_t *wc = shcl_widen(copied), *wm = shcl_widen(missing);
	int cfd = wc && wm ? shcl_create_like(wm, wc) : -1;
	free(wc); free(wm);
	if (cfd < 0) fail("dacl", "a create with no DACL to copy failed");
	else close(cfd);
	if (!dacl_sddl(copied, got, sizeof got) || strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL dacl: a temp file with no DACL to copy has %s, want %s\n", got, want);
		nfail++;
	}
	DIR *dd = opendir(dir); const struct dirent *de;
	while (dd && (de = readdir(dd))) if (strcmp(de->d_name, ".") != 0 && strcmp(de->d_name, "..") != 0) {
		char left[600]; snprintf(left, sizeof left, "%s\\%s", dir, de->d_name); remove(left);
	}
	if (dd) closedir(dd);
	rmdir(dir);
}
#endif

/* The sequence fixture's generator: xorshift64* on a fixed seed, so every
   runner builds the same documents and the same steps. */
static uint64_t seq_s;
static size_t seq_below(size_t n) {
	uint64_t x = seq_s;
	x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
	seq_s = x;
	return (size_t)((x * 0x2545F4914F6CDD1DULL) % n);
}
typedef struct { char *p; size_t n, cap; } SeqBuf;
static void seq_put(SeqBuf *b, const char *s, size_t n) {
	if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->p = xrealloc(b->p, b->cap); }
	memcpy(b->p + b->n, s, n); b->n += n; b->p[b->n] = 0;
}
static void seq_puts(SeqBuf *b, const char *s) { seq_put(b, s, strlen(s)); }
static void seq_num(SeqBuf *b, size_t n) { char t[24]; snprintf(t, sizeof t, "%zu", n); seq_puts(b, t); }
static const char *const seq_names[] = {"a", "b", "m"};

/* Lines that have comments and blanks somewhere a later step can move them:
   comments at every depth, empty and reopened blocks, a same-line fence with a
   comment after an empty binding, and misplaced lines kept as written, one of
   them among a list's elements. */
static void seq_doc(SeqBuf *b) {
	b->n = 0; seq_put(b, "", 0);
	size_t depth = 0;
	for (size_t n = 1 + seq_below(10); n > 0; n--) {
		size_t r = seq_below(6);
		if (r == 0) depth = 0;
		else if (r == 1) { if (depth) depth--; }
		else if (r == 2) { if (depth < 3) depth++; }
		char ind[4];
		memset(ind, '\t', depth); ind[depth] = 0;
		const char *name = seq_names[seq_below(3)];
		switch (seq_below(10)) {
		case 0: seq_puts(b, ind); seq_puts(b, "# c"); seq_num(b, seq_below(3)); break;
		case 1: break;
		case 2: seq_puts(b, ind); seq_puts(b, name); seq_puts(b, ":"); break;
		case 3: seq_puts(b, ind); seq_puts(b, name); seq_puts(b, ": "); seq_num(b, seq_below(3)); break;
		case 4:
			seq_puts(b, ind); seq_puts(b, name); seq_puts(b, ": ```x  # t\n");
			seq_puts(b, ind); seq_puts(b, "\tbody\n"); seq_puts(b, ind); seq_puts(b, "\t```");
			break;
		case 5: seq_puts(b, ind); seq_puts(b, name); seq_puts(b, ": "); seq_num(b, seq_below(3)); seq_puts(b, "  # t"); break;
		case 6: seq_puts(b, ind); seq_puts(b, name); seq_puts(b, "."); seq_puts(b, name); seq_puts(b, ": 1"); break;
		case 7: seq_puts(b, ind); seq_puts(b, " "); seq_puts(b, name); seq_puts(b, ": "); seq_num(b, seq_below(3)); break;
		case 8:
			seq_puts(b, ind); seq_puts(b, name); seq_puts(b, ":\n");
			seq_puts(b, ind); seq_puts(b, "\t* 1\n"); seq_puts(b, ind); seq_puts(b, " x: 1\n");
			seq_puts(b, ind); seq_puts(b, "\t* 2");
			break;
		default: seq_puts(b, ind); seq_puts(b, "\t# deep"); break;
		}
		seq_puts(b, "\n");
	}
}

/* Every error code `d` loads with, `of` loaded with at least as often. */
static int no_new_errors(const shcl_doc *d, const shcl_doc *of) {
	for (size_t i = 0; i < shcl_diag_count(d); i++) {
		if (shcl_diag_severity(d, i) != SHCL_SEV_ERROR) continue;
		const char *code = shcl_diag_code(d, i);
		size_t mine = 0, theirs = 0;
		for (size_t j = 0; j < shcl_diag_count(d); j++)
			mine += shcl_diag_severity(d, j) == SHCL_SEV_ERROR && strcmp(shcl_diag_code(d, j), code) == 0;
		for (size_t j = 0; j < shcl_diag_count(of); j++)
			theirs += shcl_diag_severity(of, j) == SHCL_SEV_ERROR && strcmp(shcl_diag_code(of, j), code) == 0;
		if (mine > theirs) return 0;
	}
	return 1;
}

/* On a base that loads clean, a new field saved with the lines kept writes
   every line of the base that is not blank, in order. A repeat the load
   folded away comes back too (20260925c item 1). A kept misplaced line is
   left out, since it turns into a comment once a new field above it would
   take it as a child. */
static int keeps_every_line(const char *base, size_t n) {
	shcl_doc *d = shcl_parse_keep_lines(base, n, SHCL_STANDARD);
	int ok = 1, kept = 0, clean = 1;
	for (size_t i = 0; i < shcl_diag_count(d); i++)
		if (shcl_diag_severity(d, i) == SHCL_SEV_ERROR) clean = 0;
	if (clean && shcl_set_int(d, "zz_new", 6, 1)) {
		shcl_str t = shcl_to_text_keep_lines(d, &kept);
		size_t at = 0;
		for (size_t p = 0; kept && ok && p < n;) {
			size_t e = p;
			while (e < n && base[e] != '\n') e++;
			size_t q = p;
			while (q < e && (base[q] == ' ' || base[q] == '\t')) q++;
			if (q < e) {
				ok = 0;
				while (!ok && at < t.n) {
					size_t te = at;
					while (te < t.n && t.p[te] != '\n') te++;
					ok = te - at == e - p && memcmp(t.p + at, base + p, e - p) == 0;
					at = te + 1;
				}
			}
			p = e + 1;
		}
	}
	shcl_free(d);
	return ok;
}

/* A merge or an edit leaves the document its own saved text reloads as,
   comments included, so the next step comes out the same whether or not the file
   was saved in between. Comments were filed one way by a load and another by a
   merge, a new child or the writer's fold three times in three days, and the
   text fixpoint cannot see it, since both placements are fixpoints. Same
   fixture in every runner. */
static void edits_and_merges_match_a_reload(void) {
	seq_s = 0x5EED0923C0DE0003ULL;
	SeqBuf base = {0}, layer = {0}, log = {0}, path = {0}, a = {0}, b = {0};
	int bad = 0;
	for (int i = 0; i < 3000 && !bad; i++) {
		seq_doc(&base);
		/* The same tree as a plain parse, with the text kept for the save
		   that keeps lines, which is checked after every step too. */
		shcl_doc *live = shcl_parse_keep_lines(base.p, base.n, SHCL_STANDARD);
		log.n = 0; seq_puts(&log, "base:\n"); seq_put(&log, base.p, base.n);
		if (!keeps_every_line(base.p, base.n)) {
			fprintf(stderr, "FAIL edits_and_merges: a new field moved or dropped a line at iteration %d:\n%s", i, log.p);
			nfail++; bad = 1;
		}
		for (size_t steps = 2 + seq_below(3); steps > 0 && !bad; steps--) {
			shcl_str t = shcl_to_canonical(live);
			shcl_doc *back = shcl_parse(t.p, t.n);
			shcl_str *paths; size_t np = shcl_paths(live, &paths);
			path.n = 0; seq_put(&path, "", 0);
			if (np == 0 || seq_below(3) == 0) {
				seq_puts(&path, seq_names[seq_below(3)]); seq_puts(&path, ".");
				seq_puts(&path, seq_names[seq_below(3)]);
			} else {
				shcl_str pick = paths[seq_below(np)];
				seq_put(&path, pick.p, pick.n);
			}
			char v[24]; snprintf(v, sizeof v, "v%zu", seq_below(3)); /* room for any size_t, or -Os warns */
			size_t op = seq_below(11);
			seq_doc(&layer);
			/* A kept line the settle turned into a comment is still the user's
			   line and survives shcl_clear_comments, and a remove beside it.
			   The canonical text writes it as a comment, so on the reload it is
			   one, and the two cannot agree (20260926 item 2). */
			int settled = 0;
			if (op == 4 || op == 9) {
				shcl_str *lc, *bc;
				size_t nl = shcl_comments(live, path.p, path.n, &lc);
				settled = nl != shcl_comments(back, path.p, path.n, &bc);
				for (size_t k = 0; !settled && k < nl; k++) settled = lc[k].n != bc[k].n || memcmp(lc[k].p, bc[k].p, lc[k].n) != 0;
			}
			shcl_doc *docs[2] = {live, back};
			int applied = 0;
			for (int k = 0; k < 2; k++) {
				shcl_doc *d = docs[k];
				switch (op) {
				case 0: case 1: { shcl_doc *l = shcl_parse(layer.p, layer.n); shcl_merge(d, l); shcl_free(l); break; }
				case 2: applied += shcl_set_int(d, path.p, path.n, 7); break;
				case 3: applied += shcl_set_string(d, path.p, path.n, v, strlen(v)); break;
				case 4: applied += (int)shcl_remove(d, path.p, path.n); break;
				case 5: applied += shcl_set_comment(d, path.p, path.n, v, strlen(v)); break;
				case 6: applied += shcl_set_empty(d, path.p, path.n); break;
				case 7: applied += shcl_set_raw(d, path.p, path.n, "body", 4, v, strlen(v)); break;
				case 8: applied += shcl_set_int_default(d, path.p, path.n, 1); break;
				case 9: applied += (int)shcl_clear_comments(d, path.p, path.n); break;
				default: applied += (int)shcl_set_banner(d, strcmp(v, "v0") != 0); break;
				}
			}
			(void)applied;
			if (op <= 1) { seq_puts(&log, "merge:\n"); seq_put(&log, layer.p, layer.n); }
			else { seq_puts(&log, "op "); seq_num(&log, op); seq_puts(&log, " at "); seq_put(&log, path.p, path.n); seq_puts(&log, "\n"); }
			t = shcl_to_canonical(live); a.n = 0; seq_put(&a, t.p, t.n);
			t = shcl_to_canonical(back); b.n = 0; seq_put(&b, t.p, t.n);
			if (!settled && (a.n != b.n || memcmp(a.p, b.p, a.n) != 0)) {
				fprintf(stderr, "FAIL edits_and_merges: a step on the document and on its reload differ at iteration %d:\n%s--- live\n%s--- reload\n%s", i, log.p, a.p, b.p);
				nfail++; bad = 1;
			}
			int kept = 0;
			shcl_str kt = shcl_to_text_keep_lines(live, &kept);
			if (kept) {
				shcl_doc *kd = shcl_parse(kt.p, kt.n);
				shcl_str kc = shcl_to_canonical(kd);
				if (!bad && (kc.n != a.n || memcmp(kc.p, a.p, a.n) != 0)) {
					fprintf(stderr, "FAIL edits_and_merges: kept lines reload as another document at iteration %d:\n%s--- wrote\n%.*s", i, log.p, (int)kt.n, kt.p);
					nfail++; bad = 1;
				}
				shcl_doc *bd = shcl_parse(base.p, base.n);
				if (!bad && !no_new_errors(kd, bd)) {
					fprintf(stderr, "FAIL edits_and_merges: kept lines load with a new error at iteration %d:\n%s--- wrote\n%.*s", i, log.p, (int)kt.n, kt.p);
					nfail++; bad = 1;
				}
				/* Every line the load dropped went out as written (20260926
				   item 1). */
				if (!bad && shcl_lost_count(kd) != shcl_lost_count(bd)) {
					fprintf(stderr, "FAIL edits_and_merges: kept lines lost a dropped line at iteration %d:\n%s--- wrote\n%.*s", i, log.p, (int)kt.n, kt.p);
					nfail++; bad = 1;
				}
				shcl_free(bd);
				shcl_free(kd);
			} else if (!bad && (kt.n != a.n || memcmp(kt.p, a.p, a.n) != 0)) {
				fprintf(stderr, "FAIL edits_and_merges: a save that kept no lines is not canonical at iteration %d:\n%s", i, log.p);
				nfail++; bad = 1;
			}
			shcl_free(back);
		}
		shcl_free(live);
	}
	free(base.p); free(layer.p); free(log.p); free(path.p); free(a.p); free(b.p);
}

int main(int argc, char **argv) {
	setlocale(LC_ALL, "C");
	/* The library has to format and read floats the same whatever locale the
	   host program has set, and no corpus case can ask for a locale. The gate
	   builds a comma-decimal one and runs the whole corpus under it; only the
	   numeric category moves, so everything else here stays deterministic. */
	if (getenv("SHCL_TEST_LC_NUMERIC")) setlocale(LC_NUMERIC, "");
	const char *corpus = argc > 1 ? argv[1] : "project/conformance";

	DIR *dir = opendir(corpus);
	if (!dir) { fprintf(stderr, "no corpus dir: %s\n", corpus); return 2; }
	char **names = NULL; size_t nn = 0, cn = 0; const struct dirent *de;
	while ((de = readdir(dir))) {
		if (de->d_name[0] == '.') continue;
		/* Every subdirectory is a case, so one with no input.shcl reaches the
		   missing-file check below instead of being skipped without a word.
		   opendir is the directory test that needs no extra header on windows. */
		char path[4096]; snprintf(path, sizeof path, "%s/%s", corpus, de->d_name);
		DIR *sub = opendir(path); if (!sub) continue; closedir(sub);
		if (nn == cn) { cn = cn ? cn * 2 : 8; names = xrealloc(names, cn * sizeof *names); }
		names[nn++] = strdup(de->d_name);
	}
	closedir(dir);
	if (nn == 0) { fprintf(stderr, "no corpus cases under %s\n", corpus); return 2; }
	qsort(names, nn, sizeof *names, cmp_str);

	// The bad-ops loop's names-no-op check is only worth something while a
	// misspelled op still comes back told apart from an ordinary refusal.
	test_id("Er207Ye", "a_misspelled_op_is_told_apart");
	{
		shcl_doc *pd = shcl_parse("a: 1\n", 5);
		char misspelled[] = "itn\ta\t1", refused[] = "int\ta\tx";
		if (try_apply_op_c(pd, misspelled) != 2) fail("write_bad_ops", "a misspelled op read as a refusal");
		if (try_apply_op_c(pd, refused) != 1) fail("write_bad_ops", "a refusal read as a misspelled op");
		shcl_free(pd);
	}
	test_id_end();

	// Every dimension of a case runs in this one pass, so its line is failed by
	// anything charged while it ran.
	for (size_t ci = 0; ci < nn; ci++) {
		const int case_fails = nfail;
		char path[4096];
		snprintf(path, sizeof path, "%s/%s/input.shcl", corpus, names[ci]); size_t ilen; char *input = read_file(path, &ilen);
		snprintf(path, sizeof path, "%s/%s/expected.shcl", corpus, names[ci]); size_t elen; char *expected = read_file(path, &elen);
		snprintf(path, sizeof path, "%s/%s/reads.tsv", corpus, names[ci]); size_t rlen; char *reads = read_file(path, &rlen);
		/* Required, as the other three runners open them unconditionally. A
		   missing one used to count as a pass with that dimension absent. */
		if (!input) fail(names[ci], "missing input.shcl");
		if (!expected) fail(names[ci], "missing expected.shcl");
		if (!reads) fail(names[ci], "missing reads.tsv");

		// Canonical output must match expected.shcl and be a fixpoint.
		shcl_doc *d = shcl_parse(input, ilen);
		shcl_str got = shcl_to_canonical(d);
		if (got.n != elen || (elen && memcmp(got.p, expected, elen) != 0)) fail(names[ci], "canonical output differs from expected.shcl");
		shcl_doc *d2 = shcl_parse(got.p, got.n);
		shcl_str again = shcl_to_canonical(d2);
		if (again.n != got.n || (got.n && memcmp(again.p, got.p, got.n) != 0)) fail(names[ci], "formatter is not idempotent");
		shcl_free(d2);

		// A document merged onto itself is left as it is (20260918b item 19).
		// The walk read over while it wrote d, so Go doubled a retained line,
		// Python grew without end and C ran out of memory. Same fixture in
		// every runner.
		{
			shcl_doc *sm = shcl_parse(input, ilen);
			shcl_str b = shcl_to_canonical(sm);
			char *bc = (char *)malloc(b.n + 1);
			if (bc) memcpy(bc, b.p, b.n);
			shcl_merge(sm, sm);
			shcl_str a = shcl_to_canonical(sm);
			if (!bc || a.n != b.n || (b.n && memcmp(a.p, bc, b.n) != 0)) fail(names[ci], "merge onto itself changed the document");
			free(bc); shcl_free(sm);
		}

		// Diagnostics: count, line, severity, and stable code must match the golden
		// (the same shape `check` prints to stdout at Standard).
		snprintf(path, sizeof path, "%s/%s/expected-diags.txt", corpus, names[ci]); size_t dlen; char *ediags = read_file(path, &dlen);
		if (!ediags) fail(names[ci], "missing expected-diags.txt");
		else {
			size_t jl; char *dj = diag_text(d, &jl);
			if (jl != dlen || (dlen && memcmp(dj, ediags, dlen) != 0)) fail(names[ci], "diagnostics differ from expected-diags.txt");
			free(dj); free(ediags);
		}
		// Compaction rebuilds the document into fresh arenas: everything a save
		// or a strict gate reads off it has to come through unchanged. Every
		// case, so no shape of trivia or value is left to a hand-picked
		// fixture; mem_bounds.c checks that the old storage goes.
		{
			size_t ndiag = shcl_diag_count(d), nlost = shcl_lost_count(d), nerr = shcl_error_count(d);
			shcl_strictness st = shcl_strictness_of(d);
			char *canon = (char *)xrealloc(NULL, got.n + 1); memcpy(canon, got.p, got.n); size_t canon_n = got.n;
			char *dj = xrealloc(NULL, 64); size_t jl = 0, jc = 64;
			for (size_t i = 0; i < ndiag; i++) {
				shcl_str m = shcl_diag_message(d, i);
				int w = snprintf(NULL, 0, "%zu|%d|%s|", shcl_diag_line(d, i), (int)shcl_diag_severity(d, i), shcl_diag_code(d, i));
				if (jl + (size_t)w + m.n + 2 > jc) { jc = (jl + (size_t)w + m.n + 2) * 2; dj = xrealloc(dj, jc); }
				jl += (size_t)snprintf(dj + jl, jc - jl, "%zu|%d|%s|", shcl_diag_line(d, i), (int)shcl_diag_severity(d, i), shcl_diag_code(d, i));
				memcpy(dj + jl, m.p, m.n); jl += m.n; dj[jl++] = '\n';
			}
			shcl_compact(d);
			if (shcl_diag_count(d) != ndiag || shcl_lost_count(d) != nlost || shcl_error_count(d) != nerr || shcl_strictness_of(d) != st) fail(names[ci], "compaction changed the load's counts");
			size_t kl = 0;
			for (size_t i = 0; i < shcl_diag_count(d); i++) {
				shcl_str m = shcl_diag_message(d, i);
				char head[128]; int w = snprintf(head, sizeof head, "%zu|%d|%s|", shcl_diag_line(d, i), (int)shcl_diag_severity(d, i), shcl_diag_code(d, i));
				if (kl + (size_t)w + m.n + 1 > jl || memcmp(dj + kl, head, (size_t)w) != 0 || memcmp(dj + kl + w, m.p, m.n) != 0) { fail(names[ci], "compaction changed a diagnostic"); break; }
				kl += (size_t)w + m.n + 1;
			}
			shcl_str after = shcl_to_canonical(d);
			if (after.n != canon_n || (canon_n && memcmp(after.p, canon, canon_n) != 0)) fail(names[ci], "compaction changed the canonical output");
			free(canon); free(dj);
		}
		shcl_free(d);

		if (reads) {
			char **lines; size_t nl = split_lines(reads, rlen, &lines);
			for (size_t li = 0; li < nl; li++) {
				if (li == 0 || lines[li][0] == '\0') continue;
				// split by tab
				char *cols[8]; int nc = 0; char *p = lines[li];
				cols[nc++] = p;
				for (; *p && nc < 8; p++) if (*p == '\t') { *p = '\0'; cols[nc++] = p + 1; }
				if (nc < 4) { fail(names[ci], "reads.tsv line too short"); continue; }
				const char *query = cols[0], *kind = cols[1], *exp = cols[2], *status = cols[3];
				shcl_strictness level = parse_level(nc > 4 ? cols[4] : NULL);
				size_t qn = strlen(query);
				char at[512]; snprintf(at, sizeof at, "%s (%s %s)", names[ci], query, kind);

				if (!strcmp(kind, "load")) {
					shcl_doc *ld = shcl_parse_with(input, ilen, level);
					int ok = !shcl_strict_failed(ld); shcl_free(ld);
					int want = !strcmp(exp, "ok") ? 1 : (!strcmp(exp, "fail") ? 0 : -1);
					if (want < 0) fail(at, "bad load expectation");
					else if (ok != want) fail(at, "load outcome mismatch");
					continue;
				}
				shcl_doc *rd = shcl_parse_with(input, ilen, level);
				if (shcl_strict_failed(rd)) { fail(at, "load failed but reads.tsv has reads there"); shcl_free(rd); continue; }
				if (!strcmp(kind, "schema")) {
					size_t rn = 0; const char *r = shcl_schema_ref(input, ilen, &rn);
					if (!r) { r = "-"; rn = 1; }
					if (rn != strlen(exp) || memcmp(r, exp, rn) != 0) fail(at, "schema mismatch");
					shcl_free(rd); continue;
				}
				if (!strcmp(kind, "lost")) {
					char nb[32]; snprintf(nb, sizeof nb, "%zu", shcl_lost_count(rd));
					if (strcmp(nb, exp)) fail(at, "lost mismatch");
					shcl_free(rd); continue;
				}
				if (!strcmp(kind, "count")) {
					char nb[32]; snprintf(nb, sizeof nb, "%zu", shcl_count(rd, query, qn));
					if (strcmp(nb, exp)) fail(at, "count mismatch");
					shcl_free(rd); continue;
				}
				if (!strcmp(kind, "instances")) {
					shcl_str *vals; size_t n = shcl_instances(rd, query, qn, &vals);
					char *joined = join_pipe(vals, n);
					if (strcmp(joined, exp)) fail(at, "instances mismatch");
					free(joined); shcl_free(rd); continue;
				}
				if (!strcmp(kind, "children")) {
					shcl_str *kids; size_t n = shcl_children(rd, query, qn, &kids);
					char *joined = join_pipe(kids, n);
					if (strcmp(joined, exp)) fail(at, "children mismatch");
					free(joined); shcl_free(rd); continue;
				}
				if (!strcmp(kind, "paths")) {
					shcl_str *ps; size_t n = shcl_paths(rd, &ps);
					char *joined = join_pipe(ps, n);
					if (strcmp(joined, exp)) fail(at, "paths mismatch");
					free(joined); shcl_free(rd); continue;
				}
				if (!strcmp(kind, "instance_paths")) {
					shcl_str *ps; size_t n = shcl_instance_paths(rd, &ps);
					char *joined = join_pipe(ps, n);
					if (strcmp(joined, exp)) fail(at, "instance_paths mismatch");
					free(joined); shcl_free(rd); continue;
				}
				if (!strcmp(kind, "comments")) {
					shcl_str *cs; size_t n = shcl_comments(rd, query, qn, &cs);
					char *joined = join_pipe(cs, n);
					if (strcmp(joined, exp)) fail(at, "comments mismatch");
					free(joined); shcl_free(rd); continue;
				}
				shcl_status st; const shcl_status *slots; size_t nslots;
				char *val = scalar_read(rd, kind, query, qn, &st, &slots, &nslots);
				if (strcmp(shcl_status_name(st), status)) fail(at, "status mismatch");
				if (strcmp(exp, "-") && strcmp(val, exp)) fail(at, "value mismatch");
				// Optional 6th column: per-slot statuses, |-joined (needs col 5 set).
				if (nc > 5) {
					char sj[1024]; size_t sl = 0; sj[0] = '\0';
					for (size_t i = 0; i < nslots && sl + 16 < sizeof sj; i++)
						sl += (size_t)snprintf(sj + sl, sizeof sj - sl, "%s%s", i ? "|" : "", shcl_status_name(slots[i]));
					if (strcmp(sj, cols[5])) fail(at, "slots mismatch");
				}
				free(val); shcl_free(rd);
			}
			free(lines);
		}

		// Loaded to keep its lines and saved with no edits, every input is its
		// own text again, byte for byte.
		{
			shcl_doc *kd = shcl_parse_keep_lines(input, ilen, SHCL_STANDARD);
			int kept = 0;
			shcl_str kt = shcl_to_text_keep_lines(kd, &kept);
			if (!kept || kt.n != ilen || (ilen && memcmp(kt.p, input, ilen) != 0)) fail(names[ci], "an unedited save changed the text");
			shcl_free(kd);
		}

		// Write dimension (optional): apply write.ops and match expected-write.shcl,
		// and the same ops through the save that keeps lines, expected-keep.shcl.
		// The three files come together.
		snprintf(path, sizeof path, "%s/%s/write.ops", corpus, names[ci]); size_t olen; char *ops = read_file(path, &olen);
		snprintf(path, sizeof path, "%s/%s/expected-write.shcl", corpus, names[ci]); size_t wlen; char *ew = read_file(path, &wlen);
		snprintf(path, sizeof path, "%s/%s/expected-keep.shcl", corpus, names[ci]); size_t klen; char *ek = read_file(path, &klen);
		if (!ops != !ew || !ops != !ek) fail(names[ci], "write.ops, expected-write.shcl and expected-keep.shcl come together");
		if (ops && ew && ek) {
			shcl_doc *wd = shcl_parse(input, ilen);
			shcl_doc *kd = shcl_parse_keep_lines(input, ilen, SHCL_STANDARD);
			char **olines; size_t nol = split_lines(ops, olen, &olines);
			for (size_t li = 0; li < nol; li++) {
				if (olines[li][0] == '\0' || olines[li][0] == '#') continue;
				// The op is split in place, so each document gets its own copy.
				size_t on = strlen(olines[li]);
				char *op2 = (char *)xrealloc(NULL, on + 1);
				memcpy(op2, olines[li], on + 1);
				apply_op_c(wd, olines[li]);
				apply_op_c(kd, op2);
				free(op2);
			}
			shcl_str wgot = shcl_to_canonical(wd);
			if (wgot.n != wlen || (wlen && memcmp(wgot.p, ew, wlen) != 0)) fail(names[ci], "writer output differs from expected-write.shcl");
			shcl_doc *wd2 = shcl_parse(wgot.p, wgot.n);
			shcl_str wagain = shcl_to_canonical(wd2);
			if (wagain.n != wgot.n || (wgot.n && memcmp(wagain.p, wgot.p, wgot.n) != 0)) fail(names[ci], "written output is not a fmt fixpoint");
			int kept = 0;
			shcl_str kt = shcl_to_text_keep_lines(kd, &kept);
			if (kt.n != klen || (klen && memcmp(kt.p, ek, klen) != 0)) fail(names[ci], "output differs from expected-keep.shcl");
			if (!kept && (kt.n != wgot.n || (wgot.n && memcmp(kt.p, wgot.p, wgot.n) != 0))) fail(names[ci], "a save that kept no lines is not canonical");
			shcl_doc *kd2 = shcl_parse(kt.p, kt.n);
			shcl_str kc = shcl_to_canonical(kd2);
			if (kc.n != wgot.n || (wgot.n && memcmp(kc.p, wgot.p, wgot.n) != 0)) fail(names[ci], "expected-keep.shcl reloads as another document");
			shcl_free(kd2); shcl_free(kd); shcl_free(wd2); shcl_free(wd); free(olines);
		}
		free(ops); free(ew); free(ek);

		// Bad-op dimension (optional): each write-bad.ops line, applied alone,
		// must be rejected and leave the document unchanged.
		snprintf(path, sizeof path, "%s/%s/write-bad.ops", corpus, names[ci]); size_t blen; char *bops = read_file(path, &blen);
		if (bops) {
			char **blines; size_t nbl = split_lines(bops, blen, &blines);
			for (size_t li = 0; li < nbl; li++) {
				if (blines[li][0] == '\0' || blines[li][0] == '#') continue;
				shcl_doc *bd = shcl_parse(input, ilen);
				shcl_str before = shcl_to_canonical(bd);
				char *before_copy = (char *)xrealloc(NULL, before.n ? before.n : 1);
				memcpy(before_copy, before.p, before.n); size_t before_n = before.n;
				int brc = try_apply_op_c(bd, blines[li]);
				if (brc == 0) fail(names[ci], "write-bad.ops line was accepted");
				if (brc == 2) fail(names[ci], "write-bad.ops line names no op");
				shcl_str after = shcl_to_canonical(bd);
				if (after.n != before_n || (before_n && memcmp(after.p, before_copy, before_n) != 0)) fail(names[ci], "write-bad.ops line changed the document");
				free(before_copy); shcl_free(bd);
			}
			free(blines); free(bops);
		}

		// Schema dimension (optional): golden = the exact `check --schema` stdout
		// at Standard (doc parse diags, then validation diags, then the summary).
		// A schema that does not load cleanly is a single V099, mirroring the CLI.
		snprintf(path, sizeof path, "%s/%s/schema.shcl", corpus, names[ci]); size_t schlen; char *sch = read_file(path, &schlen);
		if (sch) {
			snprintf(path, sizeof path, "%s/%s/expected-validate.txt", corpus, names[ci]); size_t evlen; char *ev = read_file(path, &evlen);
			if (!ev) { fail(names[ci], "schema.shcl without expected-validate.txt"); free(sch); }
			else {
				shcl_doc *vd = shcl_parse(input, ilen);
				shcl_doc *sd = shcl_parse(sch, schlen);
				int v99 = 0;
				for (size_t i = 0; i < shcl_diag_count(sd); i++) if (shcl_diag_severity(sd, i) == SHCL_SEV_ERROR) v99 = 1;
				shcl_validation *vv = v99 ? NULL : shcl_validate(vd, sd);
				if (vv) { shcl_suppress_declared_repeats(sd, vd); shcl_suppress_declared_reopens(sd, vd); }
				size_t nd = shcl_diag_count(vd), nv = vv ? shcl_validation_count(vv) : 0, nerr = 0;
				size_t total = nd + nv + (v99 ? 1 : 0);
				char *vj = xrealloc(NULL, 64); size_t jl = 0, jc = 64;
				for (size_t i = 0; i < nd + nv + (size_t)(v99 ? 1 : 0); i++) {
					char ln[128]; int w;
					if (i < nd) {
						if (shcl_diag_severity(vd, i) == SHCL_SEV_ERROR) nerr++;
						w = snprintf(ln, sizeof ln, "line %zu: %s: %s\n", shcl_diag_line(vd, i), shcl_diag_severity(vd, i) == SHCL_SEV_ERROR ? "Error" : "Hint", shcl_diag_code(vd, i));
					} else if (v99) {
						nerr++;
						w = snprintf(ln, sizeof ln, "line 0: Error: V099\n");
					} else {
						size_t k = i - nd;
						if (shcl_validation_severity(vv, k) == SHCL_SEV_ERROR) nerr++;
						w = snprintf(ln, sizeof ln, "line %zu: %s: %s\n", shcl_validation_line(vv, k), shcl_validation_severity(vv, k) == SHCL_SEV_ERROR ? "Error" : "Hint", shcl_validation_code(vv, k));
					}
					if (jl + (size_t)w + 1 > jc) { jc = (jl + (size_t)w + 1) * 2; vj = xrealloc(vj, jc); }
					memcpy(vj + jl, ln, (size_t)w); jl += (size_t)w;
				}
				char sum[96]; int sw;
				if (nerr) sw = snprintf(sum, sizeof sum, "failed: %zu diagnostic(s), %zu error(s)\n", total, nerr);
				else sw = snprintf(sum, sizeof sum, "ok (%zu diagnostic(s))\n", total);
				if (jl + (size_t)sw + 1 > jc) { jc = jl + (size_t)sw + 1; vj = xrealloc(vj, jc); }
				memcpy(vj + jl, sum, (size_t)sw); jl += (size_t)sw;
				if (jl != evlen || (evlen && memcmp(vj, ev, evlen) != 0)) fail(names[ci], "validation output differs from expected-validate.txt");
				free(vj);
				shcl_validation_free(vv); shcl_free(sd); shcl_free(vd); free(sch); free(ev);
			}
		}

		// Layered-load dimension (optional): fold the layer*.shcl files (lowest
		// first) and input.shcl (highest file layer) via the library shcl_merge,
		// apply the merge.sets path=value overrides, match expected-merged.shcl.
		snprintf(path, sizeof path, "%s/%s/expected-merged.shcl", corpus, names[ci]); size_t emlen; char *em = read_file(path, &emlen);
		if (em) {
			// Collect layer file names in the case dir, sorted (filename = priority).
			char layerNames[64][256]; int nlayer = 0;
			snprintf(path, sizeof path, "%s/%s", corpus, names[ci]);
			DIR *cd = opendir(path);
			if (cd) {
				const struct dirent *le;
				while ((le = readdir(cd))) {
					size_t dn = strlen(le->d_name);
					// d_name holds 260 on mingw, more than a row.
					if (dn > 5 && dn < sizeof layerNames[0] && !strncmp(le->d_name, "layer", 5) && !strcmp(le->d_name + dn - 5, ".shcl") && nlayer < 64)
						memcpy(layerNames[nlayer++], le->d_name, dn + 1);
				}
				closedir(cd);
			}
			for (int a = 0; a < nlayer; a++) for (int b = a + 1; b < nlayer; b++) if (strcmp(layerNames[a], layerNames[b]) > 0) { char tmp[256]; memcpy(tmp, layerNames[a], 256); memcpy(layerNames[a], layerNames[b], 256); memcpy(layerNames[b], tmp, 256); }
			// Fold: layer0 (base) then each higher layer, then input.shcl.
			char *ltexts[65]; size_t llens[65]; int nt = 0;
			shcl_doc *md = NULL;
			for (int li = 0; li < nlayer; li++) {
				// The precision is the same 256 the store above enforces: without it the
				// compiler bounds layerNames[li] by the whole array, not by one row.
				snprintf(path, sizeof path, "%s/%s/%.255s", corpus, names[ci], layerNames[li]);
				ltexts[nt] = read_file(path, &llens[nt]);
				shcl_doc *dd = shcl_parse(ltexts[nt], llens[nt]); nt++;
				if (!md) md = dd; else { shcl_merge(md, dd); shcl_free(dd); }
			}
			{
				shcl_doc *dd = shcl_parse(input, ilen);
				if (!md) md = dd; else { shcl_merge(md, dd); shcl_free(dd); }
			}
			// merge.sets: one path=value per line, applied as the top layer.
			snprintf(path, sizeof path, "%s/%s/merge.sets", corpus, names[ci]); size_t mslen; char *ms = read_file(path, &mslen);
			if (ms) {
				char **slines; size_t nsl = split_lines(ms, mslen, &slines);
				for (size_t li = 0; li < nsl; li++) {
					if (slines[li][0] == '\0' || slines[li][0] == '#') continue;
					const char *eq = strchr(slines[li], '=');
					if (!eq) { fail(names[ci], "bad merge.sets line"); continue; }
					if (!shcl_set_string(md, slines[li], (size_t)(eq - slines[li]), eq + 1, strlen(eq + 1))) fail(names[ci], "merge.set did not apply");
				}
				free(slines); free(ms);
			}
			shcl_str mgot = shcl_to_canonical(md);
			if (mgot.n != emlen || (emlen && memcmp(mgot.p, em, emlen) != 0)) fail(names[ci], "merged output differs from expected-merged.shcl");
			/* The canonical text lives in md's read arena, so it is copied out
			   before md2 is parsed from it. */
			char *mcopy = (char *)malloc(mgot.n ? mgot.n : 1);
			if (!mcopy) { fail(names[ci], "out of memory"); return 1; }
			memcpy(mcopy, mgot.p, mgot.n);
			shcl_doc *md2 = shcl_parse(mcopy, mgot.n);
			shcl_str magain = shcl_to_canonical(md2);
			if (magain.n != mgot.n || (mgot.n && memcmp(magain.p, mcopy, mgot.n) != 0)) fail(names[ci], "merged output is not a fmt fixpoint");
			/* Reads answered by the merged document itself, not just its text: a
			   merged arena holds dropped nodes, a rebuilt index and cloned child
			   lists, and only a read walks those. shcl_instances is left out
			   because it hands back the source spelling, which canonical output
			   may rewrite. Same fixture in every runner. Results live until
			   shcl_free here, so nothing has to be copied between reads. */
			{
				shcl_str *mp1 = NULL, *mp2 = NULL;
				size_t mn1 = shcl_paths(md, &mp1), mn2 = shcl_paths(md2, &mp2);
				int same = mn1 == mn2;
				for (size_t k = 0; same && k < mn1; k++) same = s_eq(mp1[k], mp2[k]);
				if (!same) fail(names[ci], "merged paths differ from a reparse");
				for (size_t k = 0; same && k < mn1; k++) {
					const char *pp = mp1[k].p; size_t pn = mp1[k].n;
					if (shcl_count(md, pp, pn) != shcl_count(md2, pp, pn)) fail(names[ci], "merged count differs from a reparse");
					shcl_str *k1, *k2;
					size_t kn1 = shcl_children(md, pp, pn, &k1), kn2 = shcl_children(md2, pp, pn, &k2);
					int ksame = kn1 == kn2;
					for (size_t x = 0; ksame && x < kn1; x++) ksame = s_eq(k1[x], k2[x]);
					if (!ksame) fail(names[ci], "merged children differ from a reparse");
					shcl_read_str r1 = shcl_read_string(md, pp, pn), r2 = shcl_read_string(md2, pp, pn);
					if (r1.status != r2.status || !s_eq(r1.value, r2.value)) fail(names[ci], "merged read differs from a reparse");
					shcl_read_str_arr a1 = shcl_read_string_array(md, pp, pn), a2 = shcl_read_string_array(md2, pp, pn);
					int asame = a1.status == a2.status && a1.n == a2.n;
					for (size_t x = 0; asame && x < a1.n; x++) asame = a1.statuses[x] == a2.statuses[x] && s_eq(a1.values[x], a2.values[x]);
					if (!asame) fail(names[ci], "merged array read differs from a reparse");
				}
			}
			shcl_free(md2); shcl_free(md); free(mcopy);
			for (int li = 0; li < nt; li++) free(ltexts[li]);
			free(em);
		}

		// Generation dimension (optional): Generate on the schema must reproduce
		// the golden starter config, and that output must itself load cleanly.
		snprintf(path, sizeof path, "%s/%s/init-schema.shcl", corpus, names[ci]); size_t islen; char *isch = read_file(path, &islen);
		if (isch) {
			snprintf(path, sizeof path, "%s/%s/expected-init.shcl", corpus, names[ci]); size_t eilen; char *ei = read_file(path, &eilen);
			if (!ei) { fail(names[ci], "init-schema.shcl without expected-init.shcl"); free(isch); }
			else {
				shcl_doc *isd = shcl_parse(isch, islen);
				int ok = 0;
				shcl_str it = shcl_generate(isd, 0, &ok);
				if (!ok) fail(names[ci], "init schema has faults");
				else {
					if (it.n != eilen || (eilen && memcmp(it.p, ei, eilen) != 0)) fail(names[ci], "init output differs from expected-init.shcl");
					// The footer is the only difference the flag makes:
					// everything before it is byte-for-byte what the default
					// run produced.
					shcl_str bare = shcl_generate(isd, 1, &ok);
					if (!bare.n || bare.n >= it.n || memcmp(it.p, bare.p, bare.n) != 0)
						fail(names[ci], "--no-banner output is not a prefix of the default");
					else if (!contains(it.p + bare.n, it.n - bare.n, "This config file format is SHCL."))
						fail(names[ci], "default init output is missing the format footer");
					// Valid SHCL, and not so much as a hint: a starter that hints
					// on its own first lines (H002 from a parent re-opened after
					// another field) teaches a reader to ignore them.
					shcl_doc *gd = shcl_parse(it.p, it.n);
					if (shcl_diag_count(gd)) fail(names[ci], "generated starter does not load cleanly");
					// And it must satisfy the very schema that produced it.
					shcl_validation *gv = shcl_validate(gd, isd);
					for (size_t i = 0; i < shcl_validation_count(gv); i++)
						if (shcl_validation_severity(gv, i) == SHCL_SEV_ERROR) { fail(names[ci], "generated starter fails its own schema"); break; }
					shcl_validation_free(gv);
					shcl_free(gd);
				}
				shcl_free(isd); free(isch); free(ei);
			}
		}

		// Migration dimension (optional): migrate on the input must reproduce the
		// golden byte for byte, and the golden's load diagnostics are pinned
		// beside it, so a rewrite that no longer loads cannot pass. A fmt
		// fixpoint is not required, since migrate keeps the author's layout;
		// the migrate fixpoint is checked next.
		snprintf(path, sizeof path, "%s/%s/expected-migrate.shcl", corpus, names[ci]); size_t mglen; char *emig = read_file(path, &mglen);
		snprintf(path, sizeof path, "%s/%s/expected-migrate-diags.txt", corpus, names[ci]); size_t mgdlen; char *emigd = read_file(path, &mgdlen);
		if (!emig != !emigd) fail(names[ci], "expected-migrate.shcl and expected-migrate-diags.txt must come as a pair");
		else if (emig) {
			shcl_migration mm = shcl_migrate(input, ilen, 1);
			size_t mn = mm.len; char *mt = mm.text;
			if (mn != mglen || (mglen && memcmp(mt, emig, mglen) != 0)) fail(names[ci], "migrate output differs from expected-migrate.shcl");
			shcl_doc *md = shcl_parse(mt, mn);
			size_t mjl; char *mj = diag_text(md, &mjl);
			if (mjl != mgdlen || (mgdlen && memcmp(mj, emigd, mgdlen) != 0)) fail(names[ci], "migrated text's diagnostics differ from expected-migrate-diags.txt");
			free(mj); shcl_free(md); free(mt);
		}
		free(emig); free(emigd);
		{
			shcl_migration m1 = shcl_migrate(input, ilen, 1), m2 = shcl_migrate(m1.text, m1.len, 1);
			size_t on = m1.len, tn = m2.len;
			char *once = m1.text, *twice = m2.text;
			if (tn != on || (on && memcmp(once, twice, on) != 0)) fail(names[ci], "migrate changes its own output");
			free(twice); free(once);
		}
		// Over every input, not only the migrate cases: the stamp is the one
		// difference, and a file is current exactly when its Format line says so.
		for (int from_v2 = 1; from_v2 >= 0; from_v2--) {
			shcl_migration full = shcl_migrate(input, ilen, from_v2);
			shcl_migration bare = shcl_migrate_unstamped(input, ilen, from_v2);
			if (bare.current != full.current || bare.ambiguous != full.ambiguous || bare.lost != full.lost) fail(names[ci], "counts differ without the stamp");
			if (contains(bare.text, bare.len, SHCL_FORMAT_LINE_HEAD) && !contains(input, ilen, SHCL_FORMAT_LINE_HEAD)) fail(names[ci], "migrate_unstamped wrote a Format line");
			// The stamp's lines end the way most of the input's lines do.
			size_t crlf = 0, lf = 0;
			for (size_t k = 0; k < ilen; k++) {
				if (input[k] != '\n') continue;
				if (k > 0 && input[k - 1] == '\r') crlf++;
				else lf++;
			}
			const char *eol = crlf > lf ? "\r\n" : "\n";
			size_t eol_n = strlen(eol);
			size_t wcap = bare.len + sizeof(SHCL_FORMAT_LINE) + sizeof(SHCL_MIGRATED_LINE) + 8, wn = 0;
			char *want = (char *)malloc(wcap);
			if (!want) abort();
			memcpy(want, bare.text, bare.len); wn = bare.len;
			int same = full.len == bare.len && (bare.len == 0 || memcmp(full.text, bare.text, bare.len) == 0);
			if (!full.current && !same) {
				if (wn && want[wn - 1] != '\n') { memcpy(want + wn, eol, eol_n); wn += eol_n; }
				memcpy(want + wn, SHCL_FORMAT_LINE, sizeof(SHCL_FORMAT_LINE) - 1); wn += sizeof(SHCL_FORMAT_LINE) - 1;
				memcpy(want + wn, eol, eol_n); wn += eol_n;
				if (bare.len != ilen || (ilen && memcmp(bare.text, input, ilen) != 0)) {
					memcpy(want + wn, SHCL_MIGRATED_LINE, sizeof(SHCL_MIGRATED_LINE) - 1); wn += sizeof(SHCL_MIGRATED_LINE) - 1;
					memcpy(want + wn, eol, eol_n); wn += eol_n;
				}
			}
			if (full.len != wn || (wn && memcmp(full.text, want, wn) != 0)) fail(names[ci], "the stamp is not the only difference");
			if (full.current != (shcl_format_version(input, ilen) >= SHCL_FORMAT_MAJOR)) fail(names[ci], "current disagrees with format_version");
			free(want); free(full.text); free(bare.text);
		}
		free(input); free(expected); free(reads);
		/* The case's test ID, or dashes: a corpus built for a test of this
		   runner need not have one. */
		char id[16] = "-------";
		snprintf(path, sizeof path, "%s/%s/test-id", corpus, names[ci]); size_t tlen; char *tid = read_file(path, &tlen);
		if (tid) {
			while (tlen && (tid[tlen - 1] == '\n' || tid[tlen - 1] == '\r' || tid[tlen - 1] == ' ')) tlen--;
			if (tlen && tlen < sizeof id) { memcpy(id, tid, tlen); id[tlen] = '\0'; }
			free(tid);
		}
		char cname[4200]; snprintf(cname, sizeof cname, "corpus/%s", names[ci]);
		test_line(nfail > case_fails ? "FAIL" : "ok", id, cname);
	}
	for (size_t i = 0; i < nn; i++) free(names[i]);
	free(names);
	// paths(): file order, deduplicated, non-bare segments quoted so every
	// path resolves. Same fixture is pinned in every runner.
	test_id("EloioKm", "paths_enumeration_shape");
	{
		const char *pt = "a: 1\na.b: 2\n\"q n\": 3\nx:\n\tb: 4\nx.b: 5\n";
		shcl_doc *pd = shcl_parse(pt, strlen(pt));
		shcl_str *pv; size_t pn = shcl_paths(pd, &pv);
		const char *want[] = { "a", "a.b", "\"q n\"", "x", "x.b" };
		if (pn != 5) fail("paths", "count mismatch");
		else for (size_t i = 0; i < 5; i++) if (pv[i].n != strlen(want[i]) || memcmp(pv[i].p, want[i], pv[i].n) != 0) { fail("paths", "fixture mismatch"); break; }
		for (size_t i = 0; i < pn; i++) if (shcl_count(pd, pv[i].p, pv[i].n) < 1) { fail("paths", "emitted path does not resolve"); break; }
		// quote_segment: same spelling both directions, injection-safe.
		shcl_str qs = shcl_quote_segment(pd, "q n", 3);
		if (qs.n != 5 || memcmp(qs.p, "\"q n\"", 5) != 0) fail("paths", "quote_segment spelling drift");
		shcl_read_i64 qr = shcl_read_int(pd, qs.p, qs.n);
		if (qr.value != 3 || qr.status != SHCL_GOOD) fail("paths", "quoted segment read failed");
		shcl_free(pd);
	}
	// A raw body is the only content kept untrimmed, so it is the only place a
	// trailing CR survives the load - and one written back becomes CRLF, which
	// reads as neither. The whole trailing run comes off instead; a CR inside a
	// line is content and stays. Same fixture in every runner: a golden would be
	// rewritten by any platform's line-ending translation.
	test_id("EnLyQsW", "raw_block_line_endings_normalize_and_round_trip");
	{
		const char *rt = "r:\n\t~~~\n\tone\r\r\n\ta\rb\n\t~~~\n";
		shcl_doc *rd = shcl_parse(rt, strlen(rt));
		shcl_read_str rr = shcl_read_raw(rd, "r", 1);
		if (rr.value.n != 7 || memcmp(rr.value.p, "one\na\rb", 7) != 0) fail("raw", "trailing CR run not normalized");
		shcl_str rc = shcl_to_canonical(rd);
		shcl_doc *rd2 = shcl_parse(rc.p, rc.n);
		shcl_str rc2 = shcl_to_canonical(rd2);
		if (rc.n != rc2.n || memcmp(rc.p, rc2.p, rc.n) != 0) fail("raw", "raw block with CR is not a formatter fixpoint");
		shcl_free(rd2);
		shcl_free(rd);
	}
	// line()/quoted()/children(): read-surface accessors. Same fixture in every
	// runner - the other three have line and quoted on the read result, C
	// keeps its read structs value+status and answers with these instead.
	test_id("ElorUZm", "read_surface_line_quoted_children");
	{
		const char *lt = "a: @null\nb: \"@null\"\ncode:\n\thook: 1\n\thook: 2\n\tdone: 3\n";
		shcl_doc *ld = shcl_parse(lt, strlen(lt));
		if (shcl_quoted(ld, "a", 1)) fail("quoted", "unquoted read reports quoted");
		if (!shcl_quoted(ld, "b", 1)) fail("quoted", "quoted read not flagged");
		if (shcl_quoted(ld, "code", 4)) fail("quoted", "a block reports quoted");
		if (shcl_quoted(ld, "missing", 7)) fail("quoted", "missing path reports quoted");
		if (shcl_line(ld, "code.done", 9) != 6) fail("line", "code.done not line 6");
		if (shcl_line(ld, "code", 4) != 3) fail("line", "code not line 3");
		if (shcl_line(ld, "missing", 7) != 0) fail("line", "missing path not 0");
		// lines(): the plural - a repeated field cites every binding, wildcard
		// slots keep their index (0 = unresolved), a miss is the empty list.
		if (shcl_line(ld, "code.hook", 9) != 0) fail("line", "code.hook not 0"); // Multiple - the singular's gap
		size_t *lv; size_t lnc = shcl_lines(ld, "code.hook", 9, &lv);
		if (lnc != 2 || lv[0] != 4 || lv[1] != 5) fail("lines", "code.hook not [4, 5]");
		lnc = shcl_lines(ld, "code.done", 9, &lv);
		if (lnc != 1 || lv[0] != 6) fail("lines", "code.done not [6]");
		lnc = shcl_lines(ld, "a", 1, &lv);
		if (lnc != 1 || lv[0] != 1) fail("lines", "a not [1]");
		lnc = shcl_lines(ld, "code[*].done", 12, &lv);
		if (lnc != 1 || lv[0] != 6) fail("lines", "code[*].done not [6]");
		lnc = shcl_lines(ld, "code[*].nope", 12, &lv);
		if (lnc != 1 || lv[0] != 0) fail("lines", "code[*].nope not [0]");
		if (shcl_lines(ld, "missing", 7, &lv) != 0) fail("lines", "missing path not empty");
		shcl_str *cv; size_t chn = shcl_children(ld, "code", 4, &cv);
		const char *cw[] = { "hook", "hook", "done" };
		if (chn != 3) fail("children", "code count mismatch");
		else for (size_t i = 0; i < 3; i++) if (cv[i].n != strlen(cw[i]) || memcmp(cv[i].p, cw[i], cv[i].n) != 0) { fail("children", "code names mismatch"); break; }
		chn = shcl_children(ld, "", 0, &cv);
		const char *rw[] = { "a", "b", "code" };
		if (chn != 3) fail("children", "root count mismatch");
		else for (size_t i = 0; i < 3; i++) if (cv[i].n != strlen(rw[i]) || memcmp(cv[i].p, rw[i], cv[i].n) != 0) { fail("children", "root names mismatch"); break; }
		if (shcl_children(ld, "missing", 7, &cv) != 0) fail("children", "missing path not empty");
		shcl_free(ld);
	}
	// gitsby's report: children on a repeated key answered nothing, and a walk
	// had to know to index each instance. Same fixture in every runner.
	test_id("Eqpzw7W", "children_and_instance_paths_walk_a_repeated_key");
	{
		const char *gt = "account: w\n\temail: e@x\n\t\tsshkey: k1\n\temail: f@x\n\t\tsshkey: k2\n";
		shcl_doc *gd = shcl_parse(gt, strlen(gt));
		shcl_str *gv; size_t gn = shcl_children(gd, "account[#0].email", 17, &gv);
		if (gn != 2 || gv[0].n != 6 || memcmp(gv[0].p, "sshkey", 6) || gv[1].n != 6 || memcmp(gv[1].p, "sshkey", 6)) fail("children", "every instance's children not listed");
		gn = shcl_children(gd, "account.email[#1]", 17, &gv);
		if (gn != 1) fail("children", "one instance's children not listed");
		const char *iw[] = { "account", "account.email[#0]", "account.email[#0].sshkey", "account.email[#1]", "account.email[#1].sshkey" };
		gn = shcl_instance_paths(gd, &gv);
		if (gn != 5) fail("instance_paths", "count mismatch");
		else for (size_t i = 0; i < 5; i++) if (gv[i].n != strlen(iw[i]) || memcmp(gv[i].p, iw[i], gv[i].n) != 0) { fail("instance_paths", "fixture mismatch"); break; }
		shcl_read_str gr = shcl_read_string(gd, "account.email[#1].sshkey", 24);
		if (gr.status != SHCL_GOOD || gr.value.n != 2 || memcmp(gr.value.p, "k2", 2)) fail("instance_paths", "indexed path does not read");
		shcl_free(gd);
	}
	// authored_name: the author's spelling, unfolded; merged instances keep the
	// first binding's; unresolved or Multiple is empty; writer-built keeps the
	// setter path's spelling. Same fixture in every runner.
	test_id("EnLH7OS", "authored_name");
	{
		const char *nt = "SYMBOLS: 3\nCode:\n\tx: 1\ncode:\n\ty: 2\n";
		shcl_doc *nd = shcl_parse(nt, strlen(nt));
		shcl_str sn = shcl_authored_name(nd, "symbols", 7);
		if (sn.n != 7 || memcmp(sn.p, "SYMBOLS", 7) != 0) fail("authored_name", "symbols spelling mismatch");
		sn = shcl_authored_name(nd, "code", 4);
		if (sn.n != 4 || memcmp(sn.p, "Code", 4) != 0) fail("authored_name", "code spelling mismatch");
		if (shcl_authored_name(nd, "missing", 7).n != 0) fail("authored_name", "missing path not empty");
		if (!shcl_set_int(nd, "NewTop.n", 8, 1)) fail("authored_name", "set_int NewTop.n failed");
		sn = shcl_authored_name(nd, "newtop", 6);
		if (sn.n != 6 || memcmp(sn.p, "NewTop", 6) != 0) fail("authored_name", "newtop spelling mismatch");
		shcl_free(nd);
		// Escapes ARE resolved on a name, so both spellings of the path find the
		// same node - while shcl_authored_name still hands back the source
		// spelling, which is the one thing it is for. Same fixture everywhere.
		const char *et = "\"Ab\\tCd\": 2\n";
		shcl_doc *ed = shcl_parse(et, strlen(et));
		sn = shcl_authored_name(ed, "\"ab\\tcd\"", 8);
		if (sn.n != 6 || memcmp(sn.p, "Ab\\tCd", 6) != 0) fail("authored_name", "escaped spelling mismatch");
		sn = shcl_authored_name(ed, "\"ab\tcd\"", 7); // a real tab: one byte shorter than the escaped spelling
		if (sn.n != 6 || memcmp(sn.p, "Ab\\tCd", 6) != 0) fail("authored_name", "literal spelling mismatch");
		if (shcl_read_int(ed, "\"ab\tcd\"", 7).value != 2) fail("authored_name", "read via the literal spelling failed");
		{
			// Canonical output folds the case, as it always has, and escapes the tab.
			const char *ec = "\"ab\\tcd\": 2\n";
			shcl_str ecn = shcl_to_canonical(ed);
			if (ecn.n != strlen(ec) || memcmp(ecn.p, ec, ecn.n) != 0) fail("authored_name", "canonical name spelling moved");
		}
		shcl_free(ed);
	}
	// The get-tier value survives only on Good; Empty/BadType/NotFound all fall
	// back to the call-site default, so a real zero can't be faked. `_or` is the
	// cross-binding spelling for it, so a routine ported between two bindings
	// cannot keep the call name while changing which tier it uses. Same
	// fixture in every runner (C's convenience tier is the value types only).
	test_id("EnLD4c4", "convenience_tier_falls_back_only_on_good");
	{
		const char *ct = "a: 42\nb: not-a-number\ne:\nblk:\n\t```html\n\thi\n\t```\n";
		shcl_doc *cd = shcl_parse(ct, strlen(ct));
		if (shcl_get_int_or(cd, "a", 1, 9) != 42) fail("get_or", "Good did not read through");
		if (shcl_get_int_or(cd, "b", 1, 9) != 9) fail("get_or", "BadType did not fall back");
		if (shcl_get_int_or(cd, "e", 1, 9) != 9) fail("get_or", "Empty did not fall back");
		if (shcl_get_int_or(cd, "missing", 7, 9) != 9) fail("get_or", "NotFound did not fall back");
		// C's convenience tier deliberately stops at the value types, so the
		// info-string read is only reachable on the status tier here.
		{ shcl_read_str ri = shcl_read_raw_info(cd, "blk", 3);
		  if (ri.status != SHCL_GOOD || ri.value.n != 4 || memcmp(ri.value.p, "html", 4))
			  fail("get_or", "read_raw_info did not read the info-string"); }
		if (shcl_get_float_or(cd, "missing", 7, 1.5) != 1.5) fail("get_or", "float did not fall back");
		if (shcl_get_bool_or(cd, "missing", 7, 1) != 1) fail("get_or", "bool did not fall back");
		// The ok predicate and the convenience tier deliberately disagree on an
		// explicitly emptied field: one asks whether the author spoke for it, the
		// other whether there is a usable value.
		if (!shcl_status_ok(shcl_read_int(cd, "e", 1).status)) fail("status_ok", "an emptied field is not ok");
		if (shcl_status_ok(shcl_read_int(cd, "missing", 7).status)) fail("status_ok", "a missing field is ok");
		shcl_free(cd);
	}
	// parse_limited: the caps exist because a document amplifies to many times
	// its byte size in memory, so shcl_read_file's byte cap alone cannot bound
	// a load. Same fixture in every runner.
	test_id("Eoe5NRy", "parse_limited_caps");
	{
		const char *lt = "a: 1\nb: 2\nc: 3\nd: 4\n";
		shcl_doc *ld = shcl_parse_limited(lt, strlen(lt), SHCL_STANDARD, 2, 0, 0);
		size_t ncap = 0, capline = 0;
		for (size_t k = 0; k < shcl_diag_count(ld); k++)
			if (strcmp(shcl_diag_code(ld, k), "E020") == 0) { ncap++; capline = shcl_diag_line(ld, k); }
		if (ncap != 1 || capline != 4) fail("parse_limited", "want one E020 at line 4");
		if (shcl_lost_count(ld) != 1) fail("parse_limited", "the remainder must count as lost");
		if (shcl_get_int_or(ld, "a", 1, 0) != 1) fail("parse_limited", "parsed part unreadable");
		if (shcl_exists(ld, "d", 1)) fail("parse_limited", "the remainder must not parse");
		shcl_free(ld);
		// A cap crossed by the document's last content line still reports.
		ld = shcl_parse_limited("a: 1\nb: 2\nc: 3", 15, SHCL_STANDARD, 2, 0, 0);
		ncap = 0;
		for (size_t k = 0; k < shcl_diag_count(ld); k++)
			if (strcmp(shcl_diag_code(ld, k), "E020") == 0) ncap++;
		if (ncap != 1 || shcl_lost_count(ld) != 0) fail("parse_limited", "last-line cross must report, nothing lost");
		shcl_free(ld);
		// One line may overshoot the cap by its own path; the parse still stops.
		ld = shcl_parse_limited("x.y.z: 1\n", 9, SHCL_STANDARD, 1, 0, 0);
		ncap = 0;
		for (size_t k = 0; k < shcl_diag_count(ld); k++)
			if (strcmp(shcl_diag_code(ld, k), "E020") == 0) ncap++;
		if (ncap != 1) fail("parse_limited", "deep line must report E020");
		if (shcl_get_int_or(ld, "x.y.z", 5, 0) != 1) fail("parse_limited", "overshot line must stay in the document");
		shcl_free(ld);
		// 0 is no cap: identical to shcl_parse_with.
		ld = shcl_parse_limited(lt, strlen(lt), SHCL_STANDARD, 0, 0, 0);
		if (shcl_diag_count(ld) != 0) fail("parse_limited", "uncapped must match parse_with");
		shcl_free(ld);
		// Element cap, inline spelling: the whole line is refused, the rest of
		// the document is untouched.
		const char *et = "arr: 1, 2, 3\nok: 5\n";
		ld = shcl_parse_limited(et, strlen(et), SHCL_STANDARD, 0, 2, 0);
		ncap = 0; capline = 0;
		for (size_t k = 0; k < shcl_diag_count(ld); k++)
			if (strcmp(shcl_diag_code(ld, k), "E021") == 0) { ncap++; capline = shcl_diag_line(ld, k); }
		if (ncap != 1 || capline != 1) fail("parse_limited", "want one E021 at line 1");
		if (shcl_exists(ld, "arr", 3)) fail("parse_limited", "refused line must not bind");
		if (shcl_get_int_or(ld, "ok", 2, 0) != 5) fail("parse_limited", "rest of the document unreadable");
		if (shcl_lost_count(ld) != 1) fail("parse_limited", "refused line must count as lost");
		shcl_free(ld);
		// Element cap, stacked spelling: each element line past the cap is
		// refused on its own; the array keeps what fit.
		const char *st2 = "arr:\n\t* 1\n\t* 2\n\t* 3\n";
		ld = shcl_parse_limited(st2, strlen(st2), SHCL_STANDARD, 0, 2, 0);
		ncap = 0;
		for (size_t k = 0; k < shcl_diag_count(ld); k++)
			if (strcmp(shcl_diag_code(ld, k), "E021") == 0) ncap++;
		shcl_read_i64_arr ra = shcl_read_int_array(ld, "arr", 3);
		if (ncap != 1 || ra.status != SHCL_GOOD || ra.n != 2 || ra.values[0] != 1 || ra.values[1] != 2)
			fail("parse_limited", "stacked array must keep what fit");
		shcl_free(ld);
		// A cap refuses only a line that would bind: bracket text stays E019
		// and kept, and an element under a field with a value stays E011.
		const char *bt = "arr: [1, 2, 3]\nk: x\n\t* 1\n";
		ld = shcl_parse_limited(bt, strlen(bt), SHCL_STANDARD, 0, 1, 0);
		{
			shcl_str canon = shcl_to_canonical(ld);
			int ok = shcl_diag_count(ld) == 2
				&& shcl_diag_line(ld, 0) == 1 && strcmp(shcl_diag_code(ld, 0), "E019") == 0
				&& shcl_diag_line(ld, 1) == 3 && strcmp(shcl_diag_code(ld, 1), "E011") == 0
				&& shcl_lost_count(ld) == 1
				&& canon.n >= 14 && memcmp(canon.p, "arr: [1, 2, 3]", 14) == 0;
			if (!ok) fail("parse_limited", "a cap over a refused line must keep that line's code");
		}
		shcl_free(ld);
		// The count the cap judges is the count the array reads back as,
		// spelling by spelling: quoted commas, a backslash (a character, so it
		// shields nothing), empty and blank slots, a Unicode blank (content:
		// only a space or a tab is blank), a quote that never closes (a
		// character too, so the comma after it splits). Refused at one under,
		// kept at exact.
		static const struct { const char *spelling; size_t n; } counts[] = {
			{"1, 2, 3", 3}, {"\"a, b\", c", 2}, {"a\\, b, c", 3}, {"a,,b", 2},
			{"a, , b", 2}, {" a ", 1}, {"\"\", ''", 2}, {"'a\", b'", 1},
			{"\"open, b", 2}, {"\\", 1}, {"x,\xe3\x80\x80", 2}, {"x, \xc2\xa0y", 2}, {", , ,", 0},
		};
		for (size_t ci = 0; ci < sizeof counts / sizeof counts[0]; ci++) {
			char ctext[64]; snprintf(ctext, sizeof ctext, "v: %s\n", counts[ci].spelling);
			size_t n = counts[ci].n;
			ld = shcl_parse_limited(ctext, strlen(ctext), SHCL_STANDARD, 0, n ? n : 1, 0);
			for (size_t k = 0; k < shcl_diag_count(ld); k++)
				if (strcmp(shcl_diag_code(ld, k), "E021") == 0) fail("parse_limited", "count table: refused at the exact cap");
			shcl_read_str_arr sa = shcl_read_string_array(ld, "v", 1);
			if (n == 0 ? (!shcl_exists(ld, "v", 1) || sa.status == SHCL_GOOD) : (sa.status != SHCL_GOOD || sa.n != n))
				fail("parse_limited", "count table: element count differs from the read");
			shcl_free(ld);
			if (n >= 2) {
				ld = shcl_parse_limited(ctext, strlen(ctext), SHCL_STANDARD, 0, n - 1, 0);
				if (shcl_lost_count(ld) != 1) fail("parse_limited", "count table: not refused one under");
				shcl_free(ld);
			}
		}
		// A refused line reports the cap alone: the quote check runs after
		// it, so it never splits a value the cap already turned away.
		const char *qt = "v: a, \"open, b\n";
		ld = shcl_parse_limited(qt, strlen(qt), SHCL_STANDARD, 0, 1, 0);
		if (shcl_diag_count(ld) != 1 || strcmp(shcl_diag_code(ld, 0), "E021") != 0) fail("parse_limited", "refused line must report the cap alone");
		shcl_free(ld);
		// A fence whose info string splits past the cap is refused with its
		// block, in both spellings, so the body never reads as live lines. Same
		// fixture in every runner.
		const char *fences[] = {
			"secrets:\n\t```a,b,c,d\n\tpassword: hunter2\n\t```\nafter: 1\n",
			"secrets: ```a,b,c,d\n\tpassword: hunter2\n\t```\nafter: 1\n",
		};
		for (size_t fi = 0; fi < 2; fi++) {
			ld = shcl_parse_limited(fences[fi], strlen(fences[fi]), SHCL_STANDARD, 0, 3, 0);
			if (shcl_diag_count(ld) != 1 || strcmp(shcl_diag_code(ld, 0), "E021") != 0) fail("parse_limited", "a capped fence must report the cap alone");
			if (shcl_exists(ld, "secrets.password", 16)) fail("parse_limited", "a capped fence's body bound");
			if (shcl_get_int_or(ld, "after", 5, 0) != 1) fail("parse_limited", "the line after a capped fence's block is gone");
			if (shcl_lost_count(ld) != 1) fail("parse_limited", "a capped fence must count one lost");
			shcl_free(ld);
		}
		// Diagnostic cap: the first N are listed and one E022 tail counts the
		// rest. Its severity is Error when any unlisted one was, so a scan of
		// the list for errors still finds one and error_count stays nonzero.
		char bad[9 * 50 + 1]; bad[0] = 0;
		for (int i = 0; i < 50; i++) strcat(bad, "no colon\n");
		ld = shcl_parse_limited(bad, strlen(bad), SHCL_STANDARD, 0, 0, 10);
		if (shcl_diag_count(ld) != 11) fail("parse_limited", "diag cap: want 11 listed");
		else {
			for (size_t k = 0; k < 10; k++) if (strcmp(shcl_diag_code(ld, k), "E014") != 0) fail("parse_limited", "diag cap: listed the wrong code");
			shcl_str tm = shcl_diag_message(ld, 10);
			const char *want = "diagnostic cap of 10 reached; 40 more not listed, 40 of them errors";
			if (strcmp(shcl_diag_code(ld, 10), "E022") != 0 || shcl_diag_severity(ld, 10) != SHCL_SEV_ERROR || shcl_diag_line(ld, 10) != 0 || tm.n != strlen(want) || memcmp(tm.p, want, tm.n) != 0)
				fail("parse_limited", "diag cap: tail differs");
		}
		if (shcl_error_count(ld) != 11) fail("parse_limited", "diag cap: error count");
		shcl_free(ld);
		ld = shcl_parse_limited(bad, strlen(bad), SHCL_STRICT, 0, 0, 10);
		if (!shcl_strict_failed(ld)) fail("parse_limited", "diag cap: capped strict load must fail");
		shcl_free(ld);
		// Hints past the cap leave a Hint tail, so a document with no error
		// still loads at Strict.
		const char *hints = "x: 1\nx: 2\ny: 1\ny: 2\n";
		ld = shcl_parse_limited(hints, strlen(hints), SHCL_STRICT, 0, 0, 1);
		if (shcl_strict_failed(ld) || shcl_diag_count(ld) != 2 || strcmp(shcl_diag_code(ld, 0), "H001") != 0 || strcmp(shcl_diag_code(ld, 1), "E022") != 0 || shcl_diag_severity(ld, 1) != SHCL_SEV_HINT || shcl_error_count(ld) != 0)
			fail("parse_limited", "hint tail differs");
		else {
			shcl_str tm = shcl_diag_message(ld, 1); const char *suffix = "1 more not listed, 0 of them errors";
			if (tm.n < strlen(suffix) || memcmp(tm.p + tm.n - strlen(suffix), suffix, strlen(suffix)) != 0) fail("parse_limited", "hint tail message");
		}
		shcl_free(ld);
		// At the cap exactly, nothing is unlisted and there is no tail.
		ld = shcl_parse_limited(hints, strlen(hints), SHCL_STANDARD, 0, 0, 2);
		if (shcl_diag_count(ld) != 2) fail("parse_limited", "at the cap: a tail appeared");
		shcl_free(ld);
		// A cap diagnostic is an error, so a Strict capped load fails - with
		// the parsed part still readable.
		ld = shcl_parse_limited(lt, strlen(lt), SHCL_STRICT, 2, 0, 0);
		if (!shcl_strict_failed(ld)) fail("parse_limited", "capped strict load must fail");
		if (shcl_get_int_or(ld, "a", 1, 0) != 1) fail("parse_limited", "failed strict doc unusable");
		shcl_free(ld);
	}
	// load_file/save_file: the status separates absent / unreadable / parsed
	// with errors / clean, and a save round-trips through the atomic write.
	// Same fixture in every runner.
	test_id("Er207Yf", "file_tier_load_save");
	{
		char tdir[256], tfile[288];
		snprintf(tdir, sizeof tdir, "%s/shcl-filetier-%ld", tmp_root(), (long)getpid());
#ifdef _WIN32
		if (_mkdir(tdir) != 0) fail("file_tier", "mkdir failed");
#else
		if (mkdir(tdir, 0700) != 0) fail("file_tier", "mkdir failed");
#endif
		snprintf(tfile, sizeof tfile, "%s/t.shcl", tdir);
		shcl_file_status fst;
		shcl_doc *fd = shcl_load_file(tfile, &fst);
		if (fst != SHCL_FILE_NOT_FOUND) fail("file_tier", "missing file status");
		shcl_free(fd);
		fd = shcl_load_file(tdir, &fst); // a directory is not readable
		if (fst != SHCL_FILE_UNREADABLE) fail("file_tier", "directory status");
		shcl_free(fd);
		// Bad encoding is unreadable too: the parser assumes well-formed text, so a
		// binary file loading clean would read back mangled and a later save would
		// write the mangled version over the original.
		{
			FILE *bf = fopen(tfile, "wb");
			if (!bf || fputs("a: 1\nb: \xff\xfe bad\n", bf) == EOF || fclose(bf) != 0) fail("file_tier", "seed write failed");
			fd = shcl_load_file(tfile, &fst);
			if (fst != SHCL_FILE_UNREADABLE) fail("file_tier", "bad encoding status");
			if (shcl_to_canonical(fd).n != 0) fail("file_tier", "bad encoding document");
			shcl_free(fd);
		}
		FILE *tf = fopen(tfile, "wb");
		if (!tf || fputs("a: 1\n: broken\n", tf) == EOF || fclose(tf) != 0) fail("file_tier", "seed write failed");
		fd = shcl_load_file(tfile, &fst);
		if (fst != SHCL_FILE_HAD_ERRORS) fail("file_tier", "broken file status");
		if (shcl_get_int(fd, "a", 1, 0) != 1) fail("file_tier", "broken file read");
		shcl_free(fd);
		tf = fopen(tfile, "wb");
		if (!tf || fputs("a: 1\nb: x\n", tf) == EOF || fclose(tf) != 0) fail("file_tier", "seed rewrite failed");
		fd = shcl_load_file(tfile, &fst);
		if (fst != SHCL_FILE_CLEAN) fail("file_tier", "clean file status");
		// shcl_read_file is the load's read half on its own: the exact bytes,
		// or the status. The cap counts bytes, and a file exactly at it passes.
		// Same fixture in every runner.
		{
			size_t rn = 0; shcl_file_status rst;
			char *rt = shcl_read_file(tfile, 0, &rn, &rst);
			if (!rt || rst != SHCL_FILE_CLEAN || rn != 10 || memcmp(rt, "a: 1\nb: x\n", 11) != 0) fail("file_tier", "read_file");
			free(rt);
			rt = shcl_read_file(tfile, 10, &rn, &rst);
			if (!rt || rst != SHCL_FILE_CLEAN || rn != 10) fail("file_tier", "read_file at the cap");
			free(rt);
			rt = shcl_read_file(tfile, 9, &rn, &rst);
			if (rt || rst != SHCL_FILE_UNREADABLE) fail("file_tier", "read_file past the cap");
			free(rt);
			// A cap given as the type maximum used to overflow the over-cap
			// probe and read nothing. Same fixture in every runner.
			rt = shcl_read_file(tfile, (size_t)-1, &rn, &rst);
			if (!rt || rst != SHCL_FILE_CLEAN || rn != 10 || memcmp(rt, "a: 1\nb: x\n", 11) != 0) fail("file_tier", "read_file at the largest cap");
			free(rt);
			char none[320];
			snprintf(none, sizeof none, "%s/none.shcl", tdir);
			rt = shcl_read_file(none, 0, &rn, &rst);
			if (rt || rst != SHCL_FILE_NOT_FOUND) fail("file_tier", "read_file missing");
			free(rt);
		}
		if (!shcl_set_int(fd, "c", 1, 3)) fail("file_tier", "set_int failed");
		if (shcl_save_file(fd, tfile) != SHCL_SAVE_OK) fail("file_tier", "save failed");
		shcl_doc *fb = shcl_load_file(tfile, &fst);
		shcl_str c1 = shcl_to_canonical(fd), c2 = shcl_to_canonical(fb);
		if (fst != SHCL_FILE_CLEAN || c1.n != c2.n || memcmp(c1.p, c2.p, c1.n) != 0) fail("file_tier", "save round-trip mismatch");
		shcl_free(fb); shcl_free(fd);
		// Creating a file and overwriting one are two different code paths in
		// the write - the create picks its own mode, the overwrite copies the
		// target's, and the publish step differs by platform (windows goes
		// through ReplaceFile, with a rename fallback). Both run everywhere: an
		// overwrite used to throw outright on windows in the python binding,
		// which no POSIX-only fixture could ever have caught. Same fixture in
		// every runner.
		{
			char fresh[320];
			snprintf(fresh, sizeof fresh, "%s/fresh.shcl", tdir);
			shcl_doc *nd = shcl_parse("a: 1\n", 5);
			for (int pass = 0; pass < 2; pass++) {
				if (shcl_save_file(nd, fresh) != SHCL_SAVE_OK) fail("file_tier", pass ? "overwrite save failed" : "new file save failed");
				shcl_doc *nb = shcl_load_file(fresh, &fst);
				shcl_str nc = shcl_to_canonical(nb);
				if (fst != SHCL_FILE_CLEAN || nc.n != 5 || memcmp(nc.p, "a: 1\n", 5) != 0) fail("file_tier", pass ? "overwritten file round-trip" : "new file round-trip");
				shcl_free(nb);
			}
			// A new file ends up where an ordinary create puts one - 0666 narrowed
			// by the umask - and an existing one keeps the mode it had. Neither
			// is visible on stdout, so no corpus case can see either, and
			// neither is a windows concept, so the mode half is POSIX-only.
#ifndef _WIN32
			{
				char probe[320], born[320];
				snprintf(probe, sizeof probe, "%s/probe", tdir);
				snprintf(born, sizeof born, "%s/born.shcl", tdir);
				FILE *pf = fopen(probe, "wb");
				if (!pf || fclose(pf) != 0) fail("file_tier", "probe create failed");
				struct stat ps, ns;
				if (stat(probe, &ps) != 0) fail("file_tier", "probe stat failed");
				if (shcl_save_file(nd, born) != SHCL_SAVE_OK) fail("file_tier", "new file save failed");
				if (stat(born, &ns) != 0) fail("file_tier", "new file stat failed");
				if ((ns.st_mode & 0777) != (ps.st_mode & 0777)) fail("file_tier", "new file mode");
				if (chmod(born, 0640) != 0) fail("file_tier", "chmod failed");
				if (shcl_save_file(nd, born) != SHCL_SAVE_OK) fail("file_tier", "existing file save failed");
				if (stat(born, &ns) != 0) fail("file_tier", "existing file stat failed");
				if ((ns.st_mode & 0777) != 0640) fail("file_tier", "existing file mode");
				// setuid and setgid come over too: applying the mode before
				// the data lets the kernel clear them on the write.
				if (chmod(born, 06750) == 0 && stat(born, &ns) == 0 && (ns.st_mode & 07777) == 06750) {
					if (shcl_save_file(nd, born) != SHCL_SAVE_OK) fail("file_tier", "set-id save failed");
					if (stat(born, &ns) != 0) fail("file_tier", "set-id stat failed");
					if ((ns.st_mode & 07777) != 06750) fail("file_tier", "set-id bits lost");
				} else {
					/* Setgid is cleared when the file's group is not one of the
					   caller's, which happens on ordinary boxes. The skip was
					   silent, so this fixture passed wherever it fired. */
					printf("conformance: skipping the set-id fixture (mode came back %o, want 6750)\n", (unsigned)(ns.st_mode & 07777));
				}
				remove(probe); remove(born);
			}
#endif
			// Windows-only, and C-only in effect: a path written with the platform
			// separator, a name outside the active code page, and a drive-relative
			// target. The fixture above joins with '/', which is why none of these
			// ever failed here - the writer split on '/' alone, and every file call
			// was the code-page one, so a backslash path failed outright and a
			// non-ANSI name went to disk under a mojibake spelling. The other
			// bindings split and open through their runtimes and never had it.
#ifdef _WIN32
			{
				char bsfile[320], u8file[320], drfile[320], cwd[320];
				snprintf(bsfile, sizeof bsfile, "%s\\bs.shcl", tdir);
				for (char *p = bsfile; *p; p++) if (*p == '/') *p = '\\';
				if (shcl_save_file(nd, bsfile) != SHCL_SAVE_OK) fail("file_tier", "backslash path save failed");
				shcl_doc *bb = shcl_load_file(bsfile, &fst);
				if (fst != SHCL_FILE_CLEAN) fail("file_tier", "backslash path load");
				shcl_free(bb); remove(bsfile);
				// Checked through the wide API on purpose: the narrow calls would
				// write and read back the same wrong name, so a round trip through
				// them proves nothing.
				snprintf(u8file, sizeof u8file, "%s/\xe6\x97\xa5.shcl", tdir);
				if (shcl_save_file(nd, u8file) != SHCL_SAVE_OK) fail("file_tier", "utf-8 name save failed");
				wchar_t wname[320];
				if (MultiByteToWideChar(CP_UTF8, 0, u8file, -1, wname, 320) == 0) fail("file_tier", "widen failed");
				if (GetFileAttributesW(wname) == INVALID_FILE_ATTRIBUTES) fail("file_tier", "utf-8 name not on disk under its own spelling");
				bb = shcl_load_file(u8file, &fst);
				if (fst != SHCL_FILE_CLEAN) fail("file_tier", "utf-8 name load");
				shcl_free(bb); _wremove(wname);
				// `C:x` names x in C:'s current directory, so the save has to end up
				// beside the fixture's other files once that directory is tdir.
				if (tdir[1] == ':' && _getcwd(cwd, sizeof cwd) && _chdir(tdir) == 0) {
					snprintf(drfile, sizeof drfile, "%c:dr.shcl", tdir[0]);
					if (shcl_save_file(nd, drfile) != SHCL_SAVE_OK) fail("file_tier", "drive-relative save failed");
					if (_chdir(cwd) != 0) fail("file_tier", "chdir back failed");
					snprintf(drfile, sizeof drfile, "%s/dr.shcl", tdir);
					bb = shcl_load_file(drfile, &fst);
					if (fst != SHCL_FILE_CLEAN) fail("file_tier", "drive-relative save ended up elsewhere");
					shcl_free(bb); remove(drfile);
				}
			}
#endif
			// (NULL, 0) through the public atomic write: fwrite with a null
			// buffer is undefined even at length zero, and only the sanitized
			// build of this runner would see it.
			if (!shcl_write_file_atomic(fresh, NULL, 0)) fail("file_tier", "atomic write of (NULL, 0) failed");
			{
				FILE *ef = fopen(fresh, "rb");
				if (!ef || fgetc(ef) != EOF) fail("file_tier", "atomic write of (NULL, 0) left bytes");
				if (ef) fclose(ef);
			}
			shcl_free(nd);
			remove(fresh);
		}
		// Content-malformed lines are retained as trivia (lost 0, the line
		// survives a save); position-dependent drops count as lost and make
		// shcl_save_file refuse until the caller opts into the lossy save.
		// Same fixture in every runner.
		const char *kt = "a: 1\nsquare-miles 300\nb: 2\n";
		shcl_doc *kd = shcl_parse(kt, strlen(kt));
		if (shcl_lost_count(kd) != 0) fail("lost", "kept lost_count not 0");
		shcl_str kc = shcl_to_canonical(kd);
		if (!contains(kc.p, kc.n, "square-miles 300\n")) fail("lost", "retained line missing");
		// An indent matching no level is kept as written when it holds a space,
		// which no level the emitter writes can equal, and lost when it is tabs.
		const char *sp = "a:\n\tb: 1\n  c: 2\n\td: 3\n";
		shcl_doc *spd = shcl_parse(sp, strlen(sp));
		if (shcl_lost_count(spd) != 0) fail("lost", "spaced lost_count not 0");
		shcl_str spc = shcl_to_canonical(spd);
		if (spc.n != strlen(sp) || memcmp(spc.p, sp, spc.n) != 0) fail("lost", "spaced line not kept as written");
		shcl_free(spd);
		const char *lt2 = "a:\n\t\tb: 1\n\tc: 2\n";
		shcl_doc *lo = shcl_parse(lt2, strlen(lt2));
		if (shcl_lost_count(lo) != 1) fail("lost", "lost_count not 1");
		if (shcl_save_file(kd, tfile) != SHCL_SAVE_OK) fail("lost", "kept save failed");
		shcl_doc *kb = shcl_load_file(tfile, &fst);
		shcl_str kbc = shcl_to_canonical(kb);
		if (!contains(kbc.p, kbc.n, "square-miles 300\n")) fail("lost", "retained line lost through save");
		shcl_free(kb);
		if (shcl_save_file(lo, tfile) != SHCL_SAVE_REFUSED) fail("lost", "save did not refuse a lossy save");
		if (shcl_save_file_lossy(lo, tfile) != SHCL_SAVE_OK) fail("lost", "lossy save failed");
		// A refusal and a failed write are separate values, not two spellings of
		// one message, and the gate answers before any i/o - so an unwritable path
		// still reports the refusal. Same fixture in every runner.
		char bad[320];
		snprintf(bad, sizeof bad, "%s/nope/t.shcl", tdir);
		if (shcl_save_file(kd, bad) != SHCL_SAVE_FAILED) fail("lost", "a failed write did not report as one");
		if (shcl_save_file(lo, bad) != SHCL_SAVE_REFUSED) fail("lost", "refusal did not survive an unwritable path");
		// A save that keeps lines writes the dropped line back as it was, so it
		// refuses only when it falls back to canonical. Here removing the line
		// above it would make it a child of `a`.
		shcl_doc *kl = shcl_parse_keep_lines(lt2, strlen(lt2), SHCL_STANDARD);
		if (!shcl_set_int(kl, "a.b", 3, 5)) fail("lost", "keep set failed");
		int klk = 0;
		if (shcl_save_file_keep_lines(kl, tfile, &klk) != SHCL_SAVE_OK || !klk) fail("lost", "keep save did not keep a dropped line");
		size_t kll = 0; shcl_file_status kls;
		char *klt = shcl_read_file(tfile, 0, &kll, &kls);
		const char *klw = "a:\n\t\tb: 5\n\tc: 2\n";
		if (!klt || kll != strlen(klw) || memcmp(klt, klw, kll) != 0) fail("lost", "keep save text mismatch");
		free(klt);
		if (shcl_remove(kl, "a.b", 3) != 1) fail("lost", "keep remove failed");
		if (shcl_save_file_keep_lines(kl, tfile, &klk) != SHCL_SAVE_REFUSED) fail("lost", "keep save did not refuse its fallback");
		shcl_free(kl);
		shcl_free(lo); shcl_free(kd);
		remove(tfile); rmdir(tdir);
	}
	// The save gate on kept lines, from inside: once the edits that lose one are
	// fixed, no public call reaches the gate, so these take a line out by hand.
	// Same fixture in every runner.
	test_id("EreWlg6", "a_kept_line_gone_from_the_tree_refuses_the_save");
	{
		const char *kbase = "x: 1\nr: [1, 2]\ny: 3\n";
		shcl_doc *kd = shcl_parse_keep_lines(kbase, strlen(kbase), SHCL_STANDARD);
		if (shcl_lost_count(kd) != 0) fail("kept_gate", "lost before the edit");
		ShclVecSize *kids = &kd->nodes.data[0].children; // the root
		ShclTrivia *yt = kd->nodes.data[kids->data[kids->len - 1]].trivia;
		if (!yt || yt->leading.len == 0 || !lead_is_kept_line(&yt->leading.data[yt->leading.len - 1])) fail("kept_gate", "no kept line on y");
		else yt->leading.len--;
		if (shcl_lost_count(kd) != 1) fail("kept_gate", "lost_count not 1");
		int kk = 1;
		shcl_to_text_keep_lines(kd, &kk);
		if (kk) fail("kept_gate", "the keep save kept lines with one gone");
		char kdir[256], kfile[288];
		snprintf(kdir, sizeof kdir, "%s/shcl-keptgate-%ld", tmp_root(), (long)getpid());
		snprintf(kfile, sizeof kfile, "%s/f.shcl", kdir);
#ifdef _WIN32
		if (_mkdir(kdir) != 0) fail("kept_gate", "mkdir failed");
#else
		if (mkdir(kdir, 0700) != 0) fail("kept_gate", "mkdir failed");
#endif
		FILE *kf = fopen(kfile, "wb");
		if (kf) { fputs(kbase, kf); fclose(kf); }
		if (shcl_save_file(kd, kfile) != SHCL_SAVE_REFUSED) fail("kept_gate", "save_file did not refuse");
		if (shcl_save_file_keep_lines(kd, kfile, &kk) != SHCL_SAVE_REFUSED) fail("kept_gate", "save_file_keep_lines did not refuse");
		size_t kn = 0; shcl_file_status kst;
		char *kt = shcl_read_file(kfile, 0, &kn, &kst);
		if (!kt || kn != strlen(kbase) || memcmp(kt, kbase, kn) != 0) fail("kept_gate", "the file changed");
		free(kt);
		shcl_free(kd);
		remove(kfile); rmdir(kdir);
	}
	// A compaction rebuilds the document, so it carries the kept-line count
	// with the lost count, or a compacted document never refuses. C only.
	test_id("EreZ0ar", "compact_keeps_the_kept_line_count");
	{
		const char *kbase = "x: 1\nr: [1, 2]\ny: 3\n";
		shcl_doc *cd = shcl_parse(kbase, strlen(kbase));
		shcl_compact(cd);
		ShclVecSize *ck = &cd->nodes.data[0].children;
		ShclTrivia *cy = cd->nodes.data[ck->data[ck->len - 1]].trivia;
		if (cy && cy->leading.len) cy->leading.len--;
		if (shcl_lost_count(cd) != 1) fail("kept_gate", "a compacted document lost a kept line and did not count it");
		shcl_free(cd);
	}
	// design.md's table: a remove takes the kept line written as the field's own
	// line, and nothing beside it.
	test_id("EreWli7", "a_remove_takes_the_kept_line_heading_its_field");
	{
		const char *ht = "a: [1]\n\tb: 2\ny: 3\n";
		shcl_doc *hd = shcl_parse(ht, strlen(ht));
		if (shcl_remove(hd, "a", 1) != 1) fail("kept_gate", "remove a failed");
		if (shcl_lost_count(hd) != 0) fail("kept_gate", "removing a field opened from a kept line counted it lost");
		shcl_str hc = shcl_to_canonical(hd);
		if (hc.n != 5 || memcmp(hc.p, "y: 3\n", 5) != 0) fail("kept_gate", "removing a field opened from a kept line left more than y");
		shcl_free(hd);
	}
	{
		// design.md's table: a remove leaves the kept lines beside its target,
		// above or below it, with the comments above them (2026100307163901).
		// Then a field opened only by the lines under it goes with the last of
		// them, and its kept line stays (escblock; 2026100307163907).
		static const struct { const char *id, *name, *text, *path, *want; } rc[] = {
			{"ErgTokB", "a_remove_leaves_the_kept_lines_beside_it", "x: 1\nr: [1, 2]\ny: 3\n", "y", "x: 1\nr: [1, 2]\n"},
			{NULL, NULL, "x: 1\nbad name: 1\ny: 3\n", "y", "x: 1\nbad name: 1\n"},
			{NULL, NULL, "j:\n\tr: [1]\n\tq: 1\nz: 2\n", "j.q", "j:\n\tr: [1]\nz: 2\n"},
			{NULL, NULL, "j:\n\tq: 1\n\tr: [1]\nz: 2\n", "j.q", "j:\n\tr: [1]\nz: 2\n"},
			{NULL, NULL, "j:\n\tq: 1\n\tr: [1]\n\tw: 3\nz: 2\n", "j.q", "j:\n\tr: [1]\n\tw: 3\nz: 2\n"},
			{NULL, NULL, "# on r\nr: [1]\n# on y\ny: 3\nz: 1\n", "y", "# on r\nr: [1]\nz: 1\n"},
			{"ErgTom6", "a_field_opened_by_a_kept_line_goes_with_its_last_line", "a: [1]\n\tb: 2\ny: 3\n", "a.b", "a: [1]\ny: 3\n"},
			{NULL, NULL, "a: [1]\n\tb: 2\n\tc: 3\ny: 3\n", "a.b", "a: [1]\n\tc: 3\ny: 3\n"},
			{NULL, NULL, "a: [1]\n\tb: 2\n\tr: [3]\ny: 3\n", "a.b", "a: [1]\n\tr: [3]\ny: 3\n"},
			{NULL, NULL, "o: [9]\n\ta: [1]\n\t\tb: 2\ny: 3\n", "o.a.b", "o: [9]\n\ta: [1]\ny: 3\n"},
			{NULL, NULL, "o:\n\ta: [1]\n\t\tb: 2\n", "o.a.b", "o:\n\ta: [1]\n"},
		};
		for (size_t i = 0; i < sizeof rc / sizeof rc[0]; i++) {
			if (rc[i].id) test_id(rc[i].id, rc[i].name);
			shcl_doc *rd = shcl_parse(rc[i].text, strlen(rc[i].text));
			size_t n = shcl_remove(rd, rc[i].path, strlen(rc[i].path));
			shcl_str out = shcl_to_canonical(rd);
			if (n != 1 || shcl_lost_count(rd) != 0 || out.n != strlen(rc[i].want) || memcmp(out.p, rc[i].want, out.n) != 0) {
				fail("kept_gate", rc[i].text);
			} else {
				shcl_doc *back = shcl_parse(out.p, out.n);
				shcl_str again = shcl_to_canonical(back);
				if (again.n != out.n || memcmp(again.p, out.p, out.n) != 0) fail("kept_gate", "a remove wrote text that reloads otherwise");
				shcl_free(back);
			}
			shcl_free(rd);
		}
	}
	test_id("EreWlk5", "a_merged_layer_owes_its_kept_lines");
	{
		const char *kbase = "x: 1\nr: [1, 2]\ny: 3\n";
		shcl_doc *md = shcl_parse("a: 1\n", 5);
		shcl_doc *ml = shcl_parse(kbase, strlen(kbase));
		shcl_merge(md, ml);
		shcl_str mc = shcl_to_canonical(md);
		if (shcl_lost_count(md) != 0 || !contains(mc.p, mc.n, "r: [1, 2]\n")) fail("kept_gate", "a merged layer's kept line counted as lost or went missing");
		// Owed, not just present: taking it out again is a loss.
		ShclVecSize *mk = &md->nodes.data[0].children;
		ShclTrivia *my = md->nodes.data[mk->data[mk->len - 1]].trivia;
		if (my && my->leading.len) my->leading.len--;
		if (shcl_lost_count(md) != 1) fail("kept_gate", "a merged kept line taken out did not count as lost");
		shcl_free(ml); shcl_free(md);
	}
	// design.md's table: a settled kept line on a leaf the layer replaces goes
	// with the leaf's comments, so it is no longer owed.
	test_id("ErfGoMO", "a_replaced_leaf_takes_its_settled_kept_line");
	{
		const char *rt = "x: 0\n\tc: 2\n  a: 5\nb: 1\n";
		shcl_doc *rd = shcl_parse(rt, strlen(rt));
		if (shcl_remove(rd, "x.c", 3) != 1) fail("kept_gate", "remove x.c failed");
		shcl_str rc = shcl_to_canonical(rd);
		const char *rw = "x: 0\n# a: 5\nb: 1\n";
		if (rc.n != strlen(rw) || memcmp(rc.p, rw, rc.n) != 0) fail("kept_gate", "the replaced-leaf fixture did not settle its kept line");
		shcl_doc *rl = shcl_parse("b: 9\n", 5);
		shcl_merge(rd, rl);
		rc = shcl_to_canonical(rd);
		rw = "x: 0\nb: 9\n";
		if (rc.n != strlen(rw) || memcmp(rc.p, rw, rc.n) != 0) fail("kept_gate", "the replaced leaf kept its settled line");
		if (shcl_lost_count(rd) != 0) fail("kept_gate", "a replaced leaf's settled line counted as lost");
		shcl_free(rl); shcl_free(rd);
	}
	// design.md's table: the footer dedup skips a layer's kept line the base
	// already has, so that copy is not owed.
	test_id("ErfGoMP", "a_footer_line_the_base_has_is_not_owed_twice");
	{
		const char *ft = "bad name: 1\n";
		shcl_doc *fd = shcl_parse(ft, strlen(ft));
		shcl_doc *fl = shcl_parse(ft, strlen(ft));
		shcl_merge(fd, fl);
		shcl_str fc = shcl_to_canonical(fd);
		if (fc.n != strlen(ft) || memcmp(fc.p, ft, fc.n) != 0) fail("kept_gate", "the footer dedup wrote the line twice");
		if (shcl_lost_count(fd) != 0) fail("kept_gate", "a deduped footer line counted as lost");
		shcl_free(fl); shcl_free(fd);
	}
	// set_raw: the body's shared indent survives a reload (the closing fence's
	// indent is what comes off), the info-string is stored as a fence line
	// reads it back, and an info with a line break or a `#` has no spelling and
	// fails the write. Same fixture in every runner.
	test_id("EoM5gS8", "set_raw_keeps_a_shared_indent_and_trims_the_info");
	{
		shcl_doc *sd = shcl_new();
		if (!shcl_set_raw(sd, "q", 1, "  a\n  b", 7, " sql ", 5)) fail("set_raw", "set_raw failed");
		shcl_str sc = shcl_to_canonical(sd);
		shcl_doc *back = shcl_parse(sc.p, sc.n);
		shcl_read_str br = shcl_read_raw(back, "q", 1);
		if (br.status != SHCL_GOOD || br.value.n != 7 || memcmp(br.value.p, "  a\n  b", 7) != 0) fail("set_raw", "shared indent did not survive a reload");
		shcl_read_str bi = shcl_read_raw_info(back, "q", 1);
		if (bi.status != SHCL_GOOD || bi.value.n != 3 || memcmp(bi.value.p, "sql", 3) != 0) fail("set_raw", "info not trimmed");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "a\nb", 3)) fail("set_raw", "info with a newline accepted");
		br = shcl_read_raw(sd, "q", 1);
		if (br.status != SHCL_GOOD || br.value.n != 7 || memcmp(br.value.p, "  a\n  b", 7) != 0) fail("set_raw", "refused write changed the document");
		// A trailing CR is a blank and comes off, as the load takes it; one
		// mid-info is content.
		if (!shcl_set_raw(sd, "q", 1, "x", 1, "ab\r", 3)) fail("set_raw", "info ending in a CR refused");
		shcl_free(back);
		sc = shcl_to_canonical(sd);
		back = shcl_parse(sc.p, sc.n);
		bi = shcl_read_raw_info(back, "q", 1);
		if (bi.status != SHCL_GOOD || bi.value.n != 2 || memcmp(bi.value.p, "ab", 2) != 0) fail("set_raw", "trailing CR on an info not trimmed");
		if (!shcl_set_raw(sd, "q", 1, "x", 1, "a\rb", 3)) fail("set_raw", "info with a mid-string CR refused");
		shcl_free(back);
		sc = shcl_to_canonical(sd);
		back = shcl_parse(sc.p, sc.n);
		bi = shcl_read_raw_info(back, "q", 1);
		if (bi.status != SHCL_GOOD || bi.value.n != 3 || memcmp(bi.value.p, "a\rb", 3) != 0) fail("set_raw", "mid-string CR info did not round-trip");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "a # b", 5)) fail("set_raw", "info with a # accepted");
		// An info string has no quoting of its own: quotes are characters in
		// it, so they hide nothing, and a `#` glued to the label opens a
		// comment too.
		if (shcl_set_raw(sd, "q", 1, "x", 1, "\"a # b\"", 7)) fail("set_raw", "quoted # info accepted");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "c#", 2)) fail("set_raw", "glued # info accepted");
		shcl_free(back);
		// A body line ending in CR has no fence spelling: the load takes the
		// whole trailing CR run off every line, so it is refused rather than
		// lost. A CR mid-line is content and still round-trips.
		if (shcl_set_raw(sd, "q", 1, "a\r\nb", 4, "", 0)) fail("set_raw", "body with a line-ending CR accepted");
		if (shcl_set_raw(sd, "q", 1, "\r", 1, "", 0)) fail("set_raw", "body of one CR accepted");
		if (!shcl_set_raw(sd, "q", 1, "a\rb", 3, "", 0)) fail("set_raw", "body with a mid-line CR refused");
		sc = shcl_to_canonical(sd);
		back = shcl_parse(sc.p, sc.n);
		br = shcl_read_raw(back, "q", 1);
		if (br.status != SHCL_GOOD || br.value.n != 3 || memcmp(br.value.p, "a\rb", 3) != 0) fail("set_raw", "mid-line CR did not survive the reload");
		shcl_free(back); shcl_free(sd);
	}
	// A link to a file that is not there yet is written through like any
	// other link: the file appears where the link points and the link stays a
	// link. Same fixture in every POSIX runner.
#ifndef _WIN32
	test_id("EoM5gS9", "save_creates_the_file_behind_a_dangling_symlink");
	{
		char ddir[256], dreal[288], dlink[288], dtarget[320];
		snprintf(ddir, sizeof ddir, "%s/shcl-dangling-%ld", tmp_root(), (long)getpid());
		snprintf(dreal, sizeof dreal, "%s/real", ddir);
		snprintf(dlink, sizeof dlink, "%s/c.shcl", ddir);
		snprintf(dtarget, sizeof dtarget, "%s/real/c.shcl", ddir);
		if (mkdir(ddir, 0700) != 0 || mkdir(dreal, 0700) != 0) fail("dangling", "mkdir failed");
		if (symlink("real/c.shcl", dlink) != 0) fail("dangling", "symlink failed");
		shcl_doc *dd = shcl_parse("a: 1\n", 5);
		if (shcl_save_file(dd, dlink) != SHCL_SAVE_OK) fail("dangling", "save through a dangling link failed");
		struct stat ls;
		if (lstat(dlink, &ls) != 0 || !S_ISLNK(ls.st_mode)) fail("dangling", "the link is no longer a link");
		size_t tn; char *tt = read_file(dtarget, &tn);
		if (!tt || tn != 5 || memcmp(tt, "a: 1\n", 5) != 0) fail("dangling", "file not created behind the link");
		free(tt); shcl_free(dd);
		remove(dlink); remove(dtarget); rmdir(dreal); rmdir(ddir);
	}
	// Two links pointing at each other resolve to nothing, so the save fails
	// and says why. It must not "fix" the cycle by dropping a regular file over
	// one of the links. Same fixture in every POSIX runner.
	test_id("EoUxXlS", "save_reports_a_symlink_cycle_instead_of_replacing_it");
	{
		char cdir[256], ca[288], cb[288];
		snprintf(cdir, sizeof cdir, "%s/shcl-cycle-%ld", tmp_root(), (long)getpid());
		snprintf(ca, sizeof ca, "%s/a.shcl", cdir);
		snprintf(cb, sizeof cb, "%s/b.shcl", cdir);
		if (mkdir(cdir, 0700) != 0) fail("cycle", "mkdir failed");
		if (symlink("b.shcl", ca) != 0 || symlink("a.shcl", cb) != 0) fail("cycle", "symlink failed");
		shcl_doc *cd = shcl_parse("a: 1\n", 5);
		if (shcl_save_file(cd, ca) == SHCL_SAVE_OK) fail("cycle", "a symlink cycle saved without an error");
		struct stat cs;
		if (lstat(ca, &cs) != 0 || !S_ISLNK(cs.st_mode)) fail("cycle", "a symlink cycle was replaced by a regular file");
		if (lstat(cb, &cs) != 0 || !S_ISLNK(cs.st_mode)) fail("cycle", "a symlink cycle was replaced by a regular file");
		shcl_free(cd);
		remove(ca); remove(cb); rmdir(cdir);
	}
	// Save outcomes in design.md, the rows the CLI's own check hides. A FIFO
	// was swapped for a regular file at exit 0, a link whose text names a
	// directory made a file of that name, and Go cleaned `lnk/..` as text where
	// the kernel follows lnk first. Same fixture in every POSIX runner.
	test_id("EqLbKeM", "save_replaces_only_a_regular_file");
	{
		char tdir[256], tp[320], tq[320], tr[320];
		snprintf(tdir, sizeof tdir, "%s/shcl-targets-%ld", tmp_root(), (long)getpid());
		if (mkdir(tdir, 0700) != 0) fail("targets", "mkdir failed");
		shcl_doc *td = shcl_parse("a: 1\n", 5);
		struct stat ts;
		snprintf(tp, sizeof tp, "%s/p.shcl", tdir);
		if (mkfifo(tp, 0600) != 0) fail("targets", "mkfifo failed");
		if (shcl_save_file(td, tp) == SHCL_SAVE_OK) fail("targets", "a FIFO saved without an error");
		if (lstat(tp, &ts) != 0 || !S_ISFIFO(ts.st_mode)) fail("targets", "a FIFO was replaced by a regular file");
		remove(tp);
		snprintf(tp, sizeof tp, "%s/l.shcl", tdir);
		snprintf(tq, sizeof tq, "%s/d", tdir);
		if (symlink("d/", tp) != 0) fail("targets", "symlink failed");
		if (shcl_save_file(td, tp) == SHCL_SAVE_OK) fail("targets", "a link naming a directory saved without an error");
		if (lstat(tq, &ts) == 0) fail("targets", "a link naming a directory made a file");
		remove(tp);
		snprintf(tp, sizeof tp, "%s/real", tdir); if (mkdir(tp, 0700) != 0) fail("targets", "mkdir failed");
		snprintf(tp, sizeof tp, "%s/real/sub", tdir); if (mkdir(tp, 0700) != 0) fail("targets", "mkdir failed");
		snprintf(tp, sizeof tp, "%s/top", tdir); if (mkdir(tp, 0700) != 0) fail("targets", "mkdir failed");
		snprintf(tp, sizeof tp, "%s/top/lnkdir", tdir);
		snprintf(tq, sizeof tq, "%s/real/sub/f.shcl", tdir);
		if (symlink("../real/sub", tp) != 0 || symlink("../x.shcl", tq) != 0) fail("targets", "symlink failed");
		snprintf(tr, sizeof tr, "%s/top/lnkdir/f.shcl", tdir);
		if (shcl_save_file(td, tr) != SHCL_SAVE_OK) fail("targets", "save through lnk/.. failed");
		snprintf(tr, sizeof tr, "%s/real/x.shcl", tdir);
		size_t xn; char *xt = read_file(tr, &xn);
		if (!xt || xn != 5 || memcmp(xt, "a: 1\n", 5) != 0) fail("targets", "file not created behind lnk/..");
		free(xt);
		remove(tr); remove(tq); remove(tp);
		snprintf(tp, sizeof tp, "%s/top", tdir); rmdir(tp);
		snprintf(tp, sizeof tp, "%s/real/sub", tdir); rmdir(tp);
		snprintf(tp, sizeof tp, "%s/real", tdir); rmdir(tp);
		rmdir(tdir);
		shcl_free(td);
	}
#endif
	// A read-only target is rewritten, as it is on POSIX, and comes back
	// read-only; no temp file is left behind. Same fixture in every runner.
#ifdef _WIN32
	test_id("EoM5gSA", "save_rewrites_a_read_only_file");
	{
		char rdir[256], rfile[288];
		snprintf(rdir, sizeof rdir, "%s/shcl-readonly-%ld", tmp_root(), (long)getpid());
		snprintf(rfile, sizeof rfile, "%s/ro.shcl", rdir);
		if (_mkdir(rdir) != 0) fail("readonly", "mkdir failed");
		FILE *rf = fopen(rfile, "wb");
		if (!rf || fputs("a: 1\n", rf) == EOF || fclose(rf) != 0) fail("readonly", "seed write failed");
		if (!SetFileAttributesA(rfile, GetFileAttributesA(rfile) | FILE_ATTRIBUTE_READONLY)) fail("readonly", "set read-only failed");
		shcl_doc *rd = shcl_parse("a: 2\n", 5);
		if (shcl_save_file(rd, rfile) != SHCL_SAVE_OK) fail("readonly", "save over a read-only file failed");
		size_t rn; char *rt = read_file(rfile, &rn);
		if (!rt || rn != 5 || memcmp(rt, "a: 2\n", 5) != 0) fail("readonly", "file not rewritten");
		free(rt);
		if (!(GetFileAttributesA(rfile) & FILE_ATTRIBUTE_READONLY)) fail("readonly", "file did not come back read-only");
		// Hidden and system come back too: ReplaceFile's preserve list does not
		// include the basic attributes and the fallback move keeps none, so a
		// hidden config used to come back visible.
		SetFileAttributesA(rfile, (GetFileAttributesA(rfile) & ~(DWORD)FILE_ATTRIBUTE_READONLY) | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM);
		shcl_doc *hd = shcl_parse("a: 3\n", 5);
		if (shcl_save_file(hd, rfile) != SHCL_SAVE_OK) fail("attrs", "save over a hidden file failed");
		DWORD after = GetFileAttributesA(rfile);
		if (!(after & FILE_ATTRIBUTE_HIDDEN)) fail("attrs", "file did not come back hidden");
		if (!(after & FILE_ATTRIBUTE_SYSTEM)) fail("attrs", "file did not come back system");
		shcl_free(hd);
		SetFileAttributesA(rfile, FILE_ATTRIBUTE_NORMAL);
		SetFileAttributesA(rfile, GetFileAttributesA(rfile) | FILE_ATTRIBUTE_READONLY);
		// The temp name starts with a dot, so only the two directory entries
		// are skipped, not every dotfile. A planted lookalike proves the count
		// can see one: a filter that skipped every dotfile passed with nothing
		// to count, and nothing planted it.
		char planted[320]; snprintf(planted, sizeof planted, "%s/.ro.shcl.tmp999.0", rdir);
		FILE *pf = fopen(planted, "wb"); if (!pf || fclose(pf) != 0) fail("readonly", "planting a dot-named file failed");
		DIR *rdd = opendir(rdir); int left = 0; const struct dirent *re;
		while (rdd && (re = readdir(rdd))) if (strcmp(re->d_name, ".") != 0 && strcmp(re->d_name, "..") != 0) left++;
		if (rdd) closedir(rdd);
		if (left != 2) fail("readonly", left == 1 ? "the leftover count cannot see a dot-named file" : "a temp file was left behind");
		remove(planted);
		shcl_free(rd);
		SetFileAttributesA(rfile, FILE_ATTRIBUTE_NORMAL);
		remove(rfile); rmdir(rdir);
	}
	// A publish that fails leaves errno describing it. The wide calls report
	// through GetLastError and used to leave errno at 0, so the CLI printed
	// "Success" beside exit 8. A target held open without delete sharing
	// fails the replace; a device name fails the move.
	test_id("EojrwSW", "a_failed_publish_sets_errno");
	{
		char hdir[256], hfile[288];
		snprintf(hdir, sizeof hdir, "%s/shcl-held-%ld", tmp_root(), (long)getpid());
		snprintf(hfile, sizeof hfile, "%s/held.shcl", hdir);
		if (_mkdir(hdir) != 0) fail("errno", "mkdir failed");
		FILE *hf = fopen(hfile, "wb");
		if (!hf || fputs("a: 1\n", hf) == EOF || fclose(hf) != 0) fail("errno", "seed write failed");
		wchar_t wh[320];
		if (MultiByteToWideChar(CP_UTF8, 0, hfile, -1, wh, 320) == 0) fail("errno", "widen failed");
		HANDLE hold = CreateFileW(wh, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
		if (hold == INVALID_HANDLE_VALUE) fail("errno", "hold failed");
		errno = 0;
		if (shcl_write_file_atomic(hfile, "a: 2\n", 5)) fail("errno", "write over a held file succeeded");
		if (errno == 0) fail("errno", "failed publish left errno at 0");
		CloseHandle(hold);
		errno = 0;
		if (shcl_write_file_atomic("nul", "a: 2\n", 5)) fail("errno", "write to a device name succeeded");
		if (errno == 0) fail("errno", "failed publish to a device left errno at 0");
		DIR *hdd = opendir(hdir); const struct dirent *he;
		while (hdd && (he = readdir(hdd))) if (strcmp(he->d_name, ".") != 0 && strcmp(he->d_name, "..") != 0) {
			char left[600]; snprintf(left, sizeof left, "%s/%s", hdir, he->d_name); remove(left);
		}
		if (hdd) closedir(hdd);
		rmdir(hdir);
	}
	test_id("EoM5gSB", "publish_failures");
	publish_failures();
	test_id("ErO2NoF", "temp_takes_the_targets_dacl");
	temp_takes_the_targets_dacl();
#endif
	// Reads and saves must not retain: a read of a plain field hands back a
	// slice of the retained input (a million reads once grew a document by
	// 32 MB), and a save emits into scratch (200 saves of 79 KB once grew it by
	// 17 MB). The bound is one arena block, well under either regression.
	test_id("EoM5gSC", "reads_and_saves_do_not_retain");
	{
		char gdir[256], gfile[288];
		snprintf(gdir, sizeof gdir, "%s/shcl-retain-%ld", tmp_root(), (long)getpid());
		snprintf(gfile, sizeof gfile, "%s/g.shcl", gdir);
#ifdef _WIN32
		if (_mkdir(gdir) != 0) fail("retain", "mkdir failed");
#else
		if (mkdir(gdir, 0700) != 0) fail("retain", "mkdir failed");
#endif
		// About 30 KB: 2000 keys, so an unfixed save shows up at once.
		size_t gcap = 2000 * 16 + 1, gn = 0; char *gt = xrealloc(NULL, gcap);
		for (int i = 0; i < 2000; i++) gn += (size_t)snprintf(gt + gn, gcap - gn, "k%04d: v%04d\n", i, i);
		shcl_doc *gd = shcl_parse(gt, gn);
		size_t before = arena_bytes(&gd->arena);
		for (int i = 0; i < 100000; i++) {
			shcl_read_str r = shcl_read_string(gd, "k0042", 5);
			if (r.status != SHCL_GOOD || r.value.n != 5 || memcmp(r.value.p, "v0042", 5) != 0) { fail("retain", "read failed"); break; }
		}
		for (int i = 0; i < 200; i++) if (shcl_save_file(gd, gfile) != SHCL_SAVE_OK) { fail("retain", "save failed"); break; }
		size_t after = arena_bytes(&gd->arena);
		if (after > before + 65536) fail("retain", "reads and saves grew the document arena");
		shcl_free(gd); free(gt);
		remove(gfile); rmdir(gdir);
	}
	// Array reads must not grow the document arena, and the release call has to
	// give back what they do allocate. C-only: the other three hand back owned
	// collections their runtime reclaims, so there is nothing to mirror.
	test_id("EoTeOXw", "array_reads_do_not_grow_the_arena");
	{
		const char *at = "ports: 80, 443, 8080\n";
		shcl_doc *ad = shcl_parse(at, strlen(at));
		size_t docBefore = arena_bytes(&ad->arena);
		for (int i = 0; i < 20000; i++) {
			shcl_read_i64_arr r = shcl_read_int_array(ad, "ports", 5);
			if (r.status != SHCL_GOOD || r.n != 3 || r.values[1] != 443) { fail("array_retain", "read failed"); break; }
		}
		if (arena_bytes(&ad->arena) > docBefore + 4096) fail("array_retain", "array reads grew the document arena");
		shcl_reads_release(ad);
		if (arena_bytes(&ad->reads) != 0) fail("array_retain", "release did not reclaim the read arena");
		for (int i = 0; i < 20000; i++) {
			shcl_read_i64_arr r = shcl_read_int_array(ad, "ports", 5);
			if (r.status != SHCL_GOOD) { fail("array_retain", "read after release failed"); break; }
			shcl_reads_release(ad);
		}
		if (arena_bytes(&ad->reads) > 4096) fail("array_retain", "releasing per read did not keep the arena flat");
		shcl_free(ad);
	}
	// The copy-out reads leave the read arena as they found it, so a caller
	// that never releases still stays flat. Short buffers get what fits and
	// the whole count. C-only, for the same reason as above.
	test_id("Equbm1d", "copy_out_reads_leave_the_arena");
	{
		const char *at = "ports: 80, 443, 8080\nnames: a, \"b c\"\nwhen: 2026-01-02T03:04:05.25Z, 2027-01-01\nflags: true, false\nf: 1.5, 2\n";
		shcl_doc *ad = shcl_parse(at, strlen(at));
		size_t readsBefore = arena_bytes(&ad->reads);
		int64_t iv[3]; double fv[2]; int bv[2]; shcl_datetime dv[2]; shcl_str sv[2]; shcl_status sl[3];
		char buf[64]; size_t n = 0, len = 0;
		for (int i = 0; i < 20000; i++) {
			if (shcl_read_int_array_to(ad, "ports", 5, iv, sl, 3, &n) != SHCL_GOOD || n != 3 || iv[2] != 8080 || sl[1] != SHCL_GOOD) { fail("copy_out", "int array"); break; }
			if (shcl_read_float_array_to(ad, "f", 1, fv, NULL, 2, &n) != SHCL_GOOD || n != 2 || fv[0] != 1.5) { fail("copy_out", "float array"); break; }
			if (shcl_read_bool_array_to(ad, "flags", 5, bv, NULL, 2, &n) != SHCL_GOOD || n != 2 || bv[0] != 1 || bv[1] != 0) { fail("copy_out", "bool array"); break; }
			if (shcl_read_datetime_array_to(ad, "when", 4, dv, NULL, 2, &n) != SHCL_GOOD || n != 2 || dv[0].year != 2026 || dv[0].frac.n != 2 || memcmp(dv[0].frac.p, "25", 2) != 0) { fail("copy_out", "datetime array"); break; }
			if (shcl_read_string_array_to(ad, "names", 5, sv, NULL, 2, &n) != SHCL_GOOD || n != 2 || sv[1].n != 3 || memcmp(sv[1].p, "b c", 3) != 0) { fail("copy_out", "string array"); break; }
			if (shcl_read_string_to(ad, "names", 5, buf, sizeof buf, &len) != SHCL_GOOD || len != 8 || strcmp(buf, "a, \"b c\"") != 0) { fail("copy_out", "joined string"); break; }
		}
		if (arena_bytes(&ad->reads) != readsBefore) fail("copy_out", "copy-out reads grew the read arena");
		if (shcl_read_int_array_to(ad, "ports", 5, iv, sl, 1, &n) != SHCL_GOOD || n != 3 || iv[0] != 80) fail("copy_out", "short int buffer");
		if (shcl_read_string_to(ad, "names", 5, buf, 4, &len) != SHCL_GOOD || len != 8 || strcmp(buf, "a, ") != 0) fail("copy_out", "short string buffer");
		if (shcl_read_string_to(ad, "nope", 4, buf, sizeof buf, &len) != SHCL_NOT_FOUND || len != 0 || buf[0]) fail("copy_out", "missing path");
		if (shcl_read_int_array_to(ad, "nope", 4, iv, sl, 3, &n) != SHCL_NOT_FOUND || n != 0) fail("copy_out", "missing array");
		shcl_free(ad);
	}
	// Every field of shcl_datetime is public, so a caller can hand the renderer
	// values the parser never produces - a negative year, epoch seconds in sec,
	// a frac of any length. The buffer it documents is fixed, so the render has
	// to clamp. C-only: nothing to mirror where the caller cannot supply them.
	test_id("EoaHtYO", "datetime_render_clamps");
	{
		shcl_datetime worst;
		memset(&worst, 0, sizeof worst);
		char frac[4096]; memset(frac, '9', sizeof frac);
		worst.has_date = 1; worst.year = INT32_MIN; worst.month = UINT32_MAX; worst.day = UINT32_MAX;
		worst.has_time = 1; worst.hour = UINT32_MAX; worst.minute = UINT32_MAX;
		worst.has_sec = 1; worst.sec = UINT32_MAX;
		worst.has_frac = 1; worst.frac.p = frac; worst.frac.n = sizeof frac;
		worst.zone = SHCL_ZONE_OFFSET; worst.off_min = INT32_MIN;
		// On the heap and exactly the documented size, so a write past it is a
		// sanitizer stop rather than a quiet stamp on the next local.
		char *out = (char *)xrealloc(NULL, SHCL_DT_BUF);
		size_t dn = shcl_datetime_str(&worst, out);
		if (dn > SHCL_DT_BUF) fail("dt_clamp", "the render outgrew the buffer it documents");
		free(out);
		// The set path renders into its own SHCL_DT_BUF array before it judges
		// the value, so it has to survive the same value - and then refuse it,
		// since nothing this shape reads back.
		shcl_doc *dd = shcl_new();
		if (shcl_set_datetime(dd, "when", 4, &worst)) fail("dt_clamp", "the setter bound a datetime the reader refuses");
		if (shcl_exists(dd, "when", 4)) fail("dt_clamp", "a refused datetime left a node behind");
		shcl_free(dd);
	}
	// write_reason: the reason behind a setter's bare 0. Same fixture in every
	// runner.
	test_id("ElouJ8M", "write_reason_names_the_failure");
	{
		const char *wt = "a:\n\tb: 1\n";
		shcl_doc *wd = shcl_parse(wt, strlen(wt));
		if (shcl_write_reason_(wd, "a.b", 3) != SHCL_W_WRITABLE) fail("write_reason", "a.b not writable");
		if (shcl_write_reason_(wd, "a.new[Boston].x", 15) != SHCL_W_WRITABLE) fail("write_reason", "creatable path not writable");
		if (shcl_write_reason_(wd, "", 0) != SHCL_W_BAD_PATH) fail("write_reason", "empty path not bad");
		if (shcl_write_reason_(wd, "a..b", 4) != SHCL_W_BAD_PATH) fail("write_reason", "a..b not bad");
		if (shcl_write_reason_(wd, "a.b: 2", 6) != SHCL_W_VALUE_IN_PATH) fail("write_reason", "value part not flagged");
		if (shcl_write_reason_(wd, "a[*].b", 6) != SHCL_W_WILDCARD) fail("write_reason", "wildcard not flagged");
		if (shcl_write_reason_(wd, "a[#5].b", 7) != SHCL_W_NO_SUCH_INDEX) fail("write_reason", "a[#5] not flagged");
		if (shcl_write_reason_(wd, "nope[#0].b", 10) != SHCL_W_NO_SUCH_INDEX) fail("write_reason", "off-tree index not flagged");
		{
			char deep[1026]; size_t dn = 0; // 513 segments: "d.d.d..."
			for (size_t i = 0; i < 513; i++) { if (i) deep[dn++] = '.'; deep[dn++] = 'd'; }
			if (shcl_write_reason_(wd, deep, dn) != SHCL_W_TOO_DEEP) fail("write_reason", "513 segments not too deep");
		}
		// A literal line break is writable wherever a path can have one: a name
		// emits through the name escaper and a selector value through the value
		// emitter, and both write a break \n and read it back as one. The
		// selector was refused while the value emitter still wrote elements in
		// their source spelling and had nothing to escape with. Not
		// corpus-pinnable - an ops line cannot contain a raw newline.
		if (shcl_write_reason_(wd, "a[\"p\nq\"].b", 10) != SHCL_W_WRITABLE) fail("write_reason", "newline in selector not writable");
		if (shcl_write_reason_(wd, "\"x\ny\".b", 7) != SHCL_W_WRITABLE) fail("write_reason", "newline in name not writable");
		if (shcl_write_reason_(wd, "\"x\\ny\".b", 8) != SHCL_W_WRITABLE) fail("write_reason", "escaped newline not writable");
		// The probe never creates: the doc is unchanged after all of the above.
		if (shcl_count(wd, "a", 1) != 1) fail("write_reason", "probe created nodes");
		shcl_free(wd);
	}
	// Both halves of a path can contain a line break and write it \n: a name
	// through the name escaper, a selector value through the value emitter. The
	// selector was refused while elements were stored in their source spelling
	// and the emitter had nothing to escape with. Same fixture in every runner.
	test_id("EpGigIO", "a_line_break_in_a_path_writes_and_reads_back");
	{
		shcl_doc *nd = shcl_parse("z: 0\n", 5);
		if (!shcl_set_int(nd, "x[\"p\nq\"].c", sizeof "x[\"p\nq\"].c" - 1, 1)
			|| !shcl_set_int(nd, "\"a\nb\".c", sizeof "\"a\nb\".c" - 1, 1))
			fail("path_newline", "a line break in a path was refused");
		shcl_str nt = shcl_to_canonical(nd);
		char ntext[256];
		if (nt.n >= sizeof ntext) {
			fail("path_newline", "the canonical text outgrew the fixture buffer");
		} else {
			memcpy(ntext, nt.p, nt.n); ntext[nt.n] = 0;
			shcl_doc *nb = shcl_parse(ntext, nt.n);
			if (shcl_error_count(nb) != 0) fail("path_newline", "the reload has errors");
			shcl_str n2 = shcl_to_canonical(nb);
			if (n2.n != nt.n || memcmp(n2.p, ntext, nt.n) != 0) fail("path_newline", "not a fixpoint");
			if (shcl_read_int(nb, "x[\"p\\nq\"].c", sizeof "x[\"p\\nq\"].c" - 1).value != 1
				|| shcl_read_int(nb, "\"a\\nb\".c", sizeof "\"a\\nb\".c" - 1).value != 1
				|| shcl_read_int(nb, "\"a\nb\".c", sizeof "\"a\nb\".c" - 1).value != 1)
				fail("path_newline", "a line break in a path did not read back");
			shcl_free(nb);
		}
		shcl_free(nd);
	}
	// Each setter is the inverse of its read, so a value with no spelling the
	// reader accepts fails the write and leaves the document alone. Same
	// fixture in every runner.
	test_id("Eof29pa", "setters_refuse_a_value_the_reader_refuses");
	{
		shcl_doc *sd = shcl_parse("z: 0\n", 5);
		double nonfinite[3]; nonfinite[0] = INFINITY; nonfinite[1] = -INFINITY; nonfinite[2] = NAN;
		for (int i = 0; i < 3; i++) {
			double pair[2]; pair[0] = 1; pair[1] = nonfinite[i];
			if (shcl_set_float(sd, "f", 1, nonfinite[i]) || shcl_set_float_default(sd, "f", 1, nonfinite[i]) || shcl_set_float_array(sd, "f", 1, pair, 2))
				fail("setters_refuse", "a non-finite float was written");
			// A default form on a path that is already there writes nothing, and
			// still refuses what the plain setter would.
			if (shcl_set_float_default(sd, "z", 1, nonfinite[i]) || shcl_set_float_array_default(sd, "z", 1, pair, 2))
				fail("setters_refuse", "a non-finite float passed a default form on a present path");
		}
		if (!shcl_set_float(sd, "f", 1, 2.5) || shcl_get_float_or(sd, "f", 1, 0) != 2.5) fail("setters_refuse", "a finite float was refused");
		if (!shcl_set_float_default(sd, "z", 1, 2.5) || shcl_get_float_or(sd, "z", 1, 1) != 0) fail("setters_refuse", "a finite float default on a present path was refused or written");
		shcl_datetime bad[10]; memset(bad, 0, sizeof bad);
		// [0] nothing written
		bad[1].has_date = 1; bad[1].year = 2026; bad[1].month = 13; bad[1].day = 1;
		bad[2].has_date = 1; bad[2].year = 2026; bad[2].month = 2; bad[2].day = 30;
		bad[3].has_date = 1; bad[3].year = -1; bad[3].month = 1; bad[3].day = 1;
		bad[4].has_time = 1; bad[4].hour = 24;
		bad[5].has_time = 1; bad[5].hour = 1; bad[5].minute = 2; bad[5].has_frac = 1; bad[5].frac = s_lit("5"); // fraction with no seconds
		bad[6].has_time = 1; bad[6].hour = 1; bad[6].minute = 2; bad[6].has_sec = 1; bad[6].sec = 3; bad[6].has_frac = 1; bad[6].frac = s_lit(""); // empty fraction
		bad[7] = bad[6]; bad[7].frac = s_lit("12345678901"); // 11 digits
		bad[8].has_time = 1; bad[8].hour = 1; bad[8].minute = 2; bad[8].zone = SHCL_ZONE_OFFSET; bad[8].off_min = 9999; // +166:39
		bad[9].has_date = 1; bad[9].year = 2026; bad[9].month = 1; bad[9].day = 1; bad[9].zone = SHCL_ZONE_UTC; // zone on a date alone
		shcl_datetime good; memset(&good, 0, sizeof good); good.has_date = 1; good.year = 2026; good.month = 1; good.day = 1;
		for (int i = 0; i < 10; i++) {
			shcl_datetime pair[2]; pair[0] = good; pair[1] = bad[i];
			if (shcl_set_datetime(sd, "d", 1, &bad[i]) || shcl_set_datetime_default(sd, "d", 1, &bad[i]) || shcl_set_datetime_array(sd, "d", 1, pair, 2))
				fail("setters_refuse", "a datetime the reader refuses was written");
			if (shcl_set_datetime_default(sd, "z", 1, &bad[i]) || shcl_set_datetime_array_default(sd, "z", 1, pair, 2))
				fail("setters_refuse", "a datetime the reader refuses passed a default form on a present path");
		}
		shcl_datetime ok = good; ok.day = 2; ok.has_time = 1; ok.hour = 3; ok.minute = 4; ok.has_sec = 1; ok.sec = 5; ok.has_frac = 1; ok.frac = s_lit("60"); ok.zone = SHCL_ZONE_OFFSET; ok.off_min = -90;
		if (!shcl_set_datetime(sd, "d", 1, &ok)) fail("setters_refuse", "a valid datetime was refused");
		shcl_read_dt rd = shcl_read_datetime(sd, "d", 1);
		char okb[SHCL_DT_BUF], rdb[SHCL_DT_BUF]; size_t okn = shcl_datetime_str(&ok, okb), rdn = shcl_datetime_str(&rd.value, rdb);
		if (rd.status != SHCL_GOOD || okn != rdn || memcmp(okb, rdb, okn) != 0) fail("setters_refuse", "the datetime read back differently");
		shcl_str canon = shcl_to_canonical(sd);
		const char *want = "z: 0\n\nf: 2.5\n\nd: \"2026-01-02T03:04:05.60-01:30\"\n";
		if (canon.n != strlen(want) || memcmp(canon.p, want, canon.n) != 0) fail("setters_refuse", "document after the refusals differs");
		shcl_free(sd);
	}
	// One combined diagnostics list (parse first, then validation) and an
	// error predicate, so recover-and-continue can't read as success by
	// accident. Same fixture in every runner.
	test_id("Elp3cOi", "one_shot_load_and_validate");
	{
		const char *ot = ": nope\nport: x\n";
		const char *os = "field: port\n\ttype: int\n";
		shcl_doc *od = shcl_load_and_validate(ot, strlen(ot), os, strlen(os), SHCL_STANDARD);
		if (shcl_diag_count(od) != 2) fail("oneshot", "diag count not 2");
		else if (strcmp(shcl_diag_code(od, 0), "E014") || strcmp(shcl_diag_code(od, 1), "V003")) fail("oneshot", "codes not E014,V003");
		if (shcl_error_count(od) != 2) fail("oneshot", "error_count not 2");
		shcl_read_str pr = shcl_read_string(od, "port", 4); // doc still usable
		if (pr.status != SHCL_GOOD || pr.value.n != 1 || pr.value.p[0] != 'x') fail("oneshot", "port not readable");
		shcl_free(od);
		// Strict never errors out here; the diagnostics are the answer.
		shcl_doc *sd = shcl_load_and_validate(ot, strlen(ot), os, strlen(os), SHCL_STRICT);
		if (shcl_error_count(sd) < 2) fail("oneshot", "strict error_count < 2");
		shcl_free(sd);
		// An empty schema declares nothing and validates nothing.
		shcl_doc *pd = shcl_load_and_validate("a: 1\n", 5, "", 0, SHCL_STANDARD);
		if (shcl_error_count(pd) != 0 || shcl_diag_count(pd) != 0) fail("oneshot", "plain doc not clean");
		shcl_free(pd);
	}
	// A schema that does not load would otherwise drop the constraints on its
	// broken lines, or report every field as unknown - blaming the document.
	// Same fixture in every runner.
	test_id("Eqzz38a", "one_shot_load_reports_a_broken_schema");
	{
		const char *bt = "host: example\n";
		const char *bs = "field: apikey\n\ttype: string\n  required: true\n";
		shcl_doc *bd = shcl_load_and_validate(bt, strlen(bt), bs, strlen(bs), SHCL_STANDARD);
		if (shcl_diag_count(bd) != 1) fail("oneshot_broken", "expected only the schema fault");
		else if (strcmp(shcl_diag_code(bd, 0), "V099")) fail("oneshot_broken", "code not V099");
		if (shcl_error_count(bd) != 1) fail("oneshot_broken", "error_count not 1");
		shcl_free(bd);
		// A schema that loads still validates normally.
		shcl_doc *ld = shcl_load_and_validate(bt, strlen(bt), "field: host\n", 12, SHCL_STANDARD);
		if (shcl_error_count(ld) != 0) fail("oneshot_broken", "loading schema not clean");
		shcl_free(ld);
		// An empty schema still means "skip validation", not "everything unknown".
		shcl_doc *ed = shcl_load_and_validate(bt, strlen(bt), "", 0, SHCL_STANDARD);
		if (shcl_error_count(ed) != 0) fail("oneshot_broken", "empty schema not clean");
		shcl_free(ed);
	}
	// The unknown-field chain key is length-prefixed, not NUL-joined: a single
	// field whose name literally contains a NUL must not impersonate the
	// two-segment path x.y. Same fixture in every runner.
	test_id("Eqzz38b", "nul_name_does_not_satisfy_a_dotted_schema_path");
	{
		static const char nt[] = "\"x\0y\": 1\n";
		shcl_doc *ns = shcl_parse("field: x.y\n", 11);
		shcl_doc *nd = shcl_parse(nt, sizeof nt - 1);
		shcl_validation *nv = shcl_validate(nd, ns);
		if (!nv) fail("nul_name", "validate returned NULL");
		else {
			if (shcl_validation_count(nv) != 1) fail("nul_name", "NUL-bearing name slipped past the sweep");
			else {
				shcl_str m = shcl_validation_message(nv, 0);
				if (strcmp(shcl_validation_code(nv, 0), "V001")) fail("nul_name", "code not V001");
				if (m.n < 14 || memcmp(m.p, "unknown field ", 14) != 0) fail("nul_name", "message not 'unknown field ...'");
			}
			shcl_validation_free(nv);
		}
		// The genuinely two-segment spelling still validates clean.
		shcl_doc *od = shcl_parse("x:\n\ty: 1\n", 9);
		shcl_validation *ov = shcl_validate(od, ns);
		if (!ov || shcl_validation_count(ov) != 0) fail("nul_name", "x.y did not validate clean");
		if (ov) shcl_validation_free(ov);
		shcl_free(od); shcl_free(nd); shcl_free(ns);
	}
	// (NULL, 0) is the usual C spelling of "no text", and a fast path that
	// hands it to memchr breaks glibc's nonnull contract. Only the sanitized
	// build of this runner can see that.
	test_id("EpHDKeu", "a_null_span_is_no_text");
	{
		shcl_doc *zd = shcl_parse("", 0);
		if (!shcl_set_literal(zd, "l", 1, NULL, 0)) fail("null_span", "set_literal refused (NULL, 0)");
		if (!shcl_set_raw(zd, "r", 1, NULL, 0, NULL, 0)) fail("null_span", "set_raw refused (NULL, 0)");
		if (!shcl_set_literal_default(zd, "l2", 2, NULL, 0)) fail("null_span", "set_literal_default refused (NULL, 0)");
		if (!shcl_set_raw_default(zd, "r2", 2, NULL, 0, NULL, 0)) fail("null_span", "set_raw_default refused (NULL, 0)");
		shcl_str zc = shcl_to_canonical(zd);
		const char *zwant = "l:\n\nr:\n\t```\n\t```\n\nl2:\n\nr2:\n\t```\n\t```\n";
		if (zc.n != strlen(zwant) || memcmp(zc.p, zwant, zc.n) != 0) fail("null_span", "document differs from empty literal and raw values");
		shcl_free(zd);
	}
	// Every arena a validate arms has to be disarmed before the call returns,
	// or the guard still names a frame that has gone. The suggestion scratch is
	// armed down inside the unknown-field sweep, so the sweep has to run: the
	// document has a field the schema does not declare.
	test_id("EoXPDVg", "validate_disarms_every_guard");
	{
		const char *vt = "port: 1\nprot: 2\n";
		const char *vs = "field: port\n\ttype: int\n";
		shcl_doc *vd = shcl_parse(vt, strlen(vt));
		shcl_doc *vsd = shcl_parse(vs, strlen(vs));
		shcl_validation *vv = shcl_validate(vd, vsd);
		if (!vv) fail("guards", "validate returned NULL");
		else {
			if (shcl_validation_count(vv) == 0) fail("guards", "the sweep reported nothing, so it did not run");
			if (vv->arena.panic || vv->scratch.panic) fail("guards", "validation arena still armed after the call");
			if (vd->index_arena.panic || vd->scratch.panic || vd->reads.panic) fail("guards", "document arena still armed after a validate");
			shcl_validation_free(vv);
		}
		shcl_free(vd); shcl_free(vsd);
	}
#ifndef _WIN32
	// Validation used to put one scratch arena per level of the depth cap on the
	// stack - 16 KB, which is nothing on a main thread and past the whole stack
	// of a small worker. The platform's smallest allowed thread stack is the
	// assertion: it is under the array the old code wanted on it.
	test_id("EoXPDVh", "validate_fits_a_small_stack");
	{
		pthread_attr_t at;
		pthread_t th;
		long floorBytes = sysconf(_SC_THREAD_STACK_MIN);
		size_t small = floorBytes > 0 ? (size_t)floorBytes : (size_t)16384;
		if (pthread_attr_init(&at) != 0 || pthread_attr_setstacksize(&at, small) != 0) {
			fail("small-stack", "cannot make a 32 KB thread attribute");
		} else if (pthread_create(&th, &at, validate_on_small_stack, NULL) != 0) {
			fail("small-stack", "cannot start a 32 KB thread");
		} else {
			void *res = NULL;
			pthread_join(th, &res);
			if (res == NULL) fail("small-stack", "validate did not finish on a 32 KB stack");
		}
		pthread_attr_destroy(&at);
	}
#endif
	/* A path that names a directory - it ends in a separator, or its last
	   component is `.` or `..` - is not a document. A path cleanup drops the
	   trailing separator first, so a save through `f/.` used to rewrite `f` in
	   some bindings. Same fixture in every runner. */
	test_id("EomvfCt", "save_refuses_a_directory_shaped_path");
	{
		char ddir[256], dfile[320], dpath[336];
		snprintf(ddir, sizeof ddir, "%s/shcl-dirpath-%ld", tmp_root(), (long)getpid());
		snprintf(dfile, sizeof dfile, "%s/f.shcl", ddir);
#ifdef _WIN32
		if (_mkdir(ddir) != 0) fail("dirpath", "mkdir failed");
#else
		if (mkdir(ddir, 0700) != 0) fail("dirpath", "mkdir failed");
#endif
		FILE *df = fopen(dfile, "wb");
		if (!df || fputs("a: 1\n", df) == EOF || fclose(df) != 0) fail("dirpath", "seed write failed");
		shcl_doc *dd = shcl_parse("a: 2\n", 5);
		static const char *sfx[] = { "/", "/.", "/.." };
		for (size_t si = 0; si < sizeof sfx / sizeof sfx[0]; si++) {
			snprintf(dpath, sizeof dpath, "%s%s", dfile, sfx[si]);
			if (shcl_save_file(dd, dpath) == SHCL_SAVE_OK) fail("dirpath", "a directory-shaped path was accepted");
		}
		size_t dn; char *dt = read_file(dfile, &dn);
		if (!dt || dn != 5 || memcmp(dt, "a: 1\n", 5) != 0) fail("dirpath", "a refused save changed the file");
		free(dt);
		if (shcl_save_file(dd, dfile) != SHCL_SAVE_OK) fail("dirpath", "the plain path did not save");
		shcl_free(dd);
		remove(dfile); rmdir(ddir);
	}

	/* A written value with both quote kinds is stored the way its own
	   reload stores it, so shcl_instances and a read's raw text agree across a
	   save. The emitter escapes the double quotes; the writer used to keep them
	   bare. Same fixture in every runner. */
	test_id("EommtF4", "written_spelling_matches_its_reload");
	{
		shcl_doc *wd = shcl_parse("x: 1\n", 5);
		if (!shcl_set_string(wd, "k", 1, "q\"q'", 4)) fail("written_spelling", "set_string refused");
		/* The canonical text lives in wd's read arena, so it is copied onto
		   the stack before wb is parsed from it - a fixture value is short. */
		shcl_str wc = shcl_to_canonical(wd);
		char wcopy[64];
		if (wc.n > sizeof wcopy) fail("written_spelling", "canonical text longer than the fixture buffer");
		memcpy(wcopy, wc.p, wc.n < sizeof wcopy ? wc.n : sizeof wcopy);
		shcl_doc *wb = shcl_parse(wcopy, wc.n < sizeof wcopy ? wc.n : sizeof wcopy);
		shcl_str *wi = NULL, *bi = NULL;
		size_t wn = shcl_instances(wd, "k", 1, &wi), bn = shcl_instances(wb, "k", 1, &bi);
		if (wn != 1 || bn != 1 || wi[0].n != bi[0].n || memcmp(wi[0].p, bi[0].p, wi[0].n) != 0)
			fail("written_spelling", "instances differ across a reload");
		shcl_read_str r = shcl_read_string(wd, "k", 1);
		if (r.status != SHCL_GOOD || r.value.n != 4 || memcmp(r.value.p, "q\"q'", 4) != 0)
			fail("written_spelling", "written value did not read back");
		shcl_free(wb); shcl_free(wd);
	}

	/* A setter writes only what reads back. Each one builds its text through
	   the emitter and hands it to the tokenizer before the document is
	   touched, so for every input either the call refuses and the document is
	   byte-identical, or the canonical text reloads to itself and the read
	   gives the value back. Twelve review items were one setter's own trim,
	   carriage-return or `#` rule disagreeing with the parser's. Every
	   accepted write also goes into one document that is saved and loaded back
	   at the end, since the file tier checks what an in-memory reload does
	   not: a setter once took bytes the save wrote and the next load refused.
	   Same fixture in every runner. */
	test_id("EpGigIP", "setters_write_only_what_reads_back");
	{
		shcl_doc *every = shcl_parse("", 0);
		size_t slot = 0;
		/* The alphabet: every character that means something to the
		   tokenizer, plus a blank the load trims and a no-break space it does
		   not. Every string of one and two characters over it, and the empty
		   string. */
		static const char *const soup[] = { "\"", "'", "\\", "#", ",", "[", "]", "\r", "\n", " ", "\t", "\xc2\xa0", "a" };
		const size_t nsoup = sizeof soup / sizeof soup[0];
		for (size_t ai = 0; ai <= nsoup; ai++) for (size_t bi = 0; bi < (ai == 0 ? 1u : nsoup + 1); bi++) {
			char in[8]; size_t inn = 0;
			if (ai) { size_t l = strlen(soup[ai - 1]); memcpy(in, soup[ai - 1], l); inn = l; }
			if (ai && bi) { size_t l = strlen(soup[bi - 1]); memcpy(in + inn, soup[bi - 1], l); inn += l; }
			for (int kind = 0; kind < 6; kind++) {
				shcl_doc *sd = shcl_parse("k: 1\n", 5);
				char before[SOUP_BUF]; size_t bn;
				soup_text(sd, before, &bn);
				int applied = soup_set(sd, kind, "k", 1, in, inn);
				if (applied) {
					char sp[24]; int spn = snprintf(sp, sizeof sp, "k%zu", ++slot);
					if (!soup_set(every, kind, sp, (size_t)spn, in, inn)) soup_fail("a slot refused what k took", kind, in, inn);
				}
				char text[SOUP_BUF]; size_t tn;
				soup_text(sd, text, &tn);
				if (!applied) {
					if (tn != bn || memcmp(text, before, tn) != 0) soup_fail("a refused write changed the document", kind, in, inn);
					shcl_free(sd);
					continue;
				}
				shcl_doc *back = shcl_parse(text, tn);
				char again[SOUP_BUF]; size_t an2;
				soup_text(back, again, &an2);
				if (an2 != tn || memcmp(again, text, tn) != 0) soup_fail("written text is not a fixpoint", kind, in, inn);
				shcl_str *wi = NULL, *bk = NULL;
				size_t wn = shcl_instances(sd, "k", 1, &wi), bn2 = shcl_instances(back, "k", 1, &bk);
				int same = wn == bn2;
				for (size_t i = 0; same && i < wn; i++) same = wi[i].n == bk[i].n && memcmp(wi[i].p, bk[i].p, wi[i].n) == 0;
				if (!same) soup_fail("the value read differs after a reload", kind, in, inn);
				if (kind == 0) {
					shcl_read_str r = shcl_read_string(back, "k", 1);
					if (r.status != SHCL_GOOD || r.value.n != inn || memcmp(r.value.p, in, inn) != 0) soup_fail("string did not read back", kind, in, inn);
				} else if (kind == 2) {
					/* A comment has no accessor of its own, so the oracle is
					   the text: whatever the load would keep of what was
					   handed in has to be in the document, not a shortened
					   form of it. */
					size_t kn = inn;
					while (kn && (in[kn - 1] == ' ' || in[kn - 1] == '\t' || in[kn - 1] == '\r')) kn--;
					char kept[sizeof in]; memcpy(kept, in, kn); kept[kn] = '\0';
					if (!contains(text, tn, kept)) soup_fail("the comment handed in is not in the document", kind, in, inn);
				} else if (kind == 3 || kind == 4) {
					shcl_read_str rb = shcl_read_raw(back, "k", 1), rw = shcl_read_raw(sd, "k", 1);
					if (rb.status != rw.status || rb.value.n != rw.value.n || memcmp(rb.value.p, rw.value.p, rw.value.n) != 0) soup_fail("raw body did not read back", kind, in, inn);
					shcl_read_str ib = shcl_read_raw_info(back, "k", 1), iw = shcl_read_raw_info(sd, "k", 1);
					if (ib.status != iw.status || ib.value.n != iw.value.n || memcmp(ib.value.p, iw.value.p, iw.value.n) != 0) soup_fail("raw info did not read back", kind, in, inn);
				} else if (kind == 5) {
					shcl_read_str_arr ra = shcl_read_string_array(back, "k", 1);
					if (ra.n != 2 || ra.values[0].n != 1 || ra.values[0].p[0] != 'x'
						|| ra.values[1].n != inn || memcmp(ra.values[1].p, in, inn) != 0) soup_fail("array did not read back", kind, in, inn);
				}
				shcl_free(back); shcl_free(sd);
			}
			/* The same rule for a name: whatever shcl_quote_segment writes has
			   to come back as one segment holding that name, or the write is
			   refused. */
			shcl_doc *nd = shcl_parse("k: 1\n", 5);
			shcl_str qs = shcl_quote_segment(nd, in, inn);
			char qp[SOUP_BUF]; size_t qn = qs.n;
			if (qn > sizeof qp) fail("setters_read_back", "quoted segment longer than the fixture buffer");
			memcpy(qp, qs.p, qn);
			char before[SOUP_BUF]; size_t bn;
			soup_text(nd, before, &bn);
			int wrote = shcl_set_string(nd, qp, qn, "v", 1);
			if (wrote && !shcl_set_string(every, qp, qn, "v", 1)) soup_fail("the name was refused the second time", -1, in, inn);
			char text[SOUP_BUF]; size_t tn;
			soup_text(nd, text, &tn);
			if (!wrote) {
				if (tn != bn || memcmp(text, before, tn) != 0) soup_fail("a refused name write changed the document", -1, in, inn);
			} else {
				shcl_doc *back = shcl_parse(text, tn);
				char again[SOUP_BUF]; size_t an2;
				soup_text(back, again, &an2);
				if (an2 != tn || memcmp(again, text, tn) != 0) soup_fail("the name is not a fixpoint", -1, in, inn);
				shcl_read_str r = shcl_read_string(back, qp, qn);
				if (r.status != SHCL_GOOD || r.value.n != 1 || r.value.p[0] != 'v') soup_fail("the name did not read back", -1, in, inn);
				shcl_free(back);
			}
			shcl_free(nd);
		}
		char ef[288];
		snprintf(ef, sizeof ef, "%s/shcl-setters-%ld.shcl", tmp_root(), (long)getpid());
		if (shcl_save_file(every, ef) != SHCL_SAVE_OK) fail("setters_read_back", "every accepted write together would not save");
		else {
			shcl_file_status est;
			shcl_doc *eb = shcl_load_file(ef, &est);
			if (est != SHCL_FILE_CLEAN) fail("setters_read_back", "every accepted write together did not load clean");
			else {
				shcl_str et = shcl_to_canonical(every);
				char *ec = xrealloc(NULL, et.n + 1); memcpy(ec, et.p, et.n);
				shcl_str bt = shcl_to_canonical(eb);
				if (bt.n != et.n || memcmp(bt.p, ec, et.n) != 0) fail("setters_read_back", "every accepted write together changed on a save and load");
				free(ec);
			}
			shcl_free(eb);
			remove(ef);
		}
		shcl_free(every);
	}
	test_id("Er7vwLo", "format_version_caps_at_32_bits");
	/* Digits past 32 bits are not a 2.x file either, so they read as the
	   current major, in every binding (20260926 item 9). */
	{
		const char *a = "##    Format   4294967295\na: 1\n", *b = "##    Format   4294967296\na: 1\n";
		if (shcl_format_version(a, strlen(a)) != 4294967295LL) fail("format_version_caps_at_32_bits", "4294967295 did not read as itself");
		if (shcl_format_version(b, strlen(b)) != SHCL_FORMAT_MAJOR) fail("format_version_caps_at_32_bits", "4294967296 did not read as the current major");
	}
	test_id("EonWXt2", "edits_and_merges_match_a_reload");
	edits_and_merges_match_a_reload();
	test_id("Er7o9rQ", "compact_keeps_generation_faults");
	{
		/* shcl_generate drops the faults of an earlier call first, and it tells
		   them by a flag the compaction copy used to clear, so two calls and a
		   compaction left the third listing two (20260926 item 6). */
		const char *sch = "field: a.b\n\ttype: int\n\tmin: 1\n\tmax: 10\n\tdefault: 99\n";
		shcl_doc *s = shcl_parse(sch, strlen(sch));
		int ok = 0;
		(void)shcl_generate(s, 1, &ok);
		(void)shcl_generate(s, 1, &ok);
		size_t before = shcl_diag_count(s);
		shcl_compact(s);
		(void)shcl_generate(s, 1, &ok);
		if (before == 0 || shcl_diag_count(s) != before) fail("compact_keeps_generation_faults", "a generation fault outlived the next shcl_generate");
		shcl_free(s);
	}

#ifdef _WIN32
	/* Windows-only, and wine cannot show either one: it maps onto a filesystem
	   with no MAX_PATH and follows a unix symlink before the API ever sees it.
	   The hosted windows job is where these are judged. */
	test_id("EonWXt3", "save_through_a_long_path");
	{
		/* A path past MAX_PATH. The narrow and wide file calls both refuse one
		   unless it has the \\?\ prefix, so a save through a deep tree used
		   to fail on windows and work everywhere else. */
		char lp[1024], real_short[320]; size_t ln = 0;
		snprintf(real_short, sizeof real_short, "%s/shcl-short-%ld.shcl", tmp_root(), (long)getpid());
		size_t lbase = (size_t)snprintf(lp, sizeof lp, "%s/shcl-lp-%ld", tmp_root(), (long)getpid());
		ln = lbase;
		mkdir_long(lp);
		for (int i = 0; i < 12 && ln < sizeof lp - 64; i++) {
			ln += (size_t)snprintf(lp + ln, sizeof lp - ln, "/dddddddddddddddddddddddd%02d", i);
			mkdir_long(lp);
		}
		ln += (size_t)snprintf(lp + ln, sizeof lp - ln, "/cfg.shcl");
		if (ln <= MAX_PATH) fail("longpath", "the fixture path is not past MAX_PATH");
		/* The prefix is the mechanism, and wine's filesystem has no MAX_PATH to
		   refuse the path without it, so the spelling is asserted directly. */
		char *lr = shcl_resolve_target(lp);
		if (!lr || strncmp(lr, "\\\\?\\", 4) != 0) fail("longpath", "a path past MAX_PATH did not take the long-path prefix");
		free(lr);
		char *sr = shcl_resolve_target(real_short);
		if (!sr || strncmp(sr, "\\\\?\\", 4) == 0) fail("longpath", "a short path took the long-path prefix");
		free(sr);
		shcl_doc *ld = shcl_parse("a: 1\n", 5);
		if (shcl_save_file(ld, lp) != SHCL_SAVE_OK) fail("longpath", "save refused a path past MAX_PATH");
		/* Through the library, which is what has to add the prefix: the
		   runner's own reader is plain fopen and would refuse the path. */
		size_t rn = 0; shcl_file_status lst; char *rt = shcl_read_file(lp, 0, &rn, &lst);
		if (!rt || lst != SHCL_FILE_CLEAN || rn != 5 || memcmp(rt, "a: 1\n", 5) != 0)
			fail("longpath", "the long path did not read back");
		free(rt);
		if (shcl_set_int(ld, "a", 1, 2) && shcl_save_file(ld, lp) != SHCL_SAVE_OK)
			fail("longpath", "a rewrite of a path past MAX_PATH failed");
		shcl_free(ld);
		remove_long(lp);
		/* Up to the fixture's own root and no further: the walk is what removes
		   the tree, and one step too many would be someone else's directory. */
		for (ln = strlen(lp); ln > lbase; ) {
			while (ln > lbase && lp[ln] != '/') ln--;
			lp[ln] = '\0';
			rmdir_long(lp);
			if (ln > lbase) ln--;
		}
	}
	test_id("EonWXt4", "winlink");
	{
		/* A save through a link replaces what the link points at, not the link.
		   An unprivileged symlink needs developer mode, so a runner without it
		   skips rather than failing on the setup. */
		char sdir[256], real[320], link[320];
		snprintf(sdir, sizeof sdir, "%s/shcl-link-%ld", tmp_root(), (long)getpid());
		if (_mkdir(sdir) != 0) fail("winlink", "mkdir failed");
		snprintf(real, sizeof real, "%s/real.shcl", sdir);
		snprintf(link, sizeof link, "%s/link.shcl", sdir);
		FILE *sf = fopen(real, "wb");
		if (!sf || fputs("a: 1\n", sf) == EOF || fclose(sf) != 0) fail("winlink", "seed write failed");
		wchar_t *wl = shcl_widen(link), *wr = shcl_widen(real);
		int made = wl && wr && CreateSymbolicLinkW(wl, wr, 0x2 /* ALLOW_UNPRIVILEGED_CREATE */);
		/* Wine reports success and creates nothing, so the attribute is what
		   says a link is really there. Without the privilege, so does windows. */
		if (made) {
			DWORD la = GetFileAttributesW(wl);
			made = la != INVALID_FILE_ATTRIBUTES && (la & FILE_ATTRIBUTE_REPARSE_POINT);
		}
		if (!made) { test_skip(); printf("conformance: winlink skipped (no symlink)\n"); }
		else {
			shcl_doc *sd = shcl_parse("a: 2\n", 5);
			if (shcl_save_file(sd, link) != SHCL_SAVE_OK) fail("winlink", "save through the link failed");
			shcl_free(sd);
			size_t rn; char *rt = read_file(real, &rn);
			if (!rt || rn != 5 || memcmp(rt, "a: 2\n", 5) != 0) fail("winlink", "the save did not reach the link's target");
			free(rt);
			DWORD a = GetFileAttributesW(wl);
			if (a == INVALID_FILE_ATTRIBUTES || !(a & FILE_ATTRIBUTE_REPARSE_POINT))
				fail("winlink", "the save replaced the link with a regular file");
			remove(link);
		}
		free(wl); free(wr);
		remove(real); _rmdir(sdir);
	}
	test_id("EqnwIkY", "windangle");
	{
		/* 20260923 item 8: a read through a dangling link created a file where
		   the link pointed and deleted it again, the save side's probe. If the
		   delete failed, an empty file stayed and the next load read it as an
		   empty document. The directory's write time is what the create and
		   delete leave behind, so it is set back first and must not move. */
		char sdir[256], link[320];
		snprintf(sdir, sizeof sdir, "%s/shcl-dangle-%ld", tmp_root(), (long)getpid());
		if (_mkdir(sdir) != 0) fail("windangle", "mkdir failed");
		snprintf(link, sizeof link, "%s/link.shcl", sdir);
		wchar_t *wl = shcl_widen(link), *wd = shcl_widen(sdir);
		int made = wl && wd && CreateSymbolicLinkW(wl, L"gone.shcl", 0x2 /* ALLOW_UNPRIVILEGED_CREATE */);
		if (made) {
			DWORD la = GetFileAttributesW(wl);
			made = la != INVALID_FILE_ATTRIBUTES && (la & FILE_ATTRIBUTE_REPARSE_POINT);
		}
		if (!made) { test_skip(); printf("conformance: windangle skipped (no symlink)\n"); }
		else {
			FILETIME old_t = { 0x6C0D8000u, 0x01C0A6A4u }; /* early 2001 */
			FILETIME now_t;
			HANDLE dh = CreateFileW(wd, FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
			                        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
			if (dh == INVALID_HANDLE_VALUE || !SetFileTime(dh, NULL, NULL, &old_t)) fail("windangle", "could not set the directory's time");
			shcl_file_status st;
			shcl_doc *ld = shcl_load_file(link, &st);
			if (st != SHCL_FILE_NOT_FOUND) fail("windangle", "a read through a dangling link did not say not found");
			shcl_free(ld);
			if (dh != INVALID_HANDLE_VALUE) {
				if (!GetFileTime(dh, NULL, NULL, &now_t)) fail("windangle", "could not read the directory's time");
				else if (CompareFileTime(&now_t, &old_t) != 0) fail("windangle", "a read through a dangling link created a file");
				CloseHandle(dh);
			}
			wchar_t gone[320];
			swprintf(gone, sizeof gone / sizeof *gone, L"%ls\\gone.shcl", wd);
			if (GetFileAttributesW(gone) != INVALID_FILE_ATTRIBUTES) fail("windangle", "a read through a dangling link left a file");
			DeleteFileW(gone);
			remove(link);
		}
		free(wl); free(wd);
		_rmdir(sdir);
	}
	test_id("Eqzz38c", "windsave");
	{
		/* A save through a dangling link creates the file it points at and
		   keeps the link, as on POSIX. The windows resolve could not open the
		   link, fell through to its own name, and published a regular file over
		   it with the target never created. */
		char sdir[256], link[320];
		snprintf(sdir, sizeof sdir, "%s/shcl-dsave-%ld", tmp_root(), (long)getpid());
		if (_mkdir(sdir) != 0) fail("windsave", "mkdir failed");
		snprintf(link, sizeof link, "%s/link.shcl", sdir);
		wchar_t *wl = shcl_widen(link), *wd = shcl_widen(sdir);
		int made = wl && wd && CreateSymbolicLinkW(wl, L"gone.shcl", 0x2 /* ALLOW_UNPRIVILEGED_CREATE */);
		if (made) {
			DWORD la = GetFileAttributesW(wl);
			made = la != INVALID_FILE_ATTRIBUTES && (la & FILE_ATTRIBUTE_REPARSE_POINT);
		}
		if (!made) { test_skip(); printf("conformance: windsave skipped (no symlink)\n"); }
		else {
			shcl_doc *sd = shcl_parse("a: 1\n", 5);
			if (shcl_save_file(sd, link) != SHCL_SAVE_OK) fail("windsave", "save through a dangling link failed");
			shcl_free(sd);
			DWORD a = GetFileAttributesW(wl);
			if (a == INVALID_FILE_ATTRIBUTES || !(a & FILE_ATTRIBUTE_REPARSE_POINT))
				fail("windsave", "the save replaced the link with a regular file");
			char gone[320];
			snprintf(gone, sizeof gone, "%s/gone.shcl", sdir);
			size_t rn; char *rt = read_file(gone, &rn);
			if (!rt || rn != 5 || memcmp(rt, "a: 1\n", 5) != 0) fail("windsave", "file not created behind the link");
			free(rt);
			remove(gone);
			remove(link);
		}
		free(wl); free(wd);
		_rmdir(sdir);
	}
#endif

	test_id_end();
	if (nfail) { fprintf(stderr, "conformance: %d failure(s)\n", nfail); return 1; }
	printf("conformance: %zu case(s) pass\n", nn);
	return 0;
}
