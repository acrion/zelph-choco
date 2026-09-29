#!/usr/bin/env bats
# Tests for scripts/release.sh. Everything except the last case works offline and
# without a Chocolatey installation; the last one packs with the real choco and is
# skipped when that is missing.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/.." && pwd)"
    source "${REPO_ROOT}/scripts/release.sh"
    CHECKSUM='892c7c073ce8d2942be89ab30529cd2d958762d9a8fdd7ac364092f2a82be501'
    FIXTURES="${REPO_ROOT}/tests/fixtures/feed"
    FEED_DIR="${BATS_TEST_TMPDIR}/feed"
    mkdir -p "$FEED_DIR"
}

# The community feed, as seen through the script via curl. A version answers
# with its entry from FEED_DIR, or with the status code found in
# VERSION.code, and otherwise with the 404 that the real feed gives for a
# rejected version. Only a request structured exactly like the one
# feed_status issues receives a reply, so any modification to that request
# becomes visible here.
curl() {
    local url=${!#} version
    [[ " $* " == *" -w "* && " $* " != *" -f"* && " $* " != *" -o "* && $url == *"Id='zelph'"* ]] || {
        printf 'the stub feed does not answer this call: curl %s\n' "$*" >&2
        return 2
    }
    version=${url##*Version=\'}
    version=${version%%\'*}
    if [[ -f ${FEED_DIR}/${version}.code ]]; then
        printf 'unavailable\n%s' "$(< "${FEED_DIR}/${version}.code")"
    elif [[ -f ${FEED_DIR}/${version}.xml ]]; then
        cat "${FEED_DIR}/${version}.xml"
        printf '\n200'
    else
        cat "${FIXTURES}/rejected.xml"
        printf '\n404'
    fi
}

# Put VERSION on the stub feed, setting its moderation state as specified. The
# entry is the real one of zelph 1.0.1.1 when the version is approved or
# exempted, and of zelph 1.0.1 in all other cases, with its status properties
# replaced, thereby guaranteeing that the entry's shape aligns with the actual
# output delivered by the feed.
on_feed() {
    local version=$1 status=$2 substatus=${3:-Waiting} validation=${4:-Passing} verification=${5:-Passing}
    local entry="${FIXTURES}/zelph-1.0.1.xml"
    [[ $status == Approved || $status == Exempted ]] && entry="${FIXTURES}/zelph-1.0.1.1.xml"
    sed -e "s|<d:Version>[^<]*<|<d:Version>${version}<|" \
        -e "s|<d:PackageStatus>[^<]*<|<d:PackageStatus>${status}<|" \
        -e "s|<d:PackageSubmittedStatus>[^<]*<|<d:PackageSubmittedStatus>${substatus}<|" \
        -e "s|<d:PackageValidationResultStatus>[^<]*<|<d:PackageValidationResultStatus>${validation}<|" \
        -e "s|<d:PackageTestResultStatus>[^<]*<|<d:PackageTestResultStatus>${verification}<|" \
        "$entry" > "${FEED_DIR}/${version}.xml"
}

# A repository whose manifest held the given versions, one commit per version, in
# order.
repository_with_history() {
    local repo="${BATS_TEST_TMPDIR}/repo" version
    git init -q "$repo"
    cp "${REPO_ROOT}/zelph.nuspec" "${repo}/zelph.nuspec"
    for version in "$@"; do
        update_nuspec "${repo}/zelph.nuspec" "$version"
        git -C "$repo" add zelph.nuspec
        git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm "v${version}"
    done
    printf '%s\n' "$repo"
}

# The manifest as it appears within a built package, which is not the one kept in
# the repository: packing normalizes the element order, drops the file section and
# moves to a different schema version. The fixtures imitate that shape, because it
# is the only shape validate_nupkg ever sees.
packed_manifest() {
    local version=$1 release_version=${2:-$1}
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
    <releaseNotes>https://github.com/acrion/zelph/releases/tag/v${release_version}</releaseNotes>
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
    local version=$1 checksum=$2 name=$3 release_version=${4:-$1}
    local dir="${BATS_TEST_TMPDIR}/${name}"
    mkdir -p "${dir}/tools"
    packed_manifest "$version" "$release_version" > "${dir}/zelph.nuspec"
    packed_install_script "$release_version" "$checksum" > "${dir}/tools/chocolateyinstall.ps1"
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

# --- the community feed ------------------------------------------------------

@test "feed_status reads the real entry of a version in moderation" {
    cp "${FIXTURES}/zelph-1.0.1.xml" "${FEED_DIR}/1.0.1.xml"
    run feed_status 1.0.1
    [ "$status" -eq 0 ]
    [ "$output" = "Submitted Waiting Passing Failing" ]
}

@test "feed_status reads the real entry of an approved version" {
    cp "${FIXTURES}/zelph-1.0.1.1.xml" "${FEED_DIR}/1.0.1.1.xml"
    run feed_status 1.0.1.1
    [ "$status" -eq 0 ]
    [[ "$output" == "Approved "* ]]
}

# The feed gives the identical 404 error for a rejected version as it does for
# a version that was never pushed; the fixture serves as its response
# specifically for a rejected version.
@test "feed_status reports a version the feed does not answer for as absent" {
    run feed_status 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "Absent - - -" ]
}

@test "feed_status does not guess when the feed answers with anything else" {
    printf '503' > "${FEED_DIR}/2.3.4.code"
    run feed_status 2.3.4
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 503"* ]]
}

@test "assert_pushable lets a version through that the feed has never seen" {
    run assert_pushable 2.3.4
    [ "$status" -eq 0 ]
}

# After failing verification on 7 Sep 2026, 1.0.1 required the following. The
# check subsequently interpreted the feed's HTTP 200 as an approved version
# and turned the push down, causing the fix to be released as 1.0.1.1 instead,
# while 1.0.1 remained in moderation, displaying a warning on every page of
# the package until it was ultimately rejected.
@test "assert_pushable lets a version in moderation be pushed again under its own number" {
    on_feed 2.3.4 Submitted Waiting Passing Failing
    run assert_pushable 2.3.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"replaces that submission"* ]]
}

@test "assert_pushable turns an approved version down and points at a package fix" {
    on_feed 2.3.4 Approved
    run assert_pushable 2.3.4
    [ "$status" -ne 0 ]
    [[ "$output" == *"--package-fix"* ]]
}

@test "assert_pushable turns an approved fix version down without suggesting another fix on top" {
    on_feed 2.3.4.20261015 Approved
    run assert_pushable 2.3.4.20261015
    [ "$status" -ne 0 ]
    [[ "$output" != *"--package-fix"* ]]
}

@test "assert_pushable turns an exempted version down like an approved one" {
    on_feed 2.3.4 Exempted
    run assert_pushable 2.3.4
    [ "$status" -ne 0 ]
}

# As of 10 Sep 2026, the status of 1.0.1: users receive 1.0.1.1, while 1.0.1
# sorts beneath it, meaning that pushing 1.0.1 again would correct a version
# that nobody installs.
@test "assert_pushable turns down a release in moderation that an approved fix of it sorts above" {
    on_feed 2.3.4 Submitted Waiting Passing Failing
    on_feed 2.3.4.1 Approved
    run assert_pushable 2.3.4 2.3.4.1 2.3.4
    [ "$status" -ne 0 ]
    [[ "$output" == *"2.3.4.1 is approved and sorts above 2.3.4"* ]]
    [[ "$output" == *"--package-fix"* ]]
    [[ "$output" == *"https://community.chocolatey.org/packages/zelph/2.3.4"* ]]
}

# The state of 1.0.1 once it is rejected. The feed responds with 404 for it,
# just as it does for a version that was never pushed, and without the approved
# fix to go by, the push would only encounter failure at Chocolatey.
@test "assert_pushable turns down a rejected release that an approved fix of it sorts above" {
    on_feed 2.3.4.1 Approved
    run assert_pushable 2.3.4 2.3.4.1 2.3.4
    [ "$status" -ne 0 ]
    [[ "$output" == *"--package-fix"* ]]
}

@test "assert_pushable is not held back by an approved version of another release" {
    on_feed 2.3.3 Approved
    on_feed 2.3.5 Approved
    run assert_pushable 2.3.4 2.3.5 2.3.3
    [ "$status" -eq 0 ]
}

@test "packed_versions lists every version the manifest has held, newest first" {
    local repo; repo=$(repository_with_history 0.9.2 0.9.9 0.9.10 1.0.0 1.0.1 1.0.1.1 1.0.1.20261015)
    run packed_versions "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' 1.0.1.20261015 1.0.1.1 1.0.1 1.0.0 0.9.10 0.9.9 0.9.2)" ]
}

# After the push, the script asks for the version bump to be committed, meaning
# the pushed version temporarily resides solely in the working tree.
@test "packed_versions includes a version pushed but not yet committed" {
    local repo; repo=$(repository_with_history 1.0.0)
    update_nuspec "${repo}/zelph.nuspec" 1.0.1
    run packed_versions "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' 1.0.1 1.0.0)" ]
}

# In version 0.9.5, a second commit introduced a previously absent
# dependency while keeping the version unchanged.
@test "packed_versions names a version once however many commits it spans" {
    local repo; repo=$(repository_with_history 0.9.5)
    sed -i 's|<tags>|<tags>extra |' "${repo}/zelph.nuspec"
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qam "added missing dependency"
    [ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]
    run packed_versions "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = "0.9.5" ]
}

@test "report_moderation_queue names a version left in moderation and where to reject it" {
    on_feed 1.0.1 Submitted Waiting Passing Failing
    on_feed 1.0.0 Approved
    run report_moderation_queue 1.0.2 1.0.2 1.0.1 1.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"zelph 1.0.1 is still in moderation"* ]]
    [[ "$output" == *"https://community.chocolatey.org/packages/zelph/1.0.1 (Reject Package?)"* ]]
    [[ "$output" != *"1.0.0"* ]]
}

# Chocolatey lets a maintainer reject a version solely if it has failed an
# automated check. Age alone is not a reason it accepts for rejection, thus a
# version that has not failed any check is named without such a recommendation.
@test "report_moderation_queue does not advise rejecting a version that failed no check" {
    on_feed 1.0.1 Submitted Ready Passing Passing
    run report_moderation_queue 1.0.2 1.0.2 1.0.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"zelph 1.0.1 is still in moderation"* ]]
    [[ "$output" != *"Reject"* ]]
}

@test "report_moderation_queue is silent about the version being pushed" {
    on_feed 1.0.1 Submitted Waiting Passing Failing
    run report_moderation_queue 1.0.1 1.0.1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "report_moderation_queue also points at rejection for a version that failed validation only" {
    on_feed 1.0.1 Submitted Waiting Failing Passing
    run report_moderation_queue 1.0.2 1.0.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"(Reject Package?)"* ]]
}

# The history of the manifest continues to include 1.0.0 and 1.0.1
# even after they are rejected, and thereafter the feed answers with
# 404 for each of them.
@test "report_moderation_queue is silent about a rejected version" {
    run report_moderation_queue 1.0.2 1.0.1 1.0.0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# There is no way to publish the newest release if it is rejected: a rejected
# number is never reused, and there is no approved version of it to fix.
@test "report_moderation_queue does not advise rejecting a failed version newer than the one being pushed" {
    on_feed 1.0.3 Submitted Waiting Passing Failing
    run report_moderation_queue 1.0.2.20261015 1.0.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"zelph 1.0.3 is still in moderation"* ]]
    [[ "$output" == *"pushing it again under its own number"* ]]
    [[ "$output" != *"Reject"* ]]
}

# When the status is Waiting and both checks are passing, it indicates that a
# moderator has requested modifications. The version remains in a state of
# waiting until the maintainer responds or pushes it once more; if not, the
# cleaner will reject it.
@test "report_moderation_queue says that a version a moderator asked to change waits for an answer" {
    on_feed 1.0.1 Submitted Waiting Passing Passing
    run report_moderation_queue 1.0.2 1.0.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"a moderator asked for changes"* ]]
}

@test "report_moderation_queue stops when the feed cannot tell where a version stands" {
    printf '503' > "${FEED_DIR}/1.0.1.code"
    run report_moderation_queue 1.0.2 1.0.1
    [ "$status" -ne 0 ]
}

@test "describe_feed_version gives the page of a version in moderation" {
    on_feed 1.0.1 Submitted Waiting Passing Failing
    run describe_feed_version 1.0.1
    [ "$status" -eq 0 ]
    [ "$output" = "zelph 1.0.1: in moderation (Waiting), validation Passing, verification Failing, https://community.chocolatey.org/packages/zelph/1.0.1" ]
}

@test "describe_feed_version names the status of an approved version" {
    on_feed 1.0.1.1 Approved
    run describe_feed_version 1.0.1.1
    [ "$status" -eq 0 ]
    [ "$output" = "zelph 1.0.1.1: Approved" ]
}

@test "describe_feed_version says a version the feed does not answer for may have been rejected" {
    run describe_feed_version 1.0.0
    [ "$status" -eq 0 ]
    [ "$output" = "zelph 1.0.0: not on the community feed (never pushed, or rejected)" ]
}

@test "plan_push checks the version it settled on rather than the release" {
    on_feed 2.3.4 Approved
    run --separate-stderr plan_push 2.3.4 1 20261015 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4.20261015" ]
}

# The live state of 1.0.1: solely the list of packed versions shows the
# approved fix upon which a further fix depends.
@test "plan_push hands the packed versions to a package fix" {
    on_feed 2.3.4 Submitted Waiting Passing Failing
    on_feed 2.3.4.1 Approved
    run --separate-stderr plan_push 2.3.4 1 20261015 2.3.4.1 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4.20261015" ]
}

@test "plan_push reports the versions left in moderation" {
    on_feed 1.0.0 Submitted Waiting Passing Failing
    run --separate-stderr plan_push 1.0.2 0 20261015 1.0.2 1.0.0
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.2" ]
    [[ "$stderr" == *"zelph 1.0.0 is still in moderation"* ]]
}

# The option solely performs reading. Beyond its table lies the route involving
# builds and pushes, and a Chocolatey installation that is not located
# immediately halts this route, so reaching it causes this case to fail.
@test "--status describes every packed version and goes no further" {
    git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
    local expected; expected=$(packed_versions "$REPO_ROOT" | wc -l)
    CHOCOLATEY_HOME="${BATS_TEST_TMPDIR}/no-chocolatey" run main --status
    [ "$status" -eq 0 ]
    [ "$(wc -l <<< "$output")" -eq "$expected" ]
    [ "$(grep -vc '^zelph ' <<< "$output")" -eq 0 ]
}

@test "commit_hint asks for the version bump to be committed" {
    local repo; repo=$(repository_with_history 1.0.0)
    update_nuspec "${repo}/zelph.nuspec" 1.0.1
    run commit_hint "$repo" 1.0.1
    [[ "$output" == *"commit -am 'v1.0.1'"* ]]
}

# Pushing a version in moderation once more under its own number writes back the
# content that both files already hold.
@test "commit_hint says there is nothing to commit after a push that changed nothing" {
    local repo; repo=$(repository_with_history 1.0.1)
    update_nuspec "${repo}/zelph.nuspec" 1.0.1
    run commit_hint "$repo" 1.0.1
    [[ "$output" == *"nothing to commit"* ]]
}

# --- package fix versions ----------------------------------------------------

@test "package_fix_version dates a fix of an approved release" {
    on_feed 2.3.4 Approved
    run package_fix_version 2.3.4 20261015 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4.20261015" ]
}

# A fix that failed verification yesterday is corrected under its original
# number. Reassigning it a new date would result in yesterday's version
# remaining in moderation, which the date form must not turn into a routine
# practice.
@test "package_fix_version pushes a fix in moderation again instead of dating a new one" {
    on_feed 2.3.4 Approved
    on_feed 2.3.4.20261014 Submitted Waiting Passing Failing
    run package_fix_version 2.3.4 20261015 2.3.4.20261014 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4.20261014" ]
}

# The case of 1.0.1: a release that failed in moderation is not fixed through
# the addition of a fourth component; instead, it is pushed again as itself.
@test "package_fix_version turns down a release that is still in moderation" {
    on_feed 2.3.4 Submitted Waiting Passing Failing
    run package_fix_version 2.3.4 20261015 2.3.4
    [ "$status" -ne 0 ]
    [[ "$output" == *"without --package-fix"* ]]
}

@test "package_fix_version turns down a release with no approved version" {
    run package_fix_version 2.3.4 20261015
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to fix"* ]]
}

# As of 10 Sep 2026, version 1.0.1 remains in moderation; however, its fix
# 1.0.1.1 has been approved. Users are installing the fix, which therefore
# becomes the foundation upon which any subsequent fix is built.
@test "package_fix_version builds on an approved fix while the release still waits" {
    on_feed 2.3.4 Submitted Waiting Passing Failing
    on_feed 2.3.4.1 Approved
    run package_fix_version 2.3.4 20261015 2.3.4.1 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4.20261015" ]
}

# Once 1.0.1 is rejected, the feed ceases to provide answers regarding the
# release, while the approved fix continues to carry its binaries.
@test "package_fix_version builds on an approved fix of a rejected release" {
    on_feed 2.3.4.1 Approved
    run package_fix_version 2.3.4 20261015 2.3.4.1 2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4.20261015" ]
}

@test "package_fix_version does not take a fix of another release for one of its own" {
    on_feed 2.3.45.20261001 Approved
    run package_fix_version 2.3.4 20261015 2.3.45.20261001
    [ "$status" -ne 0 ]
}

@test "package_fix_version does not read the dots of a release as any character" {
    on_feed 2.304.20261001 Approved
    run package_fix_version 2.3.4 20261015 2.304.20261001
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to fix"* ]]
}

# A fix in moderation is not a fix users receive, thus it does not make the
# release fixable.
@test "package_fix_version turns down a release whose only fix is still in moderation" {
    on_feed 2.3.4.20261014 Submitted Waiting Passing Failing
    run package_fix_version 2.3.4 20261015 2.3.4.20261014
    [ "$status" -ne 0 ]
}

@test "package_fix_version stops when the feed cannot tell where a fix stands" {
    on_feed 2.3.4 Approved
    printf '503' > "${FEED_DIR}/2.3.4.20261014.code"
    run package_fix_version 2.3.4 20261015 2.3.4.20261014 2.3.4
    [ "$status" -ne 0 ]
}

# Each day, the date form assigns a single number, and once a number is
# approved, it becomes final.
@test "package_fix_version turns down a second fix on a day whose fix is approved already" {
    on_feed 2.3.4 Approved
    on_feed 2.3.4.20261015 Approved
    run package_fix_version 2.3.4 20261015 2.3.4.20261015 2.3.4
    [ "$status" -ne 0 ]
    [[ "$output" == *"tomorrow"* ]]
}

@test "update_nuspec keeps the release notes on the release version" {
    cp "${REPO_ROOT}/zelph.nuspec" "${BATS_TEST_TMPDIR}/zelph.nuspec"
    run update_nuspec "${BATS_TEST_TMPDIR}/zelph.nuspec" 2.3.4.5 2.3.4
    [ "$status" -eq 0 ]
    [ "$(xml_value "${BATS_TEST_TMPDIR}/zelph.nuspec" version)" = "2.3.4.5" ]
    [ "$(xml_value "${BATS_TEST_TMPDIR}/zelph.nuspec" releaseNotes)" = "https://github.com/acrion/zelph/releases/tag/v2.3.4" ]
}

# The manifest and the install script part company for a package fix: the
# manifest says 1.0.1.1, and everything that names the binaries stays on 1.0.1.
# Both halves are held here, because getting either one wrong yields a package
# that installs the wrong archive or sends its readers to a release that does
# not exist.
@test "validate_nupkg accepts a package fix version" {
    local nupkg; nupkg=$(build_nupkg 1.0.1.1 "$CHECKSUM" fix 1.0.1)
    run validate_nupkg "$nupkg" 1.0.1.1 "$CHECKSUM" 1.0.1
    [ "$status" -eq 0 ]
}

@test "validate_nupkg rejects a package fix whose release notes followed the package version" {
    local nupkg; nupkg=$(build_nupkg 1.0.1.1 "$CHECKSUM" fixnotes)
    run validate_nupkg "$nupkg" 1.0.1.1 "$CHECKSUM" 1.0.1
    [ "$status" -ne 0 ]
}

@test "validate_nupkg rejects a package fix whose install script followed the package version" {
    local dir="${BATS_TEST_TMPDIR}/fixurl"
    mkdir -p "${dir}/tools"
    packed_manifest 1.0.1.1 1.0.1 > "${dir}/zelph.nuspec"
    packed_install_script 1.0.1.1 "$CHECKSUM" > "${dir}/tools/chocolateyinstall.ps1"
    ( cd "$dir" && zip -qr "../fixurl.nupkg" . )
    run validate_nupkg "${BATS_TEST_TMPDIR}/fixurl.nupkg" 1.0.1.1 "$CHECKSUM" 1.0.1
    [ "$status" -ne 0 ]
}

# --- the install script ------------------------------------------------------

# Read the statements out of the `$statements = @( ... )` block of the install
# script, one per line, with the surrounding single quotes removed.
install_check_statements() {
    sed -n "/^\\\$statements = @($/,/^)$/p" "${REPO_ROOT}/tools/chocolateyinstall.ps1" \
        | sed -n "s|^[[:space:]]*'\\(.*\\)'$|\\1|p"
}

# The package ran the fast test tier at install time until 1.0.1, and the
# Chocolatey verifier killed the install when its execution timeout expired.
# Nothing about that is visible in a reading of the script -- it looks like a
# thorough install -- so the rule is held here instead.
@test "the install script does not run the test suite" {
    run grep -n 'zelph_tests' "${REPO_ROOT}/tools/chocolateyinstall.ps1"
    [ "$status" -ne 0 ]
}

@test "the install script checks that zelph derives something" {
    grep -q "Join-Path \$toolsDir 'zelph.exe'" "${REPO_ROOT}/tools/chocolateyinstall.ps1"
    [ "$(install_check_statements | wc -l)" -eq 3 ]
    [ -n "$(ps1_value "${REPO_ROOT}/tools/chocolateyinstall.ps1" derived)" ]
}

# The install script waits for one line of zelph output, and on the day that
# line is worded differently every Windows install fails. Neither repository
# can see the other, so the two are tied together here: the statements are read
# out of the script and put to a real zelph, and the answer has to carry what
# the script waits for.
@test "zelph really derives what the install script waits for" {
    local zelph="${ZELPH_BIN:-$(command -v zelph || true)}"
    [ -n "$zelph" ] && [ -x "$zelph" ] || skip "no zelph binary (set ZELPH_BIN)"

    local derived
    derived=$(ps1_value "${REPO_ROOT}/tools/chocolateyinstall.ps1" derived)

    run env ZELPH_NO_RLWRAP=1 "$zelph" < <(install_check_statements)
    [ "$status" -eq 0 ]
    [[ "$output" == *"$derived"* ]]
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

# A four-part version is where the packer is most likely to disagree with the
# script: it decides the file name, and it rewrites the manifest. This packs one
# with the real tool and hands the result to the same validation. The fourth
# component is a date, as produced by --package-fix.
@test "choco pack produces a package fix version that passes validation" {
    local choco_home="${CHOCOLATEY_HOME:-$HOME/.local/lib/chocolatey}"
    [ -f "${choco_home}/choco.exe" ] || skip "no Chocolatey installation in ${choco_home}"
    command -v mono >/dev/null || skip "mono is not installed"

    cp "${REPO_ROOT}/zelph.nuspec" "${BATS_TEST_TMPDIR}/zelph.nuspec"
    mkdir -p "${BATS_TEST_TMPDIR}/tools"
    cp "${REPO_ROOT}/tools/chocolateyinstall.ps1" "${BATS_TEST_TMPDIR}/tools/"
    update_nuspec "${BATS_TEST_TMPDIR}/zelph.nuspec" 2.3.4.20261015 2.3.4
    update_install_script "${BATS_TEST_TMPDIR}/tools/chocolateyinstall.ps1" 2.3.4 "$CHECKSUM"

    ChocolateyInstall="$choco_home" run mono "${choco_home}/choco.exe" pack \
        "${BATS_TEST_TMPDIR}/zelph.nuspec" --output-directory="${BATS_TEST_TMPDIR}"
    [ "$status" -eq 0 ]

    run validate_nupkg "${BATS_TEST_TMPDIR}/zelph.2.3.4.20261015.nupkg" 2.3.4.20261015 "$CHECKSUM" 2.3.4
    [ "$status" -eq 0 ]
}
