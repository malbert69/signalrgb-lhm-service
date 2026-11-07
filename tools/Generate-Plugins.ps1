param([switch]$Check)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
if($Check) {
  & node (Join-Path $PSScriptRoot 'generate-plugins.cjs') --check
  exit $LASTEXITCODE
}
$cache=Join-Path $PSScriptRoot 'upstream-cache'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$hashes=@{
  'SuperIOHardware.cs'='25EFBF2F88C99662E046BD21FFAD835297594C42DF0F8AB4A4F5644DE8B945CD'
  'Identification.cs'='C1DC6999D9D35B3569FD0CDB2C437F778C695112AEF73A54DF67FE24637FD683'
  'Model.cs'='07873AB54FE613461DB995A62124116D1A1C31AA043ED0B81521A03902CAFDD8'
}
foreach($name in $hashes.Keys) {
  $sourcePath=Join-Path $cache $name
  if(-not (Test-Path -LiteralPath $sourcePath)) {
    Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v0.9.6/LibreHardwareMonitorLib/Hardware/Motherboard/'+$name) -OutFile $sourcePath -UseBasicParsing
  }
  if((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $hashes[$name]) {throw ('Upstream source hash mismatch: '+$name)}
}
if(-not (Test-Path -LiteralPath (Join-Path $projectRoot 'bin\runtimes\win-x64\lib\net10.0\LibreHardwareMonitorLib.dll'))) {throw 'Run Build.ps1 first to prepare the pinned library.'}
& dotnet run --project (Join-Path $PSScriptRoot 'PluginCatalog\PluginCatalog.csproj') -- $projectRoot
if($LASTEXITCODE -ne 0) {throw 'Mapping extraction failed.'}
& node (Join-Path $PSScriptRoot 'generate-plugins.cjs')
if($LASTEXITCODE -ne 0) {throw 'Plugin generation failed.'}
