$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
  dotnet restore '.\src\SensorService.csproj' --configfile '.\nuget.config' --locked-mode
  if($LASTEXITCODE -ne 0){throw 'Dependency restore failed.'}
  dotnet build '.\src\SensorService.csproj' --no-restore -c Release -o '.\bin'
  if($LASTEXITCODE -ne 0){throw 'Service build failed.'}
  & '.\bin\SignalRgbSensorService.exe' --self-test
  if($LASTEXITCODE -ne 0){throw 'Service self-tests failed.'}
  node '.\tools\generate-plugins.cjs' --check
  if($LASTEXITCODE -ne 0){throw 'Generated plugins are stale.'}
  node '.\test-catalog.cjs'
  if($LASTEXITCODE -ne 0){throw 'Plugin tests failed.'}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\test-installer.ps1'
  if($LASTEXITCODE -ne 0){throw 'Installer tests failed.'}
} finally {Pop-Location}
