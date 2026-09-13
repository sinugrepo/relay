#Requires -Version 5.1
<#
.SYNOPSIS
  Deploy project ini 10x (atau N kali) ke Vercel sebagai project yang BERBEDA,
  sehingga dapat 10 link project yang berbeda-beda.

.DESCRIPTION
  Tiap iterasi deploy ke project name yang berbeda via:
    vercel deploy --prod --yes --project <nama-unik>
  Flag --project meng-override project yang ter-link di .vercel/,
  jadi tidak perlu hapus .vercel / copy folder manual.

.USAGE
  # 10x deploy dengan prefix default "relay" (hasil: relay-01-xxxx, dst):
  powershell -ExecutionPolicy Bypass -File ./deploy-vercel-10x.ps1

  # Custom prefix + jumlah:
  ./deploy-vercel-10x.ps1 -Prefix "opencode-relay" -Count 10

  # Pakai team scope tertentu:
  ./deploy-vercel-10x.ps1 -Prefix "relay" -Count 10 -Scope "my-team-slug"

  # Pakai token (alternatif vercel login):
  #   $env:VERCEL_TOKEN="xxx"; ./deploy-vercel-10x.ps1

.OUTPUTS
  File deployed-urls.txt berisi daftar:
    <project-name> | <deployment-url> | <deployment-url>/api/relay
#>

param(
  [string]$Prefix = "relay",
  [int]$Count = 10,
  [string]$Scope = "",
  [string]$Token = $env:VERCEL_TOKEN,
  [string]$OutFile = "deployed-urls.txt"
)

$ErrorActionPreference = "Stop"

function Invoke-Vercel {
  param([string[]]$VercelArgs)
  $extra = @()
  if ($Scope -ne "") { $extra += @("--scope", $Scope) }
  if ($Token -ne "" -and $null -ne $Token) { $extra += @("--token", $Token) }
  # --no-color agar output URL mudah di-parse
  & vercel @VercelArgs @extra --no-color @args
}

# --- 1. Cek CLI ---
try { $ver = (vercel --version 2>&1 | Select-Object -First 1) } catch {
  Write-Error "Vercel CLI tidak ditemukan. Install dulu: npm i -g vercel"
  exit 1
}
Write-Host "Vercel CLI: $ver"

# --- 2. Cek login (kecuali pakai token, whoami tetap butuh auth) ---
try {
  $who = Invoke-Vercel @("whoami") 2>&1 | Out-String
  Write-Host "Login sebagai: $($who.Trim())"
} catch {
  Write-Error "Belum login ke Vercel. Jalankan: vercel login  (atau set `$env:VERCEL_TOKEN)"
  exit 1
}

# --- 3. Normalisasi prefix ke slug vercel yang valid ---
$Prefix = ($Prefix.ToLower() -replace '[^a-z0-9-]', '-').Trim('-')
if ($Prefix -eq "") { $Prefix = "relay" }

# Kosongkan / buat file output baru dengan header
"# deployed-urls.txt - hasil deploy $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content -LiteralPath $OutFile
"# format: <project-name> | <deployment-url> | <relay-endpoint>" | Add-Content -LiteralPath $OutFile

$success = 0
$failed = 0

for ($i = 1; $i -le $Count; $i++) {
  # suffix random 4 huruf agar nama project unik per scope (tabrakan = gagal)
  $rand = -join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
  $num = $i.ToString("00")
  $name = "$Prefix-$num-$rand"

  Write-Host ""
  Write-Host "[$i/$Count] Deploy project: $name ..."

  # (a) Buat project dulu secara eksplisit. Catatan: `project add` TIDAK
  #     mengenal flag --yes (langsung error) jadi jangan tambahkan.
  #     Kalau project sudah ada, tetap lanjut ke deploy.
  $addArgs = @("project", "add", $name)
  if ($Scope -ne "") { $addArgs += @("--scope", $Scope) }
  if ($Token) { $addArgs += @("--token", $Token) }
  $addOut = (& vercel @addArgs --no-color 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {
    $flat = ($addOut -replace "`r?`n", " ")
    Write-Host "  (project add gagal) $flat"
    if ($flat -notmatch "(?i)already exists|already claimed") {
      "# FAILED $name :: project add gagal: $($flat.Substring(0, [Math]::Min(300, $flat.Length)))" | Add-Content -LiteralPath $OutFile
      $failed++
      continue
    }
    Write-Host "  (project sudah ada, lanjut deploy)"
  } else {
    Write-Host "  (project add OK)"
  }

  # (b) Deploy ke project tersebut. --force agar rebuild walau tidak ada perubahan.
  try {
    $deployArgs = @("deploy", "--prod", "--yes", "--force", "--project", $name)
    if ($Scope -ne "") { $deployArgs += @("--scope", $Scope) }
    if ($Token) { $deployArgs += @("--token", $Token) }
    $out = (& vercel @deployArgs --no-color 2>&1 | Out-String)
    # Ambil baris terakhir yang mirip URL https://...
    $urls = [regex]::Matches($out, 'https://[^\s]+') | ForEach-Object { $_.Value.TrimEnd('.', ',', ')') }
    $url = ($urls | Select-Object -Last 1)

    if ([string]::IsNullOrWhiteSpace($url)) {
      throw "URL deployment tidak ditemukan. Output:`n$out"
    }

    $relayUrl = "$url/api/relay"
    Write-Host "  OK: $url"
    Write-Host "  Relay: $relayUrl"
    "$name | $url | $relayUrl" | Add-Content -LiteralPath $OutFile
    $success++
  } catch {
    Write-Host "  GAGAL: $($_.Exception.Message)" -ForegroundColor Red
    "# FAILED $name :: $($_.Exception.Message -replace "`r?`n", ' ')" | Add-Content -LiteralPath $OutFile
    $failed++
  }

  # Jeda kecil agar tidak kena rate-limit API Vercel
  if ($i -lt $Count) { Start-Sleep -Seconds 3 }
}

Write-Host ""
Write-Host "Selesai. Sukses: $success, Gagal: $failed. Daftar: $OutFile"
if ($failed -gt 0) { exit 2 }
