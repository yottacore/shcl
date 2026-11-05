// Its own module on purpose, so the CLI does NOT ship inside the library
// module: the go tool leaves any subdirectory holding a go.mod out of the
// parent's zip. The Rust binary is the only CLI this project distributes; the
// other three exist to be driven by the cross-binding differential check.
//
// The replace is what makes it unpublishable as well as unshipped - `go install
// <path>@<version>` refuses a module that needs a replace directive - and it is
// how a local build resolves the library next door rather than the proxy.
//
// The version on the require line is nominal - the replace decides what gets
// built - but a /vN path will not parse without a matching vN, so this moves
// with the major and only with the major.

module github.com/yottacore/shcl/source/go/cmd

go 1.20

require github.com/yottacore/shcl/source/go/v3 v3.0.0-beta1

replace github.com/yottacore/shcl/source/go/v3 => ../
