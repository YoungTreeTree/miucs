#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
dotnet run --project tests/platforms/windows/CoreTests/Miucs.CoreTests.csproj --configuration Release
dotnet build apps/windows/Miucs.Windows.csproj --configuration Release --nologo
python3 scripts/check-boundaries.py
python3 scripts/validate-contracts.py
