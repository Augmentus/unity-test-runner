#
# Stream newly appended log content without rereading the whole file.
#

function Write-NewLogContent
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cursor
    )

    if (-Not [System.IO.File]::Exists($Path))
    {
        return
    }

    $fileShare = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    try
    {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $fileShare
        )
    }
    catch [System.IO.IOException]
    {
        # The writer may still be creating or rotating the log. Try again on the next poll.
        return
    }
    catch [System.UnauthorizedAccessException]
    {
        return
    }

    try
    {
        if (-Not $Cursor.ContainsKey("Position"))
        {
            $Cursor.Position = [long]0
        }

        $position = [long]$Cursor.Position
        $creationTimeUtcTicks = $null
        try
        {
            $creationTimeUtcTicks = [System.IO.File]::GetCreationTimeUtc($Path).Ticks
        }
        catch
        {
            # The open handle is still usable if the path was rotated after it was opened.
        }

        $resetCursor = $stream.Length -lt $position
        if (
            -Not $resetCursor -and
            $null -ne $creationTimeUtcTicks -and
            $Cursor.ContainsKey("CreationTimeUtcTicks") -and
            $null -ne $Cursor.CreationTimeUtcTicks -and
            [long]$Cursor.CreationTimeUtcTicks -ne [long]$creationTimeUtcTicks
        )
        {
            $resetCursor = $true
        }

        # Detect an in-place truncate and rewrite even when the new file has already
        # grown beyond the previous cursor before the next poll.
        if (
            -Not $resetCursor -and
            $position -gt 0 -and
            $Cursor.ContainsKey("TailSignature") -and
            -Not [string]::IsNullOrEmpty([string]$Cursor.TailSignature)
        )
        {
            $signatureLength = [int][System.Math]::Min([long]64, $position)
            [void]$stream.Seek($position - $signatureLength, [System.IO.SeekOrigin]::Begin)
            $signatureBytes = [byte[]]::new($signatureLength)
            $signatureBytesRead = $stream.Read($signatureBytes, 0, $signatureLength)
            $currentTailSignature = [System.Convert]::ToBase64String(
                $signatureBytes,
                0,
                $signatureBytesRead
            )

            if ($currentTailSignature -ne [string]$Cursor.TailSignature)
            {
                $resetCursor = $true
            }
        }

        if ($resetCursor)
        {
            $position = [long]0
            $Cursor.Position = $position
            $Cursor.TailSignature = $null
        }

        [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
        $detectEncodingFromByteOrderMarks = $position -eq 0
        $reader = [System.IO.StreamReader]::new(
            $stream,
            [System.Text.Encoding]::UTF8,
            $detectEncodingFromByteOrderMarks,
            4096,
            $true
        )

        try
        {
            while ($null -ne ($line = $reader.ReadLine()))
            {
                Write-Output $line
            }
        }
        finally
        {
            $reader.Dispose()
        }

        $position = $stream.Position
        $Cursor.Position = $position
        if ($null -ne $creationTimeUtcTicks)
        {
            $Cursor.CreationTimeUtcTicks = $creationTimeUtcTicks
        }

        $signatureLength = [int][System.Math]::Min([long]64, $position)
        if ($signatureLength -gt 0)
        {
            [void]$stream.Seek($position - $signatureLength, [System.IO.SeekOrigin]::Begin)
            $signatureBytes = [byte[]]::new($signatureLength)
            $signatureBytesRead = $stream.Read($signatureBytes, 0, $signatureLength)
            $Cursor.TailSignature = [System.Convert]::ToBase64String(
                $signatureBytes,
                0,
                $signatureBytesRead
            )
        }
        else
        {
            $Cursor.TailSignature = $null
        }
    }
    finally
    {
        $stream.Dispose()
    }
}

function Wait-ProcessWithLogOutput
{
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [string]$LogFile,

        [int]$PollIntervalMilliseconds = 3000
    )

    # Accessing the handle before polling keeps ExitCode available after the process exits.
    $null = $Process.Handle
    $cursor = @{
        Position = [long]0
        CreationTimeUtcTicks = $null
        TailSignature = $null
    }

    while (-Not $Process.HasExited)
    {
        Write-NewLogContent -Path $LogFile -Cursor $cursor
        if (-Not $Process.HasExited)
        {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }
    }

    [void]$Process.WaitForExit()
    Write-NewLogContent -Path $LogFile -Cursor $cursor
}

function Write-IndentedDiagnostic
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text))
    {
        return
    }

    Write-Output "  ${Label}:"
    $Text.Trim() -split "`r?`n" | ForEach-Object { Write-Output "    $_" }
}

function Write-TestResultsSummary
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResultsPath
    )

    if (-Not [System.IO.File]::Exists($ResultsPath))
    {
        Write-Output "::warning::Test results file not found: $ResultsPath"
        return
    }

    try
    {
        [xml]$results = Get-Content -LiteralPath $ResultsPath -Raw -ErrorAction Stop
    }
    catch
    {
        Write-Output "::warning::Unable to parse test results file '$ResultsPath': $($_.Exception.Message)"
        return
    }

    $testRun = $results.SelectSingleNode("/test-run")
    if ($null -eq $testRun)
    {
        Write-Output "::warning::Test results file has no test-run element: $ResultsPath"
        return
    }

    Write-Output (
        "Result: {0}; Total: {1}; Passed: {2}; Failed: {3}; Skipped: {4}; Inconclusive: {5}; Duration: {6}s" -f
        $testRun.GetAttribute("result"),
        $testRun.GetAttribute("total"),
        $testRun.GetAttribute("passed"),
        $testRun.GetAttribute("failed"),
        $testRun.GetAttribute("skipped"),
        $testRun.GetAttribute("inconclusive"),
        $testRun.GetAttribute("duration")
    )

    $failedTests = @($results.SelectNodes("//test-case[starts-with(@result, 'Failed')]"))
    if ($failedTests.Count -eq 0)
    {
        return
    }

    Write-Output "Failed test diagnostics ($($failedTests.Count)):"
    foreach ($failedTest in $failedTests)
    {
        $testName = $failedTest.GetAttribute("fullname")
        if ([string]::IsNullOrWhiteSpace($testName))
        {
            $testName = $failedTest.GetAttribute("name")
        }

        Write-Output "- $testName"
        $failure = $failedTest.SelectSingleNode("failure")
        if ($null -ne $failure)
        {
            $message = $failure.SelectSingleNode("message")
            $stackTrace = $failure.SelectSingleNode("stack-trace")
            if ($null -ne $message)
            {
                Write-IndentedDiagnostic -Label "Message" -Text $message.InnerText
            }
            if ($null -ne $stackTrace)
            {
                Write-IndentedDiagnostic -Label "Stack trace" -Text $stackTrace.InnerText
            }
        }
    }
}

#
# Set and display project path
#

$UNITY_PROJECT_PATH = "${env:GITHUB_WORKSPACE}/${env:PROJECT_PATH}"
Write-Output "Using project path $UNITY_PROJECT_PATH"

#
# Set and display the artifacts path
#

Write-Output "Using artifacts path ${env:ARTIFACTS_PATH} to save test results."
$FULL_ARTIFACTS_PATH = "${env:GITHUB_WORKSPACE}\${env:ARTIFACTS_PATH}"

#
# Set and display the coverage results path
#

Write-Output "Using coverage results path ${env:COVERAGE_RESULTS_PATH} to save test coverage results."
$FULL_COVERAGE_RESULTS_PATH = "${env:GITHUB_WORKSPACE}\${env:COVERAGE_RESULTS_PATH}"

#
# Display custom parameters
#

Write-Output "Using custom parameters ${env:CUSTOM_PARAMETERS}"

# The following tests are 2019 mode (requires Unity 2019.2.11f1 or later)
# Reference: https://docs.unity3d.com/2019.3/Documentation/Manual/CommandLineArguments.html

#
# Display the unity version
#

Write-Output "Using Unity version ${env:UNITY_VERSION} to test."

#
# Overall info
#

Write-Output ""
Write-Output "###########################"
Write-Output "#    Artifacts folder     #"
Write-Output "###########################"
Write-Output ""
Write-Output "Creating $FULL_ARTIFACTS_PATH if it does not exist."
New-Item -Path "$FULL_ARTIFACTS_PATH" -ItemType Directory

Write-Output ""
Write-Output "###########################"
Write-Output "#    Project directory    #"
Write-Output "###########################"
Write-Output ""
Get-ChildItem -Hidden -Path "$UNITY_PROJECT_PATH"

#
# Testing for each platform
#
foreach ( $platform in ${env:TEST_PLATFORMS}.Split(";") )
{
    if ( "$platform" -eq "standalone" )
    {
        Write-Output ""
        Write-Output "###########################"
        Write-Output "#   Building Standalone   #"
        Write-Output "###########################"
        Write-Output ""
  
        # Create directories if they do not exist
        if(-Not (Test-Path -Path $UNITY_PROJECT_PATH\Assets\Editor))
        {
            # We use -Force to suppress output, doesn't overwrite anything
            New-Item -ItemType Directory -Force -Path $UNITY_PROJECT_PATH\Assets\Editor
        }
        if(-Not (Test-Path -Path $UNITY_PROJECT_PATH\Assets\Player))
        {
            # We use -Force to suppress output, doesn't overwrite anything
            New-Item -ItemType Directory -Force -Path $Env:UNITY_PROJECT_PATH\Assets\Player
        }

        # Copy the scripts
        Copy-Item -Path "c:\UnityStandaloneScripts\Assets\Editor" -Destination $UNITY_PROJECT_PATH\Assets\Editor -Recurse
        Copy-Item -Path "c:\UnityStandaloneScripts\Assets\Player" -Destination $UNITY_PROJECT_PATH\Assets\Player -Recurse

        # Verify recursive paths
        Get-ChildItem -Path $UNITY_PROJECT_PATH\Assets\Editor -Recurse
        Get-ChildItem -Path $UNITY_PROJECT_PATH\Assets\Player -Recurse
    
        $runTests="-runTests -testPlatform StandaloneWindows64 -builtTestRunnerPath $UNITY_PROJECT_PATH\Build\UnityTestRunner-Standalone.exe"
    }
    else
    {
        Write-Output ""
        Write-Output "###########################"
        Write-Output "#   Testing in $platform  #"
        Write-Output "###########################"
        Write-Output ""

        if ( $platform -ne "COMBINE_RESULTS" )
        {
            $runTests = "-runTests -testPlatform $platform -testResults $FULL_ARTIFACTS_PATH/$platform-results.xml"
        }
        else
        {
            $runTests = "-quit"
        }
    }

    # Build coverage arguments only if COVERAGE_OPTIONS is set
    $coverageArgs = ""
    if (-not [string]::IsNullOrEmpty(${env:COVERAGE_OPTIONS})) {
        $coverageArgs = "-coverageResultsPath $FULL_COVERAGE_RESULTS_PATH -enableCodeCoverage -debugCodeOptimization -coverageOptions ${env:COVERAGE_OPTIONS}"
    }

    $logFile = "$FULL_ARTIFACTS_PATH\$platform.log"
    Write-Output "Unity log file: $logFile"
    Write-Output "Starting Unity process..."

    $TEST_OUTPUT = Start-Process -FilePath "$Env:UNITY_PATH/Editor/Unity.exe" `
                                -NoNewWindow `
                                -PassThru `
                                -ArgumentList  "-batchmode `
                                                -nographics `
                                                -logFile $logFile `
                                                -projectPath $UNITY_PROJECT_PATH `
                                                $runTests `
                                                $coverageArgs `
                                                ${env:CUSTOM_PARAMETERS}"

    Wait-ProcessWithLogOutput -Process $TEST_OUTPUT -LogFile $logFile

    # Catch exit code
    $TEST_EXIT_CODE = $TEST_OUTPUT.ExitCode
    Write-Output "Unity process exited with code: $TEST_EXIT_CODE"

    if ( ( $TEST_EXIT_CODE -eq 0 ) -and ( "$platform" -eq "standalone" ) )
    {
        # Code Coverage currently only supports code ran in the Editor and not in Standalone/Player.
        # https://docs.unity.cn/Packages/com.unity.testtools.codecoverage@1.1/manual/TechnicalDetails.html#how-it-works
        
        $playerLogFile = "$FULL_ARTIFACTS_PATH\$platform-player.log"
        Write-Output "Starting standalone player..."
        $TEST_OUTPUT = Start-Process -NoNewWindow -PassThru "$UNITY_PROJECT_PATH\Build\UnityTestRunner-Standalone.exe" -ArgumentList "-batchmode -nographics -logFile $playerLogFile -testResults $FULL_ARTIFACTS_PATH\$platform-results.xml"

        Wait-ProcessWithLogOutput -Process $TEST_OUTPUT -LogFile $playerLogFile

        # Catch exit code
        $TEST_EXIT_CODE = $TEST_OUTPUT.ExitCode
        Write-Output "Standalone player exited with code: $TEST_EXIT_CODE"
    }

    # Display results
    if ($TEST_EXIT_CODE -eq 0)
    {
        Write-Output "Run succeeded, no failures occurred";
    }
    elseif ($TEST_EXIT_CODE -eq 2)
    {
        Write-Output "Run succeeded, some tests failed";
    }
    elseif ($TEST_EXIT_CODE -eq 3)
    {
        Write-Output "Run failure (other failure)";
    }
    else
    {
        Write-Output "Unexpected exit code $TEST_EXIT_CODE";
    }

    if ( $TEST_EXIT_CODE -ne 0)
    {
        $TEST_RUNNER_EXIT_CODE = $TEST_EXIT_CODE
    }

    Write-Output ""
    Write-Output "###########################"
    Write-Output "#    $platform Results    #"
    Write-Output "###########################"
    Write-Output ""

    if ($platform -ne "COMBINE_RESULTS")
    {
        Write-TestResultsSummary -ResultsPath "$FULL_ARTIFACTS_PATH/$platform-results.xml"
    }

    # Renew floating license between test modes to prevent expiration (exit code 198).
    # Each Unity process consumes license time; returning and re-acquiring ensures
    # the next process gets a fresh timeout window.
    if ($null -ne ${env:UNITY_LICENSING_SERVER} -and $null -ne $env:FLOATING_LICENSE)
    {
        Write-Output ""
        Write-Output "###########################"
        Write-Output "#   Renewing License      #"
        Write-Output "###########################"
        Write-Output ""

        Write-Output "Returning floating license: ""$env:FLOATING_LICENSE"""
        Start-Process -FilePath "$Env:UNITY_PATH\Editor\Data\Resources\Licensing\Client\Unity.Licensing.Client.exe" `
            -ArgumentList "--return-floating ""$env:FLOATING_LICENSE"" " `
            -NoNewWindow `
            -Wait

        $pollIntervalSec = if ($null -ne ${env:UNITY_LICENCE_POLL_INTERVAL_SECONDS}) { [int]${env:UNITY_LICENCE_POLL_INTERVAL_SECONDS} } else { 30 }
        $timeoutMinutes = if ($null -ne ${env:UNITY_LICENCE_POLL_TIMEOUT_MINUTES}) { [int]${env:UNITY_LICENCE_POLL_TIMEOUT_MINUTES} } else { 60 }
        $deadline = (Get-Date).AddMinutes($timeoutMinutes)
        Write-Output "Re-acquiring floating license (timeout: ${timeoutMinutes}min, poll every ${pollIntervalSec}s)..."

        $renewSuccess = $false
        $attempt = 0
        while ((Get-Date) -lt $deadline) {
            $attempt++
            $remaining = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 1)
            Write-Output "Acquire floating license attempt $attempt (${remaining}min remaining)"

            $RENEW_OUTPUT = Start-Process -FilePath "$Env:UNITY_PATH\Editor\Data\Resources\Licensing\Client\Unity.Licensing.Client.exe" `
                -ArgumentList "--acquire-floating" `
                -NoNewWindow `
                -PassThru `
                -Wait `
                -RedirectStandardOutput "license.txt"

            if ($RENEW_OUTPUT.ExitCode -eq 0) {
                $PARSEDFILE = (Get-Content "license.txt" | Select-String -AllMatches -Pattern '".*?"' | ForEach-Object { $_.Matches.Value }) -replace '"'
                $env:FLOATING_LICENSE = $PARSEDFILE[1]
                $FLOATING_LICENSE_TIMEOUT = $PARSEDFILE[3]
                Write-Output "Renewed floating license: ""$env:FLOATING_LICENSE"" with timeout $FLOATING_LICENSE_TIMEOUT"
                $renewSuccess = $true
                break
            }
            else {
                Write-Output "Failed to acquire license (attempt $attempt, exit code: $($RENEW_OUTPUT.ExitCode))"
                if ((Get-Date) -lt $deadline) {
                    Write-Output "Retrying in $pollIntervalSec seconds..."
                    Start-Sleep -Seconds $pollIntervalSec
                }
            }
        }

        if (-not $renewSuccess) {
            Write-Output "::warning::Failed to renew floating license within $timeoutMinutes minute timeout. Next test mode may fail."
        }
    }
}
