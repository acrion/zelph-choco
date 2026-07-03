$packageName = 'zelph'
$toolsDir    = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$url         = 'https://github.com/acrion/zelph/releases/download/v0.9.6/zelph-windows.zip'
$checksum    = 'a50bc015bedd44f5aba8eafa24a4e0dea1d4129007d4a81d6e7bdd10ae56de95'

Install-ChocolateyZipPackage `
  -PackageName $packageName `
  -Url $url `
  -UnzipLocation $toolsDir `
  -Checksum $checksum `
  -ChecksumType 'sha256' `
  -Url64bit $url `
  -Checksum64 $checksum `
  -ChecksumType64 'sha256'

<#
$testsExe = Join-Path $toolsDir 'zelph_tests.exe'
& $testsExe
if ($LASTEXITCODE -ne 0) {
    throw "zelph_tests failed with exit code $LASTEXITCODE"
}
#>
