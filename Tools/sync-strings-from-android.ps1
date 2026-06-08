<#
  Android strings.xml (TEK KAYNAK) → iOS Localizable.strings (en + tr) üretici.

  Neden: Android ile iOS metinleri tek yerden yönetmek için. KANONİK KAYNAK = Android
  `res/values/strings.xml` (+ `values-tr/`). Bu script onları okuyup iOS `.strings`'i ÜRETİR.
  iOS `.strings` dosyaları ELLE düzenlenmez — bu script'in çıktısıdır (regenerate edilir).

  Kullanım (metin değiştirince):
    1. Android strings.xml / values-tr/strings.xml içinde düzenle.
    2. Bu script'i çalıştır:  pwsh src/VerifyBlind.iOS/Tools/sync-strings-from-android.ps1
    3. Üretilen iOS Resources/{en,tr}.lproj/Localizable.strings'i commit et.

  Varsayım: VerifyBlind.iOS ve VerifyBlind.Android aynı `src/` altında yan yana.
  Dönüşümler: \' → ' ; " → \" ; %s → %@ ; %1$s → %1$@ (%d, %d%% aynen kalır).
#>
param(
  [string]$AndroidRes  = (Join-Path $PSScriptRoot "..\..\VerifyBlind.Android\app\src\main\res"),
  [string]$IosResources = (Join-Path $PSScriptRoot "..\Resources")
)

$ErrorActionPreference = "Stop"

function Convert-Value([string]$v) {
  if ($null -eq $v) { return "" }
  $v = $v -replace "\\'", "'"          # Android \' → '
  $v = $v -replace '"', '\"'           # " → \"  (xml InnerText zaten &quot;'u çözer)
  $v = $v -replace '%(\d+)\$s', '%${1}$$@'   # %1$s → %1$@
  $v = $v -replace '%s', '%@'                # %s → %@
  return $v
}

function Write-Strings([string]$xmlPath, [string]$outPath, [string]$lang) {
  if (-not (Test-Path $xmlPath)) { throw "Android strings bulunamadı: $xmlPath" }
  [xml]$xml = Get-Content -Raw -Encoding UTF8 $xmlPath

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("/* VerifyBlind iOS — $lang. OTOMATİK ÜRETİLDİ: Tools/sync-strings-from-android.ps1")
  [void]$sb.AppendLine("   Kaynak: Android $($lang -eq 'TR' ? 'values-tr' : 'values')/strings.xml — ELLE DÜZENLEME. */")
  [void]$sb.AppendLine("")

  $count = 0
  foreach ($s in $xml.resources.string) {
    if ($s.translatable -eq 'false') { continue }
    $name = [string]$s.name
    if ([string]::IsNullOrEmpty($name)) { continue }
    $val = Convert-Value([string]$s.InnerText)
    [void]$sb.AppendLine("`"$name`" = `"$val`";")
    $count++
  }

  $dir = Split-Path -Parent $outPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # BOM'suz UTF-8 (feedback_bat_encoding paritesi)
  [System.IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  Write-Output "✓ ${lang}: $count anahtar → $outPath"
}

Write-Strings (Join-Path $AndroidRes "values\strings.xml")    (Join-Path $IosResources "en.lproj\Localizable.strings") "EN"
Write-Strings (Join-Path $AndroidRes "values-tr\strings.xml") (Join-Path $IosResources "tr.lproj\Localizable.strings") "TR"
Write-Output "Bitti. iOS .strings Android'den üretildi."
