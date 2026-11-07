param([string]$PluginDirectory,[switch]$Elevate)
$ErrorActionPreference='Stop'
trap { $_ | Out-String | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installation-error.txt'); exit 1 }
function Test-BridgeHealth {
  param($Reply,[string]$Nonce,[double]$SampleAge)
  if($null -eq $Reply -or $Reply.protocol -ne 2 -or $Reply.nonce -ne $Nonce -or $Reply.status -ne 'ok' -or
    [double]::IsNaN($SampleAge) -or $SampleAge -lt -2000 -or $SampleAge -ge 10000 -or
    $Reply.board.manufacturer -isnot [string] -or [string]::IsNullOrWhiteSpace($Reply.board.manufacturer) -or
    $Reply.board.model -isnot [string] -or [string]::IsNullOrWhiteSpace($Reply.board.model) -or
    $Reply.sensors -isnot [array] -or $Reply.sensors.Count -lt 1 -or $Reply.sensors.Count -gt 128) {return $false}
  $identifiers=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($sensor in $Reply.sensors) {
    if($sensor.id -isnot [string] -or [string]::IsNullOrWhiteSpace($sensor.id) -or -not $identifiers.Add($sensor.id)) {return $false}
    if($sensor.celsius -isnot [double] -and $sensor.celsius -isnot [int] -and $sensor.celsius -isnot [long] -and $sensor.celsius -isnot [decimal]) {return $false}
    $temperature=[double]$sensor.celsius
    if([double]::IsNaN($temperature) -or [double]::IsInfinity($temperature) -or $temperature -lt -20 -or $temperature -gt 150) {return $false}
  }
  return $true
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  if(-not $Elevate) {throw 'Run Install.cmd, or run this installer as administrator.'}
  if(-not $PluginDirectory) {$PluginDirectory=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WhirlwindFX\Plugins'}
  # Double trailing backslashes before the closing quote for Windows argument parsing.
  $quotedPluginDirectory='"'+[regex]::Replace($PluginDirectory,'(\\+)$','$1$1')+'"'
  $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -PluginDirectory '+$quotedPluginDirectory
  $installer=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
  exit $installer.ExitCode
}
Start-Transcript -LiteralPath (Join-Path $PSScriptRoot 'installation.log') -Force | Out-Null
$serviceName='SignalRgbSensorBridge'
$installDirectory=Join-Path $env:ProgramFiles 'SignalRGB Sensor Bridge'
$dataDirectory=Join-Path $env:ProgramData $serviceName
$sourceDirectory=Join-Path $PSScriptRoot 'bin'
$executable=Join-Path $installDirectory 'SignalRgbSensorService.exe'
if(-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'SignalRgbSensorService.exe'))) {throw 'The compiled bin folder is missing.'}
$plugins=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*_LHM_Temperatures.js' -File)
$catalogDirectory=Join-Path $PSScriptRoot 'plugins'
if(Test-Path -LiteralPath $catalogDirectory) {$plugins+=@(Get-ChildItem -LiteralPath $catalogDirectory -Filter '*_LHM_Temperatures.js' -File)}
if($plugins.Count -eq 0) {throw 'No motherboard plugins were found beside the installer.'}
if(@($plugins.Name | Sort-Object -Unique).Count -ne $plugins.Count) {throw 'Packaged motherboard plugins have duplicate filenames.'}
if(-not $PluginDirectory) {
  $documents=[Environment]::GetFolderPath('MyDocuments')
  $PluginDirectory=Join-Path $documents 'WhirlwindFX\Plugins'
}
$existing=Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
if($existing -and $existing.PathName.Trim('"') -ne $executable) {throw 'A service with this name points at a different executable; refusing to replace it.'}
New-Item -ItemType Directory -Path $installDirectory,$dataDirectory,$PluginDirectory -Force | Out-Null
if($existing -and $existing.State -ne 'Stopped') {Stop-Service -Name $serviceName; (Get-Service $serviceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))}
Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $installDirectory -Recurse -Force
$pluginPaths=@(foreach($plugin in $plugins) {
  $pluginPath=Join-Path $PluginDirectory $plugin.Name
  if(Test-Path -LiteralPath $pluginPath) {Copy-Item -LiteralPath $pluginPath -Destination ($pluginPath+'.backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))}
  Copy-Item -LiteralPath $plugin.FullName -Destination $pluginPath -Force
  $pluginPath
})
if(-not $existing) {New-Service -Name $serviceName -DisplayName 'SignalRGB Motherboard Sensor Bridge' -BinaryPathName ('"'+$executable+'"') -StartupType Automatic -Description 'Reads native LibreHardwareMonitor motherboard temperatures for local SignalRGB plugins. Does not control fans.' | Out-Null}
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
    $query=@{protocol=2;request='srgb-lhm/2';nonce=$nonce} | ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($query)
    [void]$client.Send($bytes,$bytes.Length)
    $endpoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0)
    $reply=$client.Receive([ref]$endpoint)
    $healthReply=[Text.Encoding]::UTF8.GetString($reply) | ConvertFrom-Json
    $sampleAge=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$healthReply.sourceTimeMs
    $healthy=Test-BridgeHealth -Reply $healthReply -Nonce $nonce -SampleAge $sampleAge
  } catch [Net.Sockets.SocketException] { }
  finally {$client.Dispose()}
  if(-not $healthy){Start-Sleep -Milliseconds 500}
}
if(-not $healthy){throw 'Service started but did not return fresh motherboard temperatures and board identity using protocol 2. Check the service log.'}
$healthReply | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installed-health.json') -Encoding utf8
[pscustomobject]@{Service=$serviceName;Status=(Get-Service $serviceName).Status.ToString();Executable=$executable;Plugins=$pluginPaths;Log=(Join-Path $dataDirectory 'service.log')} |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installed.json') -Encoding utf8
Write-Host 'Service installed and started. Restart SignalRGB; only a plugin matching this motherboard will announce a temperature provider.'
Stop-Transcript | Out-Null
