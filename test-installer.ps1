$ErrorActionPreference='Stop'
# Parse scripts without executing installation, elevation, or service changes.
foreach($script in 'Install-Service.ps1','Uninstall-Service.ps1','Build.ps1','tools\Generate-Plugins.ps1') {
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
