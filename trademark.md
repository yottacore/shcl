<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Trademark Policy

**Short version:** the code is free, the specification is free, and implementing it needs no permission from anyone. What the name protects is a promise - that a file described as SHCL behaves the same way everywhere. Call your implementation SHCL if it passes the conformance corpus. If it does not, or if you have changed the language itself, please use your own name for it.

We would rather say yes than no. New implementations in new languages are the best thing that can happen to a config format, and nothing here is meant to slow one down. The narrow thing this policy protects is the guarantee that makes SHCL worth adopting at all: that the same file, read by any implementation using the name, produces the same result. A format that means slightly different things in different languages is worse than no format, and once that trust is gone it cannot be recovered by fixing code.

## 1. Marks covered

"SHCL", the SHCL logo, and any stylized variants (the "Marks") are trademarks of Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. We claim these Marks under common law and use them in commerce as SHCL™.

## 2. Relationship to the software license

SHCL is distributed under MIT. That license grants rights in **copyright** only. It does not grant, and must not be read as granting, any license or right to use the Marks. Trademark rights are expressly reserved.

To be explicit about what this policy does *not* do: it does not restrict who may read, implement, fork, extend, or embed the specification, in any language, for any purpose, commercial or otherwise. Those rights come from the license, and this policy takes none of them away. It governs the name only.

## 3. What conformance means

A **Conformant Implementation** is one that passes the published conformance corpus for the version of SHCL it claims to implement, without modification to the corpus.

The corpus lives at `project/conformance/` in this repository. It is the same corpus every shipped binding is held to, on every build - there is no separate or stricter bar for outside implementations. Conformance is therefore something you can check for yourself, before you ship and without asking us.

Where a claim is narrower than full conformance, say so plainly and it is fine: "a read-only SHCL parser", "a SHCL parser, schema validation not yet implemented", "an in-progress SHCL implementation". What is not fine is a bare claim of SHCL support from something that does not pass, since a user has no way to tell the difference until it breaks.

## 4. Uses that are always permitted

No permission from us is needed to:

- Implement the specification, in any language, for any purpose.

- Use the Marks in plain text to refer accurately to this project - in documentation, articles, reviews, talks, comparisons, or academic work.

- Describe a Conformant Implementation as an implementation of SHCL, as SHCL-compatible, or as supporting SHCL.

- State factually that your product reads, writes, works with, is built on, or is derived from SHCL (e.g. "Foo, a SHCL fork", "powered by SHCL"), provided the statement is true and your own name is the prominent one.

- Redistribute unmodified official builds under the project name.

- Package unmodified or minimally patched builds for a distribution or package manager under the project name, provided patches are limited to packaging, security, and portability fixes.

- Use the Marks in the name of a user group, meetup, or community forum, so long as it is clearly non-commercial and clearly not operated by us.

## 5. Implementations, variants, and extensions

The line this policy draws is between implementing the language and changing it.

- **An implementation that passes the corpus** may use the name, as described in Section 4. You need not ask, and you need not be affiliated with us.

- **An implementation that does not pass** must not be described as SHCL, SHCL-compatible, or SHCL-supporting without qualifying the claim truthfully (Section 3). This is the case the policy exists for.

- **A variant language**. One that adds syntax, removes syntax, or changes how any construct is read is a different language, however small the change. Give it your own name. You are welcome, and encouraged, to say plainly that it is derived from or inspired by SHCL.

- **A superset** that reads every valid SHCL file identically and adds constructs of its own is still a variant for naming purposes, because a file written for it will not load elsewhere. Name it yourself; describing it as "a superset of SHCL" is accurate and permitted.

Do not use the Marks in a way that could lead users to attribute your changes to us.

## 6. Uses that require written permission

- Naming your product, service, company, or app the same as, or confusingly similar to, the Marks - including as a prefix, suffix, or misspelling (e.g. "SHCL Pro", "SHCL Cloud", "SHCLify").

- Using the Marks in a domain name, social media handle, or app store listing title.

- Using the logo, or any modified form of it, as your own icon or branding.

- Using the Marks on merchandise.

- Any use that suggests sponsorship, endorsement, affiliation, or official status.

- Describing anything as certified, official, or endorsed by us. Passing the corpus earns the name; it does not make an implementation official.

## 7. Usage requirements

When using the Marks under Section 4:

- Spell and capitalize them as shown here; do not translate, abbreviate, pluralize, or use them as verbs.

- Do not alter the logo's colors, proportions, or elements.

- Include an attribution such as: "SHCL is a trademark of Jim Collier."

- When claiming conformance, name the version of SHCL you conform to. "Conformant" ages; "conformant to SHCL 1.0" does not.

## 8. Enforcement and changes

**We may revoke permission for any use that damages the Marks or misleads users**. In practice, a good-faith implementation that turns out to fail a corpus case is a bug report, not a dispute - tell us, or fix it, and nothing further is needed. Enforcement is aimed at claims that stay wrong.

We may revise this policy at any time; the current version lives at <https://github.com/yottacore/shcl/>. Requests for permission, and reports of misuse, go to shclⒶyottacore.com.

---

> *This policy is adapted for community use and may be reused freely. It is not legal advice.*
