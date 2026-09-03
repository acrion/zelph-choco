#!/usr/bin/env bash
# Release the zelph Chocolatey package from a Linux machine. Refer to
# README.md.

GITHUB_REPO='acrion/zelph'
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
WINDOWS_ASSET='zelph-windows.zip'
PACKAGE_ID='zelph'
PUSH_SOURCE='https://push.chocolatey.org/'
CHOCO_FEED='https://community.chocolatey.org/api/v2'

# The last four elements are the reason this script routes the real choco via
# mono rather than nuget or dotnet pack. Packing rewrites the manifest, and the
# NuGet implementations know nothing about these Chocolatey extensions, so they
# drop them without a word. The package still builds, and it ends up on the
# community repository stripped of its source, documentation and issue links.
REQUIRED_MANIFEST_ELEMENTS=(
    id version title authors owners licenseUrl projectUrl description
    summary releaseNotes copyright tags
    projectSourceUrl packageSourceUrl docsUrl bugTrackerUrl
)

# The install script runs zelph_tests.exe following unpacking, and zelph.exe
# needs zelph.dll adjacent to it. An archive missing any of them would yield a
# package that fails on the user's machine rather than here.
REQUIRED_ZIP_ENTRIES=(zelph.exe zelph_tests.exe zelph.dll)

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: scripts/release.sh [options]

Builds the zelph Chocolatey package from the current repository and pushes it
to the Chocolatey community repository.

Options:
  --tag TAG            Release the given git tag (default: latest zelph release)
  --no-push            Stop after packing and validating, do not push
  --yes                Do not ask for confirmation before pushing
  --allow-dirty        Proceed even if the repository has uncommitted changes
  --api-key-file FILE  Read the Chocolatey API key from FILE
                       (default: $ZELPH_CHOCO_API_KEY_FILE, or
                        ${XDG_CONFIG_HOME:-~/.config}/zelph-choco/apikey)
  --choco-home DIR     Chocolatey installation to use
                       (default: $CHOCOLATEY_HOME, or ~/.local/lib/chocolatey)
  -h, --help           Show this help
USAGE
}

require_commands() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "missing required commands: ${missing[*]}"
    fi
}

version_from_tag() {
    local tag=$1
    [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || {
        printf 'error: tag %q is not of the form vMAJOR.MINOR.PATCH\n' "$tag" >&2
        return 1
    }
    printf '%s\n' "${BASH_REMATCH[1]}"
}

xml_value() {
    local file=$1 element=$2
    sed -n "s|.*<${element}>\\([^<]*\\)</${element}>.*|\\1|p" "$file" | head -n 1
}

ps1_value() {
    local file=$1 name=$2
    sed -n "s|^\\\$${name}[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*|\\1|p" "$file" | head -n 1
}

github_latest_tag() {
    local json
    json=$(curl -fsL "${GITHUB_API}/releases/latest") \
        || { echo "error: cannot reach the GitHub release API" >&2; return 1; }
    printf '%s\n' "$json" | jq -re '.tag_name' \
        || { echo "error: the latest release carries no tag name" >&2; return 1; }
}

github_asset_digest() {
    local tag=$1 asset=$2 json digest
    json=$(curl -fsL "${GITHUB_API}/releases/tags/${tag}") \
        || { printf 'error: release %s does not exist on GitHub\n' "$tag" >&2; return 1; }
    digest=$(printf '%s\n' "$json" \
        | jq -re --arg a "$asset" '.assets[] | select(.name == $a) | .digest // ""')
    if [[ -z $digest ]]; then
        printf 'error: release %s has no asset named %s\n' "$tag" "$asset" >&2
        return 1
    fi
    [[ $digest == sha256:* ]] || {
        printf 'error: GitHub reports digest %q for %s, which is not a sha256\n' "$digest" "$asset" >&2
        return 1
    }
    printf '%s\n' "${digest#sha256:}"
}

assert_not_published() {
    local version=$1 code
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
        "${CHOCO_FEED}/Packages(Id='${PACKAGE_ID}',Version='${version}')") \
        || { echo "error: cannot reach the Chocolatey community feed" >&2; return 1; }
    case $code in
        404) return 0 ;;
        200) printf 'error: %s %s is already published on the community feed\n' \
                 "$PACKAGE_ID" "$version" >&2; return 1 ;;
        *)   printf 'error: the community feed answered HTTP %s, cannot tell whether %s exists\n' \
                 "$code" "$version" >&2; return 1 ;;
    esac
}

read_api_key() {
    local file=$1 mode key
    [[ -f $file ]] || { printf 'error: no API key file at %s\n' "$file" >&2; return 1; }
    mode=$(stat -c '%a' "$file") || return 1
    case $mode in
        400|600) ;;
        *) printf 'error: %s has mode %s, expected 600\n' "$file" "$mode" >&2; return 1 ;;
    esac
    key=$(tr -d '\r\n' < "$file")
    [[ -n $key ]] || { printf 'error: %s is empty\n' "$file" >&2; return 1; }
    [[ $key =~ ^[[:graph:]]+$ ]] \
        || { printf 'error: %s contains whitespace, so it is not a bare API key\n' "$file" >&2; return 1; }
    [[ ${#key} -ge 20 ]] \
        || { printf 'error: the key in %s is only %d characters long\n' "$file" "${#key}" >&2; return 1; }
    printf '%s' "$key"
}

verify_windows_zip() {
    local zip=$1 listing entry
    listing=$(unzip -Z1 "$zip" 2>/dev/null) \
        || { printf 'error: %s is not a readable zip archive\n' "$zip" >&2; return 1; }
    for entry in "${REQUIRED_ZIP_ENTRIES[@]}"; do
        printf '%s\n' "$listing" | grep -qxF "$entry" \
            || { printf 'error: %s does not contain %s\n' "$zip" "$entry" >&2; return 1; }
    done
    printf '%s\n' "$listing" | grep -q '^stdlib/.*\.zph$' \
        || { printf 'error: %s contains no stdlib/*.zph files\n' "$zip" >&2; return 1; }
}

update_nuspec() {
    local file=$1 version=$2
    sed -i \
        -e "0,\\|<version>[^<]*</version>|s||<version>${version}</version>|" \
        -e "s|<releaseNotes>[^<]*</releaseNotes>|<releaseNotes>https://github.com/${GITHUB_REPO}/releases/tag/v${version}</releaseNotes>|" \
        "$file" || return 1
    [[ $(xml_value "$file" version) == "$version" ]] \
        || { printf 'error: rewriting <version> in %s did not take effect\n' "$file" >&2; return 1; }
    [[ $(xml_value "$file" releaseNotes) == *"/v${version}" ]] \
        || { printf 'error: rewriting <releaseNotes> in %s did not take effect\n' "$file" >&2; return 1; }
}

update_install_script() {
    local file=$1 version=$2 checksum=$3
    local url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/${WINDOWS_ASSET}"
    sed -i \
        -e "/^\\\$url[[:space:]]/s|'[^']*'|'${url}'|" \
        -e "/^\\\$checksum[[:space:]]/s|'[^']*'|'${checksum}'|" \
        "$file" || return 1
    # shellcheck disable=SC2016  # $url is the PowerShell variable, not a shell expansion
    [[ $(ps1_value "$file" url) == "$url" ]] \
        || { printf 'error: rewriting $url in %s did not take effect\n' "$file" >&2; return 1; }
    # shellcheck disable=SC2016  # $checksum is the PowerShell variable, not a shell expansion
    [[ $(ps1_value "$file" checksum) == "$checksum" ]] \
        || { printf 'error: rewriting $checksum in %s did not take effect\n' "$file" >&2; return 1; }
}

validate_nupkg() {
    local nupkg=$1 version=$2 checksum=$3
    local tmp listing element status=0

    [[ -f $nupkg ]] || { printf 'error: %s was not created\n' "$nupkg" >&2; return 1; }
    listing=$(unzip -Z1 "$nupkg" 2>/dev/null) \
        || { printf 'error: %s is not a readable zip archive\n' "$nupkg" >&2; return 1; }

    printf '%s\n' "$listing" | grep -qxF 'tools/chocolateyinstall.ps1' \
        || { printf 'error: %s does not contain tools/chocolateyinstall.ps1\n' "$nupkg" >&2; return 1; }
    printf '%s\n' "$listing" | grep -qxF "${PACKAGE_ID}.nuspec" \
        || { printf 'error: %s does not contain %s.nuspec\n' "$nupkg" "$PACKAGE_ID" >&2; return 1; }

    # The moderation rules turn down packages that carry source control or
    # operating system files. No nuspec entry imports them today, but the file
    # section is the part a later change is most likely to widen.
    if printf '%s\n' "$listing" | grep -qE '(^|/)(\.git|\.gitignore|\.DS_Store|Thumbs\.db)'; then
        printf 'error: %s contains source control or operating system files\n' "$nupkg" >&2
        return 1
    fi

    tmp=$(mktemp -d) || return 1
    unzip -qq "$nupkg" -d "$tmp" || { rm -rf "$tmp"; return 1; }

    # Collect every missing element rather than halting at the first. If the
    # packer dropped the Chocolatey extensions, it dropped all of them, and the
    # whole list makes that obvious at a glance.
    for element in "${REQUIRED_MANIFEST_ELEMENTS[@]}"; do
        if ! grep -q "<${element}>" "$tmp/${PACKAGE_ID}.nuspec"; then
            printf 'error: the manifest inside %s has no <%s>\n' "$nupkg" "$element" >&2
            status=1
        fi
    done

    if [[ $(xml_value "$tmp/${PACKAGE_ID}.nuspec" version) != "$version" ]]; then
        printf 'error: the manifest inside %s declares version %s, expected %s\n' \
            "$nupkg" "$(xml_value "$tmp/${PACKAGE_ID}.nuspec" version)" "$version" >&2
        status=1
    fi
    if [[ $(ps1_value "$tmp/tools/chocolateyinstall.ps1" checksum) != "$checksum" ]]; then
        printf 'error: the install script inside %s carries the wrong checksum\n' "$nupkg" >&2
        status=1
    fi
    if [[ $(ps1_value "$tmp/tools/chocolateyinstall.ps1" url) != *"/v${version}/${WINDOWS_ASSET}" ]]; then
        printf 'error: the install script inside %s does not download v%s of %s\n' \
            "$nupkg" "$version" "$WINDOWS_ASSET" >&2
        status=1
    fi

    rm -rf "$tmp"
    return $status
}

main() {
    local tag='' do_push=1 assume_yes=0 allow_dirty=0
    local api_key_file="${ZELPH_CHOCO_API_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zelph-choco/apikey}"
    local choco_home="${CHOCOLATEY_HOME:-$HOME/.local/lib/chocolatey}"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --tag)           tag=${2:?--tag needs a value}; shift 2 ;;
            --no-push)       do_push=0; shift ;;
            --yes|-y)        assume_yes=1; shift ;;
            --allow-dirty)   allow_dirty=1; shift ;;
            --api-key-file)  api_key_file=${2:?--api-key-file needs a value}; shift 2 ;;
            --choco-home)    choco_home=${2:?--choco-home needs a value}; shift 2 ;;
            -h|--help)       usage; return 0 ;;
            *)               usage >&2; die "unknown argument: $1" ;;
        esac
    done

    local script_dir repo_root
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(dirname "$script_dir")

    local nuspec="${repo_root}/${PACKAGE_ID}.nuspec"
    local install_script="${repo_root}/tools/chocolateyinstall.ps1"
    local choco_exe="${choco_home}/choco.exe"

    require_commands curl jq unzip sha256sum sed grep git mono mktemp stat
    [[ -f $choco_exe ]] \
        || die "no Chocolatey installation at ${choco_home} (run scripts/install-choco.sh)"
    [[ -f $nuspec ]] || die "no ${nuspec}"
    [[ -f $install_script ]] || die "no ${install_script}"

    export ChocolateyInstall="$choco_home"
    local choco_version
    choco_version=$(mono "$choco_exe" --version 2>/dev/null | tail -n 1) \
        || die "cannot run ${choco_exe} under mono"
    log "Chocolatey ${choco_version} on $(mono --version | head -n 1)"

    if [[ $allow_dirty -eq 0 ]]; then
        local dirty
        dirty=$(git -C "$repo_root" status --porcelain) || die "not a git repository: ${repo_root}"
        [[ -z $dirty ]] || die "the repository has uncommitted changes (use --allow-dirty to ignore)"
    fi

    # Read the key before anything is downloaded or rewritten. A key that proves
    # unusable after the package is built leaves the working tree changed
    # for nothing.
    local api_key=''
    if [[ $do_push -eq 1 ]]; then
        api_key=$(read_api_key "$api_key_file") || exit 1
        log "API key read from ${api_key_file}"
    fi

    if [[ -z $tag ]]; then
        tag=$(github_latest_tag) || exit 1
        log "latest zelph release is ${tag}"
    fi
    local version
    version=$(version_from_tag "$tag") || exit 1

    local expected_digest
    expected_digest=$(github_asset_digest "$tag" "$WINDOWS_ASSET") || exit 1

    assert_not_published "$version" || exit 1
    log "${PACKAGE_ID} ${version} is not on the community feed yet"

    local workdir
    workdir=$(mktemp -d) || die "cannot create a temporary directory"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" EXIT

    log "downloading ${WINDOWS_ASSET} of ${tag}"
    local zip="${workdir}/${WINDOWS_ASSET}"
    curl -fsSL -o "$zip" \
        "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${WINDOWS_ASSET}" \
        || die "cannot download ${WINDOWS_ASSET} of ${tag}"

    # Two distinct origins for one hash: the bytes that reached this point, and
    # what GitHub records for the asset. A mismatch means the download is not the
    # file the release refers to.
    local checksum
    checksum=$(sha256sum "$zip" | cut -d' ' -f1)
    [[ $checksum == "$expected_digest" ]] \
        || die "the downloaded ${WINDOWS_ASSET} hashes to ${checksum}, but GitHub reports ${expected_digest}"
    verify_windows_zip "$zip" || exit 1
    log "checksum ${checksum} confirmed against the GitHub asset digest"

    update_nuspec "$nuspec" "$version" || exit 1
    update_install_script "$install_script" "$version" "$checksum" || exit 1
    log "updated ${PACKAGE_ID}.nuspec and tools/chocolateyinstall.ps1"
    git -C "$repo_root" --no-pager diff --stat

    local nupkg="${repo_root}/${PACKAGE_ID}.${version}.nupkg"
    rm -f "$nupkg"
    mono "$choco_exe" pack "$nuspec" --output-directory="$repo_root" >/dev/null \
        || die "choco pack failed"
    validate_nupkg "$nupkg" "$version" "$checksum" || exit 1
    log "packed and validated ${nupkg#"${repo_root}/"}"

    if [[ $do_push -eq 0 ]]; then
        log "not pushing (--no-push)"
        return 0
    fi

    if [[ $assume_yes -eq 0 ]]; then
        local answer
        printf 'Push %s %s to %s? [y/N] ' "$PACKAGE_ID" "$version" "$PUSH_SOURCE"
        read -r answer
        [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die "aborted"
    fi

    mono "$choco_exe" push "$nupkg" --source "$PUSH_SOURCE" --api-key "$api_key" \
        || die "choco push failed"
    log "pushed ${PACKAGE_ID} ${version}; it now waits for moderation"
    log "commit the version bump: git -C ${repo_root} commit -am 'v${version}'"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    main "$@"
fi
