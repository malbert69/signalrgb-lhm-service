param([switch]$RemovePlugin,[string]$PluginDirectory)
$ErrorActionPreference='Stop'
$serviceName='SignalRgbSensorBridge'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run this script as administrator.'}
$expected=Join-Path $env:ProgramFiles 'SignalRGB Sensor Bridge\SignalRgbSensorService.exe'
$service=Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
if($service -and $service.PathName.Trim('"') -ne $expected) {throw 'Service executable differs from the expected path; refusing to remove it.'}
if($service) {
  if($service.State -ne 'Stopped') {Stop-Service $serviceName; (Get-Service $serviceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))}
  & "$env:WINDIR\System32\sc.exe" delete $serviceName
  if($LASTEXITCODE -ne 0){throw 'Service removal failed.'}
}
if($RemovePlugin) {
  if(-not $PluginDirectory) {$PluginDirectory=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WhirlwindFX\Plugins'}
  $plugins=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*_LHM_Temperatures.js' -File)
  $catalogDirectory=Join-Path $PSScriptRoot 'plugins'
  if(Test-Path -LiteralPath $catalogDirectory) {$plugins+=@(Get-ChildItem -LiteralPath $catalogDirectory -Filter '*_LHM_Temperatures.js' -File)}
  foreach($plugin in $plugins) {
    $pluginPath=Join-Path $PluginDirectory $plugin.Name
    if(Test-Path -LiteralPath $pluginPath) {Remove-Item -LiteralPath $pluginPath}
  }
}
Write-Host 'Service removed. Program files, configuration, logs, and the shared PawnIO driver were retained.'
