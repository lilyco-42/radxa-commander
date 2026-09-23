# Local dev build (Windows, no Android Studio).
# Needs: JDK 17 + Android SDK (ANDROID_HOME or ANDROID_SDK_ROOT).
# Output: build/commander-dev.apk (signed with throwaway dev key, DO NOT ship).
$ErrorActionPreference = 'Continue'
$ErrorView = 'NormalView'
$root = $PSScriptRoot
$sdk = $env:ANDROID_SDK_ROOT
if (-not $sdk) { $sdk = $env:ANDROID_HOME }
if (-not $sdk) { throw 'Set ANDROID_HOME first' }
$bt = Join-Path $sdk 'build-tools\36.1.0'
$plat = Join-Path $sdk 'platforms\android-36.1\android.jar'
if (-not (Test-Path $plat)) { throw "Missing $plat" }
$out = Join-Path $root 'build'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$man = Join-Path $root 'AndroidManifest.xml'
$src = Join-Path $root 'src'
$unsigned = Join-Path $out 'commander-unsigned.apk'
$aligned = Join-Path $out 'commander-dev.apk'
$keystore = Join-Path $out 'dev.keystore'

& "$bt\aapt2.exe" link -o $unsigned -I $plat --manifest $man `
  --version-code 1 --version-name '0.1.0' --min-sdk-version 24 --target-sdk-version 36
$classes = Join-Path $out 'classes'
Remove-Item -Recurse -Force $classes -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $classes | Out-Null
$files = Get-ChildItem -Recurse -Path $src -Filter '*.java' | Select-Object -ExpandProperty FullName
$javacLog = Join-Path $out 'javac.log'
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& javac -encoding UTF-8 -Xlint:-deprecation -cp $plat -d $classes $files 2>$javacLog
$javacCode = $LASTEXITCODE
$ErrorActionPreference = $oldEAP
if ($javacCode -ne 0) { Get-Content $javacLog | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }; throw "javac failed ($javacCode)" }
$dexs = Get-ChildItem -Recurse -Path $classes -Filter '*.class' | Select-Object -ExpandProperty FullName
if (-not $dexs -or $dexs.Count -eq 0) { throw 'no classes compiled' }
$dexDir = Join-Path $out 'dex'
New-Item -ItemType Directory -Force -Path $dexDir | Out-Null
& "$bt\d8.bat" --lib $plat --min-api 24 --output $dexDir $dexs
if ($LASTEXITCODE -ne 0) { throw "d8 failed ($LASTEXITCODE)" }
Copy-Item (Join-Path $out 'dex\classes.dex') (Join-Path $out 'classes.dex')
python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'a',zipfile.ZIP_DEFLATED); z.write(sys.argv[2],'classes.dex'); z.close()" $unsigned (Join-Path $out 'classes.dex')
if (-not (Test-Path $keystore)) {
  & keytool -genkeypair -keystore $keystore -alias dev -keyalg RSA -keysize 2048 -validity 3650 `
    -storepass devdev123 -keypass devdev123 -dname 'CN=dev' | Out-Null
}
& "$bt\zipalign.exe" -f 4 $unsigned $aligned | Out-Null
if ($LASTEXITCODE -ne 0) { throw "zipalign failed ($LASTEXITCODE)" }
& "$bt\apksigner.bat" sign --ks $keystore --ks-pass pass:devdev123 --key-pass pass:devdev123 --out $aligned $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner failed ($LASTEXITCODE)" }
& "$bt\apksigner.bat" verify --print-certs $aligned | Select-String 'Signer #1'
Write-Host "APK_OK $aligned"
