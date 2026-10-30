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
python (Join-Path $root 'scripts/prepare-plugin-deps.py') --target $Runtime
if ($LASTEXITCODE -ne 0) { throw 'Plugin dependency preparation failed' }
$arch = if ($Runtime -eq 'win-arm64') { 'ARM64' } else { 'x64' }
cmake -S (Join-Path $root 'modules/plugins') -B (Join-Path $root 'build/plugins') -A $arch
if ($LASTEXITCODE -ne 0) { throw 'Plugin configure failed' }
cmake --build (Join-Path $root 'build/plugins') --config Release --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed' }
ctest --test-dir (Join-Path $root 'build/plugins') -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Plugin tests failed' }
Copy-Item (Join-Path $root 'build/plugins/Release/miucs_plugins.dll') $output
Copy-Item (Join-Path $root 'build/plugins/Release/miucs-plugin-worker.exe') $output
Copy-Item (Join-Path $root 'third_party/plugin-licenses') (Join-Path $output 'PluginLicenses') -Recurse -Force
if (Test-Path (Join-Path $output 'Plugins')) { Remove-Item (Join-Path $output 'Plugins') -Recurse -Force }
Copy-Item (Join-Path $root 'plugins') (Join-Path $output 'Plugins') -Recurse -Force
Write-Host "Portable app: $output/Miucs.exe (copy the entire directory, not just the EXE)."
