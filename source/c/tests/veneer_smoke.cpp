// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Compile + behavior smoke for the C++ veneer. Full behavior is pinned by the C
// core's conformance runner; this just proves the typed surface builds and
// delegates correctly, so the header can't silently rot. Exit nonzero on a miss.

#define SHCL_IMPLEMENTATION
#include "shcl.hpp"

#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#ifndef SHCL_NO_FILE_IO
#include <sys/stat.h>
#include <unistd.h>
#ifdef _WIN32
#include <direct.h>   // _mkdir - windows' mkdir takes no mode argument
#endif
#endif

static int fails = 0;
#define CHECK(cond) do { if (!(cond)) { std::fprintf(stderr, "veneer FAIL: %s (line %d)\n", #cond, __LINE__); fails++; } } while (0)

int main() {
	const std::string src =
		"name: demo\n"
		"port: 8080\n"
		"ratio: 3.5\n"
		"on: yes\n"
		"tags: red, green, blue\n"
		"city: Chicago\n"
		"city: Boston\n";

	auto doc = shcl::Document::parse(src);
	// False only when the parse could not allocate, so every accessor below
	// is asking about a document that exists.
	CHECK(static_cast<bool>(doc));

	auto port = doc.get<int64_t>("port");
	CHECK(port.ok() && port.status == shcl::Status::Good && port.value == 8080);

	auto ratio = doc.read_float("ratio");
	CHECK(ratio.ok() && ratio.value == 3.5);

	auto name = doc.get<std::string>("name");
	CHECK(name.value == "demo");

	// yes is a Standard boolean.
	auto on = doc.read_bool("on");
	CHECK(on.ok() && on.value == true);

	auto tags = doc.read_string_array("tags");
	CHECK(tags.ok() && tags.value.size() == 3 && tags.value[1] == "green");

	// Two same-name leaves are instances, not one scalar.
	CHECK(doc.count("city") == 2);

	CHECK(shcl::quote_segment("port") == "port");
	CHECK(shcl::quote_segment("q n") == "\"q n\"");
	auto cities = doc.instances("city");
	CHECK(cities.size() == 2 && cities[0] == "Chicago" && cities[1] == "Boston");

	CHECK(doc.line("port") == 2 && doc.line("nope") == 0);
	auto cityLines = doc.lines("city");
	CHECK(cityLines.size() == 2 && cityLines[0] == 6 && cityLines[1] == 7);
	CHECK(doc.lines("nope").empty());
	auto kids = doc.children("");
	CHECK(kids.size() == 7 && kids[0] == "name" && kids[5] == "city" && kids[6] == "city");
	CHECK(doc.children("nope").empty());
	CHECK(doc.write_reason("port") == shcl::WriteReason::Writable);
	CHECK(doc.write_reason("city[*]") == shcl::WriteReason::Wildcard);
	auto multi = doc.read_string("city");
	CHECK(multi.status == shcl::Status::Multiple);

	// Loose strictness widens coercions.
	auto loose = shcl::Document::parse_with("pct: 50%\n", shcl::Strictness::Loose);
	auto pct = loose.read_float("pct");
	CHECK(pct.ok() && pct.value == 0.5);

	// Canonical form is stable and re-parseable.
	std::string canon = doc.to_canonical();
	auto again = shcl::Document::parse(canon);
	CHECK(again.to_canonical() == canon);

	auto missing = doc.read_int("nope");
	CHECK(missing.status == shcl::Status::NotFound);

	// Convenience tier: value on Good, call-site fallback otherwise.
	CHECK(doc.get_or<int64_t>("port", 9) == 8080);
	CHECK(doc.get_or<int64_t>("nope", 9) == 9);
	CHECK(doc.get_or<std::string>("nope", std::string("fb")) == "fb");

	// The rest of the read surface the veneer used to be missing: the quoted
	// flag, existence, per-slot array statuses, and the datetime array.
	auto qd = shcl::Document::parse("a: @null\nb: \"@null\"\nnums: 1, x, 3\nwhen: 2026-08-02, nope\n");
	CHECK(!qd.quoted("a") && qd.quoted("b") && !qd.quoted("nope"));
	CHECK(qd.exists("a") && !qd.exists("nope"));
	auto nums = qd.read_int_array("nums");
	CHECK(nums.slots.size() == 3 && nums.slots[0] == shcl::Status::Good && nums.slots[1] == shcl::Status::BadType);
	CHECK(qd.read_int("a").slots.empty()); // scalar reads carry no slots
	auto when = qd.read_datetime_array_str("when");
	CHECK(when.value.size() == 2 && when.value[0] == "2026-08-02" && when.slots[1] == shcl::Status::BadType);
	auto whenDt = qd.read_datetime_array("when");
	CHECK(whenDt.value.size() == 2 && whenDt.value[0].str() == "2026-08-02" && whenDt.slots[1] == shcl::Status::BadType);
	CHECK(std::string(shcl::to_string(shcl::Status::BadType)) == "BadType");
	CHECK(shcl::status_code(shcl::Status::Good) == 0 && shcl::status_code(shcl::Status::Multiple) == 5);
	CHECK(shcl::strictness_from_arg("STRICT") == shcl::Strictness::Strict && shcl::strictness_from_arg("1") == shcl::Strictness::Loose);
	CHECK(!shcl::strictness_from_arg("4") && !shcl::strictness_from_arg(""));
	CHECK(shcl::format_float(0.1) == "0.1" && shcl::format_float(-2.5) == "-2.5");
	CHECK(shcl::parse_datetime("2026-07-12T09:30Z")->str() == "2026-07-12T09:30Z");
	// The fields are the reference's: what was written, and nothing else.
	{
		auto dt = *shcl::parse_datetime("2026-07-12T09:30:05.250-05:30");
		const shcl::Date day{2026, 7, 12};
		const shcl::Time at{9, 30, 5u};
		CHECK(dt.date == day && dt.time == at && dt.frac == std::string("250"));
		CHECK(dt.zone && dt.zone->kind == shcl::ZoneKind::Offset && dt.zone->offset_minutes == -330);
		auto clock = *shcl::parse_datetime("09:30");
		CHECK(!clock.date && clock.time && !clock.time->second && !clock.frac && !clock.zone);
		const shcl::Zone utc{shcl::ZoneKind::Utc, 0};
		CHECK(shcl::parse_datetime("2026-07-12T09:30Z")->zone == utc);
		shcl::DateTime built;
		built.date = shcl::Date{2026, 1, 2};
		built.time = shcl::Time{3, 4, std::nullopt};
		CHECK(built.str() == "2026-01-02T03:04" && built == *shcl::parse_datetime("2026-01-02T03:04"));
		CHECK(built != *shcl::parse_datetime("2026-01-02T03:04Z"));
	}
	// The format constants are the C macros, so there is one copy of each.
	CHECK(shcl::MAX_DEPTH == 512 && shcl::FORMAT_MAJOR == 3 && shcl::FORMAT_LINE == "##    Format   3");
	CHECK(shcl::FORMAT_LINE.substr(0, shcl::FORMAT_LINE_HEAD.size()) == shcl::FORMAT_LINE_HEAD);
	CHECK(shcl::GEN_BANNER.find(shcl::FORMAT_LINE) != std::string_view::npos && shcl::MIGRATED_LINE == "##    Migrated from SHCL 2.x.");
	CHECK(!shcl::parse_datetime("notadate") && !shcl::parse_datetime(""));

	// The rest of the surface, item by item: strictness, strict_failed, paths,
	// authored_name, the raw pair, the float/bool arrays, and the typed get
	// over double and bool.
	CHECK(doc.strictness() == shcl::Strictness::Standard);
	CHECK(!doc.strict_failed());
	auto strictDoc = shcl::Document::parse_with("x 1\n", shcl::Strictness::Strict);
	CHECK(strictDoc.strict_failed());
	// parse_limited: a capped load stops with E020, the parsed part readable.
	auto capped = shcl::Document::parse_limited("a: 1\nb: 2\nc: 3\nd: 4\n", shcl::Strictness::Standard, 2, 0, 0);
	CHECK(capped.error_count() == 1 && capped.get_or<std::int64_t>("a", 0) == 1 && !capped.exists("d"));
	auto elCapped = shcl::Document::parse_limited("arr: 1, 2, 3\n", shcl::Strictness::Standard, 0, 2, 0);
	CHECK(elCapped.error_count() == 1 && !elCapped.exists("arr"));
	auto allPaths = doc.paths();
	CHECK(allPaths.size() == 6 && allPaths[0] == "name" && allPaths[5] == "city");
	// A repeated key: every instance's children, and a path per instance.
	auto acct = shcl::Document::parse("account: w\n\temail: e@x\n\t\tsshkey: k1\n\temail: f@x\n\t\tsshkey: k2\n");
	CHECK(acct.children("account.email").size() == 2);
	auto each = acct.instance_paths();
	CHECK(each.size() == 5 && each[1] == "account.email[#0]" && each[4] == "account.email[#1].sshkey");
	auto spelled = shcl::Document::parse("SYMBOLS: 3\n");
	CHECK(spelled.authored_name("symbols") == "SYMBOLS");
	CHECK(spelled.authored_name("missing").empty());
	auto rawDoc = shcl::Document::parse("blk:\n\t```sql\n\tselect 1\n\t```\n");
	auto rb = rawDoc.read_raw("blk");
	CHECK(rb.ok() && rb.value == "select 1");
	CHECK(rawDoc.read_raw_info("blk").value == "sql");
	CHECK(rawDoc.read_raw("missing").status == shcl::Status::NotFound);
	auto fa = qd.read_float_array("nums");
	CHECK(fa.slots.size() == 3 && fa.slots[1] == shcl::Status::BadType && fa.value[2] == 3.0);
	auto ba = shcl::Document::parse("flags: true, false, x\n").read_bool_array("flags");
	CHECK(ba.value.size() == 3 && ba.value[0] && !ba.value[1] && ba.slots[2] == shcl::Status::BadType);
	CHECK(doc.get<double>("ratio").value == 3.5);
	CHECK(doc.get<bool>("on").value == true);
	CHECK(doc.get_or<double>("ratio", 0.0) == 3.5);
	CHECK(doc.get_or<double>("nope", 1.25) == 1.25);
	CHECK(doc.get_or<bool>("on", false) == true);
	CHECK(doc.get_or<bool>("nope", true) == true);
	// The rest of the convenience tier, which C leaves out because its reads
	// borrow memory and the veneer's copy it.
	CHECK(doc.get_or<std::vector<std::string>>("tags", {}) == std::vector<std::string>({"red", "green", "blue"}));
	CHECK(doc.get_or<std::vector<int64_t>>("tags", {7}) == std::vector<int64_t>({7}));
	CHECK(qd.get_or<std::vector<double>>("nums", {}).empty()); // a bad slot is not Good
	CHECK(doc.get_or<std::vector<bool>>("nope", {true}) == std::vector<bool>({true}));
	auto oneDay = shcl::Document::parse("d: 2026-08-02\nds: 2026-08-02, 2026-08-03\n");
	auto fallbackDay = oneDay.read_datetime("d").value;
	CHECK(oneDay.get_or<shcl::DateTime>("d", shcl::DateTime()).str() == "2026-08-02");
	CHECK(oneDay.get_or<shcl::DateTime>("nope", fallbackDay).str() == "2026-08-02");
	auto days = oneDay.get_or<std::vector<shcl::DateTime>>("ds", {});
	CHECK(days.size() == 2 && days[1].str() == "2026-08-03");
	CHECK(rawDoc.get_raw_or("blk", "") == "select 1" && rawDoc.get_raw_info_or("blk", "") == "sql");
	CHECK(rawDoc.get_raw_or("missing", "fb") == "fb" && rawDoc.get_raw_info_or("missing", "fb") == "fb");

	// Schema validation rides through the veneer: a conforming doc is clean, a
	// violation carries its stable V-code, and a key-level schema fault still
	// lets the unknown-field sweep run (the faulted entry keeps its path).
	auto schema = shcl::Document::parse("field: port\n\ttype: int\n\tmin: 1\nfield: city\nfield: ratio\nfield: name\nfield: on\nfield: tags\n");
	CHECK(doc.validate(schema).empty());
	auto badschema = shcl::Document::parse("field: port\n\ttype: int\n\tmin: 90000\n");
	auto vd = doc.validate(badschema);
	CHECK(vd.size() >= 1 && vd[0].code == "V005");
	auto broken = shcl::Document::parse("field: port\n\tfrobnicate: 1\n");
	auto fd = doc.validate(broken);
	CHECK(fd.size() >= 2 && fd[0].code == "V090" && fd.back().code == "V001");

	// Layered loading: overlay a higher-priority doc; leaf override, container merge.
	auto base = shcl::Document::parse("port: 8080\nserver: web1\n\tport: 80\n");
	auto over = shcl::Document::parse("port: 9090\nserver: web1\n\thost: h1\n");
	base.merge(over);
	CHECK(base.get_or<int64_t>("port", 0) == 9090);
	CHECK(base.get_or<int64_t>("server[web1].port", 0) == 80);
	CHECK(base.get_or<std::string>("server[web1].host", std::string()) == "h1");
	// Merged onto itself, a document is left as it is (20260918b item 19).
	{
		auto self = shcl::Document::parse("# c\na: 1\nbad line\n");
		auto before = self.to_canonical();
		self.merge(self);
		CHECK(self.to_canonical() == before);
	}
	// Compaction: the same document in fresh storage.
	auto beforeCompact = base.to_canonical();
	base.compact();
	CHECK(base.to_canonical() == beforeCompact && base.get_or<int64_t>("port", 0) == 9090);

	// Schema-driven generation: a starter config with a required live field.
	// The default run appends the format footer; --no-banner is the same bytes
	// without it.
	auto gschema = shcl::Document::parse("field: port\n\ttype: int\n\trequired: yes\n\tdefault: 8080\n");
	// The 2.x rewrite comes back as an owned string: the selector sugar loses
	// its colon and a bare backslash escape is double-quoted.
	// Told the file is 2.x, the backslash value is re-spelled and the result is
	// stamped with the format line, which is what makes a second run a no-op.
	auto mig = shcl::migrate("base:[Boston]\n\tlat: 42\nnote: a\\tb\n", true);
	CHECK(mig.text == "base: Boston\n\tlat: 42\nnote: \"a\\tb\"\n##    Format   3\n##    Migrated from SHCL 2.x.\n");
	CHECK(!mig.current && mig.ambiguous == 0 && mig.lost == 0);
	CHECK(shcl::migrate(mig.text, true).current);
	// Not told, and the file does not say: the value reads one way under each
	// rule set, so it is left as written and counted rather than guessed at.
	auto amb = shcl::migrate("note: a\\tb\n", false);
	CHECK(amb.ambiguous == 1 && amb.text == "note: a\\tb\n");
	// Without the stamp, for a program that writes the info block itself; the
	// Format line is what format_version reads.
	auto unst = shcl::migrate_unstamped("base:[Boston]\n\tlat: 42\nnote: a\\tb\n", true);
	CHECK(unst.text == "base: Boston\n\tlat: 42\nnote: \"a\\tb\"\n" && !unst.current);
	CHECK(shcl::format_version(mig.text) == 3u && !shcl::format_version(unst.text));
	// The Schema line, first one wins; one in a raw body is content.
	CHECK(shcl::schema_ref("x: 1\n##    Schema   ./a.shcl  \n##    Schema   b\n") == std::optional<std::string>("./a.shcl"));
	CHECK(!shcl::schema_ref("r:\n\t```\n##    Schema   a\n\t```\n"));
	CHECK(std::string(shcl::SCHEMA_LINE_HEAD) + "x" == "##    Schema   x");
	auto [bare, bareFaults] = shcl::generate(gschema, true);
	CHECK(bareFaults.empty() && bare == "## int, required\nport: 8080\n");
	auto [starter, starterFaults] = shcl::generate(gschema);
	CHECK(starterFaults.empty() && starter.rfind(bare, 0) == 0);
	CHECK(starter.find("This config file format is SHCL.", bare.size()) != std::string::npos);
	auto faulty = shcl::generate(shcl::Document::parse("field: port\n\tfrobnicate: 1\n"));
	CHECK(faulty.first.empty() && !faulty.second.empty() && faulty.second[0].code == "V090");
	// Generation-only codes come back from the call, the way the reference
	// returns them, and each call's list is its own. The schema keeps only its
	// own diagnostics, E014 here.
	auto genfault = shcl::Document::parse("field: p\n\ttype: int\n\trequired: yes\n\tmin: 1\n\tmax: 10\n\tdefault: 99\nbad line\n");
	for (int i = 0; i < 3; i++) {
		auto [gtext, gfaults] = shcl::generate(genfault, true);
		CHECK(gtext.empty() && gfaults.size() == 1 && gfaults[0].code == "V097" && gfaults[0].severity == shcl::Severity::Error);
	}
	auto ownDiags = genfault.diagnostics();
	CHECK(ownDiags.size() == 1 && ownDiags[0].code == "E014");
	// A default-constructed Document is an empty one, not a null handle.
	shcl::Document blank;
	CHECK(blank.to_canonical().empty() && blank.count("x") == 0 && blank.diagnostics().empty());

	// One-shot: one combined list (parse then validation), error predicate.
	auto combined = shcl::Document::load_and_validate(": nope\nport: x\n", "field: port\n\ttype: int\n", shcl::Strictness::Standard);
	auto cdiags = combined.diagnostics();
	CHECK(cdiags.size() == 2 && cdiags[0].code == "E014" && cdiags[1].code == "V003");
	CHECK(cdiags[0].severity == shcl::Severity::Error && cdiags[0].line == 1);
	auto hinted = shcl::Document::parse("a: 1\na: 2\n").diagnostics();
	CHECK(hinted.size() == 1 && hinted[0].code == "H001" && hinted[0].severity == shcl::Severity::Hint);
	CHECK(combined.error_count() == 2);
	CHECK(combined.get_or<std::string>("port", std::string()) == "x"); // doc still usable
	auto clean = shcl::Document::load_and_validate("a: 1\n", "", shcl::Strictness::Standard);
	CHECK(clean.error_count() == 0 && clean.diagnostics().empty());

	// A read must stay usable after the document it came from is gone; the
	// datetime one used to hand back a pointer into the freed arena.
	shcl::Read<shcl::DateTime> outlives;
	{
		auto tmp = shcl::Document::parse("t: 2026-08-02T10:20:30.123456789Z\n");
		outlives = tmp.read_datetime("t");
		// read_datetime is the structured read, matching every other binding;
		// read_datetime_str is the textual one. The old backwards pair is gone.
		CHECK(tmp.read_datetime_str("t").value == outlives.value.str());
	}
	CHECK(outlives.status == shcl::Status::Good);
	CHECK(outlives.value.str() == "2026-08-02T10:20:30.123456789Z");
	auto copied = outlives;
	CHECK(copied.value.str() == outlives.value.str());
	auto moved = std::move(copied);
	CHECK(moved.value == outlives.value && moved.value.frac == std::string("123456789"));

	// Writes, each read back through the veneer. A document from a parse could
	// not be written at all before the veneer had setters.
	{
		auto w = shcl::Document::parse("port: 8080\n");
		CHECK(w.set_int("port", 9090) && w.get_or<int64_t>("port", 0) == 9090);
		CHECK(w.set_float("ratio", 0.25) && w.get_or<double>("ratio", 0) == 0.25);
		CHECK(!w.set_float("inf", std::numeric_limits<double>::infinity()) && !w.exists("inf"));
		CHECK(w.set_bool("on", true) && w.get_or<bool>("on", false));
		CHECK(w.set_string("name", "a, b") && w.read_string("name").value == "a, b");
		CHECK(w.set_raw("q", "select 1", "sql") && w.get_raw_or("q", "") == "select 1" && w.get_raw_info_or("q", "") == "sql");
		CHECK(!w.set_raw("q2", "x", "c#") && !w.exists("q2"));
		CHECK(w.set_int_array("ports", {80, 443}) && w.read_int_array("ports").value == std::vector<int64_t>({80, 443}));
		CHECK(w.set_float_array("fs", {1.5, 2}) && w.read_float_array("fs").value == std::vector<double>({1.5, 2}));
		CHECK(w.set_bool_array("flags", {true, false, true}) && w.read_bool_array("flags").value == std::vector<bool>({true, false, true}));
		CHECK(w.set_string_array("tags", {"red", "a,b", ""}) && w.read_string_array("tags").value == std::vector<std::string>({"red", "a,b", ""}));
		CHECK(w.set_literal("lit", "80, 443 # two") && w.read_int_array("lit").value == std::vector<int64_t>({80, 443}));
		CHECK(!w.set_literal("lit2", "\"open") && !w.exists("lit2"));
		auto stamps = shcl::Document::parse("t: 2026-08-02T10:20:30.5Z, 2026-09-01\n").read_datetime_array("t");
		CHECK(stamps.ok() && stamps.value.size() == 2);
		CHECK(w.set_datetime("when", stamps.value[0]) && w.read_datetime_str("when").value == "2026-08-02T10:20:30.5Z");
		CHECK(w.set_datetime_array("whens", stamps.value) && w.read_datetime_array_str("whens").value == std::vector<std::string>({"2026-08-02T10:20:30.5Z", "2026-09-01"}));
		CHECK(!w.set_datetime("never", shcl::DateTime()) && !w.set_datetime_array("nevers", {stamps.value[1], shcl::DateTime()}));
		CHECK(w.set_empty("blank") && w.read_string("blank").status == shcl::Status::Empty);
		CHECK(w.set_comment("port", "the port") && w.to_canonical().find("# the port\nport: 9090\n") != std::string::npos);
		CHECK(!w.set_comment("port", "two\nlines"));
		CHECK(w.clear_comments("port") == 1 && w.to_canonical().find("# the port") == std::string::npos);
		CHECK(w.set_banner(true) == 0 && w.to_canonical().find("## This config file format is SHCL.\n") != std::string::npos);
		CHECK(w.set_banner(false) == 1 && w.to_canonical().find("##") == std::string::npos);
		// The save that keeps lines: an edit touches its own line only, a
		// document not loaded for it writes the canonical form.
		auto kept = shcl::Document::parse_keep_lines("Name:   \"x\"   # c\nblock:\n    a: 1\n", shcl::Strictness::Standard);
		CHECK(kept.to_text_keep_lines() == std::make_pair(std::string("Name:   \"x\"   # c\nblock:\n    a: 1\n"), true));
		CHECK(kept.set_int("block.a", 2) && kept.set_int("block.b", 3));
		CHECK(kept.to_text_keep_lines() == std::make_pair(std::string("Name:   \"x\"   # c\nblock:\n    a: 2\n    b: 3\n"), true));
		CHECK(w.to_text_keep_lines() == std::make_pair(w.to_canonical(), false));
		CHECK(!w.set_int("a[*]", 1) && w.write_reason("a[*]") == shcl::WriteReason::Wildcard);
		CHECK(w.remove("blank") == 1 && !w.exists("blank") && w.remove("blank") == 0);

		// A default form leaves a present field alone and still says whether the
		// value could have been written there.
		CHECK(w.set_int_default("port", 1) && w.get_or<int64_t>("port", 0) == 9090);
		CHECK(!w.set_float_default("ratio", std::numeric_limits<double>::infinity()) && w.get_or<double>("ratio", 0) == 0.25);
		CHECK(w.set_int_default("d.i", 1) && w.set_float_default("d.f", 0.5) && w.set_bool_default("d.b", false));
		CHECK(w.set_string_default("d.s", "x") && w.set_literal_default("d.l", "1, 2") && w.set_raw_default("d.r", "body", ""));
		CHECK(w.set_datetime_default("d.t", stamps.value[1]) && w.set_int_array_default("d.ia", {1}) && w.set_float_array_default("d.fa", {1.5}));
		CHECK(w.set_bool_array_default("d.ba", {true}) && w.set_string_array_default("d.sa", {"s"}) && w.set_datetime_array_default("d.ta", stamps.value));
		CHECK(w.set_string_default("d.s", "y") && w.get_or<std::string>("d.s", "") == "x");

		// All of it survives a save and a reload.
		auto back = shcl::Document::parse(w.to_canonical());
		CHECK(back.to_canonical() == w.to_canonical() && back.error_count() == 0);
		CHECK(back.get_or<int64_t>("d.i", 0) == 1 && back.get_or<double>("d.f", 0) == 0.5 && !back.get_or<bool>("d.b", true));
		CHECK(back.get_or<std::vector<int64_t>>("d.l", {}) == std::vector<int64_t>({1, 2}) && back.get_raw_or("d.r", "") == "body");
		CHECK(back.get_or<std::vector<std::string>>("tags", {}) == std::vector<std::string>({"red", "a,b", ""}));
		CHECK(back.read_datetime_array_str("d.ta").value == w.read_datetime_array_str("whens").value);
	}

	// The tokenizer, as `shcl tokens` shows a line.
	{
		shcl::Tokens tok;
		const std::string line = "srv[\"a b\"].port: 80, '', , x # note";
		shcl::tokenize(line, ':', false, shcl::Rules::Current, tok);
		CHECK(tok.segments.size() == 2 && !tok.fault_at && !tok.capped);
		CHECK(tok.segments[0].selector && tok.segments[0].selector->quote == shcl::Quote::Double);
		CHECK(line.substr(tok.segments[0].selector->start, tok.segments[0].selector->end - tok.segments[0].selector->start) == "a b");
		CHECK(line.substr(tok.segments[1].name.start, tok.segments[1].name.end - tok.segments[1].name.start) == "port");
		CHECK(!tok.segments[1].selector && tok.sep && line[*tok.sep] == ':');
		CHECK(tok.comment && line[*tok.comment] == '#');
		CHECK(line.substr(tok.value_start, tok.value_end - tok.value_start) == "80, '', , x");
		// Four pieces, and the empty bare one is not an element.
		CHECK(tok.elements.size() == 4 && tok.elements[1].quote == shcl::Quote::Single && tok.element_count() == 3);
		shcl::tokenize_value(line, *tok.sep + 1, shcl::Rules::Current, tok);
		CHECK(tok.segments.empty() && tok.elements.size() == 4 && tok.comment && line[*tok.comment] == '#');
		shcl::tokenize("*.port", '=', true, shcl::Rules::Current, tok);
		CHECK(tok.segments.size() == 2 && tok.segments[0].star && !tok.sep);
		shcl::tokenize("a[b: 1", ':', false, shcl::Rules::Current, tok);
		CHECK(tok.fault_at && std::string(tok.fault_why) == "unterminated selector");
		tok.cap = 1;
		shcl::tokenize("a: 1, 2, 3", ':', false, shcl::Rules::Current, tok);
		CHECK(tok.capped && tok.cap == 1 && !tok.fault_at && tok.fault_why == nullptr);
	}

	// The hints a schema disavows, dropped from a parsed document by hand.
	{
		auto reps = shcl::Document::parse("host: a\nhost: b\n");
		auto count = [](const shcl::Document &d, const char *code) { std::size_t n = 0; for (const auto &g : d.diagnostics()) if (g.code == code) n++; return n; };
		CHECK(count(reps, "H001") == 1);
		shcl::suppress_declared_repeats(shcl::Document::parse("field: host\n\trepeat: 0, 5\n"), reps);
		CHECK(count(reps, "H001") == 0);
		auto parts = shcl::Document::parse("s: a\n\tx: 1\nt: 1\ns: a\n\ty: 2\n");
		CHECK(count(parts, "H002") == 1);
		shcl::suppress_declared_reopens(shcl::Document::parse("field: s\n\treopen: true\nfield: s.x\nfield: s.y\nfield: t\n"), parts);
		CHECK(count(parts, "H002") == 0);
	}

	// A moved-from Document holds nothing, and says so.
	{
		auto given = shcl::Document::parse("port: 1\n");
		auto taken = std::move(given);
		CHECK(!given && taken && taken.get_or<int64_t>("port", 0) == 1);
	}

#ifndef SHCL_NO_FILE_IO
	// The file tier through the veneer: the load status, the strictness form,
	// the lost count, and a save gate whose refusal is a value the caller can
	// act on - which is the whole reason save_file is not a bool.
	{
		// TMPDIR is the POSIX spelling; windows sets TEMP/TMP and has no /tmp.
		const char *tmp = std::getenv("TMPDIR");
		if (!tmp || !*tmp) tmp = std::getenv("TEMP");
		if (!tmp || !*tmp) tmp = std::getenv("TMP");
		std::string dir = std::string(tmp && *tmp ? tmp : "/tmp") + "/shcl-veneer-" + std::to_string((long)getpid());
#ifdef _WIN32
		CHECK(_mkdir(dir.c_str()) == 0);
#else
		CHECK(mkdir(dir.c_str(), 0700) == 0);
#endif
		std::string f = dir + "/t.shcl";
		auto [absent, absentSt] = shcl::Document::load_file(f);
		CHECK(absent && absentSt == shcl::FileStatus::NotFound && absent.to_canonical().empty());
		CHECK(std::string(shcl::to_string(absentSt)) == "NotFound");
		{ FILE *fh = std::fopen(f.c_str(), "wb"); CHECK(fh && std::fputs("pct: 50%\n", fh) != EOF && std::fclose(fh) == 0); }
		auto [strict, strictSt] = shcl::Document::load_file_with(f, shcl::Strictness::Loose);
		CHECK(strictSt == shcl::FileStatus::Clean && strict.read_float("pct").value == 0.5);
		CHECK(shcl::read_file(f) == std::make_pair(std::string("pct: 50%\n"), shcl::FileStatus::Clean));
		CHECK(shcl::read_file(f, 8) == std::make_pair(std::string(), shcl::FileStatus::Unreadable));
		CHECK(strict.lost_count() == 0);
		CHECK(strict.save_file(f) == shcl::SaveResult::Ok);
		{ FILE *fh = std::fopen(f.c_str(), "wb"); CHECK(fh && std::fputs("a:   1\n", fh) != EOF && std::fclose(fh) == 0); }
		auto [keeping, keepingSt] = shcl::Document::load_file_keep_lines(f, shcl::Strictness::Standard);
		CHECK(keepingSt == shcl::FileStatus::Clean && keeping.set_int("b", 2));
		CHECK(keeping.save_file_keep_lines(f) == std::make_pair(shcl::SaveResult::Ok, true));
		CHECK(shcl::read_file(f).first == "a:   1\n\nb: 2\n");
		// An indent matching no level is lost when it is tabs; one holding a
		// space is kept as written.
		CHECK(shcl::Document::parse("a:\n\tb: 1\n  c: 2\n").lost_count() == 0);
		auto lost = shcl::Document::parse("a:\n\t\tb: 1\n\tc: 2\n");
		CHECK(lost.lost_count() == 1);
		CHECK(lost.save_file(f) == shcl::SaveResult::Refused);
		CHECK(lost.save_file_lossy(f) == shcl::SaveResult::Ok);
		CHECK(strict.save_file(dir + "/nope/t.shcl") == shcl::SaveResult::Failed);
		CHECK(shcl::write_file_atomic(f, "not: a save\n") && shcl::read_file(f).first == "not: a save\n");
		CHECK(shcl::write_file_atomic(f, "") && shcl::read_file(f) == std::make_pair(std::string(), shcl::FileStatus::Clean));
		CHECK(!shcl::write_file_atomic(dir + "/nope/t.shcl", "x"));
		std::remove(f.c_str());
		rmdir(dir.c_str());
	}
#endif

	// The veneer hands the core's read memory back on the next read, so a read
	// loop on one long-lived Document stays flat instead of climbing until the
	// Document is destroyed.
	{
		auto held = shcl::Document::parse("ports: 80, 443, 8080\n");
		for (int i = 0; i < 20000; i++) {
			auto r = held.read_int_array("ports");
			CHECK(r.status == shcl::Status::Good && r.value.size() == 3);
			if (r.status != shcl::Status::Good) break;
		}
		std::size_t held_bytes = 0;
		for (const ShclBlock *b = shcl::detail::Access::doc(held)->reads.head; b; b = b->next) held_bytes += b->used;
		CHECK(held_bytes <= 4096);
		// The canonical text is a read result too. 200 copies of a 30 KB
		// document held at once would be 6 MB; released per call it is one.
		std::string big;
		for (int i = 0; i < 2000; i++) big += "key" + std::to_string(i) + ": value" + std::to_string(i) + "\n";
		auto heldBig = shcl::Document::parse(big);
		for (int i = 0; i < 200; i++) CHECK(heldBig.to_canonical().size() == big.size());
		held_bytes = 0;
		for (const ShclBlock *b = shcl::detail::Access::doc(heldBig)->reads.head; b; b = b->next) held_bytes += b->used;
		CHECK(held_bytes <= 2 * big.size());
	}

	if (fails) { std::fprintf(stderr, "veneer: %d failure(s)\n", fails); return 1; }
	std::printf("veneer: ok\n");
	return 0;
}
