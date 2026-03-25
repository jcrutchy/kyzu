$outputFile = "kyzu_codebase_snapshot.txt"
$excludeFolders = @("target", ".git", "assets")

# 1. Initialize/Overwrite the file with the project structure
"--- PROJECT STRUCTURE ---" | Set-Content -Path $outputFile -Encoding utf8
Get-ChildItem -Recurse | Where-Object { $excludeFolders -notcontains $_.Parent.Name } | 
    Select-Object @{Name="Path"; Expression={$_.FullName.Replace((Get-Location).Path, ".")}} | 
    Add-Content -Path $outputFile -Encoding utf8

# 2. Explicitly grab essential root files
$rootFiles = @("Cargo.toml", ".rustfmt.toml", "README.md")
foreach ($f in $rootFiles) {
    if (Test-Path $f) {
        "`n--- FILE: ./$f ---" | Add-Content -Path $outputFile -Encoding utf8
        Get-Content $f | Add-Content -Path $outputFile -Encoding utf8
    }
}

# 3. Source logic and shaders (using a more reliable extension filter)
if (Test-Path "src") {
    Get-ChildItem -Path "src" -Recurse -File | Where-Object { $_.Extension -match "rs|wgsl" } | ForEach-Object {
        $relativeName = $_.FullName.Replace((Get-Location).Path, ".")
        "`n--- FILE: $relativeName ---" | Add-Content -Path $outputFile -Encoding utf8
        Get-Content $_.FullName | Add-Content -Path $outputFile -Encoding utf8
    }
}

Write-Host "Snapshot complete: $outputFile" -ForegroundColor Green