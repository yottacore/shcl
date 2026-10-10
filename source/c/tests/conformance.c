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
static shcl_set_status soup_set(shcl_doc *d, int kind, const char *p, size_t pn, const char *in, size_t inn) {
	switch (kind) {
	case 0: return shcl_set_string(d, p, pn, in, inn);
	case 1: return shcl_set_literal(d, p, pn, in, inn);
	case 2: return shcl_set_comment(d, p, pn, in, inn);
	case 3: return shcl_set_raw(d, p, pn, in, inn, "t", 1);
	case 4: return shcl_set_raw(d, p, pn, "body", 4, in, inn);
	default: { const char *av[2]; size_t al[2]; av[0] = "x"; al[0] = 1; av[1] = in; al[1] = inn; return shcl_set_string_array(d, p, pn, av, al, 2); }
	}
}
/* A capped parse's diagnostics as "LINE:CODE" words, its lost count and its
   canonical text, for the cap fixture. */
static void cap_codes(const char *text, size_t cap, char *got, size_t gn, size_t *lost, char *out, size_t on) {
	shcl_doc *d = shcl_parse_limited(text, strlen(text), SHCL_STANDARD, 0, cap, 0);
	size_t at = 0; got[0] = 0;
	for (size_t k = 0; k < shcl_diag_count(d) && at < gn; k++) {
		int w = snprintf(got + at, gn - at, "%s%zu:%s", k ? " " : "", shcl_diag_line(d, k), shcl_diag_code(d, k));
		if (w < 0) break;
		at += (size_t)w;
	}
	*lost = shcl_lost_count(d);
	shcl_str c = shcl_to_canonical(d);
	size_t cn = c.n < on - 1 ? c.n : on - 1;
	memcpy(out, c.p, cn); out[cn] = 0;
	shcl_free(d);
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

// An ops value with the file's escapes resolved, by the file's reader; a
// backslash is text (mirrors the CLI's op_text). Returns a malloc'd copy and
// its length, or NULL when the reader refuses it.
static char *cf_op_text(const char *in, size_t n, size_t *outn) {
	static const char mark[] = "\xe2\x97\x89", dq[] = "\xe2\x97\x89" "DOUBLE_QUOTE" "\xe2\x97\x89";
	int marked = 0, has_dq = 0, has_sq = 0;
	for (size_t i = 0; i < n; i++) {
		if (i + 3 <= n && memcmp(in + i, mark, 3) == 0) marked = 1;
		if (in[i] == '"') has_dq = 1;
		if (in[i] == '\'') has_sq = 1;
	}
	char *out;
	if (!marked) {
		out = (char *)xrealloc(NULL, n ? n : 1);
		if (n) memcpy(out, in, n);
		*outn = n;
		return out;
	}
	char q = has_dq && !has_sq ? '\'' : '"';
	char *text = (char *)xrealloc(NULL, n * (sizeof dq - 1) + 8), *w = text;
	memcpy(w, "v: ", 3); w += 3;
	*w++ = q;
	for (size_t i = 0; i < n; i++) {
		if (in[i] == '"' && q == '"') { memcpy(w, dq, sizeof dq - 1); w += sizeof dq - 1; }
		else *w++ = in[i];
	}
	*w++ = q; *w++ = '\n';
	shcl_doc *v = shcl_parse(text, (size_t)(w - text));
	free(text);
	if (!v) { fprintf(stderr, "conformance: out of memory\n"); exit(70); }
	for (size_t i = 0; i < shcl_diag_count(v); i++)
		if (shcl_diag_severity(v, i) == SHCL_SEV_ERROR) { shcl_free(v); return NULL; }
	shcl_str got = shcl_read_string(v, "v", 1).value;
	out = (char *)xrealloc(NULL, got.n ? got.n : 1);
	if (got.n) memcpy(out, got.p, got.n);
	*outn = got.n;
	shcl_free(v);
	return out;
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
	int only_absent = 0, rc = 0;
	shcl_set_status wrote = SHCL_SET_OK;
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
	else if (!strcmp(op, "string")) { size_t m; char *b = cf_op_text(v, vn, &m); if (!b) rc = 1; else { wrote = SET(shcl_set_string, b, m); free(b); } }
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
		memset(sv, 0, (an ? an : 1) * sizeof *sv); memset(sl, 0, (an ? an : 1) * sizeof *sl);
		for (size_t i = 0; i < an && !rc; i++) if (!(sv[i] = cf_op_text(f[2 + i], strlen(f[2 + i]), &sl[i]))) rc = 1;
		if (!rc) wrote = SET(shcl_set_string_array, (const char *const *)sv, sl, an);
		for (size_t i = 0; i < an; i++) free(sv[i]);
		free(sv); free(sl);
	}
	else if (!strcmp(op, "datetime-array")) {
		shcl_datetime *a = (shcl_datetime *)xrealloc(NULL, (an ? an : 1) * sizeof *a);
		for (size_t i = 0; i < an && !rc; i++) { ShclStr sv; sv.p = f[2 + i]; sv.n = strlen(f[2 + i]); if (!parse_datetime(&d->arena, sv, &a[i])) rc = 1; }
		if (!rc) wrote = SET(shcl_set_datetime_array, a, an);
		free(a);
	}
	else if (!strcmp(op, "raw")) { const char *cont = nf > 3 ? f[3] : ""; size_t m; char *b = cf_op_text(cont, strlen(cont), &m); if (!b) rc = 1; else { wrote = SET(shcl_set_raw, b, m, v, vn); free(b); } }
	else if (!strcmp(op, "empty") && !only_absent) wrote = shcl_set_empty(d, path, plen);
	else if (!strcmp(op, "comment") && !only_absent) { size_t m; char *b = cf_op_text(v, vn, &m); if (!b) rc = 1; else { wrote = shcl_set_comment(d, path, plen, b, m); free(b); } }
	else if (!strcmp(op, "remove") && !only_absent) shcl_remove(d, path, plen);
	else if (!strcmp(op, "clear-comments") && !only_absent) shcl_clear_comments(d, path, plen);
	else if (!strcmp(op, "banner") && !only_absent) {
		if (!strcmp(path, "on") || !strcmp(path, "off")) shcl_set_banner(d, !strcmp(path, "on"));
		else rc = 1;
	}
	else rc = 2; // no such op here: a misspelled bad-ops row is a fixture bug
	if (rc == 0 && wrote != SHCL_SET_OK) rc = 1;
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
		int saved = shcl_write_file_atomic(target, "a: 2\n", 5, NULL);
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
		if (!shcl_write_file_atomic(target, "a: 2\n", 5, NULL)) fail("dacl", "a save over an unheld file failed");
		if (!dacl_sddl(target, got, sizeof got) || strcmp(got, want) != 0) {
			fprintf(stderr, "FAIL dacl: %s: the saved file's DACL is %s, want %s\n", names[i], got, want);
			nfail++;
		}
	}
	char fresh[300], plain[300], b[300];
	snprintf(fresh, sizeof fresh, "%s\\n.shcl", dir);
	snprintf(plain, sizeof plain, "%s\\p.shcl", dir);
	snprintf(b, sizeof b, "%s\\b.shcl", dir);
	if (!shcl_write_file_atomic(fresh, "a: 2\n", 5, NULL)) fail("dacl", "a save to a new file failed");
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
			seq_puts(b, ind); seq_puts(b, "\t- 1\n"); seq_puts(b, ind); seq_puts(b, " x: 1\n");
			seq_puts(b, ind); seq_puts(b, "\t- 2");
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
	if (clean && shcl_set_int(d, "zz_new", 6, 1) == SHCL_SET_OK) {
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

static int seq_comment(const char *p, size_t n) {
	size_t k = 0;
	while (k < n && p[k] == '\t') k++;
	return k < n && p[k] == '#';
}

/* The canonical form of the text's lines that are neither blank nor a
   comment, into out. */
static void seq_bare(const char *p, size_t n, SeqBuf *out) {
	out->n = 0; seq_put(out, "", 0);
	for (size_t at = 0; at < n;) {
		size_t e = at;
		while (e < n && p[e] != '\n') e++;
		if (e > at && !seq_comment(p + at, e - at)) { seq_put(out, p + at, e - at); seq_puts(out, "\n"); }
		at = e + 1;
	}
	shcl_doc *d = shcl_parse(out->p, out->n);
	shcl_str c = shcl_to_canonical(d);
	out->n = 0; seq_put(out, c.p, c.n);
	shcl_free(d);
}

/* A kept line the settle turned into a comment is still the user's line, so
   shcl_clear_comments and a remove beside it leave it (design.md, Kept lines
   under edits). The canonical text writes it as a comment, and the reload
   takes it like one, so the two cannot agree (20260926 item 2). True when
   that is all that differs: the reload's comment lines are some of the
   document's, in order, and without comment and blank lines the two load as
   one document. A comment the reload took can also take a blank with it, step
   the comments after it back a level, or leave a kept line heading the block
   below, so the rest is compared as documents. A check of the target's
   comments missed one below the target (2026100506223902). */
static int reload_took_only_comments(const char *lp, size_t ln, const char *bp, size_t bn) {
	size_t li = 0;
	for (size_t bi = 0; bi < bn;) {
		size_t be = bi;
		while (be < bn && bp[be] != '\n') be++;
		if (seq_comment(bp + bi, be - bi)) {
			size_t bt = bi;
			while (bt < be && bp[bt] == '\t') bt++;
			int found = 0;
			while (!found && li < ln) {
				size_t le = li, lt = li;
				while (le < ln && lp[le] != '\n') le++;
				while (lt < le && lp[lt] == '\t') lt++;
				found = seq_comment(lp + li, le - li) && le - lt == be - bt && memcmp(lp + lt, bp + bt, be - bt) == 0;
				li = le + 1;
			}
			if (!found) return 0;
		}
		bi = be + 1;
	}
	SeqBuf x = {0}, y = {0};
	seq_bare(lp, ln, &x);
	seq_bare(bp, bn, &y);
	int same = x.n == y.n && memcmp(x.p, y.p, x.n) == 0;
	free(x.p); free(y.p);
	return same;
}

/* A list with a field under it (E001) after an empty binding of its name that
   has fields of its own. A merge or an edit can leave one, and then no text
   reloads as it: stacked, its header joins that binding and its items are
   dropped (E008), and in brackets it is E028 (2026100511210900). The save
   gate counts its items lost, so it is never written; the fixture checks
   that and skips the rest. */
/* A string read at the path that comes back unquoted and in brackets. A read
   of an array is never quoted, though shcl_quoted gives a one-element array
   its element's flag; an array's element never reads as the array's own
   bracket text, which is how one is told from a quoted "[x]". */
static int reads_bracketed(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_str r = shcl_read_string(d, path, plen);
	if (r.status != SHCL_GOOD || !r.value.n || r.value.p[0] != '[') return 0;
	if (!shcl_quoted(d, path, plen)) return 1;
	shcl_read_str_arr sa = shcl_read_string_array(d, path, plen);
	return sa.status == SHCL_GOOD && (sa.n != 1 || sa.values[0].n != r.value.n || memcmp(sa.values[0].p, r.value.p, r.value.n) != 0);
}

static int list_after_empty(shcl_doc *d) {
	shcl_str *ips; size_t ni = shcl_instance_paths(d, &ips);
	for (size_t i = 0; i < ni; i++) {
		shcl_str p = ips[i];
		shcl_str *kids;
		if (!shcl_children(d, p.p, p.n, &kids) || !reads_bracketed(d, p.p, p.n)) continue;
		if (!p.n || p.p[p.n - 1] != ')') continue;
		size_t at = p.n - 1;
		while (at > 0 && p.p[at - 1] != '(') at--;
		if (at == 0) continue;
		size_t k = 0;
		int digits = 0;
		for (size_t j = at; j + 1 < p.n; j++) {
			if (p.p[j] < '0' || p.p[j] > '9') { digits = 0; break; }
			k = k * 10 + (size_t)(p.p[j] - '0'); digits = 1;
		}
		if (!digits) continue;
		for (size_t j = 0; j < k; j++) {
			char e[512];
			int n = snprintf(e, sizeof e, "%.*s%zu)", (int)at, p.p, j);
			if (n < 0 || (size_t)n >= sizeof e) continue;
			if (shcl_read_string(d, e, (size_t)n).status == SHCL_EMPTY && shcl_children(d, e, (size_t)n, &kids)) return 1;
		}
	}
	return 0;
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
			shcl_doc *docs[2] = {live, back};
			int applied = 0;
			for (int k = 0; k < 2; k++) {
				shcl_doc *d = docs[k];
				switch (op) {
				case 0: case 1: { shcl_doc *l = shcl_parse(layer.p, layer.n); shcl_merge(d, l); shcl_free(l); break; }
				case 2: applied += shcl_set_int(d, path.p, path.n, 7) == SHCL_SET_OK; break;
				case 3: applied += shcl_set_string(d, path.p, path.n, v, strlen(v)) == SHCL_SET_OK; break;
				case 4: applied += (int)shcl_remove(d, path.p, path.n); break;
				case 5: applied += shcl_set_comment(d, path.p, path.n, v, strlen(v)) == SHCL_SET_OK; break;
				case 6: applied += shcl_set_empty(d, path.p, path.n) == SHCL_SET_OK; break;
				case 7: applied += shcl_set_raw(d, path.p, path.n, "body", 4, v, strlen(v)) == SHCL_SET_OK; break;
				case 8: applied += shcl_set_int_default(d, path.p, path.n, 1) == SHCL_SET_OK; break;
				case 9: applied += (int)shcl_clear_comments(d, path.p, path.n); break;
				default: applied += (int)shcl_set_banner(d, strcmp(v, "v0") != 0); break;
				}
			}
			(void)applied;
			if (op <= 1) { seq_puts(&log, "merge:\n"); seq_put(&log, layer.p, layer.n); }
			else { seq_puts(&log, "op "); seq_num(&log, op); seq_puts(&log, " at "); seq_put(&log, path.p, path.n); seq_puts(&log, "\n"); }
			if (list_after_empty(live)) {
				if (shcl_lost_count(live) == 0) {
					fprintf(stderr, "FAIL edits_and_merges: a list no text loads back saves at iteration %d:\n%s", i, log.p);
					nfail++; bad = 1;
				}
				shcl_free(back);
				break;
			}
			t = shcl_to_canonical(live); a.n = 0; seq_put(&a, t.p, t.n);
			t = shcl_to_canonical(back); b.n = 0; seq_put(&b, t.p, t.n);
			if ((a.n != b.n || memcmp(a.p, b.p, a.n) != 0) && !((op == 4 || op == 9) && reload_took_only_comments(a.p, a.n, b.p, b.n))) {
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

/* The bytes of s are exactly w. */
static int str_is(shcl_str s, const char *w) { return s.n == strlen(w) && memcmp(s.p, w, s.n) == 0; }

/* Both documents list the same paths in the same order. */
/* A setter's status agrees with shcl_check_set_path over generated
   documents: a path reason is what the path check gives for that path, a
   value reason comes with a path that checks OK, and a refusal writes
   nothing. The reference runs it over its fuzz soup; this runs it over the
   sequence fixture's documents and the setter soup, as the Python runner
   does. */
static void setter_status_agrees_with_the_path_check(void) {
	static const char *const alpha[] = { "\"", "'", "\\", "#", ",", "[", "]", "\r", "\n", " ", "\t", "\xc2\xa0", "a" };
	enum { NALPHA = sizeof alpha / sizeof alpha[0], NSOUP = 1 + NALPHA + NALPHA * NALPHA };
	static char soup[NSOUP][8];
	size_t ns = 0;
	soup[ns++][0] = 0;
	for (size_t x = 0; x < NALPHA; x++) {
		snprintf(soup[ns++], sizeof soup[0], "%s", alpha[x]);
		for (size_t y = 0; y < NALPHA; y++) snprintf(soup[ns++], sizeof soup[0], "%s%s", alpha[x], alpha[y]);
	}
	static const char *const tails[] = { "", "", "", "", ".kid", "(*)", "(7)", "..x" };
	const int64_t two[] = {1, 2}, three[] = {3};
	seq_s = 0x5EED57A71C0000D1ULL;
	SeqBuf text = {0}, path = {0}, before = {0};
	int seen[SHCL_SET_NO_READ_BACK + 1] = {0}, bad = 0;
	for (int i = 0; i < 3000 && !bad; i++) {
		seq_doc(&text);
		shcl_doc *d = shcl_parse(text.p, text.n);
		shcl_str *paths; size_t np = shcl_paths(d, &paths);
		path.n = 0; seq_put(&path, "", 0);
		if (np == 0 || seq_below(4) == 0) { seq_puts(&path, "new"); seq_num(&path, seq_below(3)); seq_puts(&path, ".k"); }
		else { shcl_str pick = paths[seq_below(np)]; seq_put(&path, pick.p, pick.n); }
		seq_puts(&path, tails[seq_below(8)]);
		const char *v = soup[seq_below(NSOUP)];
		size_t vn = strlen(v);
		shcl_set_status checked = shcl_check_set_path(d, path.p, path.n);
		shcl_str bt = shcl_to_canonical(d);
		before.n = 0; seq_put(&before, bt.p, bt.n);
		size_t op = seq_below(10);
		shcl_set_status got;
		switch (op) {
		case 0: got = shcl_set_int(d, path.p, path.n, 7); break;
		case 1: got = shcl_set_string(d, path.p, path.n, v, vn); break;
		case 2: got = shcl_set_literal(d, path.p, path.n, v, vn); break;
		case 3: got = shcl_set_comment(d, path.p, path.n, v, vn); break;
		case 4: { const char *info = soup[seq_below(NSOUP)]; got = shcl_set_raw(d, path.p, path.n, v, vn, info, strlen(info)); break; }
		case 5: got = shcl_set_int_array(d, path.p, path.n, two, 2); break;
		case 6: got = shcl_set_float(d, path.p, path.n, vn % 2 == 0 ? NAN : 1.5); break;
		case 7: got = shcl_set_literal_default(d, path.p, path.n, v, vn); break;
		case 8: got = shcl_set_int_array_default(d, path.p, path.n, three, 1); break;
		default: got = shcl_set_empty(d, path.p, path.n); break;
		}
		if ((size_t)got <= SHCL_SET_NO_READ_BACK) seen[got] = 1;
		shcl_set_status want = got <= SHCL_SET_UNDER_ARRAY ? got : SHCL_SET_OK;
		if (checked != want) {
			fprintf(stderr, "FAIL setter_status: iteration %d: op %zu at %s gave %s, check_set_path %s:\n%s", i, op, path.p, shcl_set_status_name(got), shcl_set_status_name(checked), text.p);
			nfail++; bad = 1;
		}
		shcl_str after = shcl_to_canonical(d);
		if (got != SHCL_SET_OK && (after.n != before.n || memcmp(after.p, before.p, after.n) != 0)) {
			fprintf(stderr, "FAIL setter_status: iteration %d: op %zu at %s gave %s and wrote:\n%s", i, op, path.p, shcl_set_status_name(got), text.p);
			nfail++; bad = 1;
		}
		shcl_free(d);
	}
	/* Guard: the documents still reach path and value reasons both. */
	static const shcl_set_status reach[] = {
		SHCL_SET_OK, SHCL_SET_BAD_PATH, SHCL_SET_WILDCARD, SHCL_SET_NO_SUCH_INDEX, SHCL_SET_MULTIPLE, SHCL_SET_UNDER_ARRAY,
		SHCL_SET_HAS_CHILDREN, SHCL_SET_NOT_FINITE, SHCL_SET_BAD_RAW_INFO, SHCL_SET_BAD_COMMENT, SHCL_SET_NOT_ONE_VALUE,
	};
	for (size_t k = 0; !bad && k < sizeof reach / sizeof reach[0]; k++)
		if (!seen[reach[k]]) { fprintf(stderr, "FAIL setter_status: never saw %s\n", shcl_set_status_name(reach[k])); nfail++; }
	free(text.p); free(path.p); free(before.p);
}

static int same_paths(shcl_doc *x, shcl_doc *y) {
	shcl_str *px, *py;
	size_t nx = shcl_paths(x, &px), ny = shcl_paths(y, &py);
	if (nx != ny) return 0;
	for (size_t i = 0; i < nx; i++) if (px[i].n != py[i].n || memcmp(px[i].p, py[i].p, px[i].n) != 0) return 0;
	return 1;
}

/* A file holding exactly text, and whether it still does. */
static void put_file(const char *path, const char *text) {
	FILE *f = fopen(path, "wb");
	if (!f) { fail("put_file", path); return; }
	fwrite(text, 1, strlen(text), f);
	fclose(f);
}
static int file_is(const char *path, const char *text) {
	size_t n = 0; shcl_file_status st;
	char *t = shcl_read_file(path, 0, &n, &st);
	int ok = t && n == strlen(text) && memcmp(t, text, n) == 0;
	free(t);
	return ok;
}

/* A migration's text starts with want. */
static int mig_starts(const shcl_migration *m, const char *want) {
	size_t n = strlen(want);
	return m->len >= n && memcmp(m->text, want, n) == 0;
}
/* A migration's text, loaded; a diagnostic on it fails the fixture at. */
static shcl_doc *mig_load(const shcl_migration *m, const char *at) {
	shcl_doc *d = shcl_parse(m->text, m->len);
	for (size_t i = 0; i < shcl_diag_count(d); i++) {
		shcl_str dm = shcl_diag_message(d, i);
		fprintf(stderr, "  line %zu: %s %.*s\n", shcl_diag_line(d, i), shcl_diag_code(d, i), (int)dm.n, dm.p);
		fail(at, "the migrated text loads with a diagnostic");
	}
	return d;
}

/* An upgrade's text is exactly want. */
static int up_is(const shcl_upgraded *u, const char *want) {
	size_t n = strlen(want);
	return u->text && u->len == n && memcmp(u->text, want, n) == 0;
}
/* How many entries a directory has, and then nothing in it. */
static size_t dir_entries(const char *dir) {
	size_t n = 0;
	DIR *dd = opendir(dir); const struct dirent *de;
	while (dd && (de = readdir(dd))) n += strcmp(de->d_name, ".") != 0 && strcmp(de->d_name, "..") != 0;
	if (dd) closedir(dd);
	return n;
}
static void dir_clear(const char *dir) {
	char p[512];
	DIR *dd = opendir(dir); const struct dirent *de;
	while (dd && (de = readdir(dd))) {
		if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
		snprintf(p, sizeof p, "%s/%s", dir, de->d_name);
		remove(p);
	}
	if (dd) closedir(dd);
#ifdef _WIN32
	_rmdir(dir);
#else
	rmdir(dir);
#endif
}
static void up_dir(char *dir, size_t cap, const char *tag) {
	snprintf(dir, cap, "%s/shcl-upgrade-%s-%ld", tmp_root(), tag, (long)getpid());
	dir_clear(dir);
#ifdef _WIN32
	if (_mkdir(dir) != 0) fail(tag, "mkdir failed");
#else
	if (mkdir(dir, 0700) != 0) fail(tag, "mkdir failed");
#endif
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

	// A stray continuation byte or a cut-short sequence stepped over the
	// closing quote, so the line was E017 (2026100511212359). Same fixture in
	// the Go tests.
	test_id("ErryPsK", "a_bad_utf8_byte_keeps_its_closing_quote");
	{
		static const char *const vals[] = {"a b \x80 c", "\x80", "a\x80 b", "a b \xff c", "x\xe9", "\xf0\x9f\x98", "\xc3", "\xc3\xa9"};
		static const char *const bare[] = {"x\xf0", "x\xe9\x80", "\xdf"};
		char line[64];
		for (size_t vi = 0; vi < sizeof vals / sizeof *vals + sizeof bare / sizeof *bare; vi++) {
			const int is_bare = vi >= sizeof vals / sizeof *vals;
			const char *v = is_bare ? bare[vi - sizeof vals / sizeof *vals] : vals[vi];
			for (int qi = 0; qi < (is_bare ? 1 : 2); qi++) {
				const char *q = is_bare ? "" : qi ? "'" : "\"";
				int ln = snprintf(line, sizeof line, "v: %s%s%s%s", q, v, q, is_bare ? "" : "\n");
				if (ln < 0 || (size_t)ln >= sizeof line) { fail("bad_utf8", "fixture too long"); continue; }
				shcl_doc *bd = shcl_parse(line, (size_t)ln);
				if (shcl_diag_count(bd) != 0) fail("bad_utf8", shcl_diag_code(bd, 0));
				shcl_read_str r = shcl_read_string(bd, "v", 1);
				if (r.status != SHCL_GOOD || r.value.n != strlen(v) || memcmp(r.value.p, v, r.value.n) != 0) fail("bad_utf8", "value not read back with its byte");
				shcl_free(bd);
			}
		}
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
					// A status other than `-` pins the read_ twin too.
					shcl_read_usize rc = shcl_read_count(rd, query, qn);
					snprintf(nb, sizeof nb, "%zu", rc.value);
					if (strcmp(status, "-") && (strcmp(nb, exp) || strcmp(shcl_status_name(rc.status), status))) fail(at, "read_count mismatch");
					shcl_free(rd); continue;
				}
				if (!strcmp(kind, "instances")) {
					shcl_str *vals; size_t n = shcl_instances(rd, query, qn, &vals);
					char *joined = join_pipe(vals, n);
					if (strcmp(joined, exp)) fail(at, "instances mismatch");
					free(joined);
					shcl_read_str_list ri = shcl_read_instances(rd, query, qn);
					joined = join_pipe(ri.values, ri.n);
					if (strcmp(status, "-") && (strcmp(joined, exp) || strcmp(shcl_status_name(ri.status), status))) fail(at, "read_instances mismatch");
					free(joined); shcl_free(rd); continue;
				}
				if (!strcmp(kind, "children")) {
					shcl_str *kids; size_t n = shcl_children(rd, query, qn, &kids);
					char *joined = join_pipe(kids, n);
					if (strcmp(joined, exp)) fail(at, "children mismatch");
					free(joined);
					shcl_read_str_list rk = shcl_read_children(rd, query, qn);
					joined = join_pipe(rk.values, rk.n);
					if (strcmp(status, "-") && (strcmp(joined, exp) || strcmp(shcl_status_name(rk.status), status))) fail(at, "read_children mismatch");
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
		// It comes from shcl_validate itself, and shcl_load_and_validate has to
		// give the same list, so every entry point is held to the one golden.
		snprintf(path, sizeof path, "%s/%s/schema.shcl", corpus, names[ci]); size_t schlen; char *sch = read_file(path, &schlen);
		if (sch) {
			snprintf(path, sizeof path, "%s/%s/expected-validate.txt", corpus, names[ci]); size_t evlen; char *ev = read_file(path, &evlen);
			if (!ev) { fail(names[ci], "schema.shcl without expected-validate.txt"); free(sch); }
			else {
				shcl_doc *vd = shcl_parse(input, ilen);
				shcl_doc *sd = shcl_parse(sch, schlen);
				int sbad = 0;
				for (size_t i = 0; i < shcl_diag_count(sd); i++) if (shcl_diag_severity(sd, i) == SHCL_SEV_ERROR) sbad = 1;
				shcl_validation *vv = shcl_validate(vd, sd);
				if (!vv) { fprintf(stderr, "out of memory\n"); exit(2); }
				if (!sbad) { shcl_suppress_declared_repeats(sd, vd); shcl_suppress_declared_reopens(sd, vd); }
				size_t nd = shcl_diag_count(vd), nv = shcl_validation_count(vv), nerr = 0;
				size_t total = nd + nv;
				char *vj = xrealloc(NULL, 64); size_t jl = 0, jc = 64;
				for (size_t i = 0; i < nd + nv; i++) {
					char ln[128]; int w;
					if (i < nd) {
						if (shcl_diag_severity(vd, i) == SHCL_SEV_ERROR) nerr++;
						w = snprintf(ln, sizeof ln, "line %zu: %s: %s\n", shcl_diag_line(vd, i), shcl_diag_severity(vd, i) == SHCL_SEV_ERROR ? "Error" : "Hint", shcl_diag_code(vd, i));
					} else {
						size_t k = i - nd;
						if (shcl_validation_severity(vv, k) == SHCL_SEV_ERROR) nerr++;
						w = snprintf(ln, sizeof ln, "line %zu: %s: %s\n", shcl_validation_line(vv, k), shcl_validation_severity(vv, k) == SHCL_SEV_ERROR ? "Error" : "Hint", shcl_validation_code(vv, k));
					}
					if (jl + (size_t)w + 1 > jc) { jc = (jl + (size_t)w + 1) * 2; vj = xrealloc(vj, jc); }
					memcpy(vj + jl, ln, (size_t)w); jl += (size_t)w;
				}
				{
					shcl_doc *lv = shcl_load_and_validate(input, ilen, sch, schlen, SHCL_STANDARD);
					if (!lv) { fprintf(stderr, "out of memory\n"); exit(2); }
					char *lj = xrealloc(NULL, 64); size_t ll = 0, lc = 64;
					for (size_t i = 0; i < shcl_diag_count(lv); i++) {
						char ln[128];
						int w = snprintf(ln, sizeof ln, "line %zu: %s: %s\n", shcl_diag_line(lv, i), shcl_diag_severity(lv, i) == SHCL_SEV_ERROR ? "Error" : "Hint", shcl_diag_code(lv, i));
						if (ll + (size_t)w + 1 > lc) { lc = (ll + (size_t)w + 1) * 2; lj = xrealloc(lj, lc); }
						memcpy(lj + ll, ln, (size_t)w); ll += (size_t)w;
					}
					if (ll != jl || (jl && memcmp(lj, vj, jl) != 0)) fail(names[ci], "shcl_load_and_validate disagrees with parse then validate");
					free(lj); shcl_free(lv);
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
					if (shcl_set_string(md, slines[li], (size_t)(eq - slines[li]), eq + 1, strlen(eq + 1)) != SHCL_SET_OK) fail(names[ci], "merge.set did not apply");
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
		lnc = shcl_lines(ld, "code(*).done", 12, &lv);
		if (lnc != 1 || lv[0] != 6) fail("lines", "code(*).done not [6]");
		lnc = shcl_lines(ld, "code(*).nope", 12, &lv);
		if (lnc != 1 || lv[0] != 0) fail("lines", "code(*).nope not [0]");
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
		shcl_str *gv; size_t gn = shcl_children(gd, "account(0).email", 16, &gv);
		if (gn != 2 || gv[0].n != 6 || memcmp(gv[0].p, "sshkey", 6) || gv[1].n != 6 || memcmp(gv[1].p, "sshkey", 6)) fail("children", "every instance's children not listed");
		gn = shcl_children(gd, "account.email(1)", 16, &gv);
		if (gn != 1) fail("children", "one instance's children not listed");
		const char *iw[] = { "account", "account.email(0)", "account.email(0).sshkey", "account.email(1)", "account.email(1).sshkey" };
		gn = shcl_instance_paths(gd, &gv);
		if (gn != 5) fail("instance_paths", "count mismatch");
		else for (size_t i = 0; i < 5; i++) if (gv[i].n != strlen(iw[i]) || memcmp(gv[i].p, iw[i], gv[i].n) != 0) { fail("instance_paths", "fixture mismatch"); break; }
		shcl_read_str gr = shcl_read_string(gd, "account.email(1).sshkey", 23);
		if (gr.status != SHCL_GOOD || gr.value.n != 2 || memcmp(gr.value.p, "k2", 2)) fail("instance_paths", "indexed path does not read");
		shcl_free(gd);
	}
	// The --json listings: each instance, a repeated one included, gets a path
	// that reads that one, with its name, value and line beside it. Same
	// fixture in every runner.
	test_id("EsEsFrh", "fields_give_each_instance_its_own_path");
	{
		const char *ft = "shard: 1\n\towner: ann\nshard: 0\n\towner: bob\n\towner: cy\n";
		shcl_doc *fd = shcl_parse(ft, strlen(ft));
		static const char *fp[] = { "shard(0)", "shard(0).owner", "shard(1)", "shard(1).owner(0)", "shard(1).owner(1)" };
		static const char *fnm[] = { "shard", "owner", "shard", "owner", "owner" };
		static const char *fv[] = { "1", "ann", "0", "bob", "cy" };
		#define FIELD_IS(F, I) ((F).path.n == strlen(fp[I]) && !memcmp((F).path.p, fp[I], (F).path.n) \
			&& (F).name.n == strlen(fnm[I]) && !memcmp((F).name.p, fnm[I], (F).name.n) \
			&& (F).value.n == strlen(fv[I]) && !memcmp((F).value.p, fv[I], (F).value.n) && (F).line == (size_t)(I) + 1)
		shcl_field *fa; size_t fn = shcl_fields(fd, &fa);
		if (fn != 5) fail("fields", "count mismatch");
		else for (size_t i = 0; i < 5; i++) {
			if (!FIELD_IS(fa[i], i)) { fail("fields", "fixture mismatch"); break; }
			shcl_read_str fr = shcl_read_string(fd, fp[i], strlen(fp[i]));
			if (fr.status != SHCL_GOOD || fr.value.n != strlen(fv[i]) || memcmp(fr.value.p, fv[i], fr.value.n)) { fail("fields", "a path did not read its own value"); break; }
		}
		shcl_read_field_list fl = shcl_read_fields(fd, "shard(1).owner", 14);
		if (fl.status != SHCL_GOOD || fl.n != 2 || !FIELD_IS(fl.values[0], 3) || !FIELD_IS(fl.values[1], 4)) fail("read_fields", "two instances");
		fl = shcl_read_fields(fd, "shard(0)", 8);
		if (fl.n != 1 || !FIELD_IS(fl.values[0], 0)) fail("read_fields", "one instance");
		// One slot per instance, and a slot that reached two is all empty.
		fl = shcl_read_fields(fd, "shard(*).owner", 14);
		if (fl.n != 2 || !FIELD_IS(fl.values[0], 1) || fl.values[1].path.n || fl.values[1].name.n || fl.values[1].value.n || fl.values[1].line) fail("read_fields", "slots");
		if (shcl_read_fields(fd, "nope", 4).status != SHCL_NOT_FOUND) fail("read_fields", "nope not NotFound");
		if (shcl_read_fields(fd, "a..b", 4).status != SHCL_BAD_PATH) fail("read_fields", "a..b not BadPath");
		fl = shcl_read_child_fields(fd, "", 0);
		if (fl.status != SHCL_GOOD || fl.n != 2 || !FIELD_IS(fl.values[0], 0) || !FIELD_IS(fl.values[1], 2)) fail("read_child_fields", "top level");
		fl = shcl_read_child_fields(fd, "shard", 5);
		if (fl.n != 3 || !FIELD_IS(fl.values[0], 1) || !FIELD_IS(fl.values[1], 3) || !FIELD_IS(fl.values[2], 4)) fail("read_child_fields", "every instance's children");
		if (shcl_read_child_fields(fd, "shard(1)", 8).n != 2) fail("read_child_fields", "one instance");
		if (shcl_read_child_fields(fd, "nope", 4).status != SHCL_NOT_FOUND) fail("read_child_fields", "nope not NotFound");
		if (shcl_read_child_fields(fd, "a..b", 4).status != SHCL_BAD_PATH) fail("read_child_fields", "a..b not BadPath");
		#undef FIELD_IS
		shcl_free(fd);
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
		if (shcl_set_int(nd, "NewTop.n", 8, 1) != SHCL_SET_OK) fail("authored_name", "set_int NewTop.n failed");
		sn = shcl_authored_name(nd, "newtop", 6);
		if (sn.n != 6 || memcmp(sn.p, "NewTop", 6) != 0) fail("authored_name", "newtop spelling mismatch");
		shcl_free(nd);
		// Escapes ARE resolved on a name, so both spellings of the path find the
		// same node - while shcl_authored_name still hands back the source
		// spelling, which is the one thing it is for. Same fixture everywhere.
		const char *et = "\"Ab◉TAB◉Cd\": 2\n";
		shcl_doc *ed = shcl_parse(et, strlen(et));
		const char *es = "Ab◉TAB◉Cd";
		sn = shcl_authored_name(ed, "\"ab◉tab◉cd\"", strlen("\"ab◉tab◉cd\""));
		if (sn.n != strlen(es) || memcmp(sn.p, es, sn.n) != 0) fail("authored_name", "escaped spelling mismatch");
		sn = shcl_authored_name(ed, "\"ab\tcd\"", 7); // a real tab
		if (sn.n != strlen(es) || memcmp(sn.p, es, sn.n) != 0) fail("authored_name", "literal spelling mismatch");
		if (shcl_read_int(ed, "\"ab\tcd\"", 7).value != 2) fail("authored_name", "read via the literal spelling failed");
		{
			// Canonical output folds the case, as it always has, and escapes the tab.
			const char *ec = "\"ab◉TAB◉cd\": 2\n";
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
		const char *et = "arr: [1, 2, 3]\nok: 5\n";
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
		const char *st2 = "arr:\n\t- 1\n\t- 2\n\t- 3\n";
		ld = shcl_parse_limited(st2, strlen(st2), SHCL_STANDARD, 0, 2, 0);
		ncap = 0;
		for (size_t k = 0; k < shcl_diag_count(ld); k++)
			if (strcmp(shcl_diag_code(ld, k), "E021") == 0) ncap++;
		shcl_read_i64_arr ra = shcl_read_int_array(ld, "arr", 3);
		if (ncap != 1 || ra.status != SHCL_GOOD || ra.n != 2 || ra.values[0] != 1 || ra.values[1] != 2)
			fail("parse_limited", "stacked array must keep what fit");
		shcl_free(ld);
		// A malformed array past the cap stayed E019 and kept. Since 2026-10-05
		// the cap wins over a broken value, so this is E021 now: see
		// a_cap_wins_over_a_broken_value.
		// const char *bt = "arr: [1,, 2, 3]\nk: x\n\t- 1\n";
		// ld = shcl_parse_limited(bt, strlen(bt), SHCL_STANDARD, 0, 1, 0);
		// {
		// 	shcl_str canon = shcl_to_canonical(ld);
		// 	int ok = shcl_diag_count(ld) == 2
		// 		&& shcl_diag_line(ld, 0) == 1 && strcmp(shcl_diag_code(ld, 0), "E019") == 0
		// 		&& shcl_diag_line(ld, 1) == 3 && strcmp(shcl_diag_code(ld, 1), "E011") == 0
		// 		&& shcl_lost_count(ld) == 1
		// 		&& canon.n >= 15 && memcmp(canon.p, "arr: [1,, 2, 3]", 15) == 0;
		// 	if (!ok) fail("parse_limited", "a cap over a refused line must keep that line's code");
		// }
		// shcl_free(ld);
		// The count the cap judges is the count the array reads back as,
		// spelling by spelling: quoted commas, a backslash (a character, so it
		// shields nothing), the empty array, a quoted Unicode blank (content:
		// only a space or a tab is blank, and bare it is E025). Refused at one
		// under, kept at exact. A quote that never closes made the comma after
		// it split before the value syntax; that line is E017 now and binds
		// nothing. An empty slot is E019 now, and a bare comma E026.
		static const struct { const char *spelling; size_t n; } counts[] = {
			{"[1, 2, 3]", 3}, {"[\"a, b\", c]", 2}, {"[a\\, b, c]", 3}, {"[]", 0},
			{"[ ]", 0}, {" a ", 1}, {"[\"\", '']", 2}, {"'a\", b'", 1},
			// {"\"open, b", 2},
			{"\\", 1}, {"[x,\"\xe3\x80\x80\"]", 2}, {"[x, \"\xc2\xa0y\"]", 2}, {"[80]", 1},
		};
		for (size_t ci = 0; ci < sizeof counts / sizeof counts[0]; ci++) {
			char ctext[64]; snprintf(ctext, sizeof ctext, "v: %s\n", counts[ci].spelling);
			size_t n = counts[ci].n;
			ld = shcl_parse_limited(ctext, strlen(ctext), SHCL_STANDARD, 0, n ? n : 1, 0);
			for (size_t k = 0; k < shcl_diag_count(ld); k++)
				if (strcmp(shcl_diag_code(ld, k), "E021") == 0) fail("parse_limited", "count table: refused at the exact cap");
			shcl_read_str_arr sa = shcl_read_string_array(ld, "v", 1);
			if (sa.status != SHCL_GOOD || sa.n != n)
				fail("parse_limited", "count table: element count differs from the read");
			shcl_free(ld);
			if (n >= 2) {
				ld = shcl_parse_limited(ctext, strlen(ctext), SHCL_STANDARD, 0, n - 1, 0);
				if (shcl_lost_count(ld) != 1) fail("parse_limited", "count table: not refused one under");
				shcl_free(ld);
			}
		}
		// An open quote was judged before the cap and kept the line. Since
		// 2026-10-05 the cap wins: see a_cap_wins_over_a_broken_value.
		// const char *qt = "v: [a, \"open, b]\n";
		// ld = shcl_parse_limited(qt, strlen(qt), SHCL_STANDARD, 0, 1, 0);
		// if (shcl_diag_count(ld) != 1 || strcmp(shcl_diag_code(ld, 0), "E017") != 0 || shcl_lost_count(ld) != 0) fail("parse_limited", "refused line must report the cap alone");
		// shcl_free(ld);
		// A fence whose info string splits past the cap is refused with its
		// block, in both spellings, so the body never reads as live lines. Same
		// fixture in every runner. Only a comma with a blank after it splits
		// since 20261006.
		const char *fences[] = {
			"secrets:\n\t```a, b, c, d\n\tpassword: hunter2\n\t```\nafter: 1\n",
			"secrets: ```a, b, c, d\n\tpassword: hunter2\n\t```\nafter: 1\n",
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
	test_id("EryvVSn", "a_cap_wins_over_a_broken_value");
	{
		// An item or a line past the caller's element cap is E021 and dropped,
		// even when its value is broken: the cap wins over a value fault. A
		// fault in the path or the name still comes first, and a broken item
		// within the cap is still kept. Same fixture in every runner.
		static const struct { const char *text, *own; } cc[] = {
			{"arr: [1,, 2, 3]\n", "1:E019"},
			{"arr: [a, \"open, b]\n", "1:E017"},
			{"arr: [a, b, c\n", "1:E019"},
			{"arr: [a, b] c\n", "1:E019"},
			{"arr: [a, b c, d]\n", "1:E025"},
		};
		char got[256], out[256]; size_t lost;
		for (size_t i = 0; i < sizeof cc / sizeof cc[0]; i++) {
			cap_codes(cc[i].text, 1, got, sizeof got, &lost, out, sizeof out);
			if (strcmp(got, "1:E021") != 0 || lost != 1 || strstr(out, "arr")) fail("cap_wins", cc[i].text);
			cap_codes(cc[i].text, 9, got, sizeof got, &lost, out, sizeof out);
			if (strcmp(got, cc[i].own) != 0 || lost != 0) fail("cap_wins", cc[i].text);
		}
		// A bare comma outside brackets counts its pieces the same way.
		cap_codes("a: x, y, z\n", 2, got, sizeof got, &lost, out, sizeof out);
		if (strcmp(got, "1:E021") != 0) fail("cap_wins", "bare comma past the cap");
		cap_codes("a: x, y, z\n", 3, got, sizeof got, &lost, out, sizeof out);
		if (strcmp(got, "1:E026") != 0) fail("cap_wins", "bare comma within the cap");
		// A stacked item past the cap is dropped whatever it holds; within the
		// cap a broken one is kept and the list loads around it.
		cap_codes("x:\n\t- a\n\t- b\n\t- \"open\n\t- c d\nz: 1\n", 2, got, sizeof got, &lost, out, sizeof out);
		if (strcmp(got, "4:E021 5:E021") != 0 || lost != 2 || strcmp(out, "x:\n\t- a\n\t- b\nz: 1\n") != 0) fail("cap_wins", "items past the cap");
		cap_codes("x:\n\t- a\n\t- \"open\n\t- b\n", 2, got, sizeof got, &lost, out, sizeof out);
		if (strcmp(got, "3:E017") != 0 || lost != 0 || !strstr(out, "- \"open")) fail("cap_wins", "a broken item within the cap");
		// An element under a field with a value is E011, cap or not.
		cap_codes("k: x\n\t- 1\n", 1, got, sizeof got, &lost, out, sizeof out);
		if (strcmp(got, "2:E011") != 0) fail("cap_wins", "item under a value");
		// The path and the name are judged first.
		cap_codes("404: [a, b, c]\n", 1, got, sizeof got, &lost, out, sizeof out);
		if (strcmp(got, "1:E014") != 0) fail("cap_wins", "a bad name past the cap");
	}
	test_id("EryvVUp", "no_colon_repair_stays_narrow");
	{
		// Only one clean name or path with no colon is repaired (E015), a bad
		// bare name like 404 included. Anything with a blank in a bare name
		// could be a name or a name and a value, so it is E014 and kept as
		// written.
		static const struct { const char *line, *quoted; } nc[] = {
			{"square-miles 300", "\"square-miles 300\""},
			{"this is ! not parseable", "\"this is ! not parseable\""},
			{"user name", "\"user name\""},
			{"user\tname", "\"user◉TAB◉name\""},
			{"a.b c", "a.\"b c\""},
		};
		char text[128], want[128];
		for (size_t i = 0; i < sizeof nc / sizeof nc[0]; i++) {
			snprintf(text, sizeof text, "k: 1\n%s\nz: 2\n", nc[i].line);
			shcl_doc *nd = shcl_parse(text, strlen(text));
			shcl_str out = shcl_to_canonical(nd);
			if (shcl_diag_count(nd) != 1 || strcmp(shcl_diag_code(nd, 0), "E014") != 0) fail("no_colon", nc[i].line);
			if (shcl_lost_count(nd) != 0) fail("no_colon", nc[i].line);
			if (out.n != strlen(text) || memcmp(out.p, text, out.n) != 0) fail("no_colon", nc[i].line);
			if (shcl_exists(nd, nc[i].quoted, strlen(nc[i].quoted))) fail("no_colon", nc[i].quoted);
			shcl_free(nd);
		}
		// The message names where the second word starts, as before chunk A.
		const char *mt = "a:\n\t  square-miles 300\n";
		shcl_doc *md = shcl_parse(mt, strlen(mt));
		const char *mw = "malformed line skipped: unexpected character after the path, at column 17";
		shcl_str mm = shcl_diag_count(md) ? shcl_diag_message(md, 0) : shcl_to_canonical(md);
		if (shcl_diag_count(md) == 0 || mm.n != strlen(mw) || memcmp(mm.p, mw, mm.n) != 0) fail("no_colon", "the E014 message");
		shcl_free(md);
		static const struct { const char *line, *out; } rc[] = {
			{"404", "\"404\":"}, {"-x", "\"-x\":"}, {"a.9b", "a:\n\t\"9b\":"},
		};
		for (size_t i = 0; i < sizeof rc / sizeof rc[0]; i++) {
			snprintf(text, sizeof text, "%s\n", rc[i].line);
			snprintf(want, sizeof want, "%s\n", rc[i].out);
			shcl_doc *rd = shcl_parse(text, strlen(text));
			shcl_str out = shcl_to_canonical(rd);
			if (shcl_diag_count(rd) != 1 || strcmp(shcl_diag_code(rd, 0), "E015") != 0) fail("no_colon", rc[i].line);
			if (out.n != strlen(want) || memcmp(out.p, want, out.n) != 0) fail("no_colon", rc[i].line);
			shcl_free(rd);
		}
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
		if (shcl_get_int_or(fd, "a", 1, 0) != 1) fail("file_tier", "broken file read");
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
		if (shcl_set_int(fd, "c", 1, 3) != SHCL_SET_OK) fail("file_tier", "set_int failed");
		if (shcl_save_file(fd, tfile, NULL) != SHCL_SAVE_OK) fail("file_tier", "save failed");
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
				if (shcl_save_file(nd, fresh, NULL) != SHCL_SAVE_OK) fail("file_tier", pass ? "overwrite save failed" : "new file save failed");
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
				if (shcl_save_file(nd, born, NULL) != SHCL_SAVE_OK) fail("file_tier", "new file save failed");
				if (stat(born, &ns) != 0) fail("file_tier", "new file stat failed");
				if ((ns.st_mode & 0777) != (ps.st_mode & 0777)) fail("file_tier", "new file mode");
				if (chmod(born, 0640) != 0) fail("file_tier", "chmod failed");
				if (shcl_save_file(nd, born, NULL) != SHCL_SAVE_OK) fail("file_tier", "existing file save failed");
				if (stat(born, &ns) != 0) fail("file_tier", "existing file stat failed");
				if ((ns.st_mode & 0777) != 0640) fail("file_tier", "existing file mode");
				// setuid and setgid come over too: applying the mode before
				// the data lets the kernel clear them on the write.
				// BSD gives a new file the directory's group, and refuses
				// setgid on a file whose group the caller is not in.
				if (chown(born, (uid_t)-1, getegid()) != 0) { /* the chmod below says */ }
				if (chmod(born, 06750) == 0 && stat(born, &ns) == 0 && (ns.st_mode & 07777) == 06750) {
					if (shcl_save_file(nd, born, NULL) != SHCL_SAVE_OK) fail("file_tier", "set-id save failed");
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
				if (shcl_save_file(nd, bsfile, NULL) != SHCL_SAVE_OK) fail("file_tier", "backslash path save failed");
				shcl_doc *bb = shcl_load_file(bsfile, &fst);
				if (fst != SHCL_FILE_CLEAN) fail("file_tier", "backslash path load");
				shcl_free(bb); remove(bsfile);
				// Checked through the wide API on purpose: the narrow calls would
				// write and read back the same wrong name, so a round trip through
				// them proves nothing.
				snprintf(u8file, sizeof u8file, "%s/\xe6\x97\xa5.shcl", tdir);
				if (shcl_save_file(nd, u8file, NULL) != SHCL_SAVE_OK) fail("file_tier", "utf-8 name save failed");
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
					if (shcl_save_file(nd, drfile, NULL) != SHCL_SAVE_OK) fail("file_tier", "drive-relative save failed");
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
			if (!shcl_write_file_atomic(fresh, NULL, 0, NULL)) fail("file_tier", "atomic write of (NULL, 0) failed");
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
		if (shcl_save_file(kd, tfile, NULL) != SHCL_SAVE_OK) fail("lost", "kept save failed");
		shcl_doc *kb = shcl_load_file(tfile, &fst);
		shcl_str kbc = shcl_to_canonical(kb);
		if (!contains(kbc.p, kbc.n, "square-miles 300\n")) fail("lost", "retained line lost through save");
		shcl_free(kb);
		if (shcl_save_file(lo, tfile, NULL) != SHCL_SAVE_REFUSED) fail("lost", "save did not refuse a lossy save");
		if (shcl_save_file_lossy(lo, tfile, NULL) != SHCL_SAVE_OK) fail("lost", "lossy save failed");
		// A refusal and a failed write are separate values, not two spellings of
		// one message, and the gate answers before any i/o - so an unwritable path
		// still reports the refusal. Same fixture in every runner.
		char bad[320];
		snprintf(bad, sizeof bad, "%s/nope/t.shcl", tdir);
		if (shcl_save_file(kd, bad, NULL) != SHCL_SAVE_FAILED) fail("lost", "a failed write did not report as one");
		if (shcl_save_file(lo, bad, NULL) != SHCL_SAVE_REFUSED) fail("lost", "refusal did not survive an unwritable path");
		// A save that keeps lines writes the dropped line back as it was, so it
		// refuses only when it falls back to canonical. Here removing the line
		// above it would make it a child of `a`.
		shcl_doc *kl = shcl_parse_keep_lines(lt2, strlen(lt2), SHCL_STANDARD);
		if (shcl_set_int(kl, "a.b", 3, 5) != SHCL_SET_OK) fail("lost", "keep set failed");
		int klk = 0;
		if (shcl_save_file_keep_lines(kl, tfile, &klk, NULL) != SHCL_SAVE_OK || !klk) fail("lost", "keep save did not keep a dropped line");
		size_t kll = 0; shcl_file_status kls;
		char *klt = shcl_read_file(tfile, 0, &kll, &kls);
		const char *klw = "a:\n\t\tb: 5\n\tc: 2\n";
		if (!klt || kll != strlen(klw) || memcmp(klt, klw, kll) != 0) fail("lost", "keep save text mismatch");
		free(klt);
		if (shcl_remove(kl, "a.b", 3) != 1) fail("lost", "keep remove failed");
		if (shcl_save_file_keep_lines(kl, tfile, &klk, NULL) != SHCL_SAVE_REFUSED) fail("lost", "keep save did not refuse its fallback");
		shcl_free(kl);
		shcl_free(lo); shcl_free(kd);
		remove(tfile); rmdir(tdir);
	}
	// The save gate on kept lines, from inside: once the edits that lose one are
	// fixed, no public call reaches the gate, so these take a line out by hand.
	// Same fixture in every runner.
	test_id("EreWlg6", "a_kept_line_gone_from_the_tree_refuses_the_save");
	{
		const char *kbase = "x: 1\nr: [1, 2\ny: 3\n";
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
		if (shcl_save_file(kd, kfile, NULL) != SHCL_SAVE_REFUSED) fail("kept_gate", "save_file did not refuse");
		if (shcl_save_file_keep_lines(kd, kfile, &kk, NULL) != SHCL_SAVE_REFUSED) fail("kept_gate", "save_file_keep_lines did not refuse");
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
		const char *kbase = "x: 1\nr: [1, 2\ny: 3\n";
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
		const char *ht = "a: [1\n\tb: 2\ny: 3\n";
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
			{"ErgTokB", "a_remove_leaves_the_kept_lines_beside_it", "x: 1\nr: [1, 2\ny: 3\n", "y", "x: 1\nr: [1, 2\n"},
			{NULL, NULL, "x: 1\nbad name: 1\ny: 3\n", "y", "x: 1\nbad name: 1\n"},
			{NULL, NULL, "j:\n\tr: [1\n\tq: 1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"},
			{NULL, NULL, "j:\n\tq: 1\n\tr: [1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"},
			{NULL, NULL, "j:\n\tq: 1\n\tr: [1\n\tw: 3\nz: 2\n", "j.q", "j:\n\tr: [1\n\tw: 3\nz: 2\n"},
			{NULL, NULL, "# on r\nr: [1\n# on y\ny: 3\nz: 1\n", "y", "# on r\nr: [1\nz: 1\n"},
			{"ErgTom6", "a_field_opened_by_a_kept_line_goes_with_its_last_line", "a: [1\n\tb: 2\ny: 3\n", "a.b", "a: [1\ny: 3\n"},
			{NULL, NULL, "a: [1\n\tb: 2\n\tc: 3\ny: 3\n", "a.b", "a: [1\n\tc: 3\ny: 3\n"},
			{NULL, NULL, "a: [1\n\tb: 2\n\tr: [3\ny: 3\n", "a.b", "a: [1\n\tr: [3\ny: 3\n"},
			{NULL, NULL, "o: [9\n\ta: [1\n\t\tb: 2\ny: 3\n", "o.a.b", "o: [9\n\ta: [1\ny: 3\n"},
			{NULL, NULL, "o:\n\ta: [1\n\t\tb: 2\n", "o.a.b", "o:\n\ta: [1\n"},
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
	test_id("Erlf1DT", "a_setter_comments_out_the_kept_line_heading_its_target");
	{
		// A setter on a field a kept line opened writes that line as a comment
		// with a note, so the file has one line for the field (2026100307163907).
#ifdef _WIN32
		_putenv_s("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT");
#else
		setenv("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT", 1);
#endif
		static const struct { const char *text, *path, *want; } sc[] = {
			{"a: [1\n\tb: 2\ny: 3\n", "a",
				"# a: [1  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing ']' on the line\na: 5\n\tb: 2\ny: 3\n"},
			{"o:\n\ta: \"x◉Q◉\"\n\t\tb: 2\n", "o.a",
				"o:\n\t# a: \"x◉Q◉\"  ## commented out by shcl when setting o.a, 2026-10-04 00:15:00 PDT: E023 unknown escape '◉Q◉'\n\ta: 5\n\t\tb: 2\n"},
			{"p: host: a.com\n\tq: 1\n", "p",
				"# p: host: a.com  ## commented out by shcl when setting p, 2026-10-04 00:15:00 PDT: E025 a colon then a space in a bare value\np: 5\n\tq: 1\n"},
			{"r: \"open\n\tq: 1\n", "r",
				"# r: \"open  ## commented out by shcl when setting r, 2026-10-04 00:15:00 PDT: E017 unterminated quote in value\nr: 5\n\tq: 1\n"},
			{"404: x\n\tq: 1\n", "\"404\"",
				"# 404: x  ## commented out by shcl when setting \"404\", 2026-10-04 00:15:00 PDT: E014 field name needs quotes\n\"404\": 5\n\tq: 1\n"},
		};
		for (size_t i = 0; i < sizeof sc / sizeof sc[0]; i++) {
			shcl_doc *sd = shcl_parse_keep_lines(sc[i].text, strlen(sc[i].text), SHCL_STANDARD);
			int took = shcl_set_int(sd, sc[i].path, strlen(sc[i].path), 5) == SHCL_SET_OK;
			shcl_str out = shcl_to_canonical(sd);
			if (!took || shcl_lost_count(sd) != 0 || out.n != strlen(sc[i].want) || memcmp(out.p, sc[i].want, out.n) != 0) {
				fail("kept_gate", sc[i].text);
			} else {
				shcl_doc *back = shcl_parse(out.p, out.n);
				shcl_str again = shcl_to_canonical(back);
				if (shcl_diag_count(back) != 0 || shcl_count(back, sc[i].path, strlen(sc[i].path)) != 1 || again.n != out.n || memcmp(again.p, out.p, out.n) != 0)
					fail("kept_gate", "a setter wrote text that reloads otherwise");
				shcl_free(back);
				int kept = 0;
				shcl_str keep = shcl_to_text_keep_lines(sd, &kept);
				if (!kept || keep.n != out.n || memcmp(keep.p, out.p, out.n) != 0) fail("kept_gate", "a setter's keep save differs from canonical");
			}
			shcl_free(sd);
		}
#ifdef _WIN32
		_putenv_s("SHCL_TEST_CLOCK", "");
#else
		unsetenv("SHCL_TEST_CLOCK");
#endif
		// Only the field the kept line opened: a child of it, or a field beside
		// a kept line, leaves the line as it was.
		static const struct { const char *path, *want; } bc[] = {
			{"a.c", "a: [1\n\tb: 2\n\tc: 5\n"},
			{"z", "a: [1\n\tb: 2\n\nz: 5\n"},
		};
		for (size_t i = 0; i < sizeof bc / sizeof bc[0]; i++) {
			shcl_doc *bd = shcl_parse("a: [1\n\tb: 2\n", 12);
			int took = shcl_set_int(bd, bc[i].path, strlen(bc[i].path), 5) == SHCL_SET_OK;
			shcl_str out = shcl_to_canonical(bd);
			if (!took || out.n != strlen(bc[i].want) || memcmp(out.p, bc[i].want, out.n) != 0) fail("kept_gate", bc[i].path);
			shcl_free(bd);
		}
	}
	test_id("ErmXhwI", "a_setter_comments_out_every_kept_line_of_its_name");
	{
		// A setter writing `a` writes every kept line named `a` in that block
		// as the noted comment, and a field it creates goes right under the
		// first of them, so a later hand fix never gives Multiple
		// (2026100307163907).
#ifdef _WIN32
		_putenv_s("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT");
#else
		setenv("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT", 1);
#endif
#define SETTER_NOTE(p) "  ## commented out by shcl when setting " p ", 2026-10-04 00:15:00 PDT: E019 malformed array, no closing ']' on the line"
		static const struct { const char *text, *path, *want; size_t count; } ec[] = {
			// No loaded `a`: the new line goes under the first comment.
			{"a: [1\ny: 3\n", "a", "# a: [1" SETTER_NOTE("a") "\na: 5\ny: 3\n", 1},
			{"x: 1\na: [1\ny: 3\na: [2\n", "a", "x: 1\n# a: [1" SETTER_NOTE("a") "\na: 5\ny: 3\n# a: [2" SETTER_NOTE("a") "\n", 1},
			// What was under the line goes under the new one.
			{"a: [1\n\t# under\n\tb: [2\ny: 3\n", "a", "# a: [1" SETTER_NOTE("a") "\na: 5\n\t# under\n\tb: [2\ny: 3\n", 1},
			// At the end of a block.
			{"o:\n\tx: 1\n\ta: [1\n", "o.a", "o:\n\tx: 1\n\t# a: [1" SETTER_NOTE("o.a") "\n\ta: 5\n", 1},
			// A field made on the way writes its line too.
			{"a: [1\ny: 3\n", "a.c", "# a: [1" SETTER_NOTE("a.c") "\na:\n\tc: 5\ny: 3\n", 1},
			// A loaded `a` changes in place.
			{"a: 1\nb: [1\na: [2\n", "a", "a: 5\nb: [1\n# a: [2" SETTER_NOTE("a") "\n", 1},
			// A kept line with a kept line under it stays as it is, since as
			// a comment it would leave that line under the field above.
			// Two valid lines wrote the first one here until a setter on a
			// repeated path was refused (2026100717500010); the refusal is
			// checked below.
			// {"a: 1\na: 2\n", "a", "a: 5\na: 2\n", 2},
			{"a: 1\na: [2\n\tc: [3\n", "a", "a: 5\na: [2\n\tc: [3\n", 1},
		};
#undef SETTER_NOTE
		for (size_t i = 0; i < sizeof ec / sizeof ec[0]; i++) {
			shcl_doc *ed = shcl_parse_keep_lines(ec[i].text, strlen(ec[i].text), SHCL_STANDARD);
			int took = shcl_set_int(ed, ec[i].path, strlen(ec[i].path), 5) == SHCL_SET_OK;
			shcl_str out = shcl_to_canonical(ed);
			if (!took || shcl_lost_count(ed) != 0 || out.n != strlen(ec[i].want) || memcmp(out.p, ec[i].want, out.n) != 0) {
				fail("kept_gate", ec[i].text);
			} else {
				shcl_doc *back = shcl_parse(out.p, out.n);
				shcl_str again = shcl_to_canonical(back);
				if (shcl_count(back, ec[i].path, strlen(ec[i].path)) != ec[i].count || again.n != out.n || memcmp(again.p, out.p, out.n) != 0)
					fail("kept_gate", "a setter's comments reload otherwise");
				shcl_free(back);
				int kept = 0;
				shcl_str keep = shcl_to_text_keep_lines(ed, &kept);
				if (!kept || keep.n != out.n || memcmp(keep.p, out.p, out.n) != 0) fail("kept_gate", "a setter's keep save differs from canonical");
			}
			shcl_free(ed);
		}
#ifdef _WIN32
		_putenv_s("SHCL_TEST_CLOCK", "");
#else
		unsetenv("SHCL_TEST_CLOCK");
#endif
		// Two valid lines stay as they are: the setter refuses the path.
		{
			static const char tv[] = "a: 1\na: 2\n";
			shcl_doc *td = shcl_parse_keep_lines(tv, strlen(tv), SHCL_STANDARD);
			int tkept = 0;
			int ttook = shcl_set_int(td, "a", 1, 5) == SHCL_SET_OK;
			shcl_str tk = shcl_to_text_keep_lines(td, &tkept);
			if (ttook || !tkept || tk.n != strlen(tv) || memcmp(tk.p, tv, tk.n) != 0) fail("kept_gate", "two valid lines");
			shcl_free(td);
		}
		// shcl_set_comment makes the field without touching the line.
		shcl_doc *cd = shcl_parse("a: [1\ny: 3\n", 11);
		int took = shcl_set_comment(cd, "a", 1, "n", 1) == SHCL_SET_OK;
		shcl_str out = shcl_to_canonical(cd);
		static const char cwant[] = "a: [1\ny: 3\n\n# n\na:\n";
		if (!took || out.n != strlen(cwant) || memcmp(out.p, cwant, out.n) != 0) fail("kept_gate", "set_comment beside a kept line");
		shcl_free(cd);
	}
	test_id("Erlf1GC", "a_note_names_the_zone_or_its_offset");
	{
		// The zone's short name, else its offset; and the test clock's form.
		static const struct { int offset; const char *name, *want; } zc[] = {
			{-420, "PDT", "PDT"}, {-420, "", "UTC-07:00"}, {240, "+04", "UTC+04:00"}, {330, "IST", "IST"},
			{-150, "-0230", "UTC-02:30"}, {0, "Pacific Daylight Time", "UTC+00:00"}, {0, "", "UTC+00:00"},
		};
		char label[64], when[32], name[64];
		int offset = 0;
		for (size_t i = 0; i < sizeof zc / sizeof zc[0]; i++) {
			zone_label(zc[i].offset, zc[i].name, label);
			if (strcmp(label, zc[i].want) != 0) fail("note_clock", zc[i].want);
		}
		if (!test_clock("2026-10-04 00:15:00 -420 PDT", when, &offset, name) || strcmp(when, "2026-10-04 00:15:00") != 0 || offset != -420 || strcmp(name, "PDT") != 0)
			fail("note_clock", "the test clock with a name");
		if (!test_clock("2026-10-04 00:15:00 60", when, &offset, name) || strcmp(when, "2026-10-04 00:15:00") != 0 || offset != 60 || name[0])
			fail("note_clock", "the test clock with no name");
		if (test_clock("2026-10-04 00:15:00", when, &offset, name) || test_clock("2026-10-04 00:15:00 x PDT", when, &offset, name))
			fail("note_clock", "a bad test clock was taken");
		local_clock(when, &offset, name);
		zone_label(offset, name, label);
		int shape = strlen(when) == 19 && offset >= -14 * 60 && offset <= 14 * 60;
		for (size_t k = 0; shape && k < 19; k++) {
			char c = when[k];
			shape = (k == 4 || k == 7) ? c == '-' : k == 10 ? c == ' ' : (k == 13 || k == 16) ? c == ':' : (c >= '0' && c <= '9');
		}
		if (!shape || (strncmp(label, "UTC+", 4) != 0 && strncmp(label, "UTC-", 4) != 0 && strcmp(label, name) != 0)) fail("note_clock", when);
	}
	test_id("EreWlk5", "a_merged_layer_owes_its_kept_lines");
	{
		const char *kbase = "x: 1\nr: [1, 2\ny: 3\n";
		shcl_doc *md = shcl_parse("a: 1\n", 5);
		shcl_doc *ml = shcl_parse(kbase, strlen(kbase));
		shcl_merge(md, ml);
		shcl_str mc = shcl_to_canonical(md);
		if (shcl_lost_count(md) != 0 || !contains(mc.p, mc.n, "r: [1, 2\n")) fail("kept_gate", "a merged layer's kept line counted as lost or went missing");
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
	// design.md's table: a replaced leaf takes only its own comments, the ones
	// a remove would take. A settled line or a comment past a kept line beside
	// it stays with that line.
	test_id("ErkSySr", "a_replaced_leaf_leaves_the_lines_beside_it");
	{
		const char *bt = "    srv: a\n  srv(x): [3\nb(x): [4\n# mine\nq: c\n";
		shcl_doc *bd = shcl_parse(bt, strlen(bt));
		shcl_str bc = shcl_to_canonical(bd);
		const char *bw = "srv: a\n# srv(x): [3\nb(x): [4\n# mine\nq: c\n";
		if (bc.n != strlen(bw) || memcmp(bc.p, bw, bc.n) != 0) fail("kept_gate", "the beside fixture did not settle its kept line");
		shcl_doc *bl = shcl_parse("q: 9\n", 5);
		shcl_merge(bd, bl);
		bc = shcl_to_canonical(bd);
		bw = "srv: a\n# srv(x): [3\nb(x): [4\nq: 9\n";
		if (bc.n != strlen(bw) || memcmp(bc.p, bw, bc.n) != 0) fail("kept_gate", "a replaced leaf took the lines beside it");
		if (shcl_lost_count(bd) != 0) fail("kept_gate", "a replaced leaf's neighbors counted as lost");
		shcl_free(bl); shcl_free(bd);
		const char *pt = "p:\n\tq: c\n\t# mine\n\tb(x): [4\n\t# n\n";
		const char *pl = "p:\n\tq: 9\n";
		shcl_doc *pd = shcl_parse(pt, strlen(pt));
		shcl_doc *pld = shcl_parse(pl, strlen(pl));
		shcl_merge(pd, pld);
		bc = shcl_to_canonical(pd);
		bw = "p:\n\tb(x): [4\n\t# n\n\tq: 9\n";
		if (bc.n != strlen(bw) || memcmp(bc.p, bw, bc.n) != 0) fail("kept_gate", "a replaced leaf took the lines below it");
		if (shcl_lost_count(pd) != 0) fail("kept_gate", "a replaced leaf's lines below counted as lost");
		shcl_free(pld); shcl_free(pd);
	}
	// set_raw: the body's shared indent survives a reload (the closing fence's
	// indent is what comes off), the info-string is stored as a fence line
	// reads it back, and an info with a line break or a `#` has no spelling and
	// fails the write. Same fixture in every runner.
	test_id("EoM5gS8", "set_raw_keeps_a_shared_indent_and_trims_the_info");
	{
		shcl_doc *sd = shcl_new();
		if (shcl_set_raw(sd, "q", 1, "  a\n  b", 7, " sql ", 5) != SHCL_SET_OK) fail("set_raw", "set_raw failed");
		shcl_str sc = shcl_to_canonical(sd);
		shcl_doc *back = shcl_parse(sc.p, sc.n);
		shcl_read_str br = shcl_read_raw(back, "q", 1);
		if (br.status != SHCL_GOOD || br.value.n != 7 || memcmp(br.value.p, "  a\n  b", 7) != 0) fail("set_raw", "shared indent did not survive a reload");
		shcl_read_str bi = shcl_read_raw_info(back, "q", 1);
		if (bi.status != SHCL_GOOD || bi.value.n != 3 || memcmp(bi.value.p, "sql", 3) != 0) fail("set_raw", "info not trimmed");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "a\nb", 3) == SHCL_SET_OK) fail("set_raw", "info with a newline accepted");
		br = shcl_read_raw(sd, "q", 1);
		if (br.status != SHCL_GOOD || br.value.n != 7 || memcmp(br.value.p, "  a\n  b", 7) != 0) fail("set_raw", "refused write changed the document");
		// A trailing CR is a blank and comes off, as the load takes it; one
		// mid-info is content.
		if (shcl_set_raw(sd, "q", 1, "x", 1, "ab\r", 3) != SHCL_SET_OK) fail("set_raw", "info ending in a CR refused");
		shcl_free(back);
		sc = shcl_to_canonical(sd);
		back = shcl_parse(sc.p, sc.n);
		bi = shcl_read_raw_info(back, "q", 1);
		if (bi.status != SHCL_GOOD || bi.value.n != 2 || memcmp(bi.value.p, "ab", 2) != 0) fail("set_raw", "trailing CR on an info not trimmed");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "a\rb", 3) != SHCL_SET_OK) fail("set_raw", "info with a mid-string CR refused");
		shcl_free(back);
		sc = shcl_to_canonical(sd);
		back = shcl_parse(sc.p, sc.n);
		bi = shcl_read_raw_info(back, "q", 1);
		if (bi.status != SHCL_GOOD || bi.value.n != 3 || memcmp(bi.value.p, "a\rb", 3) != 0) fail("set_raw", "mid-string CR info did not round-trip");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "a # b", 5) == SHCL_SET_OK) fail("set_raw", "info with a # accepted");
		// An info string has no quoting of its own: quotes are characters in
		// it, so they hide nothing, and a `#` glued to the label opens a
		// comment too.
		if (shcl_set_raw(sd, "q", 1, "x", 1, "\"a # b\"", 7) == SHCL_SET_OK) fail("set_raw", "quoted # info accepted");
		if (shcl_set_raw(sd, "q", 1, "x", 1, "c#", 2) == SHCL_SET_OK) fail("set_raw", "glued # info accepted");
		shcl_free(back);
		// A body line ending in CR has no fence spelling: the load takes the
		// whole trailing CR run off every line, so it is refused rather than
		// lost. A CR mid-line is content and still round-trips.
		if (shcl_set_raw(sd, "q", 1, "a\r\nb", 4, "", 0) == SHCL_SET_OK) fail("set_raw", "body with a line-ending CR accepted");
		if (shcl_set_raw(sd, "q", 1, "\r", 1, "", 0) == SHCL_SET_OK) fail("set_raw", "body of one CR accepted");
		if (shcl_set_raw(sd, "q", 1, "a\rb", 3, "", 0) != SHCL_SET_OK) fail("set_raw", "body with a mid-line CR refused");
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
		if (shcl_save_file(dd, dlink, NULL) != SHCL_SAVE_OK) fail("dangling", "save through a dangling link failed");
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
		if (shcl_save_file(cd, ca, NULL) == SHCL_SAVE_OK) fail("cycle", "a symlink cycle saved without an error");
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
		if (shcl_save_file(td, tp, NULL) == SHCL_SAVE_OK) fail("targets", "a FIFO saved without an error");
		if (lstat(tp, &ts) != 0 || !S_ISFIFO(ts.st_mode)) fail("targets", "a FIFO was replaced by a regular file");
		remove(tp);
		snprintf(tp, sizeof tp, "%s/l.shcl", tdir);
		snprintf(tq, sizeof tq, "%s/d", tdir);
		if (symlink("d/", tp) != 0) fail("targets", "symlink failed");
		if (shcl_save_file(td, tp, NULL) == SHCL_SAVE_OK) fail("targets", "a link naming a directory saved without an error");
		if (lstat(tq, &ts) == 0) fail("targets", "a link naming a directory made a file");
		remove(tp);
		snprintf(tp, sizeof tp, "%s/real", tdir); if (mkdir(tp, 0700) != 0) fail("targets", "mkdir failed");
		snprintf(tp, sizeof tp, "%s/real/sub", tdir); if (mkdir(tp, 0700) != 0) fail("targets", "mkdir failed");
		snprintf(tp, sizeof tp, "%s/top", tdir); if (mkdir(tp, 0700) != 0) fail("targets", "mkdir failed");
		snprintf(tp, sizeof tp, "%s/top/lnkdir", tdir);
		snprintf(tq, sizeof tq, "%s/real/sub/f.shcl", tdir);
		if (symlink("../real/sub", tp) != 0 || symlink("../x.shcl", tq) != 0) fail("targets", "symlink failed");
		snprintf(tr, sizeof tr, "%s/top/lnkdir/f.shcl", tdir);
		if (shcl_save_file(td, tr, NULL) != SHCL_SAVE_OK) fail("targets", "save through lnk/.. failed");
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
		if (shcl_save_file(rd, rfile, NULL) != SHCL_SAVE_OK) fail("readonly", "save over a read-only file failed");
		size_t rn; char *rt = read_file(rfile, &rn);
		if (!rt || rn != 5 || memcmp(rt, "a: 2\n", 5) != 0) fail("readonly", "file not rewritten");
		free(rt);
		if (!(GetFileAttributesA(rfile) & FILE_ATTRIBUTE_READONLY)) fail("readonly", "file did not come back read-only");
		// Hidden and system come back too: ReplaceFile's preserve list does not
		// include the basic attributes and the fallback move keeps none, so a
		// hidden config used to come back visible.
		SetFileAttributesA(rfile, (GetFileAttributesA(rfile) & ~(DWORD)FILE_ATTRIBUTE_READONLY) | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM);
		shcl_doc *hd = shcl_parse("a: 3\n", 5);
		if (shcl_save_file(hd, rfile, NULL) != SHCL_SAVE_OK) fail("attrs", "save over a hidden file failed");
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
		if (shcl_write_file_atomic(hfile, "a: 2\n", 5, NULL)) fail("errno", "write over a held file succeeded");
		if (errno == 0) fail("errno", "failed publish left errno at 0");
		CloseHandle(hold);
		errno = 0;
		if (shcl_write_file_atomic("nul", "a: 2\n", 5, NULL)) fail("errno", "write to a device name succeeded");
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
		for (int i = 0; i < 200; i++) if (shcl_save_file(gd, gfile, NULL) != SHCL_SAVE_OK) { fail("retain", "save failed"); break; }
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
		const char *at = "ports: [80, 443, 8080]\n";
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
		const char *at = "ports: [80, 443, 8080]\nnames: [a, \"b c\"]\nwhen: [2026-01-02T03:04:05.25Z, 2027-01-01]\nflags: [true, false]\nf: [1.5, 2]\n";
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
			if (shcl_read_string_to(ad, "names", 5, buf, sizeof buf, &len) != SHCL_GOOD || len != 10 || strcmp(buf, "[a, \"b c\"]") != 0) { fail("copy_out", "joined string"); break; }
		}
		if (arena_bytes(&ad->reads) != readsBefore) fail("copy_out", "copy-out reads grew the read arena");
		if (shcl_read_int_array_to(ad, "ports", 5, iv, sl, 1, &n) != SHCL_GOOD || n != 3 || iv[0] != 80) fail("copy_out", "short int buffer");
		if (shcl_read_string_to(ad, "names", 5, buf, 4, &len) != SHCL_GOOD || len != 10 || strcmp(buf, "[a,") != 0) fail("copy_out", "short string buffer");
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
		if (shcl_set_datetime(dd, "when", 4, &worst) == SHCL_SET_OK) fail("dt_clamp", "the setter bound a datetime the reader refuses");
		if (shcl_exists(dd, "when", 4)) fail("dt_clamp", "a refused datetime left a node behind");
		shcl_free(dd);
	}
	test_id("Es9JVra", "bad_path_reads_say_bad_path");
	// A path the scanner refuses, or one with a value part, is BadPath on every
	// read with a status, where a path that parses and finds nothing stays
	// NotFound. The no-status calls give their empty answer and _or its
	// default. Same fixture in every runner.
	{
		const char *bt = "site: a\n\tport: 1\n";
		shcl_doc *bd = shcl_parse(bt, strlen(bt));
		if (shcl_read_int(bd, "site(0).port", 12).status != SHCL_GOOD) fail("bad_path", "site(0).port not good");
		if (shcl_read_int(bd, "nope", 4).status != SHCL_NOT_FOUND) fail("bad_path", "nope not NotFound");
		static const char *const bps[] = {"site[0].port", "site(.port", "site..port", "", "user name", "site.port: 1", "h:p"};
		for (size_t i = 0; i < sizeof bps / sizeof bps[0]; i++) {
			const char *p = bps[i]; size_t n = strlen(p);
			shcl_read_i64 ri = shcl_read_int(bd, p, n);
			if (ri.status != SHCL_BAD_PATH || ri.value != 0) fail("bad_path", p);
			shcl_status sts[] = {
				shcl_read_float(bd, p, n).status, shcl_read_bool_(bd, p, n).status,
				shcl_read_string(bd, p, n).status, shcl_read_raw(bd, p, n).status,
				shcl_read_raw_info(bd, p, n).status, shcl_read_datetime(bd, p, n).status,
				shcl_read_duration(bd, p, n, SHCL_DURATION_NONE).status,
				shcl_read_size(bd, p, n, SHCL_SIZE_NONE, 0).status,
				shcl_read_float_array(bd, p, n).status, shcl_read_bool_array(bd, p, n).status,
				shcl_read_string_array(bd, p, n).status, shcl_read_datetime_array(bd, p, n).status,
			};
			for (size_t k = 0; k < sizeof sts / sizeof sts[0]; k++)
				if (sts[k] != SHCL_BAD_PATH) fail("bad_path", p);
			shcl_read_i64_arr ra = shcl_read_int_array(bd, p, n);
			if (ra.status != SHCL_BAD_PATH || ra.n != 0 || ra.statuses) fail("bad_path", p);
			char buf[8] = "x"; size_t len = 9; int64_t iv[2]; shcl_status sl[2]; size_t an = 9;
			if (shcl_read_string_to(bd, p, n, buf, sizeof buf, &len) != SHCL_BAD_PATH || len != 0 || buf[0]) fail("bad_path", p);
			if (shcl_read_int_array_to(bd, p, n, iv, sl, 2, &an) != SHCL_BAD_PATH || an != 0) fail("bad_path", p);
			if (shcl_get_int_or(bd, p, n, 8) != 8 || shcl_get_float_or(bd, p, n, 8.5) != 8.5 || shcl_get_bool_or(bd, p, n, 1) != 1) fail("bad_path", p);
			shcl_str *bv;
			if (shcl_count(bd, p, n) != 0 || shcl_instances(bd, p, n, &bv) != 0) fail("bad_path", p);
			if (n && shcl_children(bd, p, n, &bv) != 0) fail("bad_path", p);
		}
		// The empty path is the top level for shcl_children, as documented.
		shcl_str *kids;
		if (shcl_children(bd, "", 0, &kids) != 1 || kids[0].n != 4 || memcmp(kids[0].p, "site", 4)) fail("bad_path", "children of the empty path");
		// Last in the order, so a worst-of aggregate puts it on top.
		if (SHCL_BAD_PATH <= SHCL_MULTIPLE || strcmp(shcl_status_name(SHCL_BAD_PATH), "BadPath") || shcl_status_code(SHCL_BAD_PATH) != 1) fail("bad_path", "order, name or code");
		shcl_free(bd);
	}
	test_id("EsDQqYg", "list_reads_say_bad_path");
	// The list reads' status twins: BadPath for a path that cannot be read,
	// NotFound for one that matches nothing, Good otherwise, with the value the
	// plain call gives. Same fixture in every runner.
	{
		const char *lt = "site: a\n\tport: 1\nsite: b\n";
		shcl_doc *ld = shcl_parse(lt, strlen(lt));
		shcl_read_usize lc = shcl_read_count(ld, "site", 4);
		if (lc.value != 2 || lc.status != SHCL_GOOD) fail("list_reads", "read_count(site)");
		lc = shcl_read_count(ld, "site(0)", 7);
		if (lc.value != 1 || lc.status != SHCL_GOOD) fail("list_reads", "read_count(site(0))");
		// An unresolved wildcard slot still counts, as in shcl_count.
		lc = shcl_read_count(ld, "site(*).port", 12);
		if (lc.value != 2 || lc.status != SHCL_GOOD) fail("list_reads", "read_count(site(*).port)");
		if (shcl_read_count(ld, "nope", 4).status != SHCL_NOT_FOUND) fail("list_reads", "read_count(nope)");
		if (shcl_read_count(ld, "nope(*)", 7).status != SHCL_NOT_FOUND) fail("list_reads", "read_count(nope(*))");
		shcl_read_str_list li = shcl_read_instances(ld, "site", 4);
		if (li.status != SHCL_GOOD || li.n != 2 || li.values[0].n != 1 || li.values[0].p[0] != 'a' || li.values[1].n != 1 || li.values[1].p[0] != 'b') fail("list_reads", "read_instances(site)");
		li = shcl_read_instances(ld, "site(*).port", 12);
		if (li.status != SHCL_GOOD || li.n != 2 || li.values[0].n != 1 || li.values[0].p[0] != '1' || li.values[1].n != 0) fail("list_reads", "read_instances(site(*).port)");
		if (shcl_read_instances(ld, "nope", 4).status != SHCL_NOT_FOUND) fail("list_reads", "read_instances(nope)");
		shcl_read_str_list lk = shcl_read_children(ld, "site(0)", 7);
		if (lk.status != SHCL_GOOD || lk.n != 1 || lk.values[0].n != 4 || memcmp(lk.values[0].p, "port", 4)) fail("list_reads", "read_children(site(0))");
		// An empty section is Good, a missing one NotFound.
		lk = shcl_read_children(ld, "site(1)", 7);
		if (lk.status != SHCL_GOOD || lk.n != 0) fail("list_reads", "read_children(site(1))");
		if (shcl_read_children(ld, "nope", 4).status != SHCL_NOT_FOUND) fail("list_reads", "read_children(nope)");
		lk = shcl_read_children(ld, "", 0);
		if (lk.status != SHCL_GOOD || lk.n != 2 || lk.values[0].n != 4 || memcmp(lk.values[0].p, "site", 4) || lk.values[1].n != 4 || memcmp(lk.values[1].p, "site", 4)) fail("list_reads", "read_children of the empty path");
		static const char *const lps[] = {"site[0].port", "site(.port", "site..port", "", "user name", "site.port: 1", "h:p"};
		for (size_t i = 0; i < sizeof lps / sizeof lps[0]; i++) {
			const char *p = lps[i]; size_t n = strlen(p);
			lc = shcl_read_count(ld, p, n);
			if (lc.value != 0 || lc.status != SHCL_BAD_PATH) fail("list_reads", p);
			li = shcl_read_instances(ld, p, n);
			if (li.n != 0 || li.status != SHCL_BAD_PATH || !li.values) fail("list_reads", p);
			lk = shcl_read_children(ld, p, n);
			if (n && (lk.n != 0 || lk.status != SHCL_BAD_PATH || !lk.values)) fail("list_reads", p);
		}
		shcl_free(ld);
	}
	// check_set_path: the path's half of a setter's status. Same fixture in
	// every runner.
	test_id("ElouJ8M", "check_set_path_names_the_failure");
	{
		const char *wt = "a:\n\tb: 1\n";
		shcl_doc *wd = shcl_parse(wt, strlen(wt));
		if (shcl_check_set_path(wd, "a.b", 3) != SHCL_SET_OK) fail("check_set_path", "a.b not writable");
		if (shcl_check_set_path(wd, "a.new(Boston).x", 15) != SHCL_SET_OK) fail("check_set_path", "creatable path not writable");
		if (shcl_check_set_path(wd, "", 0) != SHCL_SET_BAD_PATH) fail("check_set_path", "empty path not bad");
		if (shcl_check_set_path(wd, "a..b", 4) != SHCL_SET_BAD_PATH) fail("check_set_path", "a..b not bad");
		if (shcl_check_set_path(wd, "a.b: 2", 6) != SHCL_SET_VALUE_IN_PATH) fail("check_set_path", "value part not flagged");
		if (shcl_check_set_path(wd, "a(*).b", 6) != SHCL_SET_WILDCARD) fail("check_set_path", "wildcard not flagged");
		if (shcl_check_set_path(wd, "a(5).b", 6) != SHCL_SET_NO_SUCH_INDEX) fail("check_set_path", "a(5) not flagged");
		if (shcl_check_set_path(wd, "nope(0).b", 9) != SHCL_SET_NO_SUCH_INDEX) fail("check_set_path", "off-tree index not flagged");
		{
			char deep[1026]; size_t dn = 0; // 513 segments: "d.d.d..."
			for (size_t i = 0; i < 513; i++) { if (i) deep[dn++] = '.'; deep[dn++] = 'd'; }
			if (shcl_check_set_path(wd, deep, dn) != SHCL_SET_TOO_DEEP) fail("check_set_path", "513 segments not too deep");
		}
		// A literal line break is writable wherever a path can have one: a name
		// emits through the name escaper and a selector value through the value
		// emitter, and both write a break \n and read it back as one. The
		// selector was refused while the value emitter still wrote elements in
		// their source spelling and had nothing to escape with. Not
		// corpus-pinnable - an ops line cannot contain a raw newline.
		if (shcl_check_set_path(wd, "a(\"p\nq\").b", 10) != SHCL_SET_OK) fail("check_set_path", "newline in selector not writable");
		if (shcl_check_set_path(wd, "\"x\ny\".b", 7) != SHCL_SET_OK) fail("check_set_path", "newline in name not writable");
		if (shcl_check_set_path(wd, "\"x\\ny\".b", 8) != SHCL_SET_OK) fail("check_set_path", "escaped newline not writable");
		// The probe never creates: the doc is unchanged after all of the above.
		if (shcl_count(wd, "a", 1) != 1) fail("check_set_path", "probe created nodes");
		shcl_free(wd);
	}
	// The values a setter refuses on a path shcl_check_set_path passes. Each
	// one here is refused, writes nothing, and the path checks OK. Same fixture
	// in every runner. setter_status_names_each_refusal has the status each one
	// gives.
	test_id("Es9S4kM", "refused_values_pass_the_path_check");
	{
		const char *rt = "ports: [80, 443]\nsec:\n\tx: 1\n";
		shcl_doc *base = shcl_parse(rt, strlen(rt));
		shcl_str bw = shcl_to_canonical(base);
		char *want = malloc(bw.n + 1);
		if (!want) { fprintf(stderr, "out of memory\n"); exit(1); }
		memcpy(want, bw.p, bw.n);
		size_t wantn = bw.n;
		shcl_free(base);
		shcl_datetime month13;
		memset(&month13, 0, sizeof month13);
		month13.has_date = 1; month13.year = 2026; month13.month = 13; month13.day = 1;
		const double inf_arr[] = {1.0, -INFINITY};
		const int64_t two[] = {1, 2};
		static const char *const what[] = {
			"NaN float", "infinite float", "infinite float in an array", "month 13",
			"raw info with #", "raw info with a line break", "raw body line ending in CR",
			"comment with a line break", "literal of two values", "literal with an open quote",
			"literal with a line break", "array on a field with lines under it",
			"literal array on a field with lines under it",
			// The path check says UnderArray for this one now
			// (2026100907362300), since no value could go there.
			// setter_status_names_each_refusal has it.
			// "field under an array",
		};
		static const char *const at[] = {"f", "f", "f", "t", "r", "r", "r", "sec.x", "l", "l", "l", "sec", "sec" /* , "ports.x" */};
		for (size_t i = 0; i < sizeof what / sizeof what[0]; i++) {
			shcl_doc *rd = shcl_parse(rt, strlen(rt));
			shcl_set_status took = SHCL_SET_OK;
			switch (i) {
			case 0: took = shcl_set_float(rd, "f", 1, NAN); break;
			case 1: took = shcl_set_float(rd, "f", 1, INFINITY); break;
			case 2: took = shcl_set_float_array(rd, "f", 1, inf_arr, 2); break;
			case 3: took = shcl_set_datetime(rd, "t", 1, &month13); break;
			case 4: took = shcl_set_raw(rd, "r", 1, "body", 4, "sh # x", 6); break;
			case 5: took = shcl_set_raw(rd, "r", 1, "body", 4, "sh\nx", 4); break;
			case 6: took = shcl_set_raw(rd, "r", 1, "a\r\nb", 4, "", 0); break;
			case 7: took = shcl_set_comment(rd, "sec.x", 5, "a\nb", 3); break;
			case 8: took = shcl_set_literal(rd, "l", 1, "a, b", 4); break;
			case 9: took = shcl_set_literal(rd, "l", 1, "\"abc", 4); break;
			case 10: took = shcl_set_literal(rd, "l", 1, "a\nb", 3); break;
			case 11: took = shcl_set_int_array(rd, "sec", 3, two, 2); break;
			case 12: took = shcl_set_literal(rd, "sec", 3, "[1, 2]", 6); break;
			// default: took = shcl_set_int(rd, "ports.x", 7, 1); break;
			default: break;
			}
			if (took == SHCL_SET_OK) fail("refused_values", what[i]);
			if (shcl_check_set_path(rd, at[i], strlen(at[i])) != SHCL_SET_OK) fail("refused_values", what[i]);
			shcl_str got = shcl_to_canonical(rd);
			if (got.n != wantn || memcmp(got.p, want, wantn)) fail("refused_values", what[i]);
			shcl_free(rd);
		}
		free(want);
	}
	// Text that is not valid UTF-8 would save as a file whose next load fails
	// whole. Every setter that takes text refuses it, as Go's do: it gives
	// SHCL_SET_NOT_UTF8, writes nothing, and the path checks OK. The same cases
	// are in the Python runner, with a lone surrogate.
	test_id("Es9aZSK", "setters_refuse_text_that_is_not_utf8");
	{
		const char *ut = "sec:\n\tx: 1\nsrv: a\n";
		shcl_doc *base = shcl_parse(ut, strlen(ut));
		shcl_str bw = shcl_to_canonical(base);
		char *want = malloc(bw.n + 1);
		if (!want) { fprintf(stderr, "out of memory\n"); exit(1); }
		memcpy(want, bw.p, bw.n);
		size_t wantn = bw.n;
		shcl_free(base);
		static const char bad[] = "a\xff" "b", cut[] = "a\xc3", sur[] = "a\xed\xa0\x80" "b", over[] = "a\xc0\xaf";
		const char *const arr[] = {"ok", bad};
		const size_t lens[] = {2, sizeof bad - 1};
		static const char *const at[] = {
			"s", "s", "s", "s", "s", "s", "s", "sec.x", "r", "r", "r", "l", "l", "l", "l",
			// A path that is not UTF-8 checks BadPath now, from
			// shcl_check_set_path as from the setter (2026100907362300), so
			// these moved to setter_status_names_each_refusal.
			// "\"a\xff" "b\"", "\"a\xff" "b\".x", "srv(a\xff" "b).x", "srv(\"a\xff" "b\").x", "\"a\xff" "b\"",
		};
		for (size_t i = 0; i < sizeof at / sizeof at[0]; i++) {
			shcl_doc *ud = shcl_parse(ut, strlen(ut));
			const char *p = at[i]; size_t pn = strlen(p);
			shcl_set_status took = SHCL_SET_OK;
			switch (i) {
			case 0: took = shcl_set_string(ud, p, pn, bad, sizeof bad - 1); break;
			case 1: took = shcl_set_string(ud, p, pn, cut, sizeof cut - 1); break;
			case 2: took = shcl_set_string(ud, p, pn, sur, sizeof sur - 1); break;
			case 3: took = shcl_set_string(ud, p, pn, over, sizeof over - 1); break;
			case 4: took = shcl_set_string_default(ud, p, pn, bad, sizeof bad - 1); break;
			case 5: took = shcl_set_string_array(ud, p, pn, arr, lens, 2); break;
			case 6: took = shcl_set_string_array_default(ud, p, pn, arr, lens, 2); break;
			case 7: took = shcl_set_comment(ud, p, pn, bad, sizeof bad - 1); break;
			case 8: took = shcl_set_raw(ud, p, pn, bad, sizeof bad - 1, "", 0); break;
			case 9: took = shcl_set_raw(ud, p, pn, "body", 4, bad, sizeof bad - 1); break;
			case 10: took = shcl_set_raw_default(ud, p, pn, bad, sizeof bad - 1, "", 0); break;
			case 11: took = shcl_set_literal(ud, p, pn, bad, sizeof bad - 1); break;
			case 12: took = shcl_set_literal(ud, p, pn, "\"a\xff" "b\"", 5); break;
			case 13: took = shcl_set_literal(ud, p, pn, "[ok, a\xff" "b]", 9); break;
			case 14: took = shcl_set_literal_default(ud, p, pn, bad, sizeof bad - 1); break;
			// case 19: took = shcl_set_comment(ud, p, pn, "c", 1); break;
			// default: took = shcl_set_int(ud, p, pn, 1); break;
			default: break;
			}
			char what[32];
			snprintf(what, sizeof what, "case %zu", i);
			if (took != SHCL_SET_NOT_UTF8) fail("not_utf8", what);
			if (shcl_check_set_path(ud, p, pn) != SHCL_SET_OK) fail("not_utf8", what);
			shcl_str got = shcl_to_canonical(ud);
			if (got.n != wantn || memcmp(got.p, want, wantn)) fail("not_utf8", what);
			shcl_free(ud);
		}
		free(want);
	}
	// A setter on a path that matches more than one field at any step writes
	// nothing and the path checks MULTIPLE, so a write never says OK where the
	// read after it would say Multiple. An index or value selector picks one.
	// Same fixture in every runner.
	test_id("Es9aZSI", "repeated_path_refuses_a_setter");
	{
		const char *mt = "port: 1\nport: 2\nsite: a\n\troot: /x\nsite: b\n\troot: /y\nsec:\n\tk: 1\n\tk: 2\n";
		shcl_doc *base = shcl_parse(mt, strlen(mt));
		shcl_str bw = shcl_to_canonical(base);
		char *want = malloc(bw.n + 1);
		if (!want) { fprintf(stderr, "out of memory\n"); exit(1); }
		memcpy(want, bw.p, bw.n);
		size_t wantn = bw.n;
		shcl_free(base);
		const int64_t nine[] = {9};
		static const char *const at[] = {
			"port", "port", "port", "port", "port", "port", "port", "port", "port",
			"site.root", "site.new", "site.new", "sec.k", "sec.k.x",
		};
		for (size_t i = 0; i < sizeof at / sizeof at[0]; i++) {
			shcl_doc *md = shcl_parse(mt, strlen(mt));
			const char *p = at[i]; size_t pn = strlen(p);
			shcl_set_status took = SHCL_SET_OK;
			switch (i) {
			case 0: took = shcl_set_int(md, p, pn, 9); break;
			case 1: took = shcl_set_string(md, p, pn, "9", 1); break;
			case 2: took = shcl_set_literal(md, p, pn, "9", 1); break;
			case 3: took = shcl_set_int_array(md, p, pn, nine, 1); break;
			case 4: took = shcl_set_empty(md, p, pn); break;
			case 5: took = shcl_set_raw(md, p, pn, "x", 1, "", 0); break;
			case 6: took = shcl_set_comment(md, p, pn, "c", 1); break;
			case 7: took = shcl_set_int_default(md, p, pn, 9); break;
			case 8: took = shcl_set_literal_default(md, p, pn, "9", 1); break;
			case 9: took = shcl_set_string(md, p, pn, "/z", 2); break;
			case 10: took = shcl_set_string(md, p, pn, "v", 1); break;
			case 11: took = shcl_set_string_default(md, p, pn, "v", 1); break;
			default: took = shcl_set_int(md, p, pn, 9); break;
			}
			if (took != SHCL_SET_MULTIPLE) fail("repeated_path", p);
			if (shcl_check_set_path(md, p, pn) != SHCL_SET_MULTIPLE) fail("repeated_path", p);
			shcl_str got = shcl_to_canonical(md);
			if (got.n != wantn || memcmp(got.p, want, wantn)) fail("repeated_path", p);
			shcl_free(md);
		}
		free(want);
		shcl_doc *md = shcl_parse(mt, strlen(mt));
		if (shcl_set_int(md, "port(1)", 7, 9) != SHCL_SET_OK || shcl_set_string(md, "site(1).root", 12, "/z", 2) != SHCL_SET_OK
			|| shcl_set_string(md, "site(a).root", 12, "/w", 2) != SHCL_SET_OK || shcl_set_int(md, "sec.k(0)", 8, 7) != SHCL_SET_OK)
			fail("repeated_path", "a setter naming one instance was refused");
		shcl_read_str rb = shcl_read_string(md, "site(b).root", 12), ra = shcl_read_string(md, "site(a).root", 12);
		if (shcl_get_int_or(md, "port(0)", 7, 0) != 1 || shcl_get_int_or(md, "port(1)", 7, 0) != 9
			|| shcl_get_int_or(md, "sec.k(0)", 8, 0) != 7 || rb.value.n != 2 || memcmp(rb.value.p, "/z", 2)
			|| ra.value.n != 2 || memcmp(ra.value.p, "/w", 2))
			fail("repeated_path", "wrote the wrong instance");
		// A remove takes every instance it matches, as a read sees them.
		if (shcl_remove(md, "port", 4) != 2 || shcl_check_set_path(md, "port", 4) != SHCL_SET_OK) fail("repeated_path", "remove");
		shcl_free(md);
	}
	// Every status a setter gives, in the order every binding numbers them,
	// and the names the other three print. Same fixture in every runner.
	test_id("EsDjstE", "setter_status_values_in_order");
	{
		static const shcl_set_status all[] = {
			SHCL_SET_OK, SHCL_SET_BAD_PATH, SHCL_SET_VALUE_IN_PATH, SHCL_SET_WILDCARD, SHCL_SET_NO_SUCH_INDEX,
			SHCL_SET_TOO_DEEP, SHCL_SET_MULTIPLE, SHCL_SET_UNDER_ARRAY, SHCL_SET_HAS_CHILDREN, SHCL_SET_NOT_FINITE,
			SHCL_SET_BAD_DATETIME, SHCL_SET_BAD_RAW_INFO, SHCL_SET_BAD_RAW_BODY, SHCL_SET_BAD_COMMENT,
			SHCL_SET_NOT_ONE_VALUE, SHCL_SET_NOT_UTF8, SHCL_SET_OUT_OF_RANGE, SHCL_SET_NO_READ_BACK,
		};
		static const char *const snames[] = {
			"Ok", "BadPath", "ValueInPath", "Wildcard", "NoSuchIndex", "TooDeep", "Multiple", "UnderArray",
			"HasChildren", "NotFinite", "BadDateTime", "BadRawInfo", "BadRawBody", "BadComment", "NotOneValue",
			"NotUtf8", "OutOfRange", "NoReadBack",
		};
		if (sizeof all / sizeof all[0] != sizeof snames / sizeof snames[0]) fail("setter_status_order", "a value and its name are not one to one");
		for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) {
			if ((size_t)all[i] != i) fail("setter_status_order", snames[i]);
			if (strcmp(shcl_set_status_name(all[i]), snames[i]) != 0) fail("setter_status_order", snames[i]);
		}
	}
	// A setter's status names why it wrote nothing. A path reason is the one
	// shcl_check_set_path gives, and wins over a value reason when both apply,
	// since the path is what to fix first; a value reason comes with a path
	// that checks OK. A default form on a path already there writes nothing and
	// gives what the plain setter would. Same fixture in every runner, plus C's
	// own: SHCL_SET_NOT_UTF8 for value, comment, info and body text, ahead of
	// the other value reasons, and SHCL_SET_BAD_PATH for a path that is not
	// UTF-8. OUT_OF_RANGE and NO_READ_BACK have no case: an int64_t is in
	// range, and no other value is known that fails to read back.
	test_id("EsDjsvT", "setter_status_names_each_refusal");
	{
		const char *st = "a:\n\tb: 1\nports: [80, 443]\nsec:\n\tx: 1\nport: 1\nport: 2\n";
		shcl_datetime month13;
		memset(&month13, 0, sizeof month13);
		month13.has_date = 1; month13.year = 2026; month13.month = 13; month13.day = 1;
		char deep[1026]; size_t dn = 0; // 513 segments: "d.d.d..."
		for (size_t i = 0; i < 513; i++) { if (i) deep[dn++] = '.'; deep[dn++] = 'd'; }
		deep[dn] = 0;
		const int64_t two[] = {1, 2}, one[] = {1};
		const double inf_pair[] = {1, INFINITY};
		static const char bad[] = "a\xff" "b";
		const char *const sv[] = {"v"}, *const sbad[] = {"x", bad};
		const size_t svl[] = {1}, sbadl[] = {1, sizeof bad - 1};
		static const struct { const char *path; shcl_set_status want; } sc[] = {
			{"a.b", SHCL_SET_OK}, {"a.c", SHCL_SET_OK}, {"a.b", SHCL_SET_OK},
			{"", SHCL_SET_BAD_PATH}, {"a..b", SHCL_SET_BAD_PATH}, {"a.b: 2", SHCL_SET_VALUE_IN_PATH},
			{"a(*).b", SHCL_SET_WILDCARD}, {"a(5).b", SHCL_SET_NO_SUCH_INDEX}, {NULL, SHCL_SET_TOO_DEEP},
			{"port", SHCL_SET_MULTIPLE}, {"ports.x", SHCL_SET_UNDER_ARRAY}, {"ports.x.y", SHCL_SET_UNDER_ARRAY},
			{"ports.x", SHCL_SET_UNDER_ARRAY}, {"ports.x", SHCL_SET_UNDER_ARRAY},
			{"sec", SHCL_SET_HAS_CHILDREN}, {"sec", SHCL_SET_HAS_CHILDREN}, {"sec", SHCL_SET_HAS_CHILDREN},
			{"f", SHCL_SET_NOT_FINITE}, {"f", SHCL_SET_NOT_FINITE}, {"a.b", SHCL_SET_NOT_FINITE},
			{"t", SHCL_SET_BAD_DATETIME},
			{"r", SHCL_SET_BAD_RAW_INFO}, {"r", SHCL_SET_BAD_RAW_INFO}, {"a.b", SHCL_SET_BAD_RAW_INFO},
			{"r", SHCL_SET_BAD_RAW_BODY}, {"sec.x", SHCL_SET_BAD_COMMENT},
			{"l", SHCL_SET_NOT_ONE_VALUE}, {"l", SHCL_SET_NOT_ONE_VALUE}, {"l", SHCL_SET_NOT_ONE_VALUE}, {"a.b", SHCL_SET_NOT_ONE_VALUE},
			// Both halves wrong: the path's reason.
			{"a(*).b", SHCL_SET_WILDCARD}, {"ports.x", SHCL_SET_UNDER_ARRAY}, {"a..b", SHCL_SET_BAD_PATH},
			{"a(5).b", SHCL_SET_NO_SUCH_INDEX}, {"port", SHCL_SET_MULTIPLE}, {"port", SHCL_SET_MULTIPLE},
			// C's own: text that is not UTF-8. It wins over the other value
			// reasons, and a path's reason still wins over it.
			{"s", SHCL_SET_NOT_UTF8}, {"s", SHCL_SET_NOT_UTF8}, {"s", SHCL_SET_NOT_UTF8}, {"s", SHCL_SET_NOT_UTF8},
			{"sec.x", SHCL_SET_NOT_UTF8}, {"sec.x", SHCL_SET_NOT_UTF8},
			{"r", SHCL_SET_NOT_UTF8}, {"r", SHCL_SET_NOT_UTF8}, {"r", SHCL_SET_NOT_UTF8}, {"a.b", SHCL_SET_NOT_UTF8},
			{"port", SHCL_SET_MULTIPLE}, {"a\xff" ".b", SHCL_SET_BAD_PATH}, {"a\xff" ".b", SHCL_SET_BAD_PATH},
			// A name or selector that is not UTF-8, from
			// setters_refuse_text_that_is_not_utf8.
			{"\"a\xff" "b\"", SHCL_SET_BAD_PATH}, {"\"a\xff" "b\".x", SHCL_SET_BAD_PATH}, {"srv(a\xff" "b).x", SHCL_SET_BAD_PATH},
			{"srv(\"a\xff" "b\").x", SHCL_SET_BAD_PATH}, {"\"a\xff" "b\"", SHCL_SET_BAD_PATH},
		};
		for (size_t i = 0; i < sizeof sc / sizeof sc[0]; i++) {
			const char *p = sc[i].path ? sc[i].path : deep; size_t pn = strlen(p);
			shcl_doc *sd = shcl_parse(st, strlen(st));
			shcl_str bt = shcl_to_canonical(sd);
			char *before = malloc(bt.n + 1);
			if (!before) { fprintf(stderr, "out of memory\n"); exit(1); }
			memcpy(before, bt.p, bt.n);
			size_t beforen = bt.n;
			shcl_set_status got = SHCL_SET_OK;
			switch (i) {
			case 0: got = shcl_set_int(sd, p, pn, 2); break;
			case 1: got = shcl_set_float(sd, p, pn, 2.5); break;
			case 2: got = shcl_set_int_default(sd, p, pn, 9); break;
			case 3: got = shcl_set_int(sd, p, pn, 1); break;
			case 4: got = shcl_set_string(sd, p, pn, "v", 1); break;
			case 5: case 6: case 7: case 8: got = shcl_set_int(sd, p, pn, 1); break;
			case 9: got = shcl_set_int(sd, p, pn, 9); break;
			case 10: case 11: got = shcl_set_int(sd, p, pn, 1); break;
			case 12: got = shcl_set_comment(sd, p, pn, "c", 1); break;
			case 13: got = shcl_set_int_default(sd, p, pn, 1); break;
			case 14: got = shcl_set_int_array(sd, p, pn, two, 2); break;
			case 15: got = shcl_set_string_array(sd, p, pn, sv, svl, 1); break;
			case 16: got = shcl_set_literal(sd, p, pn, "[1, 2]", 6); break;
			case 17: got = shcl_set_float(sd, p, pn, NAN); break;
			case 18: got = shcl_set_float_array(sd, p, pn, inf_pair, 2); break;
			case 19: got = shcl_set_float_default(sd, p, pn, NAN); break;
			case 20: got = shcl_set_datetime(sd, p, pn, &month13); break;
			case 21: got = shcl_set_raw(sd, p, pn, "body", 4, "sh # x", 6); break;
			case 22: got = shcl_set_raw(sd, p, pn, "body", 4, "sh\nx", 4); break;
			case 23: got = shcl_set_raw_default(sd, p, pn, "body", 4, "sh # x", 6); break;
			case 24: got = shcl_set_raw(sd, p, pn, "a\r\nb", 4, "", 0); break;
			case 25: got = shcl_set_comment(sd, p, pn, "a\nb", 3); break;
			case 26: got = shcl_set_literal(sd, p, pn, "a, b", 4); break;
			case 27: got = shcl_set_literal(sd, p, pn, "\"abc", 4); break;
			case 28: got = shcl_set_literal(sd, p, pn, "a\nb", 3); break;
			case 29: got = shcl_set_literal_default(sd, p, pn, "a, b", 4); break;
			case 30: got = shcl_set_float(sd, p, pn, NAN); break;
			case 31: got = shcl_set_literal(sd, p, pn, "a, b", 4); break;
			case 32: got = shcl_set_comment(sd, p, pn, "a\nb", 3); break;
			case 33: got = shcl_set_raw(sd, p, pn, "x", 1, "#", 1); break;
			case 34: got = shcl_set_int_array(sd, p, pn, one, 1); break;
			case 35: got = shcl_set_float_default(sd, p, pn, NAN); break;
			case 36: got = shcl_set_string(sd, p, pn, bad, sizeof bad - 1); break;
			case 37: got = shcl_set_string_array(sd, p, pn, sbad, sbadl, 2); break;
			case 38: got = shcl_set_literal(sd, p, pn, bad, sizeof bad - 1); break;
			case 39: got = shcl_set_literal(sd, p, pn, "a\xff, b", 5); break;
			case 40: got = shcl_set_comment(sd, p, pn, bad, sizeof bad - 1); break;
			case 41: got = shcl_set_comment(sd, p, pn, "a\xff\nb", 4); break;
			case 42: got = shcl_set_raw(sd, p, pn, bad, sizeof bad - 1, "", 0); break;
			case 43: got = shcl_set_raw(sd, p, pn, "body", 4, "sh\xff", 3); break;
			case 44: got = shcl_set_raw(sd, p, pn, "a\xff\r\nb", 5, "#", 1); break;
			case 45: got = shcl_set_string_default(sd, p, pn, bad, sizeof bad - 1); break;
			case 46: got = shcl_set_string(sd, p, pn, bad, sizeof bad - 1); break;
			case 47: got = shcl_set_int(sd, p, pn, 1); break;
			case 48: got = shcl_set_string(sd, p, pn, bad, sizeof bad - 1); break;
			case 53: got = shcl_set_comment(sd, p, pn, "c", 1); break;
			default: got = shcl_set_int(sd, p, pn, 1); break;
			}
			char what[96];
			snprintf(what, sizeof what, "case %zu: got %s, want %s", i, shcl_set_status_name(got), shcl_set_status_name(sc[i].want));
			if (got != sc[i].want) fail("setter_status", what);
			shcl_doc *cd = shcl_parse(st, strlen(st));
			shcl_set_status checked = shcl_check_set_path(cd, p, pn);
			shcl_free(cd);
			int path_reason = sc[i].want != SHCL_SET_OK && sc[i].want <= SHCL_SET_UNDER_ARRAY;
			if (path_reason ? checked != sc[i].want : checked != SHCL_SET_OK) fail("setter_status", what);
			shcl_str after = shcl_to_canonical(sd);
			if (got != SHCL_SET_OK && (after.n != beforen || memcmp(after.p, before, beforen) != 0)) fail("setter_status", what);
			free(before);
			shcl_free(sd);
		}
	}
	test_id("EsDjsxk", "setter_status_agrees_with_the_path_check");
	setter_status_agrees_with_the_path_check();
	// Both halves of a path can contain a line break and write it \n: a name
	// through the name escaper, a selector value through the value emitter. The
	// selector was refused while elements were stored in their source spelling
	// and the emitter had nothing to escape with. Same fixture in every runner.
	test_id("EpGigIO", "a_line_break_in_a_path_writes_and_reads_back");
	{
		shcl_doc *nd = shcl_parse("z: 0\n", 5);
		if (shcl_set_int(nd, "x(\"p\nq\").c", sizeof "x(\"p\nq\").c" - 1, 1) != SHCL_SET_OK
			|| shcl_set_int(nd, "\"a\nb\".c", sizeof "\"a\nb\".c" - 1, 1) != SHCL_SET_OK)
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
			if (shcl_read_int(nb, "x(\"p◉NEWLINE◉q\").c", sizeof "x(\"p◉NEWLINE◉q\").c" - 1).value != 1
				|| shcl_read_int(nb, "\"a◉NEWLINE◉b\".c", sizeof "\"a◉NEWLINE◉b\".c" - 1).value != 1
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
			if (shcl_set_float(sd, "f", 1, nonfinite[i]) != SHCL_SET_NOT_FINITE || shcl_set_float_default(sd, "f", 1, nonfinite[i]) != SHCL_SET_NOT_FINITE || shcl_set_float_array(sd, "f", 1, pair, 2) != SHCL_SET_NOT_FINITE)
				fail("setters_refuse", "a non-finite float was written, or not as NOT_FINITE");
			// A default form on a path that is already there writes nothing, and
			// still refuses what the plain setter would.
			if (shcl_set_float_default(sd, "z", 1, nonfinite[i]) != SHCL_SET_NOT_FINITE || shcl_set_float_array_default(sd, "z", 1, pair, 2) != SHCL_SET_NOT_FINITE)
				fail("setters_refuse", "a non-finite float passed a default form on a present path");
		}
		if (shcl_set_float(sd, "f", 1, 2.5) != SHCL_SET_OK || shcl_get_float_or(sd, "f", 1, 0) != 2.5) fail("setters_refuse", "a finite float was refused");
		if (shcl_set_float_default(sd, "z", 1, 2.5) != SHCL_SET_OK || shcl_get_float_or(sd, "z", 1, 1) != 0) fail("setters_refuse", "a finite float default on a present path was refused or written");
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
			if (shcl_set_datetime(sd, "d", 1, &bad[i]) != SHCL_SET_BAD_DATETIME || shcl_set_datetime_default(sd, "d", 1, &bad[i]) != SHCL_SET_BAD_DATETIME || shcl_set_datetime_array(sd, "d", 1, pair, 2) != SHCL_SET_BAD_DATETIME)
				fail("setters_refuse", "a datetime the reader refuses was written, or not as BAD_DATETIME");
			if (shcl_set_datetime_default(sd, "z", 1, &bad[i]) != SHCL_SET_BAD_DATETIME || shcl_set_datetime_array_default(sd, "z", 1, pair, 2) != SHCL_SET_BAD_DATETIME)
				fail("setters_refuse", "a datetime the reader refuses passed a default form on a present path");
		}
		shcl_datetime ok = good; ok.day = 2; ok.has_time = 1; ok.hour = 3; ok.minute = 4; ok.has_sec = 1; ok.sec = 5; ok.has_frac = 1; ok.frac = s_lit("60"); ok.zone = SHCL_ZONE_OFFSET; ok.off_min = -90;
		if (shcl_set_datetime(sd, "d", 1, &ok) != SHCL_SET_OK) fail("setters_refuse", "a valid datetime was refused");
		shcl_read_dt rd = shcl_read_datetime(sd, "d", 1);
		char okb[SHCL_DT_BUF], rdb[SHCL_DT_BUF]; size_t okn = shcl_datetime_str(&ok, okb), rdn = shcl_datetime_str(&rd.value, rdb);
		if (rd.status != SHCL_GOOD || okn != rdn || memcmp(okb, rdb, okn) != 0) fail("setters_refuse", "the datetime read back differently");
		shcl_str canon = shcl_to_canonical(sd);
		const char *want = "z: 0\n\nf: 2.5\n\nd: \"2026-01-02T03:04:05.60-01:30\"\n";
		if (canon.n != strlen(want) || memcmp(canon.p, want, canon.n) != 0) fail("setters_refuse", "document after the refusals differs");
		shcl_free(sd);
	}
	test_id("EryvVQj", "a_backtick_value_reads_raw_with_its_flag");
	{
		// A backtick value is raw text the program decodes itself: read as
		// written, with its own flag beside shcl_quoted. A setter keeps the
		// backticks when the new text fits in them, and the writer picks quotes
		// when it does not. Same fixture in every runner.
		const char *bt = "c: `#FF8800`\nq: \"x\"\nb: x\na: [`1`, b]\nn: `7`\n";
		shcl_doc *bd = shcl_parse(bt, strlen(bt));
		shcl_read_str br = shcl_read_string(bd, "c", 1);
		if (br.status != SHCL_GOOD || br.value.n != 7 || memcmp(br.value.p, "#FF8800", 7) != 0 || !shcl_quoted(bd, "c", 1) || !shcl_backtick(bd, "c", 1)) fail("backtick", "c");
		if (!shcl_quoted(bd, "q", 1) || shcl_backtick(bd, "q", 1)) fail("backtick", "q");
		if (shcl_quoted(bd, "b", 1) || shcl_backtick(bd, "b", 1)) fail("backtick", "b");
		shcl_read_str_arr ba = shcl_read_string_array(bd, "a", 1);
		if (ba.n != 2 || shcl_quoted(bd, "a", 1) || shcl_backtick(bd, "a", 1)) fail("backtick", "a");
		shcl_read_i64 bi = shcl_read_int(bd, "n", 1);
		if (bi.status != SHCL_GOOD || bi.value != 7 || !shcl_backtick(bd, "n", 1)) fail("backtick", "n");
		if (shcl_set_string(bd, "c", 1, "#00FF00", 7) != SHCL_SET_OK || !shcl_backtick(bd, "c", 1)) fail("backtick", "an overwrite lost the backticks");
		if (shcl_set_string(bd, "c", 1, "a`b", 3) != SHCL_SET_OK || shcl_backtick(bd, "c", 1)) fail("backtick", "a backtick value holding a backtick");
		shcl_str bc = shcl_to_canonical(bd);
		if (bc.n < 9 || memcmp(bc.p, "c: \"a`b\"\n", 9) != 0) fail("backtick", "the fixture wrote other text");
		shcl_free(bd);
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
		// Strict fails here as after shcl_parse_with (2026100717500012).
		shcl_doc *sd = shcl_load_and_validate(ot, strlen(ot), os, strlen(os), SHCL_STRICT);
		if (shcl_error_count(sd) < 2) fail("oneshot", "strict error_count < 2");
		if (!shcl_strict_failed(sd)) fail("oneshot", "strict load did not fail");
		shcl_free(sd);
		// An empty schema declares nothing and validates nothing.
		shcl_doc *pd = shcl_load_and_validate("a: 1\n", 5, "", 0, SHCL_STANDARD);
		if (shcl_error_count(pd) != 0 || shcl_diag_count(pd) != 0) fail("oneshot", "plain doc not clean");
		shcl_free(pd);
	}
	// Strict fails the load on any error diagnostic, from every entry point.
	// In C that is shcl_strict_failed on the document each one hands back;
	// the file status stays HadErrors. Same fixture in every runner.
	test_id("Es9mP97", "strict_fails_the_same_from_every_entry_point");
	{
		char sdir[256], sfile[288], snone[288];
		snprintf(sdir, sizeof sdir, "%s/shcl-strictsame-%ld", tmp_root(), (long)getpid());
#ifdef _WIN32
		if (_mkdir(sdir) != 0) fail("strict_same", "mkdir failed");
#else
		if (mkdir(sdir, 0700) != 0) fail("strict_same", "mkdir failed");
#endif
		snprintf(sfile, sizeof sfile, "%s/t.shcl", sdir);
		snprintf(snone, sizeof snone, "%s/none.shcl", sdir);
		const char *st = ": nope\nport: 1\n";
		const char *ss = "field: port\n\ttype: int\n";
		FILE *sf = fopen(sfile, "wb");
		if (!sf || fputs(st, sf) == EOF || fclose(sf) != 0) fail("strict_same", "seed write failed");
		const char *entries[] = {"parse_with", "parse_limited", "parse_keep_lines", "load_and_validate", "load_file_with", "load_file_keep_lines"};
		for (int lv = 0; lv < 2; lv++) {
			shcl_strictness level = lv ? SHCL_STRICT : SHCL_STANDARD;
			shcl_file_status fs1 = SHCL_FILE_CLEAN, fs2 = SHCL_FILE_CLEAN;
			shcl_doc *docs[6] = {
				shcl_parse_with(st, strlen(st), level),
				shcl_parse_limited(st, strlen(st), level, 0, 0, 0),
				shcl_parse_keep_lines(st, strlen(st), level),
				shcl_load_and_validate(st, strlen(st), ss, strlen(ss), level),
				shcl_load_file_with(sfile, level, &fs1),
				shcl_load_file_keep_lines(sfile, level, &fs2),
			};
			for (int k = 0; k < 6; k++) {
				if (!docs[k]) { fail("strict_same", entries[k]); continue; }
				if (shcl_strict_failed(docs[k]) != lv) fail("strict_same", entries[k]);
				if (shcl_diag_count(docs[k]) != 1 || strcmp(shcl_diag_code(docs[k], 0), "E014")) fail("strict_same", entries[k]);
				if (shcl_get_int_or(docs[k], "port", 4, 0) != 1) fail("strict_same", entries[k]);
				shcl_free(docs[k]);
			}
			if (fs1 != SHCL_FILE_HAD_ERRORS || fs2 != SHCL_FILE_HAD_ERRORS) fail("strict_same", "file status");
			// A file that could not be read has no diagnostics, so Strict
			// gives its status like any other level.
			shcl_doc *nd = shcl_load_file_with(snone, level, &fs1);
			if (fs1 != SHCL_FILE_NOT_FOUND || !nd || shcl_strict_failed(nd)) fail("strict_same", "missing file");
			shcl_free(nd);
			nd = shcl_load_file_keep_lines(snone, level, &fs2);
			if (fs2 != SHCL_FILE_NOT_FOUND || !nd || shcl_strict_failed(nd)) fail("strict_same", "missing file, keep lines");
			shcl_free(nd);
		}
		// A schema finding is an error in the same list, so it fails the
		// one-shot at Strict too.
		shcl_doc *vd = shcl_load_and_validate("port: x\n", 8, ss, strlen(ss), SHCL_STRICT);
		if (!vd || !shcl_strict_failed(vd) || shcl_diag_count(vd) != 1 || strcmp(shcl_diag_code(vd, 0), "V003")) fail("strict_same", "schema finding");
		shcl_free(vd);
		dir_clear(sdir);
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
	// The quote never closes, so the max line is lost and a parse then
	// validate passed 99999 with no word. Same fixture in every runner.
	test_id("Es8Oq5E", "validate_and_generate_report_a_broken_schema");
	{
		const char *qs = "field: port\n\ttype: int\n\tmax: \"65535\n";
		shcl_doc *qschema = shcl_parse(qs, strlen(qs));
		shcl_doc *qdoc = shcl_parse("port: 99999\n", 12);
		shcl_validation *qv = shcl_validate(qdoc, qschema);
		if (!qv || shcl_validation_count(qv) != 1) fail("validate_broken", "want a lone V099");
		else if (strcmp(shcl_validation_code(qv, 0), "V099") || shcl_validation_line(qv, 0) != 0 || shcl_validation_severity(qv, 0) != SHCL_SEV_ERROR) fail("validate_broken", "code not V099 at line 0");
		shcl_validation_free(qv);
		size_t before = shcl_diag_count(qschema);
		int ok = 1;
		shcl_str qt = shcl_generate(qschema, 1, &ok);
		if (ok || qt.n != 0) fail("validate_broken", "generate wrote a starter");
		if (shcl_diag_count(qschema) != before + 1 || strcmp(shcl_diag_code(qschema, before), "V099")) fail("validate_broken", "generate fault not a lone V099");
		shcl_free(qdoc); shcl_free(qschema);
		// A document that came through shcl_load_and_validate holds V codes of
		// its own, and they are not load errors when it is used as a schema.
		shcl_doc *checked = shcl_load_and_validate("field: port\n", 12, "field: other\n", 13, SHCL_STANDARD);
		if (shcl_diag_count(checked) == 0 || strcmp(shcl_diag_code(checked, 0), "V001")) fail("validate_broken", "checked schema: want V001 first");
		shcl_doc *pd = shcl_parse("port: 1\n", 8);
		shcl_validation *pv = shcl_validate(pd, checked);
		if (!pv || shcl_validation_count(pv) != 0) fail("validate_broken", "checked schema as a schema not clean");
		shcl_validation_free(pv); shcl_free(pd); shcl_free(checked);
		// So are the faults a failed shcl_generate records on its schema: the
		// same handle still validates with its V090 and surviving constraints.
		const char *fs = "field: port\n\ttype: int\n\tfrobnicate: 1\n";
		shcl_doc *fschema = shcl_parse(fs, strlen(fs));
		shcl_generate(fschema, 1, &ok);
		if (ok) fail("validate_broken", "generate passed a V090 schema");
		shcl_doc *fd = shcl_parse("port: x\n", 8);
		shcl_validation *fv = shcl_validate(fd, fschema);
		if (!fv || shcl_validation_count(fv) != 2 || strcmp(shcl_validation_code(fv, 0), "V090") || strcmp(shcl_validation_code(fv, 1), "V003")) fail("validate_broken", "validate after a failed generate not V090, V003");
		shcl_validation_free(fv); shcl_free(fd); shcl_free(fschema);
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
		if (shcl_set_literal(zd, "l", 1, NULL, 0) != SHCL_SET_OK) fail("null_span", "set_literal refused (NULL, 0)");
		if (shcl_set_raw(zd, "r", 1, NULL, 0, NULL, 0) != SHCL_SET_OK) fail("null_span", "set_raw refused (NULL, 0)");
		if (shcl_set_literal_default(zd, "l2", 2, NULL, 0) != SHCL_SET_OK) fail("null_span", "set_literal_default refused (NULL, 0)");
		if (shcl_set_raw_default(zd, "r2", 2, NULL, 0, NULL, 0) != SHCL_SET_OK) fail("null_span", "set_raw_default refused (NULL, 0)");
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
		// FreeBSD allows 2 KB, too small for the loader's own lazy binding.
		// The old array was 16 KB, so that size still catches it.
		if (small < 16384) small = 16384;
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
			if (shcl_save_file(dd, dpath, NULL) == SHCL_SAVE_OK) fail("dirpath", "a directory-shaped path was accepted");
		}
		size_t dn; char *dt = read_file(dfile, &dn);
		if (!dt || dn != 5 || memcmp(dt, "a: 1\n", 5) != 0) fail("dirpath", "a refused save changed the file");
		free(dt);
		if (shcl_save_file(dd, dfile, NULL) != SHCL_SAVE_OK) fail("dirpath", "the plain path did not save");
		shcl_free(dd);
		remove(dfile); rmdir(ddir);
	}

	/* Every reason a write gives, in the order every binding numbers them,
	   and the names the other three print. Same fixture in every runner. */
	test_id("EsEhCG9", "write_status_values_in_order");
	{
		static const shcl_write_status all[] = {
			SHCL_WRITE_OK, SHCL_WRITE_NOT_FOUND, SHCL_WRITE_UNREADABLE, SHCL_WRITE_PERMISSION_DENIED,
			SHCL_WRITE_DISK_FULL, SHCL_WRITE_READ_ONLY, SHCL_WRITE_IS_DIRECTORY, SHCL_WRITE_NOT_REGULAR, SHCL_WRITE_OTHER,
		};
		static const char *const wnames[] = {
			"Ok", "NotFound", "Unreadable", "PermissionDenied", "DiskFull", "ReadOnly", "IsDirectory", "NotRegular", "Other",
		};
		if (sizeof all / sizeof all[0] != sizeof wnames / sizeof wnames[0]) fail("write_status_order", "a value and its name are not one to one");
		for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) {
			if ((size_t)all[i] != i) fail("write_status_order", wnames[i]);
			if (strcmp(shcl_write_status_name(all[i]), wnames[i]) != 0) fail("write_status_order", wnames[i]);
		}
	}
	/* A failed write says why as a value, beside errno: from
	   shcl_write_file_atomic, a save, shcl_write_backup and shcl_upgrade_file.
	   A full disk and a read-only filesystem can't be made here without root;
	   the table test below maps those. Same fixture in every runner. */
	test_id("EsEhCGA", "write_status_names_each_failure");
	{
		char wdir[256], wp[400], wmissing[400];
		snprintf(wdir, sizeof wdir, "%s/shcl-wrstat-%ld", tmp_root(), (long)getpid());
		snprintf(wmissing, sizeof wmissing, "%s/nope/t.shcl", wdir);
#ifdef _WIN32
		if (_mkdir(wdir) != 0) fail("write_status", "mkdir failed");
		snprintf(wp, sizeof wp, "%s/sub", wdir);
		if (_mkdir(wp) != 0) fail("write_status", "mkdir failed");
#else
		if (mkdir(wdir, 0700) != 0) fail("write_status", "mkdir failed");
		snprintf(wp, sizeof wp, "%s/sub", wdir);
		if (mkdir(wp, 0700) != 0) fail("write_status", "mkdir failed");
#endif
		shcl_write_status why = SHCL_WRITE_OTHER;
		snprintf(wp, sizeof wp, "%s/ok.shcl", wdir);
		if (!shcl_write_file_atomic(wp, "a: 1\n", 5, &why) || why != SHCL_WRITE_OK) fail("write_status", "a plain write");
		why = SHCL_WRITE_OK;
		if (shcl_write_file_atomic(wmissing, "a: 1\n", 5, &why) || why != SHCL_WRITE_NOT_FOUND || errno != ENOENT) fail("write_status", "into a missing folder");
		shcl_doc *wd = shcl_parse("a: 1\n", 5);
		why = SHCL_WRITE_OK;
		if (shcl_save_file(wd, wmissing, &why) != SHCL_SAVE_FAILED || why != SHCL_WRITE_NOT_FOUND) fail("write_status", "save into a missing folder");
		why = SHCL_WRITE_OK;
		if (shcl_save_file_lossy(wd, wmissing, &why) != SHCL_SAVE_FAILED || why != SHCL_WRITE_NOT_FOUND) fail("write_status", "lossy save into a missing folder");
		shcl_doc *wk = shcl_parse_keep_lines("a: 1\n", 5, SHCL_STANDARD);
		why = SHCL_WRITE_OK;
		if (shcl_save_file_keep_lines(wk, wmissing, NULL, &why) != SHCL_SAVE_FAILED || why != SHCL_WRITE_NOT_FOUND) fail("write_status", "kept save into a missing folder");
		shcl_free(wk);
		/* A refusal is no write failure. */
		shcl_doc *wl = shcl_parse("a:\n\t\tb: 1\n\tc: 2\n", 16);
		why = SHCL_WRITE_OTHER;
		if (shcl_save_file(wl, wmissing, &why) != SHCL_SAVE_REFUSED || why != SHCL_WRITE_OK) fail("write_status", "a refusal");
		shcl_free(wl);
		/* Part of the path is a file: the folder isn't there either. */
		snprintf(wp, sizeof wp, "%s/ok.shcl/t.shcl", wdir);
		why = SHCL_WRITE_OK;
		if (shcl_write_file_atomic(wp, "a: 1\n", 5, &why) || why != SHCL_WRITE_NOT_FOUND) fail("write_status", "under a file");
		snprintf(wp, sizeof wp, "%s/sub", wdir);
		why = SHCL_WRITE_OK;
		if (shcl_write_file_atomic(wp, "a: 1\n", 5, &why) || why != SHCL_WRITE_IS_DIRECTORY) fail("write_status", "over a directory");
		shcl_upgraded wup;
		why = SHCL_WRITE_OK;
		if (shcl_upgrade_file(wp, 0, &wup, NULL, &why) != SHCL_UPGRADE_IO || why != SHCL_WRITE_IS_DIRECTORY) fail("write_status", "upgrade of a directory");
		shcl_upgraded_free(&wup);
		snprintf(wp, sizeof wp, "%s/ok.shcl/", wdir);
		why = SHCL_WRITE_OK;
		if (shcl_write_file_atomic(wp, "a: 1\n", 5, &why) || why != SHCL_WRITE_IS_DIRECTORY) fail("write_status", "through a trailing separator");
		snprintf(wp, sizeof wp, "%s/bin.shcl", wdir);
		if (!shcl_write_file_atomic(wp, "a: \xff\n", 5, NULL)) fail("write_status", "seed write failed");
		why = SHCL_WRITE_OK;
		if (shcl_upgrade_file(wp, 0, &wup, NULL, &why) != SHCL_UPGRADE_IO || why != SHCL_WRITE_UNREADABLE) fail("write_status", "upgrade of a file that is not UTF-8");
		shcl_upgraded_free(&wup);
		remove(wp);
		snprintf(wp, sizeof wp, "%s/ok.shcl", wdir);
		remove(wp);
		snprintf(wp, sizeof wp, "%s/sub", wdir);
		rmdir(wp);
#ifndef _WIN32
		snprintf(wp, sizeof wp, "%s/p.shcl", wdir);
		if (mkfifo(wp, 0600) != 0) fail("write_status", "mkfifo failed");
		why = SHCL_WRITE_OK;
		if (shcl_write_file_atomic(wp, "a: 1\n", 5, &why) || why != SHCL_WRITE_NOT_REGULAR) fail("write_status", "over a FIFO");
		why = SHCL_WRITE_OK;
		if (shcl_upgrade_file(wp, 0, &wup, NULL, &why) != SHCL_UPGRADE_IO || why != SHCL_WRITE_NOT_REGULAR) fail("write_status", "upgrade of a FIFO");
		shcl_upgraded_free(&wup);
		remove(wp);
		/* root writes anyway, so the rows wait for a probe that is refused. */
		char shut[300], v2[340];
		snprintf(shut, sizeof shut, "%s/shut", wdir);
		snprintf(v2, sizeof v2, "%s/v2.shcl", shut);
		if (mkdir(shut, 0700) != 0) fail("write_status", "mkdir failed");
		if (!shcl_write_file_atomic(v2, "x: a,b\n", 7, NULL)) fail("write_status", "seed write failed");
		if (chmod(shut, 0500) != 0) fail("write_status", "chmod failed");
		snprintf(wp, sizeof wp, "%s/probe", shut);
		FILE *probe = fopen(wp, "wb");
		if (probe) {
			fclose(probe);
			remove(wp);
		} else {
			snprintf(wp, sizeof wp, "%s/t.shcl", shut);
			why = SHCL_WRITE_OK;
			if (shcl_write_file_atomic(wp, "a: 1\n", 5, &why) || why != SHCL_WRITE_PERMISSION_DENIED) fail("write_status", "into a shut folder");
			why = SHCL_WRITE_OK;
			if (shcl_write_backup(v2, "x: a,b\n", 7, 2, NULL, NULL, &why) != SHCL_UPGRADE_IO || why != SHCL_WRITE_PERMISSION_DENIED) fail("write_status", "backup into a shut folder");
			why = SHCL_WRITE_OK;
			if (shcl_upgrade_file(v2, 1, &wup, NULL, &why) != SHCL_UPGRADE_IO || why != SHCL_WRITE_PERMISSION_DENIED) fail("write_status", "upgrade in a shut folder");
			shcl_upgraded_free(&wup);
		}
		if (chmod(shut, 0700) != 0) fail("write_status", "chmod back failed");
		remove(v2);
		rmdir(shut);
#endif
		shcl_free(wd);
		rmdir(wdir);
	}
	/* The table from errno to a write's reason, and on windows from the
	   system's code through shcl_errno_from_win32. Most rows can't be made to
	   happen on a test box: a full disk, a read-only mount, a file held open. */
	test_id("EsEhCGB", "write_status_of_errno");
	{
		static const struct { int e; shcl_write_status want; } rows[] = {
			{ ENOENT, SHCL_WRITE_NOT_FOUND }, { ENOTDIR, SHCL_WRITE_NOT_FOUND },
			{ EACCES, SHCL_WRITE_PERMISSION_DENIED }, { EPERM, SHCL_WRITE_PERMISSION_DENIED },
			{ ENOSPC, SHCL_WRITE_DISK_FULL }, { EROFS, SHCL_WRITE_READ_ONLY }, { EISDIR, SHCL_WRITE_IS_DIRECTORY },
			{ EIO, SHCL_WRITE_OTHER }, { EEXIST, SHCL_WRITE_OTHER }, { EINVAL, SHCL_WRITE_OTHER },
#ifdef EDQUOT
			{ EDQUOT, SHCL_WRITE_DISK_FULL },
#endif
		};
		for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++)
			if (s_write_status_of(rows[i].e) != rows[i].want) fail("write_status_of", strerror(rows[i].e));
#ifdef _WIN32
		static const struct { DWORD code; shcl_write_status want; } wrows[] = {
			{ 2, SHCL_WRITE_NOT_FOUND }, { 3, SHCL_WRITE_NOT_FOUND }, { 15, SHCL_WRITE_NOT_FOUND }, { 53, SHCL_WRITE_NOT_FOUND },
			{ 67, SHCL_WRITE_NOT_FOUND }, { 267, SHCL_WRITE_NOT_FOUND },
			{ 5, SHCL_WRITE_PERMISSION_DENIED }, { 32, SHCL_WRITE_PERMISSION_DENIED }, { 33, SHCL_WRITE_PERMISSION_DENIED },
			{ 1224, SHCL_WRITE_PERMISSION_DENIED },
			{ 39, SHCL_WRITE_DISK_FULL }, { 112, SHCL_WRITE_DISK_FULL }, { 1295, SHCL_WRITE_DISK_FULL },
			{ 19, SHCL_WRITE_READ_ONLY }, { 1117, SHCL_WRITE_OTHER },
		};
		for (size_t i = 0; i < sizeof wrows / sizeof wrows[0]; i++)
			if (s_write_status_of(shcl_errno_from_win32(wrows[i].code)) != wrows[i].want) fail("write_status_of", "a windows code");
#endif
	}

	/* A written value with both quote kinds is stored the way its own
	   reload stores it, so shcl_instances and a read's raw text agree across a
	   save. The emitter escapes the double quotes; the writer used to keep them
	   bare. Same fixture in every runner. */
	test_id("EommtF4", "written_spelling_matches_its_reload");
	{
		shcl_doc *wd = shcl_parse("x: 1\n", 5);
		if (shcl_set_string(wd, "k", 1, "q\"q'", 4) != SHCL_SET_OK) fail("written_spelling", "set_string refused");
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
				int applied = soup_set(sd, kind, "k", 1, in, inn) == SHCL_SET_OK;
				if (applied) {
					char sp[24]; int spn = snprintf(sp, sizeof sp, "k%zu", ++slot);
					if (soup_set(every, kind, sp, (size_t)spn, in, inn) != SHCL_SET_OK) soup_fail("a slot refused what k took", kind, in, inn);
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
			int wrote = shcl_set_string(nd, qp, qn, "v", 1) == SHCL_SET_OK;
			if (wrote && shcl_set_string(every, qp, qn, "v", 1) != SHCL_SET_OK) soup_fail("the name was refused the second time", -1, in, inn);
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
		if (shcl_save_file(every, ef, NULL) != SHCL_SAVE_OK) fail("setters_read_back", "every accepted write together would not save");
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
	test_id("EsEtTdS", "stamp_reads_say_why");
	/* The Format and Schema lines read with a status, so an unstamped file and
	   a damaged stamp read apart, and the load's H006 and H007 hints say the
	   same as the Format read on every row. Rust's stamp_reads_say_why has the
	   same rows. */
	{
		static const struct { const char *text; int64_t value; shcl_status status; size_t line; const char *hint; } ft[] = {
			{"a: 1\n", 0, SHCL_NOT_FOUND, 0, ""},
			{"a: 1\n##    Format   3\n", 3, SHCL_GOOD, 2, ""},
			{"##    Format   4\na: 1\n", 4, SHCL_GOOD, 1, "H006"},
			{"a: 1\n##    Format   2\n", 2, SHCL_GOOD, 2, "H007"},
			{"a: 1\n##    Format   3x\n", 0, SHCL_BAD_TYPE, 2, ""},
			{"a: 1\n##    Format\n", 0, SHCL_EMPTY, 2, ""},
			{"a: 1\n##    Format   \n", 0, SHCL_EMPTY, 2, ""},
			{"##    Format   x\n##    Format   2\n", 2, SHCL_GOOD, 2, "H007"},
			{"note: ~~~\n##    Format   4\n~~~\n", 0, SHCL_NOT_FOUND, 0, ""},
			{"a: 1\n##    Format  3\n", 0, SHCL_NOT_FOUND, 0, ""},
			{"\xEF\xBB\xBF##    Format   5\n", 5, SHCL_GOOD, 1, "H006"},
			{"##    Format   4294967296\n", SHCL_FORMAT_MAJOR, SHCL_GOOD, 1, ""},
			{"a:\n\t##    Format   1\n\tb: 1\n", 1, SHCL_GOOD, 2, "H007"},
		};
		for (size_t k = 0; k < sizeof ft / sizeof ft[0]; k++) {
			size_t n = strlen(ft[k].text);
			shcl_read_i64 r = shcl_read_format_version(ft[k].text, n);
			if (r.value != ft[k].value || r.status != ft[k].status) fail("stamp_reads_say_why", ft[k].text);
			if (shcl_format_version(ft[k].text, n) != (ft[k].status == SHCL_GOOD ? ft[k].value : -1)) fail("stamp_reads_say_why", ft[k].text);
			shcl_doc *hd = shcl_parse(ft[k].text, n);
			size_t hints = 0;
			for (size_t i = 0; i < shcl_diag_count(hd); i++) {
				const char *code = shcl_diag_code(hd, i);
				if (strcmp(code, "H006") && strcmp(code, "H007")) continue;
				hints++;
				if (strcmp(code, ft[k].hint) || shcl_diag_line(hd, i) != ft[k].line) fail("stamp_reads_say_why", ft[k].text);
			}
			if (hints != (ft[k].hint[0] ? 1u : 0u)) fail("stamp_reads_say_why", ft[k].text);
			shcl_free(hd);
		}
		static const struct { const char *text; const char *ref; shcl_status status; } st[] = {
			{"a: 1\n", "", SHCL_NOT_FOUND},
			{"##    Schema   ./s.shcl\n", "./s.shcl", SHCL_GOOD},
			{"##    Schema\na: 1\n", "", SHCL_EMPTY},
			{"##    Schema   \n##    Schema   b.shcl\n", "b.shcl", SHCL_GOOD},
			{"x: ~~~\n##    Schema   a\n~~~\n", "", SHCL_NOT_FOUND},
		};
		for (size_t k = 0; k < sizeof st / sizeof st[0]; k++) {
			size_t n = strlen(st[k].text), rn = 99;
			shcl_read_str r = shcl_read_schema_ref(st[k].text, n);
			if (r.status != st[k].status || r.value.n != strlen(st[k].ref) || memcmp(r.value.p, st[k].ref, r.value.n)) fail("stamp_reads_say_why", st[k].text);
			const char *plain = shcl_schema_ref(st[k].text, n, &rn);
			if ((plain != NULL) != (st[k].status == SHCL_GOOD) || rn != (plain ? strlen(st[k].ref) : 0)) fail("stamp_reads_say_why", st[k].text);
		}
	}
	test_id("EryvVWx", "a_comma_splits_a_bare_value_only_before_a_blank");
	/* A comma splits a value outside brackets only with a blank, a comment or
	   the end after it; inside brackets every one does (value-syntax.md,
	   20261006). 2.x split on every comma, which migrate still reads. */
	{
		static const struct { const char *line; size_t pieces; } ct[] = {
			{"x: rw,noatime", 1}, {"x: ,a", 1}, {"x: a,,b", 1}, {"x: a, b", 2}, {"x: a,", 2},
			{"x: a,# c", 2}, {"x: a,\tb", 2}, {"x: [a,b]", 2}, {"x: [rw,noatime, c]", 3},
		};
		shcl_doc *cd = shcl_new();
		shcl_tokens ctok; memset(&ctok, 0, sizeof ctok);
		for (size_t i = 0; i < sizeof ct / sizeof ct[0]; i++) {
			shcl_tokenize(cd, ct[i].line, strlen(ct[i].line), ':', 0, SHCL_RULES_CURRENT, &ctok);
			if (ctok.nelem != ct[i].pieces) fail("comma_split", ct[i].line);
		}
		shcl_tokenize(cd, "x: a,b", 6, ':', 0, SHCL_RULES_V2, &ctok);
		if (ctok.nelem != 2) fail("comma_split", "2.x");
		shcl_free(cd);
	}
	test_id("EryvVZ4", "bare_spaces_colons_and_commas");
	/* Spaces in a bare value or item are fine. A tab, a bracket, a quote, or a
	   colon or comma with a blank or the end after it is one error, and its
	   message says what to do. */
	{
		static const struct { const char *text, *code, *fix; } bt[] = {
			{"x: host: a.com port: 80\n", "E025", "put each field on its own line"},
			{"x: done:\n", "E025", "quote it"},
			{"x: a\tb\n", "E025", "quote it"},
			{"x: a[b]c\n", "E025", "quote it"},
			{"x: [New York, Boston]\n", "E025", "quote it"},
			{"x: [a:, b]\n", "E025", "quote it"},
			{"x: a,\n", "E026", "write an array in brackets"},
			{"x: 80, 443\n", "E026", "write an array in brackets"},
			{"x: a: b, c\n", "E025", "put each field on its own line"},
			{"x:\n\t- name: value\n", "E027", "as instances"},
			{"x:\n\t- name:\n", "E027", "as instances"},
			{"x:\n\t- a, b\n", "E026", "quote the text"},
			{"x:\n\t- a\tb\n", "E025", "quote it"},
			{"x:\n\t- [a]\n", "E019", "quote the item"},
			{"x(a:b).y: 1\n", "E025", "quote it"},
			{"x(a,b).y: 1\n", "E025", "quote it"},
			{"x(a[b).y: 1\n", "E025", "quote it"},
			{"x(a(b).y: 1\n", "E025", "quote it"},
		};
		for (size_t i = 0; i < sizeof bt / sizeof bt[0]; i++) {
			shcl_doc *bd = shcl_parse(bt[i].text, strlen(bt[i].text));
			if (shcl_diag_count(bd) != 1 || strcmp(shcl_diag_code(bd, 0), bt[i].code) != 0) fail("bare_text", bt[i].text);
			else { shcl_str m = shcl_diag_message(bd, 0); if (!contains(m.p, m.n, bt[i].fix)) fail("bare_text", bt[i].text); }
			shcl_free(bd);
		}
		static const struct { const char *text, *path, *want; } gt[] = {
			{"x: My  App\n", "x", "My  App"},
			{"x: rw,noatime\n", "x", "rw,noatime"},
			{"x: :0\n", "x", ":0"},
			{"x: https://a.com:8080/p?q=1,2\n", "x", "https://a.com:8080/p?q=1,2"},
			{"x: Jul 12 2026  # c\n", "x", "Jul 12 2026"},
			{"x:\n\t- New  York\n\t- :0\n", "x", "[\"New  York\", \":0\"]"},
		};
		for (size_t i = 0; i < sizeof gt / sizeof gt[0]; i++) {
			shcl_doc *gd = shcl_parse(gt[i].text, strlen(gt[i].text));
			shcl_read_str gr = shcl_read_string(gd, gt[i].path, strlen(gt[i].path));
			if (shcl_diag_count(gd) != 0 || gr.status != SHCL_GOOD || gr.value.n != strlen(gt[i].want) || memcmp(gr.value.p, gt[i].want, gr.value.n) != 0) fail("bare_text", gt[i].text);
			shcl_free(gd);
		}
		shcl_doc *nd = shcl_parse("x: 80,443\n", 10);
		if (shcl_read_int(nd, "x", 1).status == SHCL_GOOD) fail("bare_text", "80,443 read as a number");
		shcl_free(nd);
	}
	test_id("EryvVbF", "the_writer_quotes_a_colon_or_comma");
	/* The reader takes a colon or comma bare where it is text, but the writer
	   quotes any whitespace, colon, comma, paren or bracket wherever it sits,
	   so nobody has to know the reader's rules. A quoted value keeps its
	   quotes and its quote kind, a quoted number included. */
	{
		shcl_doc *qd = shcl_new();
		const char *tags[2] = {"rw,noatime", "b"}; size_t tl[2] = {10, 1};
		if (shcl_set_string(qd, "opts", 4, "rw,noatime", 10) != SHCL_SET_OK || shcl_set_string(qd, "display", 7, ":0", 2) != SHCL_SET_OK || shcl_set_string(qd, "end", 3, "a,", 2) != SHCL_SET_OK
			|| shcl_set_string(qd, "title", 5, "My App", 6) != SHCL_SET_OK || shcl_set_string_array(qd, "tags", 4, tags, tl, 2) != SHCL_SET_OK
			|| shcl_set_string(qd, "call", 4, "f(x)", 4) != SHCL_SET_OK || shcl_set_string(qd, "box", 3, "a[0]", 4) != SHCL_SET_OK || shcl_set_string(qd, "tabbed", 6, "a\tb", 3) != SHCL_SET_OK
			|| shcl_set_string(qd, "plain", 5, "a-b.c/d", 7) != SHCL_SET_OK)
			fail("writer_comma", "a setter refused");
		shcl_str qc = shcl_to_canonical(qd);
		const char *qw[] = {"opts: \"rw,noatime\"\n", "display: \":0\"\n", "end: \"a,\"\n", "title: \"My App\"\n", "tags: [\"rw,noatime\", b]\n",
			"call: \"f(x)\"\n", "box: \"a[0]\"\n", "tabbed: \"a◉TAB◉b\"\n", "plain: a-b.c/d\n"};
		for (size_t i = 0; i < sizeof qw / sizeof qw[0]; i++) if (!contains(qc.p, qc.n, qw[i])) fail("writer_comma", qw[i]);
		char qtext[256];
		if (qc.n >= sizeof qtext) fail("writer_comma", "the canonical text outgrew the fixture buffer");
		else {
			memcpy(qtext, qc.p, qc.n);
			shcl_doc *qb = shcl_parse(qtext, qc.n);
			shcl_str qb2 = shcl_to_canonical(qb);
			if (qb2.n != qc.n || memcmp(qb2.p, qtext, qc.n) != 0) fail("writer_comma", "the reload wrote other text");
			shcl_read_str_arr qa = shcl_read_string_array(qb, "tags", 4);
			if (qa.status != SHCL_GOOD || qa.n != 2 || qa.values[0].n != 10 || memcmp(qa.values[0].p, "rw,noatime", 10) != 0 || qa.values[1].n != 1 || qa.values[1].p[0] != 'b') fail("writer_comma", "tags");
			shcl_free(qb);
		}
		shcl_free(qd);
		shcl_doc *td = shcl_parse("n: \"1,000\"\n", 11);
		shcl_str tc = shcl_to_canonical(td);
		if (tc.n != 11 || memcmp(tc.p, "n: \"1,000\"\n", 11) != 0) fail("writer_comma", "a quoted thousands comma lost its quotes");
		if (shcl_get_int_or(td, "n", 1, 0) != 1000) fail("writer_comma", "n");
		shcl_free(td);
		const char *vin = "ver: \"8\"\nok: 'true'\nat: 2:30PM\nhost: localhost:8080\n";
		const char *vout = "ver: \"8\"\nok: 'true'\nat: \"2:30PM\"\nhost: \"localhost:8080\"\n";
		shcl_doc *vd = shcl_parse(vin, strlen(vin));
		shcl_str vc = shcl_to_canonical(vd);
		if (vc.n != strlen(vout) || memcmp(vc.p, vout, vc.n) != 0) fail("writer_comma", "a quoted number lost its quotes, or a colon went bare");
		if (shcl_get_int_or(vd, "ver", 3, 0) != 8) fail("writer_comma", "ver");
		if (shcl_set_int(vd, "ver", 3, 9) != SHCL_SET_OK) fail("writer_comma", "set ver");
		vc = shcl_to_canonical(vd);
		if (vc.n < 9 || memcmp(vc.p, "ver: \"9\"\n", 9) != 0) fail("writer_comma", "a set over a quoted number dropped its quotes");
		shcl_free(vd);
		shcl_doc *hd = shcl_parse("t: a,b\nt: c\n", 12);
		shcl_str hm = shcl_diag_count(hd) ? shcl_diag_message(hd, 0) : shcl_to_canonical(hd);
		if (shcl_diag_count(hd) == 0 || strcmp(shcl_diag_code(hd, 0), "H001") != 0 || !contains(hm.p, hm.n, "t: [\"a,b\", c]")) fail("writer_comma", "the H001 hint");
		shcl_free(hd);
	}
	test_id("Es1gWRs", "a_list_no_text_loads_back_refuses_to_save");
	/* A list with a field under it (E001) after an empty binding of its name
	   that has fields: no text loads it back, since a reload joins the list's
	   header to that binding and drops its items (E008). The load is left as
	   it is; a save that would write it refuses (2026100511210900). An edit
	   and a merge can each leave one. Same fixture in every runner. */
	{
		const char *lsrc = "x: v\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n";
		shcl_doc *ld = shcl_parse_keep_lines(lsrc, strlen(lsrc), SHCL_STANDARD);
		if (shcl_lost_count(ld) != 0) fail("list_no_text", "the load lost a line");
		if (shcl_set_empty(ld, "x(v)", 4) != SHCL_SET_OK) fail("list_no_text", "set empty refused");
		shcl_str lt = shcl_to_canonical(ld);
		if (!str_is(lt, "x:\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n")) fail("list_no_text", "canonical");
		shcl_doc *lb = shcl_parse(lt.p, lt.n);
		if (shcl_lost_count(lb) != 2) fail("list_no_text", "the reload drops both items");
		shcl_free(lb);
		if (shcl_lost_count(ld) != 2) fail("list_no_text", "lost");
		int kept = 1;
		(void)shcl_to_text_keep_lines(ld, &kept);
		if (kept) fail("list_no_text", "the source was canonical, and still no lines are kept");
		char ldir[256], lfile[288];
		snprintf(ldir, sizeof ldir, "%s/shcl-listsave-%ld", tmp_root(), (long)getpid());
#ifdef _WIN32
		if (_mkdir(ldir) != 0) fail("list_no_text", "mkdir failed");
#else
		if (mkdir(ldir, 0700) != 0) fail("list_no_text", "mkdir failed");
#endif
		snprintf(lfile, sizeof lfile, "%s/t.shcl", ldir);
		put_file(lfile, lsrc);
		if (shcl_save_file(ld, lfile, NULL) != SHCL_SAVE_REFUSED) fail("list_no_text", "save went through");
		int lk = 0;
		if (shcl_save_file_keep_lines(ld, lfile, &lk, NULL) != SHCL_SAVE_REFUSED) fail("list_no_text", "the keep save went through");
		if (!file_is(lfile, lsrc)) fail("list_no_text", "file changed");
		if (shcl_save_file_lossy(ld, lfile, NULL) != SHCL_SAVE_OK) fail("list_no_text", "lossy save failed");
		remove(lfile); rmdir(ldir);
		shcl_free(ld);
		/* The same through a merge: the list arrives over an empty binding. */
		shcl_doc *lm = shcl_parse("x:\n\tf: 1\n", 9);
		shcl_doc *lo = shcl_parse("x:\n\t- a\n\t- b\n\tg: 2\n", 19);
		shcl_merge(lm, lo);
		if (shcl_lost_count(lm) != 2) fail("list_no_text", "merge");
		shcl_free(lo); shcl_free(lm);
		/* An empty binding with no fields takes the list in, so nothing is
		   lost, and a list with no field under it goes in brackets. */
		const char *ok_src[] = {"x: v\nx:\n\t- a\n\tg: 2\n", "x: v\n\tf: 1\nx:\n\t- a\n\t- b\n"};
		for (size_t i = 0; i < 2; i++) {
			shcl_doc *od = shcl_parse(ok_src[i], strlen(ok_src[i]));
			if (shcl_set_empty(od, "x(v)", 4) != SHCL_SET_OK || shcl_lost_count(od) != 0) fail("list_no_text", ok_src[i]);
			shcl_free(od);
		}
	}
	test_id("Es1gWRt", "a_list_joining_an_emptied_field_keeps_its_fields_found");
	/* A setter that empties a field joins the stacked list after it, fields
	   and all, as a reload would. A read made before the write has the lookup
	   built, and the fields that moved still have to be found through it. */
	{
		static const struct { const char *src, *path, *field, *want; } jc[] = {
			{"b: x\nb:\n\t- 3\n\tk: 1\n", "b(0)", "b.k", "1"},
			{"b: x\nb: y z\n\t- 3\n\tk: 1\n", "b(0)", "b.k", "1"},
			{"x: v\nx:\n\t- a\n\tg: 2\n", "x(v)", "x.g", "2"},
		};
		for (size_t i = 0; i < sizeof jc / sizeof jc[0]; i++) {
			shcl_doc *jd = shcl_parse(jc[i].src, strlen(jc[i].src));
			if (shcl_read_string(jd, jc[i].field, strlen(jc[i].field)).status != SHCL_GOOD) fail("list_join_found", jc[i].src);
			if (shcl_set_empty(jd, jc[i].path, strlen(jc[i].path)) != SHCL_SET_OK) fail("list_join_found", jc[i].src);
			shcl_str jt = shcl_to_canonical(jd);
			shcl_doc *jb = shcl_parse(jt.p, jt.n);
			shcl_doc *both[2] = {jb, jd};
			for (int k = 0; k < 2; k++) {
				shcl_read_str jr = shcl_read_string(both[k], jc[i].field, strlen(jc[i].field));
				if (jr.status != SHCL_GOOD || !str_is(jr.value, jc[i].want)) fail("list_join_found", k ? "live" : "reload");
			}
			if (!same_paths(jd, jb)) fail("list_join_found", "paths");
			shcl_free(jb); shcl_free(jd);
		}
	}
	test_id("Es1gWRu", "a_list_the_source_loads_back_keeps_its_lines");
	/* A load can build that list too, under a kept array line (E028). The
	   canonical text writes the line as a comment and cannot load the list
	   back, so that save refuses. The source text does, so with no edits the
	   save that keeps lines writes it as it was. */
	{
		const char *ksrc = "c:\n\ts: 1\nc: [1]\n\tb(*): 1\n\t- 3\n\ta: 2\n";
		shcl_doc *kd = shcl_parse_keep_lines(ksrc, strlen(ksrc), SHCL_STANDARD);
		if (shcl_lost_count(kd) != 2) fail("list_source", "the wildcard line and the item");
		int kept = 0;
		shcl_str kt = shcl_to_text_keep_lines(kd, &kept);
		if (!kept || !str_is(kt, ksrc)) fail("list_source", "keep");
		char kdir[256], kfile[288];
		snprintf(kdir, sizeof kdir, "%s/shcl-listsrc-%ld", tmp_root(), (long)getpid());
#ifdef _WIN32
		if (_mkdir(kdir) != 0) fail("list_source", "mkdir failed");
#else
		if (mkdir(kdir, 0700) != 0) fail("list_source", "mkdir failed");
#endif
		snprintf(kfile, sizeof kfile, "%s/t.shcl", kdir);
		put_file(kfile, ksrc);
		if (shcl_save_file(kd, kfile, NULL) != SHCL_SAVE_REFUSED) fail("list_source", "save went through");
		int kk = 0;
		if (shcl_save_file_keep_lines(kd, kfile, &kk, NULL) != SHCL_SAVE_OK || !kk) fail("list_source", "the keep save kept no lines");
		if (!file_is(kfile, ksrc)) fail("list_source", "file changed");
		remove(kfile); rmdir(kdir);
		shcl_free(kd);
	}
	test_id("Es1gWRv", "a_merged_list_joins_an_empty_field_past_a_comment");
	/* A merge adds a list with a field under it as a new instance after an
	   empty binding of its name. A comment or kept line left after the
	   binding held the join off, though a reload joins the two
	   (2026100520243961). */
	{
		static const char *mbase[] = {
			"p:\n\ts:\n\t# c\n",
			"p:\n\ts:\n\tk: [1\n",
			"p:\n\ts:\n\t# c\n\t\t# d\n",
			"p:\n\ts:\n\t# c\n\tt: 2\n",
		};
		const char *mover = "p:\n\ts:\n\t\t- 0\n\t\tc: 1\n";
		for (size_t i = 0; i < sizeof mbase / sizeof mbase[0]; i++) {
			shcl_doc *md = shcl_parse(mbase[i], strlen(mbase[i]));
			shcl_doc *mo = shcl_parse(mover, strlen(mover));
			shcl_merge(md, mo);
			shcl_free(mo);
			shcl_str mt = shcl_to_canonical(md);
			shcl_doc *mb = shcl_parse(mt.p, mt.n);
			shcl_str mbt = shcl_to_canonical(mb);
			if (mbt.n != mt.n || memcmp(mbt.p, mt.p, mt.n) != 0) fail("merged_list_join", mbase[i]);
			if (!same_paths(md, mb)) fail("merged_list_join", "paths");
			shcl_doc *both[2] = {md, mb};
			for (int k = 0; k < 2; k++) {
				shcl_read_str mr = shcl_read_string(both[k], "p.s.c", 5);
				if (mr.status != SHCL_GOOD || !str_is(mr.value, "1")) fail("merged_list_join", "p.s.c");
			}
			if (shcl_count(md, "p.s", 3) != 1) fail("merged_list_join", "instances");
			shcl_free(mb); shcl_free(md);
		}
	}
	test_id("EsFs7xx", "a_joined_list_files_the_bindings_lines_like_a_reload");
	/* A list that joins an empty binding brings its fields, and the binding's
	   own kept line inside its block is written after them. A merge left it
	   filed inside the block, so a remove of the last field wrote it before
	   the kept line among the items, and a reload after it
	   (2026100914525821). */
	{
		static const char *jbase[] = {"srv:\n\t[\n", "srv:\n\tx: 1\n\t[\n"};
		const char *jover = "srv:\n\t- 1\n\t*\n\tb: 1\n";
		for (size_t i = 0; i < 2; i++) {
			shcl_doc *jd = shcl_parse(jbase[i], strlen(jbase[i]));
			shcl_doc *jo = shcl_parse(jover, strlen(jover));
			shcl_merge(jd, jo);
			shcl_free(jo);
			if (i == 0 && !str_is(shcl_to_canonical(jd), "srv:\n\t- 1\n\t*\n\tb: 1\n\t[\n")) fail("joined_list", "merged");
			/* The write side's join, when a remove empties the binding. */
			if (i == 1 && shcl_remove(jd, "srv.x", 5) != 1) fail("joined_list", "remove srv.x");
			shcl_str jt = shcl_to_canonical(jd);
			shcl_doc *jb = shcl_parse(jt.p, jt.n);
			if (shcl_remove(jd, "srv.b", 5) != 1 || shcl_remove(jb, "srv.b", 5) != 1) fail("joined_list", "remove srv.b");
			shcl_str jdt = shcl_to_canonical(jd);
			if (i == 0 && !str_is(jdt, "srv:\n\t- 1\n\t*\n\t[\n")) fail("joined_list", "removed");
			shcl_str jbt = shcl_to_canonical(jb);
			if (jbt.n != jdt.n || memcmp(jbt.p, jdt.p, jdt.n) != 0) fail("joined_list", jbase[i]);
			shcl_free(jb); shcl_free(jd);
		}
	}
	test_id("Es1gWRw", "a_remove_settles_a_list_after_an_empty_field");
	/* The remove twin: the merge without the gap builds the list no text loads
	   back, after a binding with a field. A remove that takes that field joins
	   the list, and one that takes the list's field puts it in brackets, as a
	   reload reads each. */
	{
		static const struct { const char *path, *want; } rc[] = {
			{"p.s.x", "p:\n\ts:\n\t\t- 0\n\t\tc: 1\n"},
			{"p.s.c", "p:\n\ts:\n\t\tx: 1\n\ts: [0]\n"},
		};
		for (size_t i = 0; i < sizeof rc / sizeof rc[0]; i++) {
			shcl_doc *rd = shcl_parse("p:\n\ts:\n\t\tx: 1\n", 14);
			shcl_doc *ro = shcl_parse("p:\n\ts:\n\t\t- 0\n\t\tc: 1\n", 20);
			shcl_merge(rd, ro);
			shcl_free(ro);
			if (shcl_lost_count(rd) == 0) fail("remove_list_join", "the list no text loads back");
			if (shcl_remove(rd, rc[i].path, strlen(rc[i].path)) != 1) fail("remove_list_join", "remove missed");
			shcl_str rt = shcl_to_canonical(rd);
			if (!str_is(rt, rc[i].want)) fail("remove_list_join", rc[i].path);
			shcl_doc *rb = shcl_parse(rt.p, rt.n);
			shcl_str rbt = shcl_to_canonical(rb);
			if (rbt.n != rt.n || memcmp(rbt.p, rt.p, rt.n) != 0 || !same_paths(rd, rb)) fail("remove_list_join", "reload differs");
			if (shcl_lost_count(rd) != 0) fail("remove_list_join", "lost");
			shcl_free(rb); shcl_free(rd);
		}
	}
	test_id("Es1gWRx", "a_setter_keeps_fields_and_arrays_apart");
	/* A field with lines under it takes one plain value or none (E028), so a
	   setter puts no field under an array and no array over fields. Each used
	   to write text that reloads as E028. */
	{
		const char *asrc = "l: [a]\nc: 1\n\tk: 2\n";
		shcl_doc *ad = shcl_parse(asrc, strlen(asrc));
		if (shcl_set_int(ad, "l.c", 3, 1) == SHCL_SET_OK) fail("setter_apart", "a field under an array");
		const char *one[1] = {"1"}; size_t onel[1] = {1};
		if (shcl_set_literal(ad, "c", 1, "[1, 2]", 6) == SHCL_SET_OK || shcl_set_string_array(ad, "c", 1, one, onel, 1) == SHCL_SET_OK) fail("setter_apart", "an array over fields");
		if (!str_is(shcl_to_canonical(ad), asrc)) fail("setter_apart", "changed");
		shcl_free(ad);
		/* An array with nothing under it takes a new one, and a stacked list
		   written with '- ' stays stacked. */
		const char *asrc2 = "l: [a]\nz:\n\t- a\n\t- b\n";
		ad = shcl_parse(asrc2, strlen(asrc2));
		const char *bc[2] = {"b", "c"}; size_t bcl[2] = {1, 1};
		const char *x1[1] = {"x"}; size_t x1l[1] = {1};
		if (shcl_set_string_array(ad, "l", 1, bc, bcl, 2) != SHCL_SET_OK || shcl_set_string_array(ad, "z", 1, x1, x1l, 1) != SHCL_SET_OK) fail("setter_apart", "an array setter refused");
		if (!str_is(shcl_to_canonical(ad), "l: [b, c]\nz:\n\t- x\n")) fail("setter_apart", "stacked");
		shcl_free(ad);
	}
	test_id("EonWXt2", "edits_and_merges_match_a_reload");
	edits_and_merges_match_a_reload();
	test_id("ErpmA6K", "a_remove_keeps_a_settled_line_below_it");
	/* The issue's steps, which the fuzz reached with the value syntax: the
	   setter comments out `a: [1` and makes `a` with the lines under it, and
	   the new `c` goes between the kept line and the settled one, so the
	   settled line sits below it. The remove leaves it there. The reload
	   reads a plain comment and takes it with the field. */
	{
		const char *st = "a: [1\n\t\t\": \n\t d-: 2\n\te: 3\n";
		shcl_doc *sl = shcl_parse(st, strlen(st));
		if (shcl_clear_comments(sl, "a.d", 3) != 0) fail("settled_below", "clear_comments took a line at a.d");
		if (shcl_set_empty(sl, "a.c", 3) != SHCL_SET_OK || shcl_set_raw(sl, "b.c", 3, "body", 4, "v0", 2) != SHCL_SET_OK) fail("settled_below", "a setter refused");
		shcl_str sc = shcl_to_canonical(sl);
		shcl_doc *sb = shcl_parse(sc.p, sc.n);
		if (shcl_remove(sl, "a.c", 3) != 1 || shcl_remove(sb, "a.c", 3) != 1) fail("settled_below", "a remove missed");
		SeqBuf sa = {0}, sr = {0};
		sc = shcl_to_canonical(sl); seq_put(&sa, sc.p, sc.n);
		sc = shcl_to_canonical(sb); seq_put(&sr, sc.p, sc.n);
		if (!strstr(sa.p, "\n\t\":\n\t# d-: 2\n\nb:\n")) fail("settled_below", "the document did not keep its settled line");
		if (!strstr(sr.p, "\n\t\":\n\nb:\n")) fail("settled_below", "the reload kept the comment");
		if (!reload_took_only_comments(sa.p, sa.n, sr.p, sr.n) || reload_took_only_comments(sr.p, sr.n, sa.p, sa.n))
			fail("settled_below", "reload_took_only_comments got it wrong");
		free(sa.p); free(sr.p);
		shcl_free(sl); shcl_free(sb);
	}
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
	test_id("Es1qzv8", "bracket_selectors_are_the_old_spelling");
	/* A selector is written in parens. One in brackets is the old spelling: a
	   file line is E029 and kept, and a lookup, a setter or a schema path in
	   brackets is refused. A body starting with `#`, the old index, is refused
	   too. Same fixture in every runner. */
	{
		const char *ot = "srv: web\n\tport: 80\nsrv[web]:\n\thost: h\n";
		shcl_doc *od = shcl_parse(ot, strlen(ot));
		if (shcl_diag_count(od) != 1 || strcmp(shcl_diag_code(od, 0), "E029") != 0 || shcl_diag_line(od, 0) != 3) fail("bracket_selector", "diagnostics");
		if (shcl_lost_count(od) != 0) fail("bracket_selector", "lost");
		shcl_read_str oh = shcl_read_string(od, "srv(web).host", 13);
		if (oh.status != SHCL_GOOD || !str_is(oh.value, "h")) fail("bracket_selector", "srv(web).host");
		if (shcl_count(od, "srv", 3) != 1) fail("bracket_selector", "srv count");
		// Was NotFound until reads got BadPath (2026100717500001).
		// if (shcl_read_string(od, "srv[web].host", 13).status != SHCL_NOT_FOUND) fail("bracket_selector", "srv[web].host found");
		if (shcl_read_string(od, "srv[web].host", 13).status != SHCL_BAD_PATH) fail("bracket_selector", "srv[web].host not BadPath");
		if (shcl_count(od, "srv[web]", 8) != 0) fail("bracket_selector", "srv[web] count");
		if (shcl_check_set_path(od, "srv[web].x", 10) != SHCL_SET_BAD_PATH) fail("bracket_selector", "check_set_path srv[web].x");
		if (shcl_check_set_path(od, "srv(#0).x", 9) != SHCL_SET_BAD_PATH) fail("bracket_selector", "check_set_path srv(#0).x");
		if (shcl_check_set_path(od, "srv(0).x", 8) != SHCL_SET_OK) fail("bracket_selector", "check_set_path srv(0).x");
		if (shcl_set_int(od, "srv[web].x", 10, 1) == SHCL_SET_OK) fail("bracket_selector", "a setter took a path in brackets");
		if (shcl_set_int(od, "srv(web).x", 10, 1) != SHCL_SET_OK) fail("bracket_selector", "a setter refused srv(web).x");
		shcl_str oc = shcl_to_canonical(od);
		if (oc.n < 19 || memcmp(oc.p, "srv[web]:\nsrv: web\n", 19) != 0) fail("bracket_selector", "canonical");
		shcl_tokens otok; memset(&otok, 0, sizeof otok);
		shcl_tokenize(od, "a(x).b[y].c: 1", 14, ':', 0, SHCL_RULES_CURRENT, &otok);
		if (!otok.has_bracket_selector || otok.bracket_selector != 6) fail("bracket_selector", "bracket_selector not 6");
		shcl_tokenize(od, "a(x).b(y).c: 1", 14, ':', 0, SHCL_RULES_CURRENT, &otok);
		if (otok.has_bracket_selector) fail("bracket_selector", "bracket_selector set with none");
		shcl_free(od);
		const char *osch = "field: \"srv[*].port\"\n";
		shcl_doc *os = shcl_parse(osch, strlen(osch));
		shcl_doc *odoc = shcl_parse("srv: a\n", 7);
		shcl_validation *ov = shcl_validate(odoc, os);
		int named = 0;
		for (size_t i = 0; i < shcl_validation_count(ov); i++) {
			shcl_str m = shcl_validation_message(ov, i);
			if (!strcmp(shcl_validation_code(ov, i), "V093") && contains(m.p, m.n, "parens")) named = 1;
		}
		if (!named) fail("bracket_selector", "no V093 naming parens");
		shcl_validation_free(ov);
		shcl_free(odoc); shcl_free(os);
	}
	test_id("Es1qzxJ", "init_refuses_a_child_of_an_array_parent");
	/* A parent whose default is an array has no selector a child line can use,
	   since a selector matches one plain value. Generation refuses it rather
	   than write a child that makes another instance. */
	{
		const char *asch = "field: tags\n\trequired: yes\n\tdefault: [a]\nfield: tags.k\n\trequired: yes\n";
		shcl_doc *as = shcl_parse(asch, strlen(asch));
		int ok = 1;
		(void)shcl_generate(as, 1, &ok);
		int refused = 0;
		for (size_t i = 0; i < shcl_diag_count(as); i++) {
			shcl_str m = shcl_diag_message(as, i);
			if (!strcmp(shcl_diag_code(as, i), "V097") && contains(m.p, m.n, "no selector spelling")) refused = 1;
		}
		if (ok || !refused) fail("init_array_parent", "a child of an array parent generated");
		shcl_free(as);
	}
	test_id("Es1ySon", "migrate_brackets_a_2x_comma_list");
	/* migrate writes a 2.x comma list in brackets, with or without a blank
	   after the comma, since 2.x read both as arrays. In a file that does not
	   say it is 2.x, `a,b` is a string under these rules, so it is left and
	   counted; `a, b` is an error here, so it converts either way. A lone bare
	   value these rules refuse is quoted. */
	{
		const char *t = "x: a, b\ny: a,b\nz: \"q\", r\nw: New York,,b\nv: done:\nu: rw,noatime\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		if (mm.ambiguous != 0) fail("migrate_comma_list", "ambiguous with from_v2");
		if (!mig_starts(&mm, "x: [a, b]\ny: [a, b]\nz: [\"q\", r]\nw: [\"New York\", b]\nv: \"done:\"\nu: [rw, noatime]\n")) fail("migrate_comma_list", mm.text);
		shcl_free(mig_load(&mm, "migrate_comma_list"));
		free(mm.text);
		t = "x: a, b\ny: a,b\n";
		mm = shcl_migrate(t, strlen(t), 0);
		if (mm.ambiguous != 1) fail("migrate_comma_list", "ambiguous not 1 without from_v2");
		if (!mig_starts(&mm, "x: [a, b]\ny: a,b\n")) fail("migrate_comma_list", mm.text);
		free(mm.text);
	}
	test_id("Es1ySoo", "migrate_writes_star_items_as_dashes");
	/* A 2.x `*` item becomes `- `, and an item these rules would read as
	   something else is quoted, such as one that looks like `- name: value`. */
	{
		const char *t = "list:\n\t* a\n\t* key: value\n\t* 'c'\n\t* O'Brien\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		if (!mig_starts(&mm, "list:\n\t- a\n\t- \"key: value\"\n\t- 'c'\n\t- \"O'Brien\"\n")) fail("migrate_star_items", mm.text);
		shcl_doc *d = mig_load(&mm, "migrate_star_items");
		shcl_read_str_arr r = shcl_read_string_array(d, "list", 4);
		if (r.status != SHCL_GOOD || r.n != 4 || !str_is(r.values[0], "a") || !str_is(r.values[1], "key: value") || !str_is(r.values[2], "c") || !str_is(r.values[3], "O'Brien"))
			fail("migrate_star_items", "list does not read back");
		shcl_free(d);
		free(mm.text);
	}
	test_id("Es1ySop", "migrate_quotes_a_name_not_led_by_a_letter");
	/* A bare 2.x name not led by a letter is quoted, so `-x: y` and `- :0`
	   stay fields rather than reading as list items, and `404` stays a name. */
	{
		const char *t = "404: a\n-x: y\nl:\n\t- :0\na.9b: 2\n_id: 7\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		if (!mig_starts(&mm, "\"404\": a\n\"-x\": y\nl:\n\t\"-\" :0\na.\"9b\": 2\n\"_id\": 7\n")) fail("migrate_name_lead", mm.text);
		shcl_doc *d = mig_load(&mm, "migrate_name_lead");
		shcl_read_str r = shcl_read_string(d, "\"-x\"", 4);
		if (r.status != SHCL_GOOD || !str_is(r.value, "y")) fail("migrate_name_lead", "\"-x\"");
		r = shcl_read_string(d, "l.\"-\"", 5);
		if (r.status != SHCL_GOOD || !str_is(r.value, "0")) fail("migrate_name_lead", "l.\"-\"");
		shcl_read_i64 ri = shcl_read_int(d, "a.\"9b\"", 6);
		if (ri.status != SHCL_GOOD || ri.value != 2) fail("migrate_name_lead", "a.\"9b\"");
		shcl_free(d);
		free(mm.text);
	}
	test_id("Es1ySoq", "migrate_escapes_a_real_mark");
	/* 2.x read a `◉` as text. A name, a bare value and a selector body
	   holding one get the escape for a real mark, so they still read as that
	   text. */
	{
		#define MK "\xe2\x97\x89"
		const char *t = "\"a" MK "q" MK "\": 1\nbare: My" MK "SPACE" MK "App\ns[x" MK "y].p: 2\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		shcl_doc *d = mig_load(&mm, "migrate_real_mark");
		shcl_str *ps; size_t np = shcl_paths(d, &ps);
		if (np < 2 || !str_is(ps[0], "\"a" MK "ESCAPE_CHAR" MK "q" MK "ESCAPE_CHAR" MK "\"") || !str_is(ps[1], "bare")) fail("migrate_real_mark", mm.text);
		shcl_read_str r = shcl_read_string(d, "bare", 4);
		if (r.status != SHCL_GOOD || !str_is(r.value, "My" MK "SPACE" MK "App")) fail("migrate_real_mark", "bare");
		if (shcl_count(d, "s", 1) != 1) fail("migrate_real_mark", "count s");
		r = shcl_read_string(d, "s(0)", 4);
		if (r.status != SHCL_GOOD || !str_is(r.value, "x" MK "y")) fail("migrate_real_mark", "s(0)");
		shcl_free(d);
		free(mm.text);
	}
	test_id("Es1ySor", "migrate_quotes_a_bare_selector_these_rules_refuse");
	/* A 2.x selector goes in parens, and a bare body these rules refuse, such
	   as one with a quote or a space, is quoted, so its block still loads. */
	{
		const char *t = "srv[O'Brien].port: 1\nsrv[New York].port: 2\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		if (!mig_starts(&mm, "srv(\"O'Brien\").port: 1\nsrv(\"New York\").port: 2\n")) fail("migrate_bare_selector", mm.text);
		shcl_doc *d = mig_load(&mm, "migrate_bare_selector");
		if (shcl_count(d, "srv", 3) != 2) fail("migrate_bare_selector", "count srv");
		shcl_free(d);
		free(mm.text);
	}
	test_id("Es1ySos", "migrate_writes_selectors_in_parens");
	/* Every 2.x selector goes in parens: an index, a value, the sugar on a
	   segment before the last, and a body with a paren in it, quoted. A
	   selector in brackets is E029 under these rules, so a file that does not
	   say it is 2.x gets the same rewrite, with nothing counted. */
	{
		const char *t = "a[x].k: 1\nb: y\nb[0].k: 2\nc[a(b)].k: 3\ne:[f].g: 4\nr[\"x\"]:\n\ts: 1\n";
		const char *want = "a(x).k: 1\nb: y\nb(0).k: 2\nc(\"a(b)\").k: 3\ne(f).g: 4\nr(\"x\"):\n\ts: 1\n";
		for (int from = 1; from >= 0; from--) {
			shcl_migration mm = shcl_migrate(t, strlen(t), from);
			if (mm.ambiguous != 0 || mm.lost != 0) fail("migrate_parens", from ? "counted with from_v2" : "counted without from_v2");
			if (!mig_starts(&mm, want)) fail("migrate_parens", mm.text);
			free(mm.text);
		}
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		shcl_doc *d = mig_load(&mm, "migrate_parens");
		static const struct { const char *path; int64_t want; } reads[] = {
			{"c(\"a(b)\").k", 3}, {"e(f).g", 4}, {"b(y).k", 2}, {"r(x).s", 1},
		};
		for (size_t i = 0; i < sizeof reads / sizeof *reads; i++) {
			shcl_read_i64 ri = shcl_read_int(d, reads[i].path, strlen(reads[i].path));
			if (ri.status != SHCL_GOOD || ri.value != reads[i].want) fail("migrate_parens", reads[i].path);
		}
		shcl_free(d);
		free(mm.text);
	}
	test_id("Es1ySot", "migrate_counts_what_nothing_spells");
	/* What 2.x bound and nothing spells now is counted lost, so the CLI
	   refuses at 7: a selector with a comma, which matched an array value, and
	   a comma list with lines under it. A list of only empty slots, which 2.x
	   read as empty, is an empty value. */
	{
		const char *t = "a[x, y].b: 1\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 1);
		if (mm.lost != 1) fail("migrate_lost", "a selector with a comma");
		free(mm.text);
		t = "a: 1, 2\n\tb: 1\nc: 3, 4\n";
		mm = shcl_migrate(t, strlen(t), 1);
		if (mm.lost != 1) fail("migrate_lost", "a comma list with lines under it");
		free(mm.text);
		t = "e: ,\nf: , # c\n";
		mm = shcl_migrate(t, strlen(t), 1);
		if (mm.lost != 0) fail("migrate_lost", "empty slots");
		if (!mig_starts(&mm, "e:\nf: # c\n")) fail("migrate_lost", mm.text);
		shcl_doc *d = mig_load(&mm, "migrate_lost");
		if (shcl_read_string(d, "e", 1).status != SHCL_EMPTY) fail("migrate_lost", "e not empty");
		shcl_free(d);
		free(mm.text);
	}
	test_id("Es1ySou", "migrate_leaves_what_reads_clean_now");
	/* A file that does not say it is 2.x could be a 3.0 one. A piece that
	   reads clean under these rules too, such as an escape, a backtick value,
	   `[a]` or a `- ` item, is left as written and counted, so the CLI asks
	   for --from-2x rather than changing a correct file at exit 0. A selector
	   in brackets is E029 now, so its line is rewritten the 2.x way. */
	{
		const char *t = "x: \"a" MK "TAB" MK "b\"\n\"n" MK "TAB" MK "\": 1\nl:\n\t- :0\ns[\"" MK "TAB" MK "\"].p: 1\nb: `abc`\nc: [a]\n";
		const char *want = "x: \"a" MK "TAB" MK "b\"\n\"n" MK "TAB" MK "\": 1\nl:\n\t- :0\ns(\"" MK "ESCAPE_CHAR" MK "TAB" MK "ESCAPE_CHAR" MK "\").p: 1\nb: `abc`\nc: [a]\n";
		shcl_migration mm = shcl_migrate(t, strlen(t), 0);
		if (mm.ambiguous != 5) fail("migrate_reads_clean", "ambiguous not 5");
		if (mm.len != strlen(want) || memcmp(mm.text, want, mm.len) != 0) fail("migrate_reads_clean", mm.text);
		free(mm.text);
		mm = shcl_migrate(t, strlen(t), 1);
		if (!contains(mm.text, mm.len, "ESCAPE_CHAR")) fail("migrate_reads_clean", "no ESCAPE_CHAR with from_v2");
		free(mm.text);
		#undef MK
	}

	/* shcl_upgrade and shcl_upgrade_file (2026100313461649): a file this
	   version cannot load clean is backed up under a timestamped name and
	   written fresh, and a good one is never touched. The backup's name reads
	   the clock, so it is pinned for all of them. */
#ifdef _WIN32
	_putenv_s("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT");
#else
	setenv("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT", 1);
#endif
#define UP_V2 "name: \"say \\\"hi\\\"\"\ntags: a, b\n\n#\n# This config file format is SHCL.\n# \"Simple Hierarchical Config Language\"\n#    Legal    SHCL is Copyright © 2026 Jim Collier. License: MIT. No warranty.\n#\n"
#define UP_TAG "_backup_20261004-001500_format-v2"
	test_id("Es2qPd0", "upgrade_leaves_a_clean_or_stamped_file");
	{
		/* a,b is one string now and an array under 2.x, but it loads clean,
		   and nothing says the file is 2.x. */
		const char *clean = "a: 1\nb: x,y\n";
		shcl_upgraded up = shcl_upgrade(clean, strlen(clean), 0);
		if (!up.current || !up_is(&up, clean) || up.diagnostics) fail("upgrade_clean", "clean");
		shcl_upgraded_free(&up);
		const char *stamped = "p: a,b\n\n" SHCL_GEN_BANNER;
		up = shcl_upgrade(stamped, strlen(stamped), 1);
		if (!up.current) fail("upgrade_clean", "stamped");
		shcl_upgraded_free(&up);
		/* A beta build stamped the same Format line, so its errors are left
		   too. */
		const char *beta = "tags: a, b\n\n" SHCL_GEN_BANNER;
		up = shcl_upgrade(beta, strlen(beta), 1);
		if (!up.current || !up_is(&up, beta) || up.format != 3) fail("upgrade_clean", "beta");
		shcl_upgraded_free(&up);
	}
	test_id("Es2qPd1", "upgrade_from_v2_rewrites_a_clean_file_that_reads_differently");
	{
		/* The caller says it is 2.x, where a,b was an array. */
		shcl_upgraded up = shcl_upgrade("p: a,b\n", 7, 1);
		if (up.current || up.lost != 0 || (up.diagnostics && shcl_diag_count(up.diagnostics) != 0)) fail("upgrade_from_v2", "a,b");
		if (!up_is(&up, "p: [a, b]\n\n" SHCL_GEN_BANNER)) fail("upgrade_from_v2", up.text);
		shcl_upgraded_free(&up);
		/* Nothing reads differently, so there is nothing to do. */
		const char *same = "a: 1\nb: x\n";
		up = shcl_upgrade(same, strlen(same), 1);
		if (!up.current || !up_is(&up, same)) fail("upgrade_from_v2", "same");
		shcl_upgraded_free(&up);
	}
	test_id("Es2qPd2", "upgrade_writes_a_fresh_file_with_the_info_block");
	{
		shcl_upgraded up = shcl_upgrade(UP_V2, strlen(UP_V2), 0);
		if (up.current || up.ambiguous != 0 || up.lost != 0 || up.format != 2) fail("upgrade_fresh", "counts");
		int e026 = 0;
		for (size_t i = 0; up.diagnostics && i < shcl_diag_count(up.diagnostics); i++) e026 |= !strcmp(shcl_diag_code(up.diagnostics, i), "E026");
		if (!e026) fail("upgrade_fresh", "no E026");
		/* 2.x's block goes, links or none, and the one init writes takes its
		   place. */
		if (!up_is(&up, "name: 'say \\\"hi\\\"'\ntags: [a, b]\n\n" SHCL_GEN_BANNER)) fail("upgrade_fresh", up.text);
		shcl_upgraded again = shcl_upgrade(up.text, up.len, 0);
		if (!again.current) fail("upgrade_fresh", "the fresh text is not current");
		shcl_upgraded_free(&again);
		shcl_upgraded_free(&up);
	}
	test_id("Es2qPd3", "upgrade_refuses_text_that_reads_two_ways");
	{
		const char *amb = "a: x,y\nb: \"q\n";
		shcl_upgraded up = shcl_upgrade(amb, strlen(amb), 0);
		if (up.current || up.ambiguous != 1 || !up_is(&up, amb)) fail("upgrade_ambiguous", "without from_v2");
		shcl_upgraded_free(&up);
		up = shcl_upgrade(amb, strlen(amb), 1);
		const char *head = "a: [x, y]\nb: '\"q'\n\n##\n";
		if (up.ambiguous != 0 || up.len < strlen(head) || memcmp(up.text, head, strlen(head)) != 0) fail("upgrade_ambiguous", up.text);
		shcl_upgraded_free(&up);
	}
	test_id("Es2qPd4", "backup_name_puts_the_tag_before_the_extension");
	{
		static const struct { const char *file; uint32_t format; const char *want; } bn[] = {
			{"f.shcl", 2, "f" UP_TAG ".shcl"},
			{"a/b.c.shcl", 2, "a/b.c" UP_TAG ".shcl"},
			{".shclrc", 2, ".shclrc" UP_TAG},
			{"d.x/f", 2, "d.x/f" UP_TAG},
			{"f.shcl", 3, "f_backup_20261004-001500_format-v3.shcl"},
		};
		for (size_t i = 0; i < sizeof bn / sizeof bn[0]; i++) {
			char *got = shcl_backup_file_name(bn[i].file, bn[i].format);
			if (strcmp(got, bn[i].want) != 0) fail("backup_name", got);
			free(got);
		}
	}
	test_id("Es2qPd5", "upgrade_file_backs_up_then_rewrites");
	{
		char udir[256], file[320], backup[320];
		up_dir(udir, sizeof udir, "write");
		snprintf(file, sizeof file, "%s/f.shcl", udir);
		snprintf(backup, sizeof backup, "%s/f" UP_TAG ".shcl", udir);
		put_file(file, UP_V2);
#ifndef _WIN32
		if (chmod(file, 0640) != 0) fail("upgrade_file", "chmod failed");
#endif
		shcl_upgraded up; char *why = NULL;
		if (shcl_upgrade_file(file, 0, &up, &why, NULL) != SHCL_UPGRADE_OK) fail("upgrade_file", why ? why : "failed");
		free(why); why = NULL;
		if (!up.backup || strcmp(up.backup, backup) != 0) fail("upgrade_file", up.backup ? up.backup : "no backup");
		if (!file_is(backup, UP_V2)) fail("upgrade_file", "the backup is not the original");
		size_t n = 0; char *now = shcl_read_file(file, 0, &n, NULL);
		if (!now || n != up.len || memcmp(now, up.text, n) != 0) fail("upgrade_file", "the file is not the fresh text");
		free(now);
#ifndef _WIN32
		struct stat bs;
		if (stat(backup, &bs) != 0 || (bs.st_mode & 07777) != 0640) fail("upgrade_file", "backup mode");
#endif
		shcl_upgraded_free(&up);
		/* The second start finds a current file and writes nothing. */
		if (shcl_upgrade_file(file, 0, &up, &why, NULL) != SHCL_UPGRADE_OK || !up.current || up.backup) fail("upgrade_file", "again");
		free(why);
		shcl_upgraded_free(&up);
		if (dir_entries(udir) != 2) fail("upgrade_file", "entries");
		dir_clear(udir);
	}
	test_id("Es2qPd6", "upgrade_file_never_writes_over_a_backup");
	{
		char udir[256], file[320], backup[320], none[320], amb[320];
		up_dir(udir, sizeof udir, "taken");
		snprintf(file, sizeof file, "%s/f.shcl", udir);
		snprintf(backup, sizeof backup, "%s/f" UP_TAG ".shcl", udir);
		put_file(file, UP_V2);
		put_file(backup, "x\n");
		shcl_upgraded up; char *why = NULL;
		if (shcl_upgrade_file(file, 0, &up, &why, NULL) != SHCL_UPGRADE_BACKUP_TAKEN || !why || strncmp(why, backup, strlen(backup)) != 0) fail("upgrade_taken", why ? why : "not refused");
		free(why); why = NULL;
		shcl_upgraded_free(&up);
		if (!file_is(file, UP_V2)) fail("upgrade_taken", "the file changed");
		if (!file_is(backup, "x\n")) fail("upgrade_taken", "the backup changed");
		/* Nothing at the path, and text that reads two ways, write nothing. */
		snprintf(none, sizeof none, "%s/none.shcl", udir);
		if (shcl_upgrade_file(none, 0, &up, NULL, NULL) != SHCL_UPGRADE_NOT_FOUND) fail("upgrade_taken", "none");
		shcl_upgraded_free(&up);
		snprintf(amb, sizeof amb, "%s/amb.shcl", udir);
		put_file(amb, "a: x,y\nb: \"q\n");
		if (shcl_upgrade_file(amb, 0, &up, NULL, NULL) != SHCL_UPGRADE_AMBIGUOUS || up.ambiguous != 1) fail("upgrade_taken", "amb");
		shcl_upgraded_free(&up);
		if (dir_entries(udir) != 3) fail("upgrade_taken", "entries");
		dir_clear(udir);
	}
#undef UP_V2
#undef UP_TAG
#ifdef _WIN32
	_putenv_s("SHCL_TEST_CLOCK", "");
#else
	unsetenv("SHCL_TEST_CLOCK");
#endif

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
		if (shcl_save_file(ld, lp, NULL) != SHCL_SAVE_OK) fail("longpath", "save refused a path past MAX_PATH");
		/* Through the library, which is what has to add the prefix: the
		   runner's own reader is plain fopen and would refuse the path. */
		size_t rn = 0; shcl_file_status lst; char *rt = shcl_read_file(lp, 0, &rn, &lst);
		if (!rt || lst != SHCL_FILE_CLEAN || rn != 5 || memcmp(rt, "a: 1\n", 5) != 0)
			fail("longpath", "the long path did not read back");
		free(rt);
		if (shcl_set_int(ld, "a", 1, 2) == SHCL_SET_OK && shcl_save_file(ld, lp, NULL) != SHCL_SAVE_OK)
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
			if (shcl_save_file(sd, link, NULL) != SHCL_SAVE_OK) fail("winlink", "save through the link failed");
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
			if (shcl_save_file(sd, link, NULL) != SHCL_SAVE_OK) fail("windsave", "save through a dangling link failed");
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
