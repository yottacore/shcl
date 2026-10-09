<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
# Retired shell wrappers

`shcl.bash` and `shcl.ps1` were the Bash and PowerShell wrappers around the `shcl` binary. They were retired on 2026-10-08.

- Both are frozen as they were that day. Nothing maintains, lints or tests them.

- No installer, package or release asset includes them. Releases up to 2.0.0 installed them under `scripts/`, and the installers remove those copies on the next update.

- Call the `shcl` binary instead. Each `shcl_*` helper was `shcl get` with a type option, or the subcommand of the same name, so `shcl_int --default=4 server.shcl workers` is `shcl get --int --default=4 server.shcl workers`. The README's [Bash](../../README.md#bash) and [PowerShell](../../README.md#powershell) sections show both.

- Why they went is in the the [design notes](../design.md#shell-wrappers-retired).
