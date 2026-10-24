// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Embeds the Windows icon and version metadata into the executable, so it does
// not show up as a nameless generic file with an empty properties panel.
//
// Deliberately dependency-free, like everything else here: it writes a resource
// script and hands it to whichever resource compiler is around. The version
// comes from Cargo.toml through the environment, so it cannot drift and the
// release bump still touches the same files it did before.
//
// Everything about this is best-effort. No Windows target, or no resource
// compiler installed, means the build carries on without the resource - a
// missing icon must never be the reason a build fails.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

fn main() {
	println!("cargo:rerun-if-changed=build.rs");
	println!("cargo:rerun-if-changed=../../assets/shcl.ico");

	// The pipeline stamps a release build with a build number worked out from
	// the commit time, so a rebuild of the same commit gets the same one. Any
	// other build, `cargo install` from crates.io included, has none. A bad
	// value is a pipeline bug, and a wrong number in a release would be worse
	// than a failed build.
	println!("cargo:rerun-if-env-changed=SHCL_BUILD");
	let build = env::var("SHCL_BUILD").unwrap_or_default();
	assert!(
		build
			.chars()
			.all(|c| "0123456789abcdefghjkmnpqrstvwxyz".contains(c)),
		"SHCL_BUILD must be lower-case Crockford base32, got {build:?}"
	);
	let suffix = if build.is_empty() {
		String::new()
	} else {
		format!(" build {build}")
	};
	println!("cargo:rustc-env=SHCL_BUILD_SUFFIX={suffix}");

	// A stamped build that isn't a release shows its date as well. The CLI
	// works it out from the build number when it runs, in the local zone of
	// whoever asks, so only the number is passed on.
	println!("cargo:rerun-if-env-changed=SHCL_BUILD_DATED");
	let dated = env::var("SHCL_BUILD_DATED").unwrap_or_default();
	assert!(
		dated.is_empty() || (dated == "1" && !build.is_empty()),
		"SHCL_BUILD_DATED must be empty, or 1 with SHCL_BUILD set, got {dated:?}"
	);
	let dated_build = if dated.is_empty() { "" } else { build.as_str() };
	println!("cargo:rustc-env=SHCL_BUILD_DATED={dated_build}");

	if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
		return;
	}

	let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is always set"));
	let version = env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".into());
	let description = env::var("CARGO_PKG_DESCRIPTION").unwrap_or_default();

	// FILEVERSION wants four comma-separated numbers; semver gives three.
	let mut parts: Vec<&str> = version.split(['.', '-', '+']).collect();
	parts.retain(|p| p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty());
	while parts.len() < 4 {
		parts.push("0");
	}
	let quad = parts[..4].join(",");

	// Built from assets/icon.png, not drawn by hand - regenerate it from there.
	let icon = Path::new("../../assets/shcl.ico").canonicalize().ok();
	let icon_line = match &icon {
		// Backslashes so the resource compiler does not read the path as escapes.
		Some(p) => format!(
			"1 ICON \"{}\"\n",
			p.display().to_string().replace('\\', "\\\\")
		),
		None => String::new(),
	};

	let rc = format!(
		"{icon_line}1 VERSIONINFO
FILEVERSION {quad}
PRODUCTVERSION {quad}
FILEOS 0x4
FILETYPE 0x1
BEGIN
	BLOCK \"StringFileInfo\"
	BEGIN
		BLOCK \"040904b0\"
		BEGIN
			VALUE \"CompanyName\", \"Jim Collier\"
			VALUE \"FileDescription\", \"{description}\"
			VALUE \"FileVersion\", \"{version}\"
			VALUE \"InternalName\", \"shcl\"
			VALUE \"LegalCopyright\", \"Copyright (C) 2026 Jim Collier. MIT License.\"
			VALUE \"OriginalFilename\", \"shcl.exe\"
			VALUE \"ProductName\", \"SHCL\"
			VALUE \"ProductVersion\", \"{version}\"
		END
	END
	BLOCK \"VarFileInfo\"
	BEGIN
		VALUE \"Translation\", 0x409, 1200
	END
END
"
	);

	let rc_path = out.join("shcl.rc");
	if fs::write(&rc_path, rc).is_err() {
		return;
	}
	let res_path = out.join("shcl_res.o");

	// zig covers every Windows target this project cross-builds, including the
	// ARM64 one that has no mingw binutils here. windres is the fallback.
	//
	// The machine has to be passed explicitly: zig infers COFF output from the
	// .o extension but then defaults to x64, and an x64 resource in an ARM64
	// link fails at the linker with a machine-type conflict.
	let target = env::var("TARGET").unwrap_or_default();
	let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_else(|_| "x86_64".into());
	let mingw = format!(
		"{}-windres",
		target.replace("-pc-windows-gnu", "-w64-mingw32")
	);
	let attempts: [(&str, Vec<String>); 3] = [
		(
			"zig",
			vec![
				"rc".into(),
				"/:target".into(),
				arch.clone(),
				"/fo".into(),
				res_path.display().to_string(),
				rc_path.display().to_string(),
			],
		),
		(
			mingw.as_str(),
			vec![
				rc_path.display().to_string(),
				"-O".into(),
				"coff".into(),
				"-o".into(),
				res_path.display().to_string(),
			],
		),
		(
			"llvm-rc",
			vec![
				format!("/fo{}", res_path.display()),
				rc_path.display().to_string(),
			],
		),
	];

	for (tool, args) in &attempts {
		if matches!(Command::new(tool).args(args).status(), Ok(s) if s.success())
			&& res_path.exists()
		{
			println!("cargo:rustc-link-arg-bins={}", res_path.display());
			return;
		}
	}
	println!(
		"cargo:warning=no Windows resource compiler found; the exe gets no icon or version metadata"
	);
}
