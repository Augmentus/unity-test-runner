$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal
{
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Expected,

        [AllowEmptyString()]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected)
    {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-Contains
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-Not $Text.Contains($Expected))
    {
        throw "$Message`nMissing text: $Expected"
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runTestsPath = Join-Path $repositoryRoot "dist\platforms\windows\run_tests.ps1"
$parseErrors = $null
$tokens = $null
$runTestsAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $runTestsPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0)
{
    throw "run_tests.ps1 has parse errors: $($parseErrors -join '; ')"
}

$requiredFunctions = @(
    "Write-NewLogContent",
    "Wait-ProcessWithLogOutput",
    "Write-IndentedDiagnostic",
    "Write-TestResultsSummary"
)

foreach ($functionName in $requiredFunctions)
{
    $functionAst = $runTestsAst.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        },
        $true
    )

    if ($null -eq $functionAst)
    {
        throw "Could not find function '$functionName' in $runTestsPath"
    }

    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$runTestsSource = [System.IO.File]::ReadAllText($runTestsPath)
if ($runTestsSource.Contains("Select-Object -Skip `$linesSeen"))
{
    throw "The old whole-file Get-Content/Select-Object log loop is still present"
}
Assert-Contains `
    -Text $runTestsSource `
    -Expected "[System.IO.File]::Open(" `
    -Message "The log reader must use an incremental FileStream"
Assert-Contains `
    -Text $runTestsSource `
    -Expected 'if (${env:WARMUP_PROJECT} -eq "true")' `
    -Message "The optional project warm-up gate is missing"
Assert-Contains `
    -Text $runTestsSource `
    -Expected '-quit `' `
    -Message "The project warm-up must exit before the test process starts"
Assert-Contains `
    -Text $runTestsSource `
    -Expected 'Wait-ProcessWithLogOutput -Process $WARMUP_OUTPUT -LogFile $warmupLogFile' `
    -Message "The project warm-up log must stream through the incremental reader"

$temporaryDirectory = Join-Path (
    [System.IO.Path]::GetTempPath()
) "unity-test-runner-log-validation-$([guid]::NewGuid())"
[void][System.IO.Directory]::CreateDirectory($temporaryDirectory)

try
{
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $cursor = @{
        Position = [long]0
        CreationTimeUtcTicks = $null
        TailSignature = $null
    }
    $logPath = Join-Path $temporaryDirectory "cursor.log"

    [System.IO.File]::WriteAllText($logPath, "first`r`nsecond`r`n", $encoding)
    $initialOutput = @(Write-NewLogContent -Path $logPath -Cursor $cursor)
    Assert-Equal `
        -Expected "first|second" `
        -Actual ($initialOutput -join "|") `
        -Message "Initial log content should be emitted once"

    [System.IO.File]::AppendAllText($logPath, "third`r`n", $encoding)
    $appendedOutput = @(Write-NewLogContent -Path $logPath -Cursor $cursor)
    Assert-Equal `
        -Expected "third" `
        -Actual ($appendedOutput -join "|") `
        -Message "Only appended log content should be emitted on the next poll"

    $unchangedOutput = @(Write-NewLogContent -Path $logPath -Cursor $cursor)
    Assert-Equal `
        -Expected "" `
        -Actual ($unchangedOutput -join "|") `
        -Message "An unchanged log should not be emitted again"

    # Make the rewritten file longer than the old cursor to exercise signature-based
    # truncation detection rather than the simpler length check.
    [System.IO.File]::WriteAllText(
        $logPath,
        "rewritten-one`r`nrewritten-two`r`nrewritten-three`r`n",
        $encoding
    )
    if ((Get-Item -LiteralPath $logPath).Length -lt [long]$cursor.Position)
    {
        throw "The rewrite fixture must be at least as long as the previous cursor"
    }
    $rewrittenOutput = @(Write-NewLogContent -Path $logPath -Cursor $cursor)
    Assert-Equal `
        -Expected "rewritten-one|rewritten-two|rewritten-three" `
        -Actual ($rewrittenOutput -join "|") `
        -Message "An in-place truncate and rewrite should reset the cursor"

    [System.IO.File]::Delete($logPath)
    [System.IO.File]::WriteAllText(
        $logPath,
        "replacement-one`r`nreplacement-two`r`nreplacement-three`r`n",
        $encoding
    )
    if ((Get-Item -LiteralPath $logPath).Length -lt [long]$cursor.Position)
    {
        throw "The replacement fixture must be at least as long as the previous cursor"
    }
    $replacementOutput = @(Write-NewLogContent -Path $logPath -Cursor $cursor)
    Assert-Equal `
        -Expected "replacement-one|replacement-two|replacement-three" `
        -Actual ($replacementOutput -join "|") `
        -Message "A recreated log should reset the cursor"

    $streamedLogPath = Join-Path $temporaryDirectory "streamed.log"
    $escapedStreamedLogPath = $streamedLogPath.Replace("'", "''")
    $writerScript = @"
`$encoding = [System.Text.UTF8Encoding]::new(`$false)
[System.IO.File]::AppendAllText('$escapedStreamedLogPath', "live-one``r``n", `$encoding)
Start-Sleep -Milliseconds 150
[System.IO.File]::AppendAllText('$escapedStreamedLogPath', "live-two``r``n", `$encoding)
Start-Sleep -Milliseconds 150
[System.IO.File]::AppendAllText('$escapedStreamedLogPath', "live-three``r``n", `$encoding)
"@
    $encodedWriterScript = [System.Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($writerScript)
    )
    $writerProcess = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -EncodedCommand $encodedWriterScript" `
        -WindowStyle Hidden `
        -PassThru

    try
    {
        $streamedOutput = @(
            Wait-ProcessWithLogOutput `
                -Process $writerProcess `
                -LogFile $streamedLogPath `
                -PollIntervalMilliseconds 25
        )
        Assert-Equal `
            -Expected "live-one|live-two|live-three" `
            -Actual ($streamedOutput -join "|") `
            -Message "The process log should stream incrementally without duplicates"
        if ($writerProcess.ExitCode -ne 0)
        {
            throw "The incremental log writer exited with code $($writerProcess.ExitCode)"
        }
    }
    finally
    {
        $writerProcess.Dispose()
    }

    $resultsPath = Join-Path $repositoryRoot "artifacts\playmode-results.xml"
    $summaryLines = @(Write-TestResultsSummary -ResultsPath $resultsPath)
    $summary = $summaryLines -join "`n"
    Assert-Contains `
        -Text $summary `
        -Expected "Result: Failed(Child); Total: 8; Passed: 2; Failed: 4; Skipped: 2; Inconclusive: 0; Duration: 0.1055695s" `
        -Message "The concise NUnit summary is missing"
    Assert-Contains `
        -Text $summary `
        -Expected "Failed test diagnostics (4):" `
        -Message "The failed-test count is missing"
    Assert-Contains `
        -Text $summary `
        -Expected "- Tests.PlayModeTest.FailedTest" `
        -Message "A failed test name is missing"
    Assert-Contains `
        -Text $summary `
        -Expected "Expected: True" `
        -Message "A failed test message is missing"
    Assert-Contains `
        -Text $summary `
        -Expected "Stack trace:" `
        -Message "A failed test stack trace is missing"

    if ($summary -match "<\?xml|<test-run|<test-case")
    {
        throw "The result summary must not dump raw XML"
    }

    $passedResultsPath = Join-Path $temporaryDirectory "passed-results.xml"
    [System.IO.File]::WriteAllText(
        $passedResultsPath,
        '<test-run result="Passed" total="3" passed="3" failed="0" skipped="0" inconclusive="0" duration="0.25" />',
        $encoding
    )
    $passedSummary = @(Write-TestResultsSummary -ResultsPath $passedResultsPath)
    Assert-Equal `
        -Expected "Result: Passed; Total: 3; Passed: 3; Failed: 0; Skipped: 0; Inconclusive: 0; Duration: 0.25s" `
        -Actual ($passedSummary -join "|") `
        -Message "Passing results should produce only the concise summary"
}
finally
{
    if ([System.IO.Directory]::Exists($temporaryDirectory))
    {
        [System.IO.Directory]::Delete($temporaryDirectory, $true)
    }
}

Write-Output "Windows run_tests.ps1 validation passed."
