#!/usr/bin/env bats
# Tests for scripts/release.sh. Everything except the last case works offline and
# without a Chocolatey installation; the last one packs with the real choco and is
# skipped when that is missing.

setup() {
    REPO_ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/.." && pwd)"
    source "${REPO_ROOT}/scripts/release.sh"
    CHECKSUM='892c7c073ce8d2942be89ab30529cd2d958762d9a8fdd7ac364092f2a82be501'
}

# The manifest as it appears within a built package, which is not the one kept in
# the repository: packing normalizes the element order, drops the file section and
# moves to a different schema version. The fixtures imitate that shape, because it
# is the only shape validate_nupkg ever sees.
packed_manifest() {
    local version=$1
    cat <<MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>zelph</id>
    <version>${version}</version>
    <title>zelph</title>
    <authors>Stefan Zipproth</authors>
    <owners>acrion</owners>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <licenseUrl>https://github.com/acrion/zelph/blob/main/LICENSE</licenseUrl>
    <projectUrl>https://zelph.org/</projectUrl>
    <description>a semantic network system</description>
    <summary>a semantic network system</summary>
    <releaseNotes>https://github.com/acrion/zelph/releases/tag/v${version}</releaseNotes>
    <copyright>2025-2026 acrion innovations GmbH</copyright>
    <tags>zelph semantic-network</tags>
    <projectSourceUrl>https://github.com/acrion/zelph</projectSourceUrl>
    <packageSourceUrl>https://github.com/acrion/zelph</packageSourceUrl>
    <docsUrl>https://zelph.org/</docsUrl>
    <bugTrackerUrl>https://github.com/acrion/zelph/issues</bugTrackerUrl>
  </metadata>
</package>
MANIFEST
}

packed_install_script() {
    local version=$1 checksum=$2
    cat <<PS1
\$packageName = 'zelph'
\$url         = 'https://github.com/acrion/zelph/releases/download/v${version}/zelph-windows.zip'
\$checksum    = '${checksum}'
PS1
}

# Assembling the fixtures with zip rather than with choco keeps these cases free of
# mono, and it is the only way to obtain the damaged packages the validation exists
# to catch.
build_nupkg() {
    local version=$1 checksum=$2 name=$3
    local dir="${BATS_TEST_TMPDIR}/${name}"
    mkdir -p "${dir}/tools"
    packed_manifest "$version" > "${dir}/zelph.nuspec"
    packed_install_script "$version" "$checksum" > "${dir}/tools/chocolateyinstall.ps1"
    ( cd "$dir" && zip -qr "../${name}.nupkg" . )
    printf '%s\n' "${BATS_TEST_TMPDIR}/${name}.nupkg"
}

build_windows_zip() {
    local name=$1; shift
    local dir="${BATS_TEST_TMPDIR}/${name}"
    mkdir -p "${dir}/stdlib"
    local entry
    for entry in "$@"; do
        mkdir -p "$(dirname "${dir}/${entry}")"
        printf 'x' > "${dir}/${entry}"
    done
    ( cd "$dir" && zip -qr "../${name}.zip" . )
    printf '%s\n' "${BATS_TEST_TMPDIR}/${name}.zip"
}

# --- version_from_tag --------------------------------------------------------

@test "version_from_tag strips the leading v" {
    run version_from_tag v1.0.0
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.0" ]
}

@test "version_from_tag handles two-digit components" {
    run version_from_tag v0.9.10
    [ "$status" -eq 0 ]
    [ "$output" = "0.9.10" ]
}

@test "version_from_tag rejects a tag without the leading v" {
    run version_from_tag 1.0.0
    [ "$status" -ne 0 ]
}

@test "version_from_tag rejects a two-component version" {
    run version_from_tag v1.0
    [ "$status" -ne 0 ]
}

# The community repository has only ever carried stable versions of zelph. A
# prerelease tag passed by mistake would be published as an ordinary release, so it
# is turned down here instead.
@test "version_from_tag rejects a prerelease tag" {
    run version_from_tag v1.0.0-beta1
    [ "$status" -ne 0 ]
}

@test "version_from_tag rejects an empty tag" {
    run version_from_tag ""
    [ "$status" -ne 0 ]
}

# --- rewriting the packaging sources ----------------------------------------

@test "update_nuspec rewrites version and releaseNotes and nothing else" {
    cp "${REPO_ROOT}/zelph.nuspec" "${BATS_TEST_TMPDIR}/zelph.nuspec"
    run update_nuspec "${BATS_TEST_TMPDIR}/zelph.nuspec" 2.3.4
    [ "$status" -eq 0 ]
    [ "$(xml_value "${BATS_TEST_TMPDIR}/zelph.nuspec" version)" = "2.3.4" ]
    [ "$(xml_value "${BATS_TEST_TMPDIR}/zelph.nuspec" releaseNotes)" = "https://github.com/acrion/zelph/releases/tag/v2.3.4" ]

    run diff "${REPO_ROOT}/zelph.nuspec" "${BATS_TEST_TMPDIR}/zelph.nuspec"
    [ "$(grep -c '^<' <<< "$output")" -eq 2 ]
    [ "$(grep -c '^>' <<< "$output")" -eq 2 ]
}

# The nuspec holds a second version, the one of the vcredist140 dependency. It is an
# attribute rather than an element, but a sloppier substitution would still access
# it and silently shift the package to a different runtime.
@test "update_nuspec leaves the dependency version alone" {
    cp "${REPO_ROOT}/zelph.nuspec" "${BATS_TEST_TMPDIR}/zelph.nuspec"
    update_nuspec "${BATS_TEST_TMPDIR}/zelph.nuspec" 2.3.4
    grep -q 'id="vcredist140" version="14.0.0"' "${BATS_TEST_TMPDIR}/zelph.nuspec"
}

@test "update_install_script rewrites url and checksum and nothing else" {
    cp "${REPO_ROOT}/tools/chocolateyinstall.ps1" "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1"
    run update_install_script "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1" 2.3.4 deadbeef
    [ "$status" -eq 0 ]
    [ "$(ps1_value "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1" url)" = "https://github.com/acrion/zelph/releases/download/v2.3.4/zelph-windows.zip" ]
    [ "$(ps1_value "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1" checksum)" = "deadbeef" ]

    run diff "${REPO_ROOT}/tools/chocolateyinstall.ps1" "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1"
    [ "$(grep -c '^<' <<< "$output")" -eq 2 ]
    [ "$(grep -c '^>' <<< "$output")" -eq 2 ]
}

# The assignments in the install script are manually aligned. Maintaining that
# alignment is not cosmetic here: it holds the diff of a release to the two values
# that really changed.
@test "update_install_script keeps the assignment alignment" {
    cp "${REPO_ROOT}/tools/chocolateyinstall.ps1" "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1"
    update_install_script "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1" 2.3.4 deadbeef
    grep -q "^\$url         = '" "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1"
    grep -q "^\$checksum    = '" "${BATS_TEST_TMPDIR}/chocolateyinstall.ps1"
}

# --- validate_nupkg ----------------------------------------------------------

@test "validate_nupkg accepts a well formed package" {
    local nupkg; nupkg=$(build_nupkg 1.0.0 "$CHECKSUM" good)
    run validate_nupkg "$nupkg" 1.0.0 "$CHECKSUM"
    [ "$status" -eq 0 ]
}

# This is what nuget pack and dotnet pack produce from the very same nuspec: a
# package that installs correctly and still ends up on the community repository
# without its source, documentation and issue links. That is the failure this
# validation exists for, so the damage is reproduced here on purpose.
@test "validate_nupkg rejects a manifest that lost the Chocolatey specific urls" {
    local nupkg; nupkg=$(build_nupkg 1.0.0 "$CHECKSUM" stripped)
    local dir="${BATS_TEST_TMPDIR}/stripped"
    sed -i -e '/packageSourceUrl/d' -e '/projectSourceUrl/d' \
           -e '/docsUrl/d' -e '/bugTrackerUrl/d' "${dir}/zelph.nuspec"
    rm -f "$nupkg"
    ( cd "$dir" && zip -qr "$nupkg" . )

    run validate_nupkg "$nupkg" 1.0.0 "$CHECKSUM"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packageSourceUrl"* ]]
    [[ "$output" == *"docsUrl"* ]]
}

@test "validate_nupkg rejects a version that does not match the release" {
    local nupkg; nupkg=$(build_nupkg 1.0.0 "$CHECKSUM" wrongversion)
    run validate_nupkg "$nupkg" 1.0.1 "$CHECKSUM"
    [ "$status" -ne 0 ]
    [[ "$output" == *"declares version 1.0.0"* ]]
}

# A checksum inherited from the previous release is the likeliest defect of all. The
# package then downloads the new archive and turns it down on every machine that
# installs it.
@test "validate_nupkg rejects an install script carrying a stale checksum" {
    local nupkg; nupkg=$(build_nupkg 1.0.0 0000000000000000000000000000000000000000000000000000000000000000 stalesum)
    run validate_nupkg "$nupkg" 1.0.0 "$CHECKSUM"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wrong checksum"* ]]
}

@test "validate_nupkg rejects a package without an install script" {
    local nupkg; nupkg=$(build_nupkg 1.0.0 "$CHECKSUM" noscript)
    local dir="${BATS_TEST_TMPDIR}/noscript"
    rm -rf "${dir}/tools"
    rm -f "$nupkg"
    ( cd "$dir" && zip -qr "$nupkg" . )

    run validate_nupkg "$nupkg" 1.0.0 "$CHECKSUM"
    [ "$status" -ne 0 ]
    [[ "$output" == *"chocolateyinstall.ps1"* ]]
}

# Only the file section of the nuspec can let such a file in, and it names
# tools alone today. The case guards the widening of that section, not the state
# the repository is in.
@test "validate_nupkg rejects a package that carries source control files" {
    local nupkg; nupkg=$(build_nupkg 1.0.0 "$CHECKSUM" polluted)
    local dir="${BATS_TEST_TMPDIR}/polluted"
    printf '*.nupkg\n' > "${dir}/.gitignore"
    rm -f "$nupkg"
    ( cd "$dir" && zip -qr "$nupkg" . )

    run validate_nupkg "$nupkg" 1.0.0 "$CHECKSUM"
    [ "$status" -ne 0 ]
    [[ "$output" == *"source control"* ]]
}

@test "validate_nupkg rejects a file that is not a zip archive" {
    printf 'not a package\n' > "${BATS_TEST_TMPDIR}/broken.nupkg"
    run validate_nupkg "${BATS_TEST_TMPDIR}/broken.nupkg" 1.0.0 "$CHECKSUM"
    [ "$status" -ne 0 ]
}

# --- verify_windows_zip ------------------------------------------------------

@test "verify_windows_zip accepts a release archive" {
    local zip; zip=$(build_windows_zip complete zelph.exe zelph_tests.exe zelph.dll stdlib/math.zph)
    run verify_windows_zip "$zip"
    [ "$status" -eq 0 ]
}

# Without zelph_tests.exe the install script stumbles over a missing file instead of
# running the tests, and the package then fails for a reason that says nothing about
# the cause.
@test "verify_windows_zip rejects an archive without the test executable" {
    local zip; zip=$(build_windows_zip untested zelph.exe zelph.dll stdlib/math.zph)
    run verify_windows_zip "$zip"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zelph_tests.exe"* ]]
}

@test "verify_windows_zip rejects an archive without the standard library" {
    local zip; zip=$(build_windows_zip bare zelph.exe zelph_tests.exe zelph.dll)
    run verify_windows_zip "$zip"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stdlib"* ]]
}

# --- read_api_key ------------------------------------------------------------

@test "read_api_key returns the key of a well protected file" {
    printf '11111111-2222-3333-4444-555555555555' > "${BATS_TEST_TMPDIR}/key"
    chmod 600 "${BATS_TEST_TMPDIR}/key"
    run read_api_key "${BATS_TEST_TMPDIR}/key"
    [ "$status" -eq 0 ]
    [ "$output" = "11111111-2222-3333-4444-555555555555" ]
}

# Most editors add one when the file is saved, so a key written by hand and a key
# written by an editor have to be treated alike.
@test "read_api_key tolerates a trailing newline" {
    printf '11111111-2222-3333-4444-555555555555\n' > "${BATS_TEST_TMPDIR}/key"
    chmod 600 "${BATS_TEST_TMPDIR}/key"
    run read_api_key "${BATS_TEST_TMPDIR}/key"
    [ "$status" -eq 0 ]
    [ "$output" = "11111111-2222-3333-4444-555555555555" ]
}

@test "read_api_key rejects a missing file" {
    run read_api_key "${BATS_TEST_TMPDIR}/absent"
    [ "$status" -ne 0 ]
}

# The key travels: it is usually pasted into a file somewhere else first, and a
# copy keeps whatever mode it had. The mode is checked rather than assumed.
@test "read_api_key rejects a file that others may read" {
    printf '11111111-2222-3333-4444-555555555555' > "${BATS_TEST_TMPDIR}/key"
    chmod 644 "${BATS_TEST_TMPDIR}/key"
    run read_api_key "${BATS_TEST_TMPDIR}/key"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected 600"* ]]
}

@test "read_api_key rejects an empty file" {
    : > "${BATS_TEST_TMPDIR}/key"
    chmod 600 "${BATS_TEST_TMPDIR}/key"
    run read_api_key "${BATS_TEST_TMPDIR}/key"
    [ "$status" -ne 0 ]
}

# The file holds the bare key and nothing else. Anything resembling a
# configuration line is turned down, because the whole line would otherwise be
# sent as the key.
@test "read_api_key rejects a file holding more than the key" {
    printf 'apikey = 11111111-2222-3333-4444-555555555555\n' > "${BATS_TEST_TMPDIR}/key"
    chmod 600 "${BATS_TEST_TMPDIR}/key"
    run read_api_key "${BATS_TEST_TMPDIR}/key"
    [ "$status" -ne 0 ]
}

@test "read_api_key rejects a key that is too short to be one" {
    printf 'secret' > "${BATS_TEST_TMPDIR}/key"
    chmod 600 "${BATS_TEST_TMPDIR}/key"
    run read_api_key "${BATS_TEST_TMPDIR}/key"
    [ "$status" -ne 0 ]
}

# --- the real thing ----------------------------------------------------------

# The cases above work on fixtures. This one packs with the real choco and hands the
# result to the same validation, which is what ties the fixtures to what the tool
# actually produces.
@test "choco pack produces a package that passes validation" {
    local choco_home="${CHOCOLATEY_HOME:-$HOME/.local/lib/chocolatey}"
    [ -f "${choco_home}/choco.exe" ] || skip "no Chocolatey installation in ${choco_home}"
    command -v mono >/dev/null || skip "mono is not installed"

    cp "${REPO_ROOT}/zelph.nuspec" "${BATS_TEST_TMPDIR}/zelph.nuspec"
    mkdir -p "${BATS_TEST_TMPDIR}/tools"
    cp "${REPO_ROOT}/tools/chocolateyinstall.ps1" "${BATS_TEST_TMPDIR}/tools/"
    update_nuspec "${BATS_TEST_TMPDIR}/zelph.nuspec" 2.3.4
    update_install_script "${BATS_TEST_TMPDIR}/tools/chocolateyinstall.ps1" 2.3.4 "$CHECKSUM"

    ChocolateyInstall="$choco_home" run mono "${choco_home}/choco.exe" pack \
        "${BATS_TEST_TMPDIR}/zelph.nuspec" --output-directory="${BATS_TEST_TMPDIR}"
    [ "$status" -eq 0 ]

    run validate_nupkg "${BATS_TEST_TMPDIR}/zelph.2.3.4.nupkg" 2.3.4 "$CHECKSUM"
    [ "$status" -eq 0 ]
}
