<#
	PSScriptAnalyzer settings for every PowerShell script the pipeline lints.

	Pinned here rather than passed on the command line so running the analyzer by
	hand gives the same answer the pipeline gets, and so a new rule in a later
	release cannot quietly change what passes.
#>
@{
	Severity = @('Error', 'Warning')

	Rules = @{
		PSUseCompatibleSyntax = @{
			Enable         = $true
			## The installer has to run on the Windows PowerShell that ships with
			## the OS, not just on 7.
			##
			## Syntax only, and that is the whole of what any rule here covers.
			## It says nothing about which framework members exist, which is the
			## class two round-20260830b defects fell into: `ResolveLinkTarget`
			## on a FileInfo, and `$IsWindows`, neither of which exists on 5.1.
			## PSUseCompatibleTypes was tried and reports nothing, because it
			## matches type names rather than the members called on an instance.
			## So the guard for that class is a member test in the code, not a
			## setting here.
			TargetVersions = @('5.1', '7.0')
		}
		## Tabs, per the style guide. The rule has no notion of spaces for
		## alignment after the tabs, so a continuation line is written as its
		## own statement rather than lined up under the one above.
		PSUseConsistentIndentation = @{
			Enable              = $true
			Kind                = 'tab'
			PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
		}
	}
}
