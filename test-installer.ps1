$ErrorActionPreference='Stop'
# Parse scripts without executing installation, elevation, or service changes.
foreach($script in 'Install-Service.ps1','Plugin-Setup.ps1','Uninstall-Service.ps1','Build.ps1','tools\Generate-Plugins.ps1') {
  $tokens=$null; $errors=$null
  $parsed=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $script),[ref]$tokens,[ref]$errors)
  if($errors.Count) {throw ($errors | Out-String)}
  if($script -eq 'Install-Service.ps1') {$installer=$parsed}
}
$healthFunction=$installer.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-BridgeHealth'},$true)
if(-not $healthFunction) {throw 'Installer health function missing.'}
. ([scriptblock]::Create($healthFunction.Extent.Text))
function Assert-Health($Reply,[bool]$Expected,[double]$Age=0) {
  $actual=Test-BridgeHealth -Reply $Reply -Nonce 'test' -SampleAge $Age
  if($actual -ne $Expected) {throw ('Unexpected health result: '+($Reply | ConvertTo-Json -Depth 5 -Compress))}
}
function New-Reply {
  return @{protocol=2;nonce='test';status='ok';board=@{manufacturer='Other manufacturer';model='Other board'};sensors=@(@{id='/test/temperature/0';celsius=0})}
}
Assert-Health (New-Reply) $true
$reply=New-Reply; $reply.sensors+=@{id='/another/temperature/1';celsius=35}; $reply.sensors+=@{id='/another/temperature/2';celsius=45}
Assert-Health $reply $true
foreach($age in -2001,10000,60000,([double]::NaN)) {Assert-Health (New-Reply) $false $age}
foreach($field in 'protocol','nonce','status','board','sensors') {
  $reply=New-Reply; $reply.Remove($field); Assert-Health $reply $false
}
$reply=New-Reply; $reply.protocol=1; Assert-Health $reply $false
$reply=New-Reply; $reply.board.model=''; Assert-Health $reply $false
$reply=New-Reply; $reply.sensors+=@{id='/test/temperature/0';celsius=35}; Assert-Health $reply $false
foreach($value in $null,'35',([double]::NaN),([double]::PositiveInfinity),151,$true) {
  $reply=New-Reply; $reply.sensors[0].celsius=$value; Assert-Health $reply $false
}
Write-Host 'PASS: PowerShell syntax and generic installer health checks (variable sensor counts, board identity, protocol, timestamps, IDs, and temperatures)'

. (Join-Path $PSScriptRoot 'Plugin-Setup.ps1')
function Assert-True([bool]$Result,[string]$Message) {if(-not $Result) {throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Expected) {
  try {& $Action; throw 'Expected an exception but none was raised.'}
  catch {if($_.Exception.Message -notlike $Expected) {throw}}
}
$manifest=Read-PluginManifest -PackageRoot $PSScriptRoot
foreach($plugin in $manifest.plugins) {
  $selection=Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer=$plugin.manufacturers[0];Product=$plugin.models[0]})
  Assert-True ($selection.path -ceq $plugin.path) ('Wrong selected plugin: '+$plugin.path)
}
$asus=Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer=' asustek   computer inc. ';Product=' prime z790-p wifi '})
Assert-True ($asus.path -ceq 'ASUS_LHM_Temperatures.js') 'Original ASUS plugin is included in installer selection.'
$aliasPlugin=$manifest.plugins | Where-Object {$_.models.Count -gt 1} | Select-Object -First 1
$selection=Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer=$aliasPlugin.manufacturers[0];Product=$aliasPlugin.models[-1]})
Assert-True ($selection.path -ceq $aliasPlugin.path) 'Exact alternate SMBIOS alias selects its plugin.'
Assert-Throws {Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer='ASUSTeK COMPUTER INC.';Product='PRIME Z790-P WIFI II'})} '*No matching motherboard plugin*'
Assert-Throws {Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer='Other vendor';Product='PRIME Z790-P WIFI'})} '*No matching motherboard plugin*'
Assert-Throws {Select-MotherboardPlugin -Manifest $manifest -BaseBoards @()} '*No matching motherboard plugin*'
Assert-Throws {Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer='';Product='PRIME Z790-P WIFI'})} '*No matching motherboard plugin*'
$other=$manifest.plugins | Where-Object {$_.path -ne $asus.path} | Select-Object -First 1
Assert-Throws {Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer='ASUS';Product='PRIME Z790-P WIFI'},@{Manufacturer=$other.manufacturers[0];Product=$other.models[0]})} '*Multiple motherboard plugins*'
$selection=Select-MotherboardPlugin -Manifest $manifest -BaseBoards @(@{Manufacturer='ASUS';Product='PRIME Z790-P WIFI'},@{Manufacturer='ASUS';Product='PRIME Z790-P WIFI'})
Assert-True ($selection.path -ceq $asus.path) 'Repeated baseboard rows should select a single plugin.'
Write-Host ('PASS: automatic selection for all '+$manifest.plugins.Count+' plugins, model aliases, normalized identities, unsupported boards, and ambiguous baseboards')

$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$fixtureRoot=Join-Path $tempParent ('signalrgb-plugin-tests-'+[Guid]::NewGuid().ToString('N'))
try {
  $package=Join-Path $fixtureRoot 'package'
  $plugins=Join-Path $package 'plugins'
  $destination=Join-Path $fixtureRoot 'installed'
  New-Item -ItemType Directory -Path $package,$plugins,$destination -Force | Out-Null
  $fixture=@{schemaVersion=1;plugins=@(
    @{path='Selected_LHM_Temperatures.js';manufacturers=@('Test vendor');models=@('Test board')},
    @{path='plugins/Other_LHM_Temperatures.js';manufacturers=@('Other vendor');models=@('Other board')}
  )}
  $fixtureManifest=Join-Path $plugins 'install-manifest.json'
  $fixture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixtureManifest
  $selectedSource=Join-Path $package 'Selected_LHM_Temperatures.js'
  Set-Content -LiteralPath $selectedSource -Value 'new selected plugin'
  Set-Content -LiteralPath (Join-Path $plugins 'Other_LHM_Temperatures.js') -Value 'packaged other plugin'
  $loaded=Read-PluginManifest -PackageRoot $package
  $selected=Select-MotherboardPlugin -Manifest $loaded -BaseBoards @(@{Manufacturer='Test vendor';Product='Test board'})
  $fresh=Join-Path $fixtureRoot 'fresh'
  $freshResult=Install-MotherboardPlugin -PackageRoot $package -PluginDirectory $fresh -Manifest $loaded -SelectedPlugin $selected
  Assert-True (@(Get-ChildItem -LiteralPath $fresh -Filter '*.js').Count -eq 1) 'Fresh installation must copy only the matching plugin.'
  Assert-True ($freshResult.DisabledPlugins -eq 0) 'Fresh installation must not disable any plugins.'
  $selectedTarget=Join-Path $destination 'Selected_LHM_Temperatures.js'
  $unusedTarget=Join-Path $destination 'Other_LHM_Temperatures.js'
  $unrelated=Join-Path $destination 'OtherApp.js'
  Set-Content -LiteralPath $selectedTarget -Value 'old selected plugin'
  Set-Content -LiteralPath $unusedTarget -Value 'old unused plugin'
  Set-Content -LiteralPath $unrelated -Value 'unrelated user plugin'
  $result=Install-MotherboardPlugin -PackageRoot $package -PluginDirectory ($destination+'\') -Manifest $loaded -SelectedPlugin $selected
  Assert-True ($result.DisabledPlugins -eq 1 -and $result.Backups.Count -eq 2) 'Upgrade must back up replaced and unused packaged plugins.'
  Assert-True (-not (Test-Path -LiteralPath $unusedTarget)) 'Unused packaged plugin must stop loading.'
  Assert-True ((Get-Content -LiteralPath $selectedTarget -Raw).Trim() -ceq 'new selected plugin') 'Matching plugin was not installed.'
  Assert-True ((Get-Content -LiteralPath $unrelated -Raw).Trim() -ceq 'unrelated user plugin') 'Unrelated plugins must remain untouched.'
  Assert-True (@($result.Backups | Where-Object {(Get-Content -LiteralPath $_ -Raw).Trim() -ceq 'old unused plugin'}).Count -eq 1) 'Unused plugin backup must preserve its content.'
  Assert-Throws {Install-MotherboardPlugin -PackageRoot $package -PluginDirectory $plugins -Manifest $loaded -SelectedPlugin $selected} '*separate from the package source*'
  $fixture.plugins[1].path='../Escape_LHM_Temperatures.js'
  $fixture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixtureManifest
  Assert-Throws {Read-PluginManifest -PackageRoot $package} '*Invalid plugin path*'
  $fixture.plugins[1].path='plugins/Other_LHM_Temperatures.js'
  $fixture.plugins[1].manufacturers=@('Test vendor'); $fixture.plugins[1].models=@('Test board')
  $fixture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixtureManifest
  Assert-Throws {Read-PluginManifest -PackageRoot $package} '*Ambiguous board identity*'
  $fixture.plugins[1].path='plugins/Selected_LHM_Temperatures.js'
  $fixture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixtureManifest
  Assert-Throws {Read-PluginManifest -PackageRoot $package} '*Duplicate packaged plugin filename*'
  Write-Host 'PASS: single-plugin installation, reversible upgrade cleanup, unrelated-plugin preservation, source protection, and manifest path/identity validation'
} finally {
  $resolvedFixture=[IO.Path]::GetFullPath($fixtureRoot)
  if((Split-Path -Parent $resolvedFixture) -ne $tempParent -or (Split-Path -Leaf $resolvedFixture) -notlike 'signalrgb-plugin-tests-*') {throw 'Unsafe test cleanup target.'}
  if(Test-Path -LiteralPath $resolvedFixture) {Remove-Item -LiteralPath $resolvedFixture -Recurse -Force}
}
