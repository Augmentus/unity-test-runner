# Activates Unity

Write-Output ""
Write-Output "###########################"
Write-Output "#        Activating       #"
Write-Output "###########################"
Write-Output ""

if ( ($null -ne ${env:UNITY_SERIAL}) -and ($null -ne ${env:UNITY_EMAIL}) -and ($null -ne ${env:UNITY_PASSWORD}) )
{
  #
  # SERIAL LICENSE MODE
  #
  # This will activate unity, using the serial activation process.
  #
  Write-Output "Requesting activation"

  $ACTIVATION_OUTPUT = Start-Process -FilePath "$Env:UNITY_PATH/Editor/Unity.exe" `
                                     -NoNewWindow `
                                     -PassThru `
                                     -ArgumentList  "-batchmode `
                                                     -quit `
                                                     -nographics `
                                                     -username $Env:UNITY_EMAIL `
                                                     -password $Env:UNITY_PASSWORD `
                                                     -serial $Env:UNITY_SERIAL `
                                                     -projectPath c:/BlankProject `
                                                     -logfile -"

  # Cache the handle so exit code works properly
  # https://stackoverflow.com/questions/10262231/obtaining-exitcode-using-start-process-and-waitforexit-instead-of-wait
  $unityHandle = $ACTIVATION_OUTPUT.Handle

  while ($true) {
      if ($ACTIVATION_OUTPUT.HasExited) {
        $ACTIVATION_EXIT_CODE = $ACTIVATION_OUTPUT.ExitCode

        # Display results
        if ($ACTIVATION_EXIT_CODE -eq 0)
        {
            Write-Output "Activation Succeeded"
        } else
        {
            Write-Output "Activation failed, with exit code $ACTIVATION_EXIT_CODE"
        }

        break
      }

      Start-Sleep -Seconds 3
  }
}
elseif( ($null -ne ${env:UNITY_LICENSING_SERVER}))
{
    #
    # Custom Unity License Server
    #

    Write-Output "Adding licensing server config"

    # Split the UNITY_LICENSING_SERVER by semicolon to support multiple servers
    $servers = ${env:UNITY_LICENSING_SERVER} -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    Write-Output "Found $($servers.Count) license server(s):"
    for ($i = 0; $i -lt $servers.Count; $i++) {
        Write-Output "  [$($i + 1)] $($servers[$i])"
    }

    $ACTIVATION_EXIT_CODE = 1
    $maxAttempts = 3

    foreach ($server in $servers) {
        Write-Output "Trying license server: $server"

        # Create the services-config.json for this server
        $configDir = "$env:ProgramData\Unity\config"
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        $servicesConfig = @"
{
  "licensingServiceBaseUrl": "$server",
  "enableEntitlementLicensing": true,
  "enableFloatingApi": true,
  "clientConnectTimeoutSec": 5,
  "clientHandshakeTimeoutSec": 10
}
"@
        $configPath = "$configDir\services-config.json"
        Set-Content -Path $configPath -Value $servicesConfig
        Write-Output "Wrote services config to $configPath"

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-Output "Acquire floating license attempt $attempt of $maxAttempts (server: $server)"

            $ACTIVATION_OUTPUT = Start-Process -FilePath "$Env:UNITY_PATH\Editor\Data\Resources\Licensing\Client\Unity.Licensing.Client.exe" `
                -ArgumentList "--acquire-floating" `
                -NoNewWindow `
                -PassThru `
                -Wait `
                -RedirectStandardOutput "license.txt"

            $ACTIVATION_EXIT_CODE = $ACTIVATION_OUTPUT.ExitCode

            if ($ACTIVATION_EXIT_CODE -eq 0) {
                $PARSEDFILE = (Get-Content "license.txt" | Select-String -AllMatches -Pattern '\".*?\"' | ForEach-Object { $_.Matches.Value }) -replace '"'

                $env:FLOATING_LICENSE = $PARSEDFILE[1]
                $FLOATING_LICENSE_TIMEOUT = $PARSEDFILE[3]

                Write-Output "Acquired floating license: ""$env:FLOATING_LICENSE"" with timeout $FLOATING_LICENSE_TIMEOUT from server $server"
                break
            }
            else {
                Write-Output "Failed to acquire license from server $server (attempt $attempt, exit code: $ACTIVATION_EXIT_CODE)"
                if ($attempt -lt $maxAttempts) {
                    $delay = 5 * $attempt
                    Write-Output "Retrying in $delay seconds..."
                    Start-Sleep -Seconds $delay
                }
            }
        }

        if ($ACTIVATION_EXIT_CODE -eq 0) {
            break
        }
    }

    if ($ACTIVATION_EXIT_CODE -ne 0) {
        Write-Output "Failed to acquire license from any server after $maxAttempts attempts each"
    }
}
else
{
    #
    # NO LICENSE ACTIVATION STRATEGY MATCHED
    #
    # This will exit since no activation strategies could be matched.
    #
    Write-Output "License activation strategy could not be determined."
    Write-Output ""
    Write-Output "Visit https://game.ci/docs/github/activation for more"
    Write-Output "details on how to set up one of the possible activation strategies."

    Write-Output "::error ::No valid license activation strategy could be determined. Make sure to provide UNITY_EMAIL, UNITY_PASSWORD, and either a UNITY_SERIAL \
or UNITY_LICENSE. See more info at https://game.ci/docs/github/activation"

    $ACTIVATION_EXIT_CODE = 1;
}
