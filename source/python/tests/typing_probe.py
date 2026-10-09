# SPDX-License-Identifier: MIT
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

# Never run. mypy reads it as a consumer would: a typed read has to come back as
# its element type, not Any, and nothing at run time would notice if it did.

from typing import TYPE_CHECKING

if TYPE_CHECKING:
	from typing_extensions import assert_type

	import shcl

	def probe(d: shcl.Document) -> None:
		assert_type(d.read_int("a").value, int)
		assert_type(d.read_float("a").value, float)
		assert_type(d.read_bool("a").value, bool)
		assert_type(d.read_string("a").value, str)
		assert_type(d.read_raw("a").value, str)
		assert_type(d.read_raw_info("a").value, str)
		assert_type(d.read_datetime("a").value, shcl.ShclDateTime)
		assert_type(d.read_int_array("a").value, list[int])
		assert_type(d.read_float_array("a").value, list[float])
		assert_type(d.read_bool_array("a").value, list[bool])
		assert_type(d.read_string_array("a").value, list[str])
		assert_type(d.read_datetime_array("a").value, list[shcl.ShclDateTime])
		assert_type(d.read_count("a").value, int)
		assert_type(d.read_instances("a").value, list[str])
		assert_type(d.read_children("a").value, list[str])
		assert_type(shcl.read_format_version("").value, int)
		assert_type(shcl.read_schema_ref("").value, str)
		assert_type(d.set_int("a", 1), shcl.SetStatus)
		assert_type(d.set_comment("a", "c"), shcl.SetStatus)
		assert_type(d.set_literal_default("a", "1"), shcl.SetStatus)
		assert_type(d.check_set_path("a"), shcl.SetStatus)
