$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
  dotnet restore '.\src\SensorService.csproj' --configfile '.\nuget.config' --locked-mode
  if($LASTEXITCODE -ne 0){throw 'Dependency restore failed.'}
  dotnet build '.\src\SensorService.csproj' --no-restore -c Release -o '.\bin'
  if($LASTEXITCODE -ne 0){throw 'Service build failed.'}
  & '.\bin\SignalRgbSensorService.exe' --self-test
  if($LASTEXITCODE -ne 0){throw 'Service self-tests failed.'}
  node '.\test-plugin.cjs'
  if($LASTEXITCODE -ne 0){throw 'Plugin tests failed.'}
} finally {Pop-Location}
