#Requires -Version 5.1
<#
.SYNOPSIS
  Redeploy semua project yang tercatat di deployed-urls.txt (untuk push update code).

.DESCRIPTION
  Membaca deployed-urls.txt baris format:
    <project-name> | <deployment-url> | <relay-endpoint>
  Lalu untuk tiap project menjalankan:
    vercel deploy --prod --yes --force --project <project-name>
  TIDAK membuat project baru, TIDAK mengubah file deployed-urls.txt
  (kecuali --UpdateUrls dipakai untuk refresh kolom URL).

.USAGE
  powershell -ExecutionPolicy Bypass -File ./redeploy-vercel.ps1
  ./redeploy-vercel.ps1 -InFile "deployed-urls.txt" -Scope "my-team-slug"
  $env:VERCEL_TOKEN="xxx"; ./redeploy-vercel.ps1 -UpdateUrls
#>

param(
  [string]$InFile = "deployed-urls.txt",
  [string]$Scope = "",
  [string]$Token = $env:VERCEL_TOKEN,
  [switch]$UpdateUrls
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $InFile)) {
  Write-Error "File tidak ditemukan: $InFile"
  exit 1
}

try { $ver = (vercel --version 2>&1 | Select-Object -First 1) } catch {
  Write-Error "Vercel CLI tidak ditemukan. Install dulu: npm i -g vercel"
  exit 1
}
Write-Host "Vercel CLI: $ver"

try {
  $extra = @()
  if ($Scope -ne "") { $extra += @("--scope", $Scope) }
  if ($Token) { $extra += @("--token", $Token) }
  $who = (& vercel whoami @extra --no-color 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { throw $who }
  Write-Host "Login sebagai: $($who.Trim())"
} catch {
  Write-Error "Belum login ke Vercel. Jalankan: vercel login (atau set `$env:VERCEL_TOKEN)"
  exit 1
}

# --- Parse deployed-urls.txt ---
$projects = @()
foreach ($line in (Get-Content -LiteralPath $InFile)) {
  $t = $line.Trim()
  if ($t -eq "" -or $t.StartsWith("#")) { continue }
  # format: name | url | relay-url ; ambil kolom pertama
  $name = ($t -split '\|')[0].Trim()
  if ($name -eq "" -or $name.StartsWith("# FAILED")) { continue }
  # skip baris FAILED
  if ($t -match "^\s*#") { continue }
  $projects += $name
}

if ($projects.Count -eq 0) {
  Write-Error "Tidak ada project valid di $InFile"
  exit 1
}

Write-Host "Ditemukan $($projects.Count) project di $InFile"

$success = 0
$failed = 0
$newUrls = @{}  # project -> url (untuk --UpdateUrls)

$i = 0
foreach ($name in $projects) {
  $i++
  Write-Host ""
  Write-Host "[$i/$($projects.Count)] Redeploy: $name ..."

  $deployArgs = @("deploy", "--prod", "--yes", "--force", "--project", $name)
  if ($Scope -ne "") { $deployArgs += @("--scope", $Scope) }
  if ($Token) { $deployArgs += @("--token", $Token) }
  $out = (& vercel @deployArgs --no-color 2>&1 | Out-String)
  $code = $LASTEXITCODE

  $urls = [regex]::Matches($out, 'https://[^\s]+') | ForEach-Object { $_.Value.TrimEnd('.', ',', ')') }
  $url = ($urls | Select-Object -Last 1)

  if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($url)) {
    Write-Host "  GAGAL: $name" -ForegroundColor Red
    ($out -split "`r?`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "    $_" }
    $failed++
  } else {
    Write-Host "  OK: $url"
    Write-Host "  Relay: $url/api/relay"
    $newUrls[$name] = $url
    $success++
  }

  if ($i -lt $projects.Count) { Start-Sleep -Seconds 3 }
}

Write-Host ""
Write-Host "Selesai. Sukses: $success, Gagal: $failed."

# --- Opsional: refresh kolom URL di file yang sama (backup dulu) ---
if ($UpdateUrls -and $success -gt 0) {
  $backup = "$InFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $InFile -Destination $backup
  Write-Host "Backup: $backup"
  $lines = Get-Content -LiteralPath $InFile
  $updated = foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#")) { $line; continue }
    $parts = $t -split '\|'
    $pname = $parts[0].Trim()
    if ($newUrls.ContainsKey($pname)) {
      $u = $newUrls[$pname]
      "$pname | $u | $u/api/relay"
    } else {
      $line
    }
  }
  $updated | Set-Content -LiteralPath $InFile
  Write-Host "URL diperbarui di: $InFile"
}

if ($failed -gt 0) { exit 2 }
