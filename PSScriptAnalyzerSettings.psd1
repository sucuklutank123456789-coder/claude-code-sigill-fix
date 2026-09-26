# PSScriptAnalyzer settings for the PowerShell scripts in this repository.
@{
    ExcludeRules = @(
        # An interactive console tool: colored status lines on the console are the output.
        'PSAvoidUsingWriteHost'
        # Internal helper functions of a script, not cmdlets: no -WhatIf/-Confirm,
        # and short positional calls keep them readable.
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingPositionalParameters'
        'PSUseSingularNouns'
        # Reports script parameters that are only read inside functions (e.g. -NoAdmin).
        'PSReviewUnusedParameter'
    )
}
