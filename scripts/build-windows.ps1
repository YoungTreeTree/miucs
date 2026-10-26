param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64',
    [switch]$FrameworkDependent
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $root 'apps/windows/Miucs.Windows.csproj'
$output = Join-Path $root "dist/windows/$Runtime"
& dotnet run --project (Join-Path $root 'tests/platforms/windows/CoreTests/Miucs.CoreTests.csproj') --configuration Release
if ($LASTEXITCODE -ne 0) { throw 'Portable tests failed' }
$selfContained = if ($FrameworkDependent) { 'false' } else { 'true' }
& dotnet publish $project -c Release -r $Runtime --self-contained $selfContained -o $output -p:PublishSingleFile=false
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed' }
Copy-Item (Join-Path $root 'apps/windows/README.md') (Join-Path $output 'README.md')
Copy-Item (Join-Path $root 'docs/windows-acceptance.md') (Join-Path $output 'ACCEPTANCE.md')
Write-Host "Portable app: $output/Miucs.exe (copy the entire directory, not just the EXE)."
