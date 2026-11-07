param([string]$PluginDirectory)
$ErrorActionPreference='Stop'
trap { $_ | Out-String | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installation-error.txt'); exit 1 }
Start-Transcript -LiteralPath (Join-Path $PSScriptRoot 'installation.log') -Force | Out-Null
$serviceName='SignalRgbSensorBridge'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run this installer as administrator.'}
$installDirectory=Join-Path $env:ProgramFiles 'SignalRGB Sensor Bridge'
$dataDirectory=Join-Path $env:ProgramData $serviceName
$sourceDirectory=Join-Path $PSScriptRoot 'bin'
$executable=Join-Path $installDirectory 'SignalRgbSensorService.exe'
if(-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'SignalRgbSensorService.exe'))) {throw 'The compiled bin folder is missing.'}
if(-not $PluginDirectory) {
  $documents=[Environment]::GetFolderPath('MyDocuments')
  $PluginDirectory=Join-Path $documents 'WhirlwindFX\Plugins'
}
$existing=Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
if($existing -and $existing.PathName.Trim('"') -ne $executable) {throw 'A service with this name points at a different executable; refusing to replace it.'}
New-Item -ItemType Directory -Path $installDirectory,$dataDirectory,$PluginDirectory -Force | Out-Null
if($existing -and $existing.State -ne 'Stopped') {Stop-Service -Name $serviceName; (Get-Service $serviceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))}
Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $installDirectory -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sensors.json') -Destination (Join-Path $installDirectory 'sensors.json') -Force
$pluginPath=Join-Path $PluginDirectory 'ASUS_LHM_Temperatures.js'
if(Test-Path -LiteralPath $pluginPath) {Copy-Item -LiteralPath $pluginPath -Destination ($pluginPath+'.backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ASUS_LHM_Temperatures.js') -Destination $pluginPath -Force
if(-not $existing) {New-Service -Name $serviceName -DisplayName 'SignalRGB Motherboard Sensor Bridge' -BinaryPathName ('"'+$executable+'"') -StartupType Automatic -Description 'Reads configured LibreHardwareMonitor temperatures and supplies a local SignalRGB plugin. Does not control fans.' | Out-Null}
& "$env:WINDIR\System32\sc.exe" config $serviceName start= delayed-auto | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not configure delayed service startup.'}
& "$env:WINDIR\System32\sc.exe" failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not configure service recovery.'}
Start-Service -Name $serviceName
(Get-Service $serviceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
$healthDeadline=[DateTime]::UtcNow.AddSeconds(20)
$healthy=$false
$healthReply=$null
while([DateTime]::UtcNow -lt $healthDeadline -and -not $healthy) {
  $client=[Net.Sockets.UdpClient]::new()
  try {
    $client.Client.ReceiveTimeout=1000
    $client.Connect('127.0.0.1',43871)
    $nonce=[Guid]::NewGuid().ToString('N')
    $query=@{protocol=1;request='srgb-lhm/1';nonce=$nonce} | ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($query)
    [void]$client.Send($bytes,$bytes.Length)
    $endpoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0)
    $reply=$client.Receive([ref]$endpoint)
    $healthReply=[Text.Encoding]::UTF8.GetString($reply) | ConvertFrom-Json
    $sampleAge=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$healthReply.sourceTimeMs
    $healthy=$healthReply.nonce -eq $nonce -and $healthReply.status -eq 'ok' -and $healthReply.sensors.Count -eq 2 -and $sampleAge -ge -2000 -and $sampleAge -lt 10000
  } catch [Net.Sockets.SocketException] { }
  finally {$client.Dispose()}
  if(-not $healthy){Start-Sleep -Milliseconds 500}
}
if(-not $healthy){throw 'Service started but did not return both fresh temperatures. Check the service log before using its sensors.'}
$healthReply | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installed-health.json') -Encoding utf8
[pscustomobject]@{Service=$serviceName;Status=(Get-Service $serviceName).Status.ToString();Executable=$executable;Plugin=$pluginPath;Log=(Join-Path $dataDirectory 'service.log')} |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installed.json') -Encoding utf8
Write-Host 'Service installed and started. Restart SignalRGB to load the temperature provider.'
Stop-Transcript | Out-Null
