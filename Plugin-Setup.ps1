# Shared installer functions. Loading this file never changes services or files.
function ConvertTo-BoardKey {
  param($Value)
  if($Value -isnot [string]) {return ''}
  return ([regex]::Replace($Value.Trim(),'\s+',' ')).ToUpperInvariant()
}

function Read-PluginManifest {
  param([string]$PackageRoot)
  $path=Join-Path $PackageRoot 'plugins\install-manifest.json'
  $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if($manifest.schemaVersion -ne 1 -or $manifest.plugins -isnot [array] -or $manifest.plugins.Count -lt 1) {throw 'Invalid plugin installation manifest.'}
  $filenames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($plugin in $manifest.plugins) {
    if($plugin.path -isnot [string] -or $plugin.path -cnotmatch '^(plugins/)?[A-Za-z0-9_]+_LHM_Temperatures\.js$') {throw 'Invalid plugin path in installation manifest.'}
    $filename=($plugin.path -split '/')[-1]
    if(-not $filenames.Add($filename)) {throw ('Duplicate packaged plugin filename: '+$filename)}
    if($plugin.manufacturers -isnot [array] -or $plugin.models -isnot [array] -or $plugin.manufacturers.Count -eq 0 -or $plugin.models.Count -eq 0) {throw ('Missing board identities for '+$filename)}
    foreach($manufacturer in $plugin.manufacturers) {
      $manufacturerKey=ConvertTo-BoardKey $manufacturer
      if(-not $manufacturerKey) {throw ('Invalid manufacturer for '+$filename)}
      foreach($model in $plugin.models) {
        $modelKey=ConvertTo-BoardKey $model
        if(-not $modelKey) {throw ('Invalid model for '+$filename)}
        if(-not $identities.Add($manufacturerKey+'|'+$modelKey)) {throw ('Ambiguous board identity in installation manifest: '+$manufacturer+' '+$model)}
      }
    }
  }
  return $manifest
}

function Select-MotherboardPlugin {
  param($Manifest,[object[]]$BaseBoards)
  $boards=@(foreach($board in $BaseBoards) {
    $manufacturer=ConvertTo-BoardKey $board.Manufacturer
    $model=ConvertTo-BoardKey $board.Product
    if($manufacturer -and $model) {[pscustomobject]@{Manufacturer=$manufacturer;Model=$model}}
  })
  $matches=@(foreach($plugin in $Manifest.plugins) {
    foreach($board in $boards) {
      $manufacturerMatches=$false
      foreach($manufacturer in $plugin.manufacturers) {if((ConvertTo-BoardKey $manufacturer) -ceq $board.Manufacturer) {$manufacturerMatches=$true; break}}
      $modelMatches=$false
      foreach($model in $plugin.models) {if((ConvertTo-BoardKey $model) -ceq $board.Model) {$modelMatches=$true; break}}
      if($manufacturerMatches -and $modelMatches) {$plugin; break}
    }
  })
  if($matches.Count -eq 0) {
    $detected=(@($BaseBoards | ForEach-Object {([string]$_.Manufacturer+' '+[string]$_.Product).Trim()}) -join '; ')
    throw ('No matching motherboard plugin for: '+$detected+'. No plugins were installed. Run the service --probe command and check the motherboard support list.')
  }
  if($matches.Count -ne 1) {throw 'Multiple motherboard plugins match the detected baseboards. No plugins were installed.'}
  return $matches[0]
}

function Install-MotherboardPlugin {
  param([string]$PackageRoot,[string]$PluginDirectory,$Manifest,$SelectedPlugin)
  $packagePath=[IO.Path]::GetFullPath($PackageRoot)
  $directory=[IO.Path]::GetFullPath($PluginDirectory).TrimEnd('\','/')
  if($directory -eq [IO.Path]::GetPathRoot($directory).TrimEnd('\','/')) {throw 'Choose a named plugin directory, not a drive root.'}
  if(@($Manifest.plugins | Where-Object {$_.path -ceq $SelectedPlugin.path}).Count -ne 1) {throw 'Selected plugin is not uniquely listed in the installation manifest.'}
  # Revalidate paths before constructing filesystem targets, even for direct callers.
  foreach($plugin in $Manifest.plugins) {
    if($plugin.path -isnot [string] -or $plugin.path -cnotmatch '^(plugins/)?[A-Za-z0-9_]+_LHM_Temperatures\.js$') {throw 'Invalid packaged plugin path.'}
    if((Split-Path -Parent ([IO.Path]::GetFullPath((Join-Path $packagePath $plugin.path)))) -eq $directory) {throw 'Choose a plugin installation directory separate from the package source.'}
  }
  $source=Join-Path $packagePath $SelectedPlugin.path
  if(-not (Test-Path -LiteralPath $source -PathType Leaf)) {throw ('Matching plugin file is missing: '+$SelectedPlugin.path)}
  $selectedName=($SelectedPlugin.path -split '/')[-1]
  $destination=Join-Path $directory $selectedName
  if([IO.Path]::GetFullPath($source) -eq $destination) {throw 'Choose a plugin installation directory separate from the package source.'}
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
  $backups=[Collections.Generic.List[string]]::new()
  if(Test-Path -LiteralPath $destination -PathType Leaf) {
    $backup=$destination+'.backup-'+$stamp
    Copy-Item -LiteralPath $destination -Destination $backup
    $backups.Add($backup)
  }
  Copy-Item -LiteralPath $source -Destination $destination -Force
  $disabled=0
  foreach($plugin in $Manifest.plugins) {
    $name=($plugin.path -split '/')[-1]
    if($name -ieq $selectedName) {continue}
    $unused=[IO.Path]::GetFullPath((Join-Path $directory $name))
    $backup=$unused+'.backup-unused-'+$stamp
    # All moves stay within the explicitly selected directory; no recursive moves.
    if((Split-Path -Parent $unused) -ne $directory -or (Split-Path -Parent $backup) -ne $directory) {throw 'Plugin backup target escaped the installation directory.'}
    if(Test-Path -LiteralPath $unused -PathType Leaf) {
      Move-Item -LiteralPath $unused -Destination $backup
      $backups.Add($backup)
      $disabled++
    }
  }
  return [pscustomobject]@{Plugin=$destination;DisabledPlugins=$disabled;Backups=@($backups.ToArray())}
}
