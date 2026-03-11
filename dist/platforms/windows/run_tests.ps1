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

    # Cache the handle so exit code works properly
    $unityHandle = $TEST_OUTPUT.Handle

    # Tail the Unity log in real-time while the process runs
    $linesSeen = 0
    while (-not $TEST_OUTPUT.HasExited) {
        Start-Sleep -Seconds 3
        if (Test-Path $logFile) {
            $newLines = @(Get-Content $logFile | Select-Object -Skip $linesSeen)
            if ($newLines.Count -gt 0) {
                $newLines | ForEach-Object { Write-Output $_ }
                $linesSeen += $newLines.Count
            }
        }
    }

    # Final flush - print any remaining log lines
    Start-Sleep -Seconds 1
    if (Test-Path $logFile) {
        $newLines = @(Get-Content $logFile | Select-Object -Skip $linesSeen)
        if ($newLines.Count -gt 0) {
            $newLines | ForEach-Object { Write-Output $_ }
        }
    }

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

        $unityHandle = $TEST_OUTPUT.Handle
        $linesSeen = 0
        while (-not $TEST_OUTPUT.HasExited) {
            Start-Sleep -Seconds 3
            if (Test-Path $playerLogFile) {
                $newLines = @(Get-Content $playerLogFile | Select-Object -Skip $linesSeen)
                if ($newLines.Count -gt 0) {
                    $newLines | ForEach-Object { Write-Output $_ }
                    $linesSeen += $newLines.Count
                }
            }
        }
        Start-Sleep -Seconds 1
        if (Test-Path $playerLogFile) {
            $newLines = @(Get-Content $playerLogFile | Select-Object -Skip $linesSeen)
            if ($newLines.Count -gt 0) {
                $newLines | ForEach-Object { Write-Output $_ }
            }
        }

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
        Get-Content "$FULL_ARTIFACTS_PATH/$platform-results.xml"
        Get-Content "$FULL_ARTIFACTS_PATH/$platform-results.xml" | Select-String "test-run" | Select-String "Passed"
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

        Write-Output "Re-acquiring floating license..."
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
        }
        else {
            Write-Output "::warning::Failed to renew floating license (exit code: $($RENEW_OUTPUT.ExitCode)). Next test mode may fail."
        }
    }
}