// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! Document generation.
//!
//! Every shape is built once as a small abstract model and then encoded by five
//! sibling encoders, so the five files hold the same data by construction rather
//! than by five hand-written generators agreeing with each other. Each encoder
//! writes the spelling a person would actually use in that format - SHCL raw
//! blocks against YAML block scalars against XML CDATA - because a size or parse
//! number taken from an unidiomatic encoding is not measuring the format.
//!
//! Deliberately absent: comments. Four of the five formats take them and JSON
//! does not, so including any would compare different documents.

use std::fmt::Write as _;

/// Nesting for the `deep` shape: 3 children per level, 6 levels under each
/// top-level subtree, so 729 leaf maps per unit - wide and deep at once rather
/// than a single narrow spine.
pub const DEEP_BRANCH: usize = 3;
pub const DEEP_LEVELS: usize = 6;

/// Lines in one `text` blob.
pub const TEXT_LINES: usize = 8;

/// Sections in the `config` shape - the whole file, not a repetition count.
pub const CONFIG_UNITS: usize = 11;

/// Size of the `ddl` shape's document. Big enough that a parser's behavior
/// shows, small enough to be a file somebody actually maintains.
pub const DDL_TARGET_BYTES: usize = 256 * 1024;

/// How many units a shape's document holds, or how many bytes it should reach.
pub enum Plan {
	Units(usize),
	Target(usize),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Shape {
	Flat,
	Deep,
	Records,
	Text,
	Config,
	Ddl,
}

impl Shape {
	pub fn name(self) -> &'static str {
		match self {
			Shape::Flat => "flat",
			Shape::Deep => "deep",
			Shape::Records => "records",
			Shape::Text => "text",
			Shape::Config => "config",
			Shape::Ddl => "ddl",
		}
	}
	pub fn from_name(s: &str) -> Option<Shape> {
		match s {
			"flat" => Some(Shape::Flat),
			"deep" => Some(Shape::Deep),
			"records" => Some(Shape::Records),
			"text" => Some(Shape::Text),
			"config" => Some(Shape::Config),
			"ddl" => Some(Shape::Ddl),
			_ => None,
		}
	}
	/// The root key holding every unit, for the shapes whose root is one list.
	pub fn list_key(self) -> Option<&'static str> {
		match self {
			Shape::Records => Some("service"),
			Shape::Ddl => Some("table"),
			_ => None,
		}
	}
	/// The four scaling shapes take whatever size the run asks for, because what
	/// they measure is parser behavior at volume. The two realistic ones carry
	/// their own size instead: a config file is a few kilobytes and a schema
	/// file a few hundred, and neither says anything useful at 64 MiB.
	pub fn plan(self, mib: usize) -> Plan {
		match self {
			Shape::Config => Plan::Units(CONFIG_UNITS),
			Shape::Ddl => Plan::Target(DDL_TARGET_BYTES),
			_ => Plan::Target(mib * 1024 * 1024),
		}
	}
	/// Units for the pre-flight equivalence check. The config file is checked
	/// whole - repeating its sections would collide top-level keys - and the
	/// deep shape is cut down because one unit of it is 729 leaf maps.
	pub fn verify_units(self, default: usize) -> usize {
		match self {
			Shape::Config => CONFIG_UNITS,
			Shape::Ddl => 20,
			Shape::Deep => default.div_ceil(50).max(1),
			_ => default,
		}
	}
	pub fn all() -> [Shape; 6] {
		[
			Shape::Flat,
			Shape::Deep,
			Shape::Records,
			Shape::Text,
			Shape::Config,
			Shape::Ddl,
		]
	}
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Fmt {
	Shcl,
	Json,
	Yaml,
	Toml,
	Xml,
}

impl Fmt {
	pub fn name(self) -> &'static str {
		match self {
			Fmt::Shcl => "shcl",
			Fmt::Json => "json",
			Fmt::Yaml => "yaml",
			Fmt::Toml => "toml",
			Fmt::Xml => "xml",
		}
	}
	pub fn ext(self) -> &'static str {
		match self {
			Fmt::Shcl => "shcl",
			Fmt::Json => "json",
			Fmt::Yaml => "yaml",
			Fmt::Toml => "toml",
			Fmt::Xml => "xml",
		}
	}
	pub fn from_name(s: &str) -> Option<Fmt> {
		match s {
			"shcl" => Some(Fmt::Shcl),
			"json" => Some(Fmt::Json),
			"yaml" => Some(Fmt::Yaml),
			"toml" => Some(Fmt::Toml),
			"xml" => Some(Fmt::Xml),
			_ => None,
		}
	}
	pub fn all() -> [Fmt; 5] {
		[Fmt::Shcl, Fmt::Json, Fmt::Yaml, Fmt::Toml, Fmt::Xml]
	}
}

pub enum Val {
	Str(String),
	Int(i64),
	Float(f64),
	Bool(bool),
	/// Multi-line, kept verbatim: a raw block, a block scalar, CDATA.
	Text(String),
	Arr(Vec<Val>),
}

pub enum Node {
	Leaf(Val),
	Map(Vec<(String, Node)>),
}

// The model, one unit at a time

/// One `flat` unit: a single top-level binding, cycling the scalar types so the
/// measurement is not one code path in each parser repeated a million times.
pub fn flat_unit(i: usize) -> (String, Node) {
	let key = format!("key-{i:07}");
	let v = match i % 5 {
		0 => Val::Str(format!("/srv/www/site-{i:07}")),
		1 => Val::Int((i as i64 % 65_536) - 32_768),
		2 => Val::Float(((i % 1000) as f64) / 10.0),
		3 => Val::Bool(i.is_multiple_of(2)),
		_ => Val::Str(format!("西部, 北 {}", i % 997)),
	};
	(key, Node::Leaf(v))
}

/// One `deep` unit: a balanced subtree, scalars only at the bottom.
pub fn deep_unit(i: usize) -> (String, Node) {
	(format!("tree-{i:05}"), deep_level(i, 0))
}

fn deep_level(i: usize, level: usize) -> Node {
	if level == DEEP_LEVELS {
		return Node::Map(vec![
			("id".into(), Node::Leaf(Val::Int((i % 100_000) as i64))),
			(
				"path".into(),
				Node::Leaf(Val::Str(format!("/n/{i:05}/{level}"))),
			),
			(
				"on".into(),
				Node::Leaf(Val::Bool((i + level).is_multiple_of(2))),
			),
		]);
	}
	let mut kids = Vec::with_capacity(DEEP_BRANCH);
	for b in 0..DEEP_BRANCH {
		kids.push((format!("n{b}"), deep_level(i * DEEP_BRANCH + b, level + 1)));
	}
	Node::Map(kids)
}

/// One `records` unit: an instance of the repeated root key, with the mix of
/// field kinds a real service block carries - including a value holding the
/// separator, so every encoder's quoting rules are exercised.
pub fn record_unit(i: usize) -> (String, Vec<(String, Node)>) {
	let name = format!("svc-{i:06}");
	let fields = vec![
		(
			"host".to_string(),
			Node::Leaf(Val::Str(format!(
				"10.{}.{}.{}",
				i % 250,
				(i / 250) % 250,
				(i * 7) % 250
			))),
		),
		(
			"port".to_string(),
			Node::Leaf(Val::Int(8000 + (i % 1000) as i64)),
		),
		(
			"enabled".to_string(),
			Node::Leaf(Val::Bool(!i.is_multiple_of(2))),
		),
		(
			"weight".to_string(),
			Node::Leaf(Val::Float(((i % 1000) as f64) / 10.0)),
		),
		(
			"started".to_string(),
			Node::Leaf(Val::Str(format!(
				"2026-0{}-1{}T0{}:3{}",
				1 + i % 9,
				i % 9,
				i % 9,
				i % 6
			))),
		),
		(
			"region".to_string(),
			Node::Leaf(Val::Str("西部, 北".to_string())),
		),
		(
			"tags".to_string(),
			Node::Leaf(Val::Arr(vec![
				Val::Str("fast".into()),
				Val::Str("eu, west".into()),
				Val::Str(format!("cheap{}", i % 13)),
			])),
		),
		(
			"limits".to_string(),
			Node::Map(vec![
				("cpu".to_string(), Node::Leaf(Val::Int(1 + (i % 16) as i64))),
				(
					"mem".to_string(),
					Node::Leaf(Val::Str(format!("{}Gi", i % 64))),
				),
				(
					"burst".to_string(),
					Node::Leaf(Val::Arr(
						(0..4).map(|j| Val::Int(((j * i) % 1000) as i64)).collect(),
					)),
				),
			]),
		),
	];
	(name, fields)
}

/// One `text` unit: a multi-line blob carrying the characters each format has to
/// escape or fence its way around.
pub fn text_unit(i: usize) -> (String, Node) {
	let mut body = String::new();
	for l in 0..TEXT_LINES {
		let _ = writeln!(
			body,
			"entry {i:06} line {l}: <tag attr=\"v\"> & 'quoted', \"double\", 100% of 5 < 6 -- 西部",
		);
	}
	(format!("doc-{i:06}"), Node::Leaf(Val::Text(body)))
}

// The two realistic shapes

fn s(v: &str) -> Node {
	Node::Leaf(Val::Str(v.to_string()))
}
fn int(v: i64) -> Node {
	Node::Leaf(Val::Int(v))
}
fn float(v: f64) -> Node {
	Node::Leaf(Val::Float(v))
}
fn boolean(v: bool) -> Node {
	Node::Leaf(Val::Bool(v))
}
fn list(items: &[&str]) -> Node {
	Node::Leaf(Val::Arr(
		items.iter().map(|x| Val::Str((*x).to_string())).collect(),
	))
}
fn map(kids: Vec<(&str, Node)>) -> Node {
	Node::Map(kids.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

/// One `config` unit: a section of an ordinary application config, in the order
/// somebody would write it. Sections rather than repetitions - a config file is
/// not a million of anything, so the whole file is one measurement and its
/// realistic size is the point.
///
/// The two top-level scalars come first because TOML requires that of any file
/// holding both scalars and tables, and the rest is chosen to hit what a config
/// actually contains: nesting, lists, every scalar type, a URL with a colon in
/// it, and a banner nobody wants reflowed.
pub fn config_unit(i: usize) -> (String, Node) {
	match i {
		0 => ("config_version".into(), int(3)),
		1 => ("environment".into(), s("production")),
		2 => (
			"server".into(),
			map(vec![
				("host", s("0.0.0.0")),
				("port", int(8443)),
				("workers", int(8)),
				("public_url", s("https://example.invalid/app")),
				(
					"tls",
					map(vec![
						("enabled", boolean(true)),
						("certificate", s("/etc/ssl/certs/app.pem")),
						("private_key", s("/etc/ssl/private/app.key")),
						("protocols", list(&["TLSv1.3", "TLSv1.2"])),
					]),
				),
				(
					"timeouts",
					map(vec![
						("read_seconds", int(30)),
						("write_seconds", int(30)),
						("idle_seconds", int(120)),
					]),
				),
			]),
		),
		3 => (
			"logging".into(),
			map(vec![
				("level", s("info")),
				("format", s("json")),
				("targets", list(&["stderr", "/var/log/app/app.log"])),
				("suppress", list(&["health-check", "static-asset"])),
				(
					"rotate",
					map(vec![
						("max_size_mb", int(64)),
						("keep", int(7)),
						("compress", boolean(true)),
					]),
				),
			]),
		),
		4 => (
			"database".into(),
			map(vec![
				("driver", s("postgres")),
				("host", s("db.internal")),
				("port", int(5432)),
				("name", s("app_production")),
				("user", s("app")),
				("sslmode", s("verify-full")),
				("statement_timeout_seconds", float(2.5)),
				(
					"pool",
					map(vec![
						("min_connections", int(2)),
						("max_connections", int(32)),
						("idle_timeout_seconds", int(300)),
					]),
				),
			]),
		),
		5 => (
			"cache".into(),
			map(vec![
				("backend", s("redis")),
				(
					"endpoints",
					list(&["cache-a.internal:6379", "cache-b.internal:6379"]),
				),
				("ttl_seconds", int(900)),
				("max_entries", int(50_000)),
			]),
		),
		6 => (
			"auth".into(),
			map(vec![
				("provider", s("oidc")),
				("issuer", s("https://login.example.invalid")),
				("session_minutes", int(720)),
				("allow_signup", boolean(false)),
				(
					"administrators",
					list(&["ops@example.invalid", "sre@example.invalid"]),
				),
				(
					"password",
					map(vec![
						("min_length", int(12)),
						("require_symbol", boolean(true)),
						("reject_common", boolean(true)),
					]),
				),
			]),
		),
		7 => (
			"paths".into(),
			map(vec![
				("data", s("/var/lib/app")),
				("uploads", s("/var/lib/app/uploads")),
				("temporary", s("/tmp/app")),
			]),
		),
		8 => (
			"limits".into(),
			map(vec![
				("upload_mb", int(25)),
				("requests_per_minute", int(600)),
				("burst", int(50)),
				("max_body_kb", int(512)),
				("concurrent_jobs", int(4)),
			]),
		),
		9 => (
			"features".into(),
			map(vec![
				("new_dashboard", boolean(true)),
				("audit_log", boolean(true)),
				("beta_search", boolean(false)),
				("export_csv", boolean(true)),
			]),
		),
		_ => (
			"motd".into(),
			map(vec![
				("enabled", boolean(true)),
				(
					"banner",
					Node::Leaf(Val::Text(
						"Maintenance runs Sundays, 02:00-03:00 UTC.\n\
						 Reach the on-call team at ops@example.invalid <#ops>.\n\
						 \"Read-only\" during a failover is normal; retry in a minute.\n\
						 歓迎 - the Tokyo & Berlin sites read this banner too.\n"
							.to_string(),
					)),
				),
			]),
		),
	}
}

/// Column templates for the `ddl` shape. A table takes a run of them, so the
/// definitions vary in width and in which optional clauses they carry, the way
/// a real schema does. An empty default or comment means the clause is absent
/// rather than blank.
#[rustfmt::skip]
const DDL_COLUMNS: &[(&str, &str, bool, &str, &str)] = &[
	("id",         "bigint",        false, "",        "Surrogate key, never reused"),
	("created_at", "timestamptz",   false, "now()",   "Set on insert, never touched again"),
	("updated_at", "timestamptz",   true,  "",        "Maintained by the row trigger"),
	("owner_id",   "bigint",        false, "",        ""),
	("name",       "varchar(120)",  false, "",        "Display name, unique per tenant"),
	("slug",       "varchar(120)",  false, "",        "URL segment, lower case"),
	("status",     "varchar(24)",   false, "'draft'", "draft, active, archived"),
	("amount",     "numeric(14,2)", true,  "0.00",    "Money, never a float"),
	("currency",   "char(3)",       true,  "'USD'",   "ISO 4217"),
	("quantity",   "integer",       true,  "0",       ""),
	("notes",      "text",          true,  "",        "Free text, sometimes long"),
	("metadata",   "jsonb",         true,  "'{}'",    "Whatever the app has not modeled yet"),
	("is_deleted", "boolean",       false, "false",   "Soft delete, filtered by every view"),
	("version",    "integer",       false, "1",       "Optimistic locking"),
];

const DDL_NOUNS: &[&str] = &[
	"account",
	"invoice",
	"shipment",
	"ledger_entry",
	"subscription",
	"audit_event",
	"attachment",
	"work_order",
];

/// One `ddl` unit: a table definition of the kind a schema file is full of -
/// typed columns, nullability, defaults, keys, indexes, and the comments that
/// are the reason such a file is kept by hand instead of dumped from a server.
pub fn ddl_unit(i: usize) -> (String, Vec<(String, Node)>) {
	let noun = DDL_NOUNS[i % DDL_NOUNS.len()];
	let name = format!("{noun}_{:04}", i / DDL_NOUNS.len());
	let width = 6 + i % (DDL_COLUMNS.len() - 5);

	let mut columns = Vec::with_capacity(width);
	for (col, ty, nullable, default, comment) in DDL_COLUMNS.iter().take(width) {
		let mut spec = vec![("type", s(ty)), ("nullable", boolean(*nullable))];
		if !default.is_empty() {
			spec.push(("default", s(default)));
		}
		if !comment.is_empty() {
			spec.push(("comment", s(comment)));
		}
		columns.push(((*col).to_string(), map(spec)));
	}

	let mut indexes = vec![(
		"ix_owner".to_string(),
		map(vec![
			("columns", list(&["owner_id"])),
			("unique", boolean(false)),
			("method", s("btree")),
		]),
	)];
	if width > 5 {
		indexes.push((
			"ix_slug".to_string(),
			map(vec![
				("columns", list(&["slug"])),
				("unique", boolean(true)),
				("method", s("btree")),
			]),
		));
	}
	if width > 9 {
		indexes.push((
			"ix_status_created".to_string(),
			map(vec![
				("columns", list(&["status", "created_at"])),
				("unique", boolean(false)),
				("method", s("btree")),
			]),
		));
	}

	let fields = vec![
		("schema".to_string(), s("public")),
		(
			"comment".to_string(),
			Node::Leaf(Val::Str(format!(
				"One row per {noun}, partitioned by month, retained 7 years"
			))),
		),
		("primary_key".to_string(), list(&["id"])),
		("column".to_string(), Node::Map(columns)),
		("index".to_string(), Node::Map(indexes)),
		(
			"foreign_key".to_string(),
			Node::Map(vec![(
				"fk_owner".to_string(),
				map(vec![
					("columns", list(&["owner_id"])),
					("references", s("account(id)")),
					("on_delete", s("cascade")),
				]),
			)]),
		),
	];
	(name, fields)
}

// Encoders

pub struct Gen {
	pub fmt: Fmt,
	shape: Shape,
	first: bool,
}

const IND: &str = "  "; // two spaces, for the formats whose tools indent that way

impl Gen {
	pub fn new(fmt: Fmt, shape: Shape) -> Gen {
		Gen {
			fmt,
			shape,
			first: true,
		}
	}

	pub fn doc_open(&mut self, o: &mut String) {
		match self.fmt {
			Fmt::Shcl | Fmt::Toml => {}
			Fmt::Json => match self.shape.list_key() {
				Some(k) => {
					let _ = write!(o, "{{\n{IND}\"{k}\": [");
				}
				None => o.push('{'),
			},
			Fmt::Yaml => {
				if let Some(k) = self.shape.list_key() {
					let _ = writeln!(o, "{k}:");
				}
			}
			Fmt::Xml => {
				o.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n");
			}
		}
	}

	pub fn doc_close(&mut self, o: &mut String) {
		match self.fmt {
			Fmt::Shcl | Fmt::Toml | Fmt::Yaml => {}
			Fmt::Json => match self.shape.list_key() {
				Some(_) => {
					let _ = write!(o, "\n{IND}]\n}}\n");
				}
				None => o.push_str("\n}\n"),
			},
			Fmt::Xml => o.push_str("</config>\n"),
		}
	}

	/// A top-level binding, for every shape whose root is a map.
	pub fn entry(&mut self, o: &mut String, key: &str, n: &Node) {
		match self.fmt {
			Fmt::Shcl => shcl_node(o, key, n, 0),
			Fmt::Json => {
				if !self.first {
					o.push(',');
				}
				let _ = write!(o, "\n{IND}");
				json_node(o, Some(key), n, 1);
			}
			Fmt::Yaml => yaml_node(o, key, n, 0),
			Fmt::Toml => toml_node(o, &mut Vec::new(), key, n),
			Fmt::Xml => xml_node(o, key, n, 1),
		}
		self.first = false;
	}

	/// One instance of the repeated root key, for the `records` shape.
	pub fn record(&mut self, o: &mut String, key: &str, name: &str, fields: &[(String, Node)]) {
		match self.fmt {
			// The instance label IS the identity; the other four carry it as an
			// ordinary first field, which is the same data written their way.
			Fmt::Shcl => {
				let _ = writeln!(o, "{}: {}", key, shcl_scalar(&Val::Str(name.to_string())));
				for (k, v) in fields {
					shcl_node(o, k, v, 1);
				}
			}
			Fmt::Json => {
				if !self.first {
					o.push(',');
				}
				let _ = write!(
					o,
					"\n{}{{\n{}\"name\": {}",
					IND.repeat(2),
					IND.repeat(3),
					json_scalar(&Val::Str(name.to_string()))
				);
				for (k, v) in fields {
					o.push(',');
					let _ = write!(o, "\n{}", IND.repeat(3));
					json_node(o, Some(k), v, 3);
				}
				let _ = write!(o, "\n{}}}", IND.repeat(2));
			}
			Fmt::Yaml => {
				let _ = writeln!(
					o,
					"{}- name: {}",
					IND,
					yaml_scalar(&Val::Str(name.to_string()))
				);
				for (k, v) in fields {
					yaml_node(o, k, v, 2);
				}
			}
			Fmt::Toml => {
				if !self.first {
					o.push('\n');
				}
				let _ = writeln!(o, "[[{key}]]");
				let _ = writeln!(o, "name = {}", toml_scalar(&Val::Str(name.to_string())));
				let mut path = vec![key.to_string()];
				for (k, v) in fields {
					toml_node(o, &mut path, k, v);
				}
			}
			Fmt::Xml => {
				let _ = writeln!(o, "{}<{key}>", IND);
				let _ = writeln!(o, "{}<name>{}</name>", IND.repeat(2), xml_text(name));
				for (k, v) in fields {
					xml_node(o, k, v, 2);
				}
				let _ = writeln!(o, "{}</{key}>", IND);
			}
		}
		self.first = false;
	}
}

// SHCL

fn shcl_node(o: &mut String, key: &str, n: &Node, depth: usize) {
	let pad = "\t".repeat(depth);
	match n {
		Node::Leaf(Val::Text(t)) => {
			let _ = writeln!(o, "{pad}{key}:");
			let _ = writeln!(o, "{pad}\t~~~");
			for line in t.lines() {
				let _ = writeln!(o, "{pad}\t{line}");
			}
			let _ = writeln!(o, "{pad}\t~~~");
		}
		Node::Leaf(v) => {
			let _ = writeln!(o, "{pad}{key}: {}", shcl_scalar(v));
		}
		Node::Map(kids) => {
			let _ = writeln!(o, "{pad}{key}:");
			for (k, v) in kids {
				shcl_node(o, k, v, depth + 1);
			}
		}
	}
}

fn shcl_scalar(v: &Val) -> String {
	match v {
		Val::Str(s) => shcl_string(s),
		Val::Int(i) => i.to_string(),
		Val::Float(f) => shcl::format_float(*f),
		Val::Bool(b) => b.to_string(),
		Val::Arr(items) => items.iter().map(shcl_scalar).collect::<Vec<_>>().join(", "),
		Val::Text(_) => unreachable!("text is fenced, not inline"),
	}
}

/// Matches what the canonical emitter itself quotes - the separator, the comment
/// mark, a quote of its own, a colon, or any whitespace. Quoting less would make
/// the round-trip column report the generator's spacing rather than the format's;
/// quoting more would inflate SHCL's own size against itself.
fn shcl_string(s: &str) -> String {
	let needs = s.is_empty()
		|| s.contains([',', '#', '"', ':'])
		|| s.contains(char::is_whitespace)
		|| s.starts_with('\'');
	if !needs {
		return s.to_string();
	}
	let mut out = String::with_capacity(s.len() + 2);
	out.push('"');
	for c in s.chars() {
		match c {
			'"' => out.push_str("\\\""),
			'\\' => out.push_str("\\\\"),
			_ => out.push(c),
		}
	}
	out.push('"');
	out
}

// JSON

/// Pretty-printed, because the premise is a file a person edits and every JSON
/// formatter in existence produces this. The compact size is recorded separately
/// so the wire-format view is not lost.
fn json_node(o: &mut String, key: Option<&str>, n: &Node, depth: usize) {
	if let Some(k) = key {
		let _ = write!(o, "\"{k}\": ");
	}
	match n {
		Node::Leaf(v) => o.push_str(&json_scalar(v)),
		Node::Map(kids) => {
			o.push('{');
			for (i, (k, v)) in kids.iter().enumerate() {
				if i > 0 {
					o.push(',');
				}
				let _ = write!(o, "\n{}", IND.repeat(depth + 1));
				json_node(o, Some(k), v, depth + 1);
			}
			let _ = write!(o, "\n{}}}", IND.repeat(depth));
		}
	}
}

fn json_scalar(v: &Val) -> String {
	match v {
		Val::Str(s) | Val::Text(s) => json_string(s),
		Val::Int(i) => i.to_string(),
		Val::Float(f) => shcl::format_float(*f),
		Val::Bool(b) => b.to_string(),
		Val::Arr(items) => format!(
			"[{}]",
			items.iter().map(json_scalar).collect::<Vec<_>>().join(", ")
		),
	}
}

fn json_string(s: &str) -> String {
	let mut out = String::with_capacity(s.len() + 2);
	out.push('"');
	for c in s.chars() {
		match c {
			'"' => out.push_str("\\\""),
			'\\' => out.push_str("\\\\"),
			'\n' => out.push_str("\\n"),
			'\r' => out.push_str("\\r"),
			'\t' => out.push_str("\\t"),
			c if (c as u32) < 0x20 => {
				let _ = write!(out, "\\u{:04x}", c as u32);
			}
			c => out.push(c),
		}
	}
	out.push('"');
	out
}

// YAML

fn yaml_node(o: &mut String, key: &str, n: &Node, depth: usize) {
	let pad = IND.repeat(depth);
	match n {
		Node::Leaf(Val::Text(t)) => {
			let _ = writeln!(o, "{pad}{key}: |");
			for line in t.lines() {
				let _ = writeln!(o, "{pad}{IND}{line}");
			}
		}
		Node::Leaf(v) => {
			let _ = writeln!(o, "{pad}{key}: {}", yaml_scalar(v));
		}
		Node::Map(kids) => {
			let _ = writeln!(o, "{pad}{key}:");
			for (k, v) in kids {
				yaml_node(o, k, v, depth + 1);
			}
		}
	}
}

fn yaml_scalar(v: &Val) -> String {
	match v {
		Val::Str(s) => yaml_string(s),
		Val::Int(i) => i.to_string(),
		Val::Float(f) => shcl::format_float(*f),
		Val::Bool(b) => b.to_string(),
		// Flow style: YAML's own compact spelling for a short list of scalars.
		Val::Arr(items) => format!(
			"[{}]",
			items.iter().map(yaml_scalar).collect::<Vec<_>>().join(", ")
		),
		Val::Text(_) => unreachable!("text is a block scalar, not inline"),
	}
}

/// A plain YAML scalar that could be read back as some other type has to be
/// quoted - which is the Norway problem, showing up here as bytes.
fn yaml_string(s: &str) -> String {
	let risky = s.is_empty()
		|| s.contains([
			',', ':', '#', '"', '\'', '[', ']', '{', '}', '&', '*', '!', '|', '>', '%', '@', '`',
		]) || s.starts_with(char::is_whitespace)
		|| s.ends_with(char::is_whitespace)
		|| s.starts_with('-')
		|| s.parse::<f64>().is_ok()
		|| matches!(
			s.to_ascii_lowercase().as_str(),
			"true" | "false" | "yes" | "no" | "on" | "off" | "null" | "~" | "y" | "n"
		);
	if !risky {
		return s.to_string();
	}
	json_string(s) // double-quoted YAML takes JSON's escapes
}

// TOML

/// TOML has no nesting without headers, so a map becomes a table and the path
/// accumulates. Scalars are emitted before any subtable, which the format
/// requires and which is exactly the ergonomic cost of deep TOML.
fn toml_node(o: &mut String, path: &mut Vec<String>, key: &str, n: &Node) {
	match n {
		Node::Leaf(Val::Text(t)) => {
			let _ = writeln!(o, "{key} = '''\n{}'''", t);
		}
		Node::Leaf(v) => {
			let _ = writeln!(o, "{key} = {}", toml_scalar(v));
		}
		Node::Map(kids) => {
			path.push(key.to_string());
			let _ = writeln!(o, "\n[{}]", path.join(".")); // blank line above every table header
			for (k, v) in kids {
				if matches!(v, Node::Leaf(_)) {
					toml_node(o, path, k, v);
				}
			}
			for (k, v) in kids {
				if matches!(v, Node::Map(_)) {
					toml_node(o, path, k, v);
				}
			}
			path.pop();
		}
	}
}

fn toml_scalar(v: &Val) -> String {
	match v {
		Val::Str(s) => json_string(s), // TOML basic strings take JSON's escapes
		Val::Int(i) => i.to_string(),
		Val::Float(f) => {
			let t = shcl::format_float(*f);
			if t.contains('.') { t } else { format!("{t}.0") } // TOML floats need a point
		}
		Val::Bool(b) => b.to_string(),
		Val::Arr(items) => format!(
			"[{}]",
			items.iter().map(toml_scalar).collect::<Vec<_>>().join(", ")
		),
		Val::Text(_) => unreachable!("text is a multi-line literal, not inline"),
	}
}

// XML

/// XML has no arrays and no types, so a list becomes repeated child elements and
/// every scalar is text. That is not a strawman - it is what XML config is.
fn xml_node(o: &mut String, key: &str, n: &Node, depth: usize) {
	let pad = IND.repeat(depth);
	match n {
		Node::Leaf(Val::Text(t)) => {
			let _ = write!(o, "{pad}<{key}><![CDATA[");
			o.push_str(t);
			let _ = writeln!(o, "]]></{key}>");
		}
		Node::Leaf(Val::Arr(items)) => {
			let _ = writeln!(o, "{pad}<{key}>");
			for it in items {
				let _ = writeln!(o, "{pad}{IND}<item>{}</item>", xml_text(&xml_scalar(it)));
			}
			let _ = writeln!(o, "{pad}</{key}>");
		}
		Node::Leaf(v) => {
			let _ = writeln!(o, "{pad}<{key}>{}</{key}>", xml_text(&xml_scalar(v)));
		}
		Node::Map(kids) => {
			let _ = writeln!(o, "{pad}<{key}>");
			for (k, v) in kids {
				xml_node(o, k, v, depth + 1);
			}
			let _ = writeln!(o, "{pad}</{key}>");
		}
	}
}

fn xml_scalar(v: &Val) -> String {
	match v {
		Val::Str(s) => s.clone(),
		Val::Int(i) => i.to_string(),
		Val::Float(f) => shcl::format_float(*f),
		Val::Bool(b) => b.to_string(),
		Val::Arr(_) | Val::Text(_) => unreachable!("handled by the caller"),
	}
}

fn xml_text(s: &str) -> String {
	let mut out = String::with_capacity(s.len());
	for c in s.chars() {
		match c {
			'&' => out.push_str("&amp;"),
			'<' => out.push_str("&lt;"),
			'>' => out.push_str("&gt;"),
			c => out.push(c),
		}
	}
	out
}
