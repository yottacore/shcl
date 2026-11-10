// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// The save's changed, create-only and not-regular checks against a real
// folder, over cases drawn from project/fs-rules.tsv: a load spelling, a save
// spelling, and what another program did between them. The expected answer
// comes from reading the folder, never from the library. Rust's
// tests/fs_property.rs is the reference, function for function
// (2026110616475901).
//
// The folder is SHCL_FS_DIR, which the pipeline points at a tmpfs made for the
// run. The budget is SHCL_FS_SECS of wall clock, and SHCL_FUZZ_DUMP gets every
// case run, with its answer, in fs/c-rows.tsv and fs/c-drawn.tsv.
// SHCL_FS_SEED runs only that seed, to replay a failure. argv[1] is the rules
// file (default project/fs-rules.tsv, run from the repo root as cicd does).

#define _POSIX_C_SOURCE 200809L // symlink, mkfifo, realpath, strdup under -std=c11

#define SHCL_IMPLEMENTATION
#include "shcl.h"

#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#endif

// One status line, with its test ID, as conformance.c prints them.
static const char *open_id, *open_name;
static void test_id(const char *id, const char *name) { open_id = id; open_name = name; }
static void test_id_end(const char *status) {
	printf("%-4s %s c %s\n", status, open_id, open_name);
	fflush(stdout);
}

#define TEST_CLOCK "2026-10-04 00:15:00 -420 PDT"

#ifdef _WIN32

// The Windows rows wait for b29w (2026111010012360), so both tests skip.
static int fs_run(int drawn, const char *file) {
	(void)drawn;
	(void)file;
	test_id_end("SKIP");
	return 0;
}

#else

// The fewest generated cases a run makes, whatever the budget, so the draw
// guard has enough to judge.
#define FS_MIN_CASES 400
#define FS_PATH 4096
#define FS_MAX_RULES 64
#define FS_MAX_EVENTS 2

static const char FS_LOADED[] = "a: 1\n";
static const char FS_OTHER[] = "b: 2\n";
static const char FS_MARKER[] = "marker: 1\n";

// The case or setup can't go on, as t.Fatal ends a Go test.
SHCL_NORETURN static void fs_fatal(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "FAIL %s: ", open_name);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	test_id_end("FAIL");
	exit(1);
}

// A path built into a fixed buffer, since every path here is the base folder
// and a few short names.
static void fs_path(char *out, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(out, FS_PATH, fmt, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= FS_PATH) fs_fatal("a path past %d bytes", FS_PATH);
}

// A growing byte string, NUL-terminated after every append.
typedef struct { char *p; size_t n, cap; } fs_buf;

static void fs_grow(fs_buf *b, size_t extra) {
	if (b->n + extra + 1 <= b->cap) return;
	size_t cap = b->cap ? b->cap : 256;
	while (b->n + extra + 1 > cap) cap *= 2;
	char *p = realloc(b->p, cap);
	if (!p) fs_fatal("out of memory");
	b->p = p;
	b->cap = cap;
}

static void fs_put(fs_buf *b, const char *s, size_t n) {
	fs_grow(b, n);
	if (n) memcpy(b->p + b->n, s, n);
	b->n += n;
	b->p[b->n] = '\0';
}

static void fs_puts(fs_buf *b, const char *s) { fs_put(b, s, strlen(s)); }

static void fs_printf(fs_buf *b, const char *fmt, ...) {
	va_list ap, again;
	va_start(ap, fmt);
	va_copy(again, ap);
	int n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (n < 0) fs_fatal("vsnprintf failed");
	fs_grow(b, (size_t)n);
	vsnprintf(b->p + b->n, (size_t)n + 1, fmt, again);
	va_end(again);
	b->n += (size_t)n;
}

static void fs_buf_free(fs_buf *b) { free(b->p); *b = (fs_buf){0}; }

typedef struct { const char *name, *path, *cwd, *os; } fs_rule;

typedef struct {
	fs_rule spells[FS_MAX_RULES], events[FS_MAX_RULES];
	size_t nspells, nevents;
	char *text; // the file, split in place; the rules point into it
} fs_rules;

// Windows and macOS rows wait for their boxes (2026111010012360), so they
// skip everywhere for now, rather than run untried.
static int fs_on_this_os(const char *os) {
	if (!strcmp(os, "any") || !strcmp(os, "posix")) return 1;
	if (!strcmp(os, "windows") || !strcmp(os, "macos")) return 0;
	fs_fatal("fs-rules.tsv: no such os \"%s\"", os);
}

// The file's bytes, malloc'd and NUL-terminated (the caller frees them), or
// NULL when it can't be read.
static char *fs_slurp(const char *p, size_t *len) {
	int fd = open(p, O_RDONLY);
	if (fd < 0) return NULL;
	fs_buf b = {0};
	fs_put(&b, "", 0);
	char chunk[4096];
	for (;;) {
		ssize_t got = read(fd, chunk, sizeof chunk);
		if (got < 0) {
			close(fd);
			fs_buf_free(&b);
			return NULL;
		}
		if (got == 0) break;
		fs_put(&b, chunk, (size_t)got);
	}
	close(fd);
	*len = b.n;
	return b.p;
}

static void fs_read_rules(fs_rules *r, const char *file) {
	size_t n = 0;
	*r = (fs_rules){0};
	r->text = fs_slurp(file, &n);
	if (!r->text) fs_fatal("can't read %s", file);
	char *line = r->text;
	while (*line) {
		char *end = strchr(line, '\n');
		char *next = end ? end + 1 : line + strlen(line);
		if (end) *end = '\0';
		if (*line && *line != '#') {
			char *f[6];
			size_t nf = 0;
			for (char *s = line; s && nf < 6; nf++) {
				f[nf] = s;
				s = strchr(s, '\t');
				if (s) *s++ = '\0';
			}
			if (nf != 5) fs_fatal("fs-rules.tsv: not 5 fields: \"%s\"", line);
			fs_rule rule = {f[1], f[2], f[3], f[4]};
			(void)fs_on_this_os(rule.os);
			if (!strcmp(f[0], "spell")) {
				if (r->nspells == FS_MAX_RULES) fs_fatal("fs-rules.tsv: more than %d spellings", FS_MAX_RULES);
				r->spells[r->nspells++] = rule;
			} else if (!strcmp(f[0], "event")) {
				if (r->nevents == FS_MAX_RULES) fs_fatal("fs-rules.tsv: more than %d events", FS_MAX_RULES);
				r->events[r->nevents++] = rule;
			} else {
				fs_fatal("fs-rules.tsv: no such kind \"%s\"", f[0]);
			}
		}
		line = next;
	}
}

// splitmix64, since it's a few lines in every binding.
typedef struct { uint64_t s; } fs_mix;

static uint64_t fs_next(fs_mix *g) {
	g->s += UINT64_C(0x9E3779B97F4A7C15);
	uint64_t z = g->s;
	z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
	z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
	return z ^ (z >> 31);
}

static size_t fs_below(fs_mix *g, size_t n) { return (size_t)(fs_next(g) % (uint64_t)n); }

typedef struct {
	int t_there, o_there;
	size_t load, save;
	size_t events[FS_MAX_EVENTS], nevents;
	int create, force;
} fs_case;

static fs_case fs_draw(const fs_rules *r, uint64_t seed) {
	fs_mix g = {seed};
	fs_case c = {0};
	c.t_there = fs_below(&g, 2) == 1;
	c.o_there = fs_below(&g, 2) == 1;
	c.load = fs_below(&g, r->nspells);
	c.save = fs_below(&g, r->nspells);
	c.nevents = 1 + fs_below(&g, 2);
	for (size_t i = 0; i < c.nevents; i++) c.events[i] = fs_below(&g, r->nevents);
	c.create = fs_below(&g, 4) == 0;
	c.force = fs_below(&g, 4) == 0;
	return c;
}

typedef enum { FS_OK, FS_CHANGED, FS_EXISTS, FS_IS_DIRECTORY, FS_NOT_REGULAR, FS_IO, FS_OUTCOMES } fs_outcome;

// Named as Rust's Debug names them, so the dumps compare as text.
static const char *const fs_outcome_names[FS_OUTCOMES] = {"Ok", "Changed", "Exists", "IsDirectory", "NotRegular", "Io"};

static fs_outcome fs_classify(shcl_save_result res, shcl_write_status why) {
	switch (res) {
	case SHCL_SAVE_OK: return FS_OK;
	case SHCL_SAVE_CHANGED: return FS_CHANGED;
	case SHCL_SAVE_EXISTS: return FS_EXISTS;
	case SHCL_SAVE_FAILED:
		if (why == SHCL_WRITE_IS_DIRECTORY) return FS_IS_DIRECTORY;
		if (why == SHCL_WRITE_NOT_REGULAR) return FS_NOT_REGULAR;
		return FS_IO;
	case SHCL_SAVE_REFUSED:
	case SHCL_SAVE_TOO_NEW:
		break;
	}
	fs_fatal("a save this test never asks for: %d", (int)res);
}

// What sits at a path, followed through links, read without the library.
typedef enum { FS_NOTHING, FS_FILE, FS_UNREADABLE, FS_DIR, FS_SPECIAL } fs_kind;
typedef struct { fs_kind kind; char *bytes; size_t n; } fs_at;

static fs_at fs_at_path(const char *p) {
	fs_at a = {FS_NOTHING, NULL, 0};
	struct stat st;
	if (stat(p, &st) != 0) return a;
	if (S_ISREG(st.st_mode)) {
		a.bytes = fs_slurp(p, &a.n);
		a.kind = a.bytes ? FS_FILE : FS_UNREADABLE;
	} else {
		a.kind = S_ISDIR(st.st_mode) ? FS_DIR : FS_SPECIAL;
	}
	return a;
}

static int fs_at_is_file(const fs_at *a, const char *bytes, size_t n) {
	return a->kind == FS_FILE && a->n == n && !memcmp(a->bytes, bytes, n);
}

static void fs_at_free(fs_at *a) { free(a->bytes); a->bytes = NULL; }

// The spelling's path, as the library gets it from its working folder.
static void fs_spelled(char *out, const fs_rule *rule, const char *w) {
	fs_buf b = {0};
	fs_puts(&b, "");
	for (const char *s = rule->path; *s;) {
		if (!strncmp(s, "{W}", 3)) {
			fs_puts(&b, w);
			s += 3;
		} else {
			fs_put(&b, s++, 1);
		}
	}
	fs_path(out, "%s", b.p);
	fs_buf_free(&b);
}

// The same path from the case's root, for reading and events. Plain text, not
// a cleaned join, so nodir/.. still meets the kernel.
static void fs_from_root(char *out, const char *root, const char *cwd, const char *path) {
	if (path[0] == '/') fs_path(out, "%s", path);
	else fs_path(out, "%s/%s/%s", root, cwd, path);
}

static int fs_write_bytes(const char *p, const char *bytes, size_t n) {
	int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return -1;
	ssize_t put = n ? write(fd, bytes, n) : 0;
	int bad = put < 0 || (size_t)put != n;
	if (close(fd) != 0) bad = 1;
	return bad ? -1 : 0;
}

static int fs_write_file(const char *p, const char *bytes) { return fs_write_bytes(p, bytes, strlen(bytes)); }

static int fs_mkdir_all(const char *p, mode_t mode) {
	char part[FS_PATH];
	fs_path(part, "%s", p);
	for (char *s = part + 1; *s; s++) {
		if (*s != '/') continue;
		*s = '\0';
		if (mkdir(part, mode) != 0 && errno != EEXIST) return -1;
		*s = '/';
	}
	return mkdir(part, mode) != 0 && errno != EEXIST ? -1 : 0;
}

static void fs_must(int rc, const char *what, const char *p) {
	if (rc != 0) fs_fatal("%s %s: %s", what, p, strerror(errno));
}

static void fs_build(const char *root, const fs_case *c) {
	char w[FS_PATH], p[FS_PATH];
	fs_path(w, "%s/w", root);
	fs_path(p, "%s/sub", w);
	fs_must(fs_mkdir_all(p, 0755), "mkdir", p);
	fs_path(p, "%s/o", root);
	fs_must(mkdir(p, 0755), "mkdir", p);
	fs_path(p, "%s/sub/t.shcl", w);
	fs_must(fs_write_file(p, "s: 1\n"), "write", p);
	if (c->t_there) {
		fs_path(p, "%s/t.shcl", w);
		fs_must(fs_write_file(p, FS_LOADED), "write", p);
	}
	if (c->o_there) {
		fs_path(p, "%s/o/t.shcl", root);
		fs_must(fs_write_file(p, "o: 1\n"), "write", p);
	}
	static const char *const links[][2] = {
		{".", "lw"}, {"t.shcl", "lt.shcl"}, {"gone.shcl", "dl.shcl"}, {"cy2.shcl", "cy.shcl"}, {"cy.shcl", "cy2.shcl"},
	};
	for (size_t i = 0; i < sizeof links / sizeof links[0]; i++) {
		fs_path(p, "%s/%s", w, links[i][1]);
		fs_must(symlink(links[i][0], p), "symlink", p);
	}
}

static int fs_is_fifo(const char *p) {
	struct stat st;
	return stat(p, &st) == 0 && S_ISFIFO(st.st_mode);
}

// Removes what's at the path but never a folder, as Rust's remove_file, since
// unlink refuses one.
static void fs_remove_file(const char *p) { (void)unlink(p); }

static void fs_write_other(const char *p) {
	if (!fs_is_fifo(p)) (void)fs_write_file(p, FS_OTHER);
}

// Another program's act between the load and the save. Each one that the tree
// makes impossible, such as a write through a link cycle, does nothing, the
// same in both trees.
static void fs_apply(const char *event, const char *root, const char *load, const char *save) {
	char w[FS_PATH], p[FS_PATH];
	fs_path(w, "%s/w", root);
	if (!strcmp(event, "none") || !strcmp(event, "chdir")) {
		// Nothing in the tree. chdir moves the save's working folder, which
		// the caller tracks.
	} else if (!strcmp(event, "write-load")) {
		fs_write_other(load);
	} else if (!strcmp(event, "write-save")) {
		fs_write_other(save);
	} else if (!strcmp(event, "remove-load")) {
		fs_remove_file(load);
	} else if (!strcmp(event, "fifo-load")) {
		fs_remove_file(load);
		(void)mkfifo(load, 0600);
	} else if (!strcmp(event, "dir-load")) {
		fs_remove_file(load);
		(void)mkdir(load, 0755);
	} else if (!strcmp(event, "mkdir")) {
		fs_path(p, "%s/nodir", w);
		(void)mkdir(p, 0755);
		fs_path(p, "%s/nd", w);
		(void)mkdir(p, 0755);
	} else if (!strcmp(event, "link-made")) {
		fs_path(p, "%s/nd", w);
		(void)symlink("sub", p);
	} else if (!strcmp(event, "relink")) {
		fs_path(p, "%s/lw", w);
		fs_remove_file(p);
		(void)symlink("sub", p);
		fs_path(p, "%s/lt.shcl", w);
		fs_remove_file(p);
		(void)symlink("sub/t.shcl", p);
	} else if (!strcmp(event, "unread")) {
		// A file only, since a folder without its bits stops the case. Through
		// the open file, so a FIFO doesn't block and the file chmodded is the
		// one looked at.
		int fd = open(load, O_RDONLY | O_NONBLOCK | O_NOCTTY);
		struct stat st;
		if (fd >= 0) {
			if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) (void)fchmod(fd, 0200);
			close(fd);
		}
	} else {
		fs_fatal("no such event \"%s\"", event);
	}
}

static int fs_by_name(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// A folder's names, sorted, malloc'd (fs_names_free frees them), or -1 when
// it can't be listed.
static long fs_names(const char *dir, char ***out) {
	DIR *d = opendir(dir);
	if (!d) return -1;
	char **names = NULL;
	size_t n = 0, cap = 0;
	for (struct dirent *e; (e = readdir(d));) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
		if (n == cap) {
			cap = cap ? cap * 2 : 16;
			char **grown = realloc(names, cap * sizeof *names);
			if (!grown) fs_fatal("out of memory");
			names = grown;
		}
		names[n] = strdup(e->d_name);
		if (!names[n]) fs_fatal("out of memory");
		n++;
	}
	closedir(d);
	if (n) qsort(names, n, sizeof *names, fs_by_name);
	*out = names;
	return (long)n;
}

static void fs_names_free(char **names, long n) {
	for (long i = 0; i < n; i++) free(names[i]);
	free(names);
}

// Every name under the root, with what it is and holds, links not followed,
// so a refused save can be shown to have written nothing anywhere. One line
// each, in name order.
static void fs_snapshot_walk(fs_buf *out, const char *dir) {
	char **names = NULL;
	long n = fs_names(dir, &names);
	if (n < 0) {
		fs_printf(out, "%s\tunlistable\n", dir);
		return;
	}
	for (long i = 0; i < n; i++) {
		char p[FS_PATH];
		fs_path(p, "%s/%s", dir, names[i]);
		struct stat st;
		if (lstat(p, &st) != 0) {
			fs_printf(out, "%s\tgone\n", p);
		} else if (S_ISLNK(st.st_mode)) {
			char to[FS_PATH];
			ssize_t got = readlink(p, to, sizeof to - 1);
			to[got < 0 ? 0 : got] = '\0';
			fs_printf(out, "%s\tlink %s\n", p, to);
		} else if (S_ISDIR(st.st_mode)) {
			fs_printf(out, "%s\tdir\n", p);
			fs_snapshot_walk(out, p);
		} else if (S_ISREG(st.st_mode)) {
			size_t len = 0;
			char *bytes = fs_slurp(p, &len);
			if (!bytes) {
				fs_printf(out, "%s\tfile of %lld bytes, unreadable\n", p, (long long)st.st_size);
			} else {
				fs_printf(out, "%s\tfile \"", p);
				for (size_t k = 0; k < len; k++) {
					unsigned char ch = (unsigned char)bytes[k];
					if (ch >= 0x20 && ch < 0x7f && ch != '"' && ch != '\\') fs_put(out, &bytes[k], 1);
					else fs_printf(out, "\\x%02x", ch);
				}
				fs_puts(out, "\"\n");
				free(bytes);
			}
		} else {
			fs_printf(out, "%s\tspecial\n", p);
		}
	}
	fs_names_free(names, n);
}

static void fs_snapshot(fs_buf *out, const char *root) {
	fs_puts(out, "");
	fs_snapshot_walk(out, root);
}

// Gives back the bits an event took, so the tree can go, and removes it. Links
// are removed, never followed.
static void fs_remove_tree(const char *p) {
	// unlink takes anything but a folder, a link to one included.
	if (unlink(p) == 0 || errno == ENOENT) return;
	// codeql[cpp/toctou-race-condition] the case's own tree, which nothing else touches as it goes
	(void)chmod(p, 0700);
	char **names = NULL;
	long n = fs_names(p, &names);
	for (long i = 0; i < n; i++) {
		char sub[FS_PATH];
		fs_path(sub, "%s/%s", p, names[i]);
		fs_remove_tree(sub);
	}
	if (n >= 0) fs_names_free(names, n);
	(void)rmdir(p);
}

// One case's run and its answers.
typedef struct {
	int skipped, same;
	fs_outcome expected, got;
	char line[FS_PATH];
} fs_ran;

static void fs_describe(char *out, const fs_rules *r, const fs_case *c) {
	char events[FS_PATH] = "";
	size_t at = 0;
	for (size_t i = 0; i < c->nevents; i++) {
		int n = snprintf(events + at, sizeof events - at, "%s%s", i ? "," : "", r->events[c->events[i]].name);
		if (n < 0 || (size_t)n >= sizeof events - at) fs_fatal("an event list past %d bytes", FS_PATH);
		at += (size_t)n;
	}
	fs_path(out, "t=%d o=%d load=%s save=%s events=%s create=%d force=%d", c->t_there, c->o_there,
		r->spells[c->load].name, r->spells[c->save].name, events, c->create, c->force);
}

static int fs_ends_with(const char *s, const char *tail) {
	size_t n = strlen(s), k = strlen(tail);
	return n >= k && !strcmp(s + n - k, tail);
}

// The answer the save has to give, from the case's tree, and whether the 2
// spellings name one file, from the replica: a marker written through the save
// spelling and read back through the load spelling.
static fs_outcome fs_verdict(const char *r_save_at) {
	struct stat st;
	if (stat(r_save_at, &st) == 0) {
		if (S_ISDIR(st.st_mode)) return FS_IS_DIRECTORY;
		if (!S_ISREG(st.st_mode)) return FS_NOT_REGULAR;
	}
	return fs_write_file(r_save_at, FS_MARKER) == 0 ? FS_OK : FS_IO;
}

static fs_outcome fs_oracle(const char *save_at, const char *r_save_at, const char *r_load_at, const char *save_path,
	const fs_at *loaded, const fs_case *c, int *same) {
	fs_outcome verdict = fs_verdict(r_save_at);
	fs_at back = fs_at_path(r_load_at);
	*same = verdict == FS_OK && fs_at_is_file(&back, FS_MARKER, strlen(FS_MARKER));
	fs_at_free(&back);
	if (fs_ends_with(save_path, "/") || fs_ends_with(save_path, "/.") || fs_ends_with(save_path, "/..")) return FS_IS_DIRECTORY;
	struct stat st;
	if (c->create && lstat(save_at, &st) == 0) return FS_EXISTS;
	if (c->create || c->force) return verdict;
	fs_at a = fs_at_path(save_at);
	fs_outcome out = verdict;
	if (a.kind == FS_UNREADABLE) out = FS_CHANGED;
	else if (a.kind == FS_FILE && (!loaded || !fs_at_is_file(&a, loaded->bytes, loaded->n))) out = FS_CHANGED;
	fs_at_free(&a);
	return out;
}

static void fs_chdir(const char *p) {
	if (chdir(p) != 0) fs_fatal("chdir %s: %s", p, strerror(errno));
}

// 0 when the case held. Otherwise 1, with why it didn't in *why, and the tree
// kept for a look.
static int fs_run_case(const fs_rules *r, const char *base, const char *label, const fs_case *c, fs_ran *ran, fs_buf *why) {
	char desc[FS_PATH];
	fs_describe(desc, r, c);
	*ran = (fs_ran){0};
	ran->expected = ran->got = FS_IO;
	fs_path(ran->line, "%s\t%s", label, desc);
	ran->skipped = !fs_on_this_os(r->spells[c->load].os) || !fs_on_this_os(r->spells[c->save].os);
	for (size_t i = 0; i < c->nevents; i++)
		if (!fs_on_this_os(r->events[c->events[i]].os)) ran->skipped = 1;
	if (ran->skipped) return 0;

	char root[FS_PATH], x[FS_PATH], rp[FS_PATH], xw[FS_PATH], rw[FS_PATH];
	fs_path(root, "%s/%s", base, label);
	for (char *s = root + strlen(base); *s; s++)
		if (*s == ':') *s = '-';
	fs_path(x, "%s/x", root);
	fs_path(rp, "%s/r", root);
	fs_build(x, c);
	fs_build(rp, c);
	const fs_rule *load = &r->spells[c->load], *save = &r->spells[c->save];
	fs_path(xw, "%s/w", x);
	fs_path(rw, "%s/w", rp);
	char load_path[FS_PATH], x_load_at[FS_PATH], r_load_at[FS_PATH], p[FS_PATH];
	fs_spelled(load_path, load, xw);
	fs_from_root(x_load_at, x, load->cwd, load_path);
	fs_spelled(p, load, rw);
	fs_from_root(r_load_at, rp, load->cwd, p);

	// codeql[cpp/path-injection] the case's own path, from the shared rules file, under its own folder
	fs_at before_load = fs_at_path(x_load_at);
	fs_path(p, "%s/%s", x, load->cwd);
	fs_chdir(p);
	shcl_file_status st;
	// codeql[cpp/path-injection] the case's own path, from the shared rules file, under its own folder
	shcl_doc *doc = shcl_load_file(load_path, &st);
	if (!doc) fs_fatal("out of memory at the load");
	const fs_at *loaded = before_load.kind == FS_FILE && (st == SHCL_FILE_CLEAN || st == SHCL_FILE_HAD_ERRORS) ? &before_load : NULL;
	(void)shcl_set_int(doc, "k", 1, 7);

	const char *save_cwd = save->cwd;
	for (size_t i = 0; i < c->nevents; i++) {
		const char *name = r->events[c->events[i]].name;
		if (!strcmp(name, "chdir")) save_cwd = !strcmp(save_cwd, "w") ? "o" : "w";
		const char *trees[] = {x, rp};
		for (size_t k = 0; k < 2; k++) {
			char w[FS_PATH], sp[FS_PATH], lp[FS_PATH], at[FS_PATH];
			fs_path(w, "%s/w", trees[k]);
			fs_spelled(sp, load, w);
			fs_from_root(lp, trees[k], load->cwd, sp);
			fs_spelled(sp, save, w);
			fs_from_root(at, trees[k], save_cwd, sp);
			// codeql[cpp/path-injection] the case's own path, from the shared rules file, under its own folder
			fs_apply(name, trees[k], lp, at);
		}
	}

	char save_path[FS_PATH], x_save_at[FS_PATH], r_save_at[FS_PATH];
	fs_spelled(save_path, save, xw);
	fs_from_root(x_save_at, x, save_cwd, save_path);
	fs_spelled(p, save, rw);
	fs_from_root(r_save_at, rp, save_cwd, p);
	// codeql[cpp/path-injection] the case's own path, from the shared rules file, under its own folder
	ran->expected = fs_oracle(x_save_at, r_save_at, r_load_at, save_path, loaded, c, &ran->same);
	fs_at_free(&before_load);

	fs_buf before = {0}, after = {0};
	fs_snapshot(&before, x);
	char save_dir[FS_PATH];
	fs_path(save_dir, "%s/%s", x, save_cwd);
	fs_chdir(save_dir);
	shcl_save_options opts = {0};
	opts.lossy = 1;
	opts.force = c->force;
	opts.create = c->create;
	shcl_write_status w = SHCL_WRITE_OK;
	// codeql[cpp/path-injection] the case's own path, from the shared rules file, under its own folder
	shcl_save_result first = shcl_save_file_with(doc, save_path, opts, NULL, &w);
	ran->got = fs_classify(first, w);
	fs_chdir(base);
	int kept = 1;
	if (ran->got != ran->expected) {
		fs_printf(why, "expected %s, got %s", fs_outcome_names[ran->expected], fs_outcome_names[ran->got]);
	} else if (ran->got == FS_OK) {
		// A file already there keeps its mode, so one an event took the read
		// bits off is still unreadable after the save.
		fs_at a = fs_at_path(x_save_at);
		if (a.kind == FS_UNREADABLE) {
			(void)chmod(x_save_at, 0600);
			a = fs_at_path(x_save_at);
		}
		shcl_str want = shcl_to_canonical(doc);
		if (!fs_at_is_file(&a, want.p, want.n)) {
			fs_printf(why, "saved, but the path holds kind %d, \"%s\"", (int)a.kind, a.bytes ? a.bytes : "");
			fs_at_free(&a);
		} else {
			fs_at_free(&a);
			// What this document last wrote is no change, and a create-only
			// save now finds its own file.
			fs_chdir(save_dir);
			shcl_save_result again = shcl_save_file_with(doc, save_path, opts, NULL, &w);
			fs_chdir(base);
			fs_outcome got = fs_classify(again, w), want_again = c->create ? FS_EXISTS : FS_OK;
			if (got != want_again) fs_printf(why, "the second save gave %s", fs_outcome_names[got]);
			else kept = 0;
		}
	} else {
		fs_snapshot(&after, x);
		if (strcmp(after.p, before.p)) fs_printf(why, "refused as %s, but the tree changed:\nbefore:\n%safter:\n%s", fs_outcome_names[ran->got], before.p, after.p);
		else kept = 0;
	}
	fs_buf_free(&before);
	fs_buf_free(&after);
	shcl_free(doc);
	if (kept) {
		fs_buf msg = {0};
		fs_printf(&msg, "%s: %s\n\tthe tree is kept at %s", ran->line, why->p, root);
		fs_buf_free(why);
		*why = msg;
		return 1;
	}
	fs_remove_tree(root);
	return 0;
}

// The folder the cases go in: SHCL_FS_DIR, or the temp folder with a note,
// never the project tree.
static void fs_base_dir(char *out, const char *test) {
	const char *parent = getenv("SHCL_FS_DIR");
	if (!parent || !*parent) {
		parent = getenv("TMPDIR");
		if (!parent || !*parent) parent = "/tmp";
		fprintf(stderr, "note: SHCL_FS_DIR is not set, so the filesystem cases go under %s\n", parent);
	}
	char base[FS_PATH];
	fs_path(base, "%s/shcl-fs-c-%ld-%s", parent, (long)getpid(), test);
	fs_remove_tree(base);
	fs_must(fs_mkdir_all(base, 0755), "mkdir", base);
	char *real = realpath(base, NULL);
	if (!real) fs_fatal("realpath %s: %s", base, strerror(errno));
	fs_path(out, "%s", real);
	free(real);
}

// A count from the environment, the whole value once spaces are trimmed, into
// *out. 0 when it isn't one.
static int fs_env_count(const char *v, uint64_t *out) {
	while (*v == ' ' || *v == '\t' || *v == '\n') v++;
	if (*v < '0' || *v > '9') return 0;
	char *end = NULL;
	errno = 0;
	unsigned long long n = strtoull(v, &end, 10);
	while (*end == ' ' || *end == '\t' || *end == '\n') end++;
	if (errno || *end || n > UINT64_MAX) return 0;
	*out = (uint64_t)n;
	return 1;
}

// The cases a test ran, one line each, written to fs/NAME.tsv under
// SHCL_FUZZ_DUMP, up to SHCL_FUZZ_DUMP_MAX lines.
static void fs_dump(const char *name, const fs_buf *lines) {
	const char *dir = getenv("SHCL_FUZZ_DUMP");
	if (!dir || !*dir) return;
	uint64_t max = 5000;
	const char *mv = getenv("SHCL_FUZZ_DUMP_MAX");
	if (mv) (void)fs_env_count(mv, &max);
	char p[FS_PATH];
	fs_path(p, "%s/fs", dir);
	fs_must(fs_mkdir_all(p, 0755), "mkdir", p);
	fs_path(p, "%s/fs/%s.tsv", dir, name);
	size_t n = 0;
	for (uint64_t k = 0; k < max && n < lines->n; k++) {
		const char *nl = memchr(lines->p + n, '\n', lines->n - n);
		n = nl ? (size_t)(nl - lines->p) + 1 : lines->n;
	}
	// codeql[cpp/path-injection] the folder the pipeline names, as SHCL_FUZZ_DUMP is for every binding
	fs_must(fs_write_bytes(p, lines->p, n), "write", p);
}

static void fs_dump_line(fs_buf *lines, const fs_ran *ran) {
	if (ran->skipped) fs_printf(lines, "%s\tskipped\n", ran->line);
	else fs_printf(lines, "%s\tsame=%d\t%s\n", ran->line, ran->same, fs_outcome_names[ran->got]);
}

// SHCL_FS_SECS, 2 when unset. A value that isn't a count is a mistake, not a
// setting.
static uint64_t fs_budget_secs(void) {
	const char *v = getenv("SHCL_FS_SECS");
	uint64_t n = 2;
	if (v && (!fs_env_count(v, &n) || n > UINT32_MAX)) fs_fatal("SHCL_FS_SECS is not a count: \"%s\"", v);
	return n;
}

typedef struct {
	const char *id;
	// The row's own platform where its spellings don't say, for an item whose
	// bug was on one platform only.
	const char *only;
	int t, o;
	const char *load, *save;
	const char *events[FS_MAX_EVENTS + 1];
	int create;
	fs_outcome expected;
} fs_row;

// One row per past bug of the class, each a case the generator can draw.
// 2026110313211991 was the CLIs' own check; its library twin is the FIFO row.
static const fs_row fs_rows[] = {
	{"2026102910482342", "any", 1, 0, "bare", "bare", {"write-load"}, 0, FS_CHANGED},
	{"2026110312163201-gone", "any", 1, 0, "bare", "dot", {"remove-load"}, 0, FS_OK},
	{"2026110312163201-made", "any", 0, 0, "bare", "bare", {"write-load"}, 0, FS_CHANGED},
	{"2026110312163201-abs", "any", 1, 0, "dot", "abs", {"write-load"}, 0, FS_CHANGED},
	{"2026110312163202-fifo", "any", 1, 0, "dot", "dot", {"fifo-load"}, 0, FS_NOT_REGULAR},
	{"2026110312163202-unread", "any", 1, 0, "dot", "dot", {"write-load", "unread"}, 0, FS_CHANGED},
	{"2026110312163207", "any", 0, 0, "dangle", "dangle", {"none"}, 1, FS_EXISTS},
	{"2026110314064292", "any", 0, 0, "bare", "nodir", {"none"}, 0, FS_IO},
	{"2026110314240418", "any", 0, 0, "nddot", "nd", {"mkdir", "write-load"}, 0, FS_CHANGED},
	{"2026110408432594-link", "windows", 0, 0, "dangle", "dangle", {"none"}, 1, FS_EXISTS},
	{"2026110408432594-dot", "windows", 0, 0, "nddot", "nd", {"mkdir", "write-load"}, 0, FS_CHANGED},
	{"2026110613470307", "any", 0, 0, "nodir", "nodir", {"mkdir", "write-save"}, 0, FS_CHANGED},
	{"2026110613470307-otherwd", "any", 1, 1, "bare", "bare", {"chdir"}, 0, FS_CHANGED},
	{"2026110613470308-trail", "any", 1, 0, "bare", "trail", {"none"}, 0, FS_IS_DIRECTORY},
	{"2026110613470308-dot", "any", 1, 0, "bare", "traildot", {"none"}, 1, FS_IS_DIRECTORY},
	{"2026110613470308-swap", "any", 1, 0, "bare", "bare", {"dir-load"}, 0, FS_IS_DIRECTORY},
};

static size_t fs_index(const fs_rule *rules, size_t n, const char *name) {
	for (size_t i = 0; i < n; i++)
		if (!strcmp(rules[i].name, name)) return i;
	fs_fatal("fs-rules.tsv has no \"%s\", which a fixed row names", name);
}

// Every past bug of the class, as a fixed row the generator can draw too.
// 0 when every row held.
static int the_save_checks_hold_on_every_past_path_bug(const fs_rules *r) {
	char base[FS_PATH];
	fs_base_dir(base, "rows");
	fs_buf lines = {0};
	fs_puts(&lines, "");
	int failed = 0;
	for (size_t i = 0; i < sizeof fs_rows / sizeof fs_rows[0]; i++) {
		const fs_row *row = &fs_rows[i];
		fs_case c = {0};
		c.t_there = row->t;
		c.o_there = row->o;
		c.load = fs_index(r->spells, r->nspells, row->load);
		c.save = fs_index(r->spells, r->nspells, row->save);
		c.create = row->create;
		for (size_t e = 0; row->events[e]; e++) c.events[c.nevents++] = fs_index(r->events, r->nevents, row->events[e]);
		if (!fs_on_this_os(row->only)) {
			fs_printf(&lines, "row:%s\tskipped\n", row->id);
			continue;
		}
		// Every row runs, so one red run names each past bug that's back.
		char label[FS_PATH];
		fs_path(label, "row:%s", row->id);
		fs_ran ran;
		fs_buf why = {0};
		fs_puts(&why, "");
		if (fs_run_case(r, base, label, &c, &ran, &why)) {
			fprintf(stderr, "FAIL %s: %s\n", open_name, why.p);
			failed = 1;
			fs_buf_free(&why);
			continue;
		}
		fs_buf_free(&why);
		fs_dump_line(&lines, &ran);
		if (!ran.skipped && ran.expected != row->expected) {
			fprintf(stderr, "FAIL %s: %s: the oracle says %s, the row %s\n", open_name, ran.line,
				fs_outcome_names[ran.expected], fs_outcome_names[row->expected]);
			failed = 1;
		}
	}
	fs_dump("c-rows", &lines);
	fs_buf_free(&lines);
	if (!failed) fs_remove_tree(base);
	return failed;
}

static double fs_now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// Cases drawn by seed for the budget. Each case is a pure function of its
// seed, so a failure replays from the seed in its message. A run that never
// drew each spelling, event, answer, and both one file and 2, fails, since it
// didn't test what it says. 0 when it held.
static int the_save_checks_hold_on_drawn_paths_and_events(const fs_rules *r) {
	char base[FS_PATH], label[FS_PATH];
	fs_base_dir(base, "drawn");
	fs_ran ran;
	fs_buf why = {0};
	fs_puts(&why, "");
	const char *v = getenv("SHCL_FS_SEED");
	if (v) {
		uint64_t seed = 0;
		if (!fs_env_count(v, &seed)) fs_fatal("SHCL_FS_SEED is not a seed: \"%s\"", v);
		fs_path(label, "seed:%" PRIu64, seed);
		fs_case c = fs_draw(r, seed);
		if (fs_run_case(r, base, label, &c, &ran, &why)) {
			fprintf(stderr, "FAIL %s: %s\n", open_name, why.p);
			fs_buf_free(&why);
			return 1;
		}
		fs_buf line = {0};
		fs_dump_line(&line, &ran);
		fputs(line.p, stderr);
		fs_buf_free(&line);
		fs_buf_free(&why);
		fs_remove_tree(base);
		return 0;
	}
	double until = fs_now() + (double)fs_budget_secs();
	int spells[FS_MAX_RULES] = {0}, events[FS_MAX_RULES] = {0}, outcomes[FS_OUTCOMES] = {0}, sames[2] = {0};
	fs_buf lines = {0};
	fs_puts(&lines, "");
	uint64_t seed = 0;
	while (seed < FS_MIN_CASES || fs_now() < until) {
		fs_case c = fs_draw(r, seed);
		fs_path(label, "seed:%" PRIu64, seed);
		if (fs_run_case(r, base, label, &c, &ran, &why)) {
			fprintf(stderr, "FAIL %s: %s\n", open_name, why.p);
			fs_buf_free(&why);
			fs_buf_free(&lines);
			return 1;
		}
		fs_dump_line(&lines, &ran);
		if (!ran.skipped) {
			spells[c.load] = spells[c.save] = 1;
			for (size_t i = 0; i < c.nevents; i++) events[c.events[i]] = 1;
			outcomes[ran.got] = 1;
			sames[ran.same] = 1;
		}
		seed++;
	}
	fs_buf_free(&why);
	fs_dump("c-drawn", &lines);
	fs_buf_free(&lines);
	int failed = 0;
	for (size_t i = 0; i < r->nspells; i++)
		if (fs_on_this_os(r->spells[i].os) && !spells[i]) {
			fprintf(stderr, "FAIL %s: %" PRIu64 " cases never drew the spelling %s\n", open_name, seed, r->spells[i].name);
			failed = 1;
		}
	for (size_t i = 0; i < r->nevents; i++)
		if (fs_on_this_os(r->events[i].os) && !events[i]) {
			fprintf(stderr, "FAIL %s: %" PRIu64 " cases never drew the event %s\n", open_name, seed, r->events[i].name);
			failed = 1;
		}
	for (size_t o = 0; o < FS_OUTCOMES; o++)
		if (!outcomes[o]) {
			fprintf(stderr, "FAIL %s: %" PRIu64 " cases never gave %s\n", open_name, seed, fs_outcome_names[o]);
			failed = 1;
		}
	if (!sames[0] || !sames[1]) {
		fprintf(stderr, "FAIL %s: %" PRIu64 " cases never gave both one file and 2\n", open_name, seed);
		failed = 1;
	}
	if (!failed) fs_remove_tree(base);
	return failed;
}

// Runs one test and prints its status line. 1 when it failed.
static int fs_run(int drawn, const char *file) {
	static fs_rules r;
	if (!r.text) fs_read_rules(&r, file);
	// The cases change the working folder, so it's put back after each test.
	char back[FS_PATH];
	if (!getcwd(back, sizeof back)) fs_fatal("getcwd: %s", strerror(errno));
	int failed = drawn ? the_save_checks_hold_on_drawn_paths_and_events(&r) : the_save_checks_hold_on_every_past_path_bug(&r);
	fs_chdir(back);
	test_id_end(failed ? "FAIL" : "PASS");
	return failed;
}

#endif

int main(int argc, char **argv) {
	// The clock every runner pins, as conformance.c does.
#ifdef _WIN32
	_putenv_s("SHCL_TEST_CLOCK", TEST_CLOCK);
#else
	setenv("SHCL_TEST_CLOCK", TEST_CLOCK, 1);
#endif
	const char *file = argc > 1 ? argv[1] : "project/fs-rules.tsv";
	test_id("df4ep", "the_save_checks_hold_on_every_past_path_bug");
	int failed = fs_run(0, file);
	test_id("df4eq", "the_save_checks_hold_on_drawn_paths_and_events");
	failed |= fs_run(1, file);
	return failed;
}
