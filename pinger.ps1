param(
    [int]$IntervalSeconds = 5,
    [int]$FailLimit = 3,
    [int]$TimeoutMilliseconds = 1000
)

function ConvertTo-HostConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $value = $Line.Trim()

    if (-not $value -or $value.StartsWith("#")) {
        return $null
    }

    $sound = "soft"

    if ($value -match "\(([^)]+)\)\s*$") {
        $sound = $matches[1].Trim().ToLowerInvariant()
        $value = ($value -replace "\s*\([^)]+\)\s*$", "").Trim()
    }

    if ($sound -notin @("loud", "soft", "silent")) {
        $sound = "soft"
    }

    if ($value -match "^\s*(.+?)\s*=\s*(.+?)\s*$") {
        $name = $matches[1].Trim()
        $address = $matches[2].Trim()
    }
    else {
        $name = $value
        $address = $value
    }

    if (-not $name -or -not $address) {
        return $null
    }

    [pscustomobject]@{
        Key = "$name|$address"
        Name = $name
        Address = $address
        Sound = $sound
    }
}

function Test-PingHost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [int]$Timeout
    )

    $ping = New-Object System.Net.NetworkInformation.Ping

    try {
        $reply = $ping.Send($Address, $Timeout)
        return $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
    }
    catch {
        return $false
    }
    finally {
        $ping.Dispose()
    }
}

function Invoke-PingerSound {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [string]$Event
    )

    if ($Mode -eq "silent") {
        return
    }

    if ($Event -eq "down") {
        if ($Mode -eq "loud") {
            [console]::beep(1400, 900)
            [console]::beep(1400, 900)
            [console]::beep(1000, 900)
            return
        }

        [console]::beep(1200, 300)
        [console]::beep(1200, 300)
        return
    }

    if ($Mode -eq "loud") {
        [console]::beep(700, 250)
        [console]::beep(900, 250)
        [console]::beep(1100, 250)
        return
    }

    [console]::beep(800, 200)
}

function Write-PingerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "$timestamp  $Message"
}

$defaultHostsToCheck = @(
    [pscustomobject]@{ Key = "google-dns|8.8.8.8"; Name = "google-dns"; Address = "8.8.8.8"; Sound = "soft" },
    [pscustomobject]@{ Key = "server|192.168.103.10"; Name = "server"; Address = "192.168.103.10"; Sound = "soft" },
    [pscustomobject]@{ Key = "device|192.168.103.183"; Name = "device"; Address = "192.168.103.183"; Sound = "soft" }
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostsFile = Join-Path $scriptRoot "hosts.txt"
$logFile = Join-Path $scriptRoot "pinger.log"

if (Test-Path -LiteralPath $hostsFile) {
    $hostsToCheck = @(
        Get-Content -LiteralPath $hostsFile |
            ForEach-Object { ConvertTo-HostConfig -Line $_ } |
            Where-Object { $null -ne $_ }
    )
}
else {
    $hostsToCheck = $defaultHostsToCheck
}

if (-not $hostsToCheck -or $hostsToCheck.Count -eq 0) {
    Write-Host "No hosts to check. Add addresses to hosts.txt or edit pinger.ps1." -ForegroundColor Red
    exit 1
}

$states = @{}
$failCounters = @{}
$downSince = @{}

foreach ($hostConfig in $hostsToCheck) {
    $states[$hostConfig.Key] = $null
    $failCounters[$hostConfig.Key] = 0
    $downSince[$hostConfig.Key] = $null
}

$host.UI.RawUI.WindowTitle = "LAN Pinger"

Write-Host "LAN Pinger started. Press Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "Hosts: $(($hostsToCheck | ForEach-Object { "$($_.Name)=$($_.Address) ($($_.Sound))" }) -join ', ')"
Write-Host "Interval: $IntervalSeconds sec | Fail limit: $FailLimit | Timeout: $TimeoutMilliseconds ms"
Write-Host "Log: $logFile"
Write-Host "------------------------------"

Write-PingerLog "START interval=${IntervalSeconds}s failLimit=$FailLimit timeout=${TimeoutMilliseconds}ms hosts=$($hostsToCheck.Count)"

while ($true) {
    foreach ($hostConfig in $hostsToCheck) {
        $online = Test-PingHost -Address $hostConfig.Address -Timeout $TimeoutMilliseconds
        $now = Get-Date
        $time = $now.ToString("HH:mm:ss")
        $label = "$($hostConfig.Name) [$($hostConfig.Address)]"
        $key = $hostConfig.Key

        if ($online) {
            $failCounters[$key] = 0
            Write-Host "$time  $label  OK" -ForegroundColor Green

            if ($states[$key] -eq $false) {
                Invoke-PingerSound -Mode $hostConfig.Sound -Event "restored"

                if ($null -ne $downSince[$key]) {
                    $downAt = $downSince[$key].ToString("dd.MM.yyyy HH:mm:ss")
                    $message = "$label RESTORED (was down since $downAt)"
                    Write-Host ">>> $message <<<" -ForegroundColor Green
                    Write-PingerLog $message
                }
                else {
                    $message = "$label RESTORED"
                    Write-Host ">>> $message <<<" -ForegroundColor Green
                    Write-PingerLog $message
                }
            }

            $states[$key] = $true
            $downSince[$key] = $null
            continue
        }

        $failCounters[$key] = [Math]::Min($failCounters[$key] + 1, $FailLimit)
        $failedEnough = $failCounters[$key] -ge $FailLimit
        $color = if ($failedEnough) { "Red" } else { "Yellow" }

        if ($failedEnough -and $null -eq $downSince[$key]) {
            $downSince[$key] = $now
        }

        if ($failedEnough) {
            $downFrom = $downSince[$key].ToString("dd.MM.yyyy HH:mm:ss")
            Write-Host "$time  $label  FAIL $($failCounters[$key])/$FailLimit  DOWN from $downFrom" -ForegroundColor $color
        }
        else {
            Write-Host "$time  $label  FAIL $($failCounters[$key])/$FailLimit" -ForegroundColor $color
        }

        if ($failedEnough -and $states[$key] -ne $false) {
            $downAt = $downSince[$key].ToString("dd.MM.yyyy HH:mm:ss")
            $message = "$label DOWN at $downAt"

            Invoke-PingerSound -Mode $hostConfig.Sound -Event "down"
            Write-Host ">>> $message <<<" -ForegroundColor Red
            Write-PingerLog $message
            $states[$key] = $false
        }
    }

    Write-Host "------------------------------"
    Start-Sleep -Seconds $IntervalSeconds
}
