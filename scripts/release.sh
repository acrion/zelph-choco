#!/usr/bin/env bash
# Release the zelph Chocolatey package from a Linux machine. Refer to
# README.md.

GITHUB_REPO='acrion/zelph'
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
WINDOWS_ASSET='zelph-windows.zip'
PACKAGE_ID='zelph'
PUSH_SOURCE='https://push.chocolatey.org/'
CHOCO_FEED='https://community.chocolatey.org/api/v2'
GALLERY='https://community.chocolatey.org/packages'

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

# The install script runs zelph.exe after unpacking, and that needs zelph.dll
# beside it. zelph_tests.exe is no longer part of the check -- it is the suite a
# user may run by hand -- but a release archive is expected to carry it, so its
# absence means a release that went wrong rather than a decision. An archive
# missing any of the three would yield a package that fails on the user's
# machine rather than here.
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
  --package-fix        Publish the package again around the unchanged binaries
                       of TAG as VERSION.YYYYMMDD, today's date in UTC; a fix
                       version of TAG still in moderation is pushed again
  --status             Show where every version this repository has packed
                       stands on the community feed, then exit
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

gallery_url() {
    printf '%s/%s/%s\n' "$GALLERY" "$PACKAGE_ID" "$1"
}

version_lt() {
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]
}

# The three-component release a version belongs to, such as 1.0.1 for
# 1.0.1.20260907.
release_of() {
    printf '%s\n' "$1" | cut -d. -f1-3
}

# Extract a single property from a feed entry received via stdin.
feed_field() {
    local field=$1
    sed -n "s|.*<d:${field}\\( [^>]*\\)\\?>\\([^<]*\\)</d:${field}>.*|\\2|p" | head -n 1
}

# The feed responds to a lookup by id and version with HTTP 200 for both an
# approved version and one currently in moderation, meaning the entry alone
# distinguishes between them. A rejected version returns 404, identical to a
# version that was never pushed. Prints four words: the status (Approved,
# Submitted, ... or Absent), the moderation substatus, and the results of
# validation and verification, using - in place of any missing data.
feed_status() {
    local version=$1 response code entry status
    response=$(curl -sS -w '\n%{http_code}' \
        "${CHOCO_FEED}/Packages(Id='${PACKAGE_ID}',Version='${version}')") \
        || { echo "error: cannot reach the Chocolatey community feed" >&2; return 1; }
    code=${response##*$'\n'}
    entry=${response%$'\n'*}
    case $code in
        404) printf 'Absent - - -\n' ;;
        200)
            status=$(feed_field PackageStatus <<< "$entry")
            [[ -n $status ]] || {
                printf 'error: the community feed entry of %s %s carries no PackageStatus\n' \
                    "$PACKAGE_ID" "$version" >&2
                return 1
            }
            printf '%s %s %s %s\n' "$status" \
                "$(feed_field PackageSubmittedStatus <<< "$entry" | sed 's/^$/-/')" \
                "$(feed_field PackageValidationResultStatus <<< "$entry" | sed 's/^$/-/')" \
                "$(feed_field PackageTestResultStatus <<< "$entry" | sed 's/^$/-/')" ;;
        *)
            printf 'error: the community feed answered HTTP %s, cannot tell where %s %s stands\n' \
                "$code" "$PACKAGE_ID" "$version" >&2
            return 1 ;;
    esac
}

# Each version this repository has packed, ordered from most recent to oldest:
# the history of the manifest, alongside the working tree, in which a version
# that has just been pushed stays until it is committed. The feed is unable to
# provide this sequence, as its listing omits every version currently in
# moderation, and those are precisely the ones that are significant in this
# context.
packed_versions() {
    local repo=$1 revisions rev
    revisions=$(git -C "$repo" log --format=%H -- "${PACKAGE_ID}.nuspec") \
        || { printf 'error: cannot read the history of %s.nuspec\n' "$PACKAGE_ID" >&2; return 1; }
    {
        xml_value "${repo}/${PACKAGE_ID}.nuspec" version
        for rev in $revisions; do
            git -C "$repo" show "${rev}:${PACKAGE_ID}.nuspec" 2>/dev/null \
                | xml_value /dev/stdin version
        done
    } | sed '/^$/d' | sort -Vru
}

# A version in moderation may be pushed again using the identical number, as
# Chocolatey anticipates this method for fixing a submission. Only a version
# that has been approved is final. A rejected one appears to be missing from
# here, and the push itself will then refuse it.
assert_pushable() {
    local version=$1; shift
    local line status substatus validation verification
    line=$(feed_status "$version") || return 1
    read -r status substatus validation verification <<< "$line"
    case $status in
        Absent|Submitted)
            assert_not_superseded "$version" "$status" "$@" || return 1
            if [[ $status == Absent ]]; then
                log "${PACKAGE_ID} ${version} is not on the community feed"
            else
                log "${PACKAGE_ID} ${version} is in moderation (${substatus}, validation ${validation}, verification ${verification}); pushing it again replaces that submission"
            fi ;;
        Approved|Exempted)
            printf 'error: %s %s is already approved on the community feed, and an approved version is final\n' \
                "$PACKAGE_ID" "$version" >&2
            if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                printf 'error: to publish the package again around the binaries of v%s, use --package-fix\n' \
                    "$version" >&2
            fi
            return 1 ;;
        *)
            printf 'error: the community feed holds %s %s as %s, which cannot be pushed\n' \
                "$PACKAGE_ID" "$version" "$status" >&2
            return 1 ;;
    esac
}

# Only the highest approved version is ever delivered to users, meaning
# that even if a version within the same release is improved and corrected,
# it will not be received by users if it ranks below an approved version.
# This applies to 1.0.1 in comparison to its approved fix, 1.0.1.1.
assert_not_superseded() {
    local version=$1 status=$2; shift 2
    local release candidate line candidate_status
    release=$(release_of "$version")
    for candidate in "$@"; do
        [[ $(release_of "$candidate") == "$release" ]] || continue
        version_lt "$version" "$candidate" || continue
        line=$(feed_status "$candidate") || return 1
        read -r candidate_status _ <<< "$line"
        [[ $candidate_status == Approved || $candidate_status == Exempted ]] || continue
        printf 'error: %s %s is approved and sorts above %s, so %s would never reach users\n' \
            "$PACKAGE_ID" "$candidate" "$version" "$version" >&2
        if [[ $version == "$release" ]]; then
            printf 'error: to correct the package of v%s, use --package-fix\n' "$release" >&2
        fi
        if [[ $status == Submitted ]]; then
            printf 'error: %s %s itself is still in moderation: %s\n' \
                "$PACKAGE_ID" "$version" "$(gallery_url "$version")" >&2
        fi
        return 1
    done
}

# A package fix, such as 1.0.1.20260907, republishes the package using the
# unchanged binaries of a release. It is meant for a single scenario: a package
# that was previously approved but later found to be incorrect. Chocolatey
# recommends using the date as the fourth component. A version currently in
# moderation is not addressed through this method. Instead, it is re-pushed with
# its own number, meaning a fix version of this release that is awaiting
# moderation is the one selected here, and only when no such version is pending
# does today's date apply.
package_fix_version() {
    local version=$1 today=$2; shift 2
    local candidate line status base_status approved='' waiting='' dated_taken=''
    local fix_pattern="^${version//./\\.}\\.[0-9]+$"

    line=$(feed_status "$version") || return 1
    read -r base_status _ <<< "$line"
    [[ $base_status == Approved || $base_status == Exempted ]] && approved=$version

    for candidate in "$@"; do
        [[ $candidate =~ $fix_pattern ]] || continue
        line=$(feed_status "$candidate") || return 1
        read -r status _ <<< "$line"
        case $status in
            Approved|Exempted)
                approved=$candidate
                [[ $candidate == "${version}.${today}" ]] && dated_taken=$candidate ;;
            Submitted)
                [[ -n $waiting ]] || waiting=$candidate ;;
        esac
    done

    if [[ -z $approved ]]; then
        if [[ $base_status == Submitted ]]; then
            printf 'error: %s %s is still in moderation, and a version in moderation is fixed under its own number: push it again without --package-fix\n' \
                "$PACKAGE_ID" "$version" >&2
        else
            printf 'error: no version of %s %s is approved on the community feed, so there is nothing to fix\n' \
                "$PACKAGE_ID" "$version" >&2
        fi
        return 1
    fi

    if [[ -n $waiting ]]; then
        printf '%s\n' "$waiting"
    elif [[ -n $dated_taken ]]; then
        printf 'error: %s %s is a fix of %s approved today already, and the date form allows one fix a day (UTC): the next one can go out tomorrow\n' \
            "$PACKAGE_ID" "$dated_taken" "$version" >&2
        return 1
    else
        printf '%s.%s\n' "$version" "$today"
    fi
}

# A single line indicating the status of a version, for someone to read.
describe_feed_version() {
    local version=$1 line status substatus validation verification
    line=$(feed_status "$version") || return 1
    read -r status substatus validation verification <<< "$line"
    case $status in
        Absent)
            printf '%s %s: not on the community feed (never pushed, or rejected)\n' "$PACKAGE_ID" "$version" ;;
        Submitted)
            printf '%s %s: in moderation (%s), validation %s, verification %s, %s\n' \
                "$PACKAGE_ID" "$version" "$substatus" "$validation" "$verification" "$(gallery_url "$version")" ;;
        *)
            printf '%s %s: %s\n' "$PACKAGE_ID" "$version" "$status" ;;
    esac
}

# Every version constitutes a distinct moderation case, and approving a more
# recent one does not close the prior one. A version left behind waits until the
# maintainer rejects it or the cleaner does, 35 days after the most recent
# request for modifications, and during this time, every page for the package
# displays a notice indicating that versions are awaiting moderation. Only a
# version that failed an automated check may be rejected by its maintainer:
# being older is not a valid reason Chocolatey accepts.
report_moderation_queue() {
    local pushing=$1; shift
    local version line status substatus validation verification
    for version in "$@"; do
        [[ $version == "$pushing" ]] && continue
        line=$(feed_status "$version") || return 1
        read -r status substatus validation verification <<< "$line"
        [[ $status == Submitted ]] || continue
        warn "${PACKAGE_ID} ${version} is still in moderation (${substatus}), and pushing ${pushing} does not close it"
        if [[ $validation == Failing || $verification == Failing ]]; then
            if version_lt "$version" "$pushing"; then
                warn "it failed an automated check, so it can be rejected on $(gallery_url "$version") (Reject Package?)"
            else
                warn "it failed an automated check, and as it is newer than ${pushing}, it is corrected by pushing it again under its own number: $(gallery_url "$version")"
            fi
        elif [[ $substatus == Waiting ]]; then
            warn "a moderator asked for changes, and it waits for an answer or a corrected push under its own number: $(gallery_url "$version")"
        else
            warn "it is reviewed on its own: $(gallery_url "$version")"
        fi
    done
}

# Determine the version to be pushed and verify whether it is permissible
# to push. The version is output to stdout, while all commentary regarding
# it is directed to stderr.
plan_push() {
    local version=$1 package_fix=$2 today=$3; shift 3
    local package_version=$version
    if [[ $package_fix -eq 1 ]]; then
        package_version=$(package_fix_version "$version" "$today" "$@") || return 1
        log "publishing ${PACKAGE_ID} ${package_version} around the binaries of v${version}" >&2
    fi
    assert_pushable "$package_version" "$@" >&2 || return 1
    report_moderation_queue "$package_version" "$@" || return 1
    printf '%s\n' "$package_version"
}

# Pushing a version in moderation once more under its own number rewrites both
# files to contain exactly what they already have, meaning that following such a
# push, there may be nothing to commit.
commit_hint() {
    local repo=$1 version=$2
    if git -C "$repo" diff --quiet -- "${PACKAGE_ID}.nuspec" tools/chocolateyinstall.ps1; then
        log "${PACKAGE_ID}.nuspec and tools/chocolateyinstall.ps1 are unchanged, so there is nothing to commit"
    else
        log "commit the version bump: git -C ${repo} commit -am 'v${version}'"
    fi
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

# The two versions are the same for an ordinary release and differ for a
# package fix, where the manifest carries 1.0.1.1 while the release notes still
# point at the tag v1.0.1 that the binaries come from.
update_nuspec() {
    local file=$1 version=$2 release_version=${3:-$2}
    sed -i \
        -e "0,\\|<version>[^<]*</version>|s||<version>${version}</version>|" \
        -e "s|<releaseNotes>[^<]*</releaseNotes>|<releaseNotes>https://github.com/${GITHUB_REPO}/releases/tag/v${release_version}</releaseNotes>|" \
        "$file" || return 1
    [[ $(xml_value "$file" version) == "$version" ]] \
        || { printf 'error: rewriting <version> in %s did not take effect\n' "$file" >&2; return 1; }
    [[ $(xml_value "$file" releaseNotes) == *"/v${release_version}" ]] \
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
    local nupkg=$1 version=$2 checksum=$3 release_version=${4:-$2}
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
    if [[ $(ps1_value "$tmp/tools/chocolateyinstall.ps1" url) != *"/v${release_version}/${WINDOWS_ASSET}" ]]; then
        printf 'error: the install script inside %s does not download v%s of %s\n' \
            "$nupkg" "$release_version" "$WINDOWS_ASSET" >&2
        status=1
    fi

    # A package fix keeps the release notes on the version the binaries come
    # from, so this is the one element that must NOT follow the package version.
    if [[ $(xml_value "$tmp/${PACKAGE_ID}.nuspec" releaseNotes) != *"/v${release_version}" ]]; then
        printf 'error: the manifest inside %s does not point its release notes at v%s\n' \
            "$nupkg" "$release_version" >&2
        status=1
    fi

    rm -rf "$tmp"
    return $status
}

main() {
    local tag='' do_push=1 assume_yes=0 allow_dirty=0 package_fix=0 status_only=0
    local api_key_file="${ZELPH_CHOCO_API_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zelph-choco/apikey}"
    local choco_home="${CHOCOLATEY_HOME:-$HOME/.local/lib/chocolatey}"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --tag)           tag=${2:?--tag needs a value}; shift 2 ;;
            --package-fix)   package_fix=1; shift ;;
            --status)        status_only=1; shift ;;
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

    if [[ $status_only -eq 1 ]]; then
        require_commands curl sed git sort
        local packed_list packed_version
        packed_list=$(packed_versions "$repo_root") || exit 1
        while read -r packed_version; do
            describe_feed_version "$packed_version" || exit 1
        done <<< "$packed_list"
        return 0
    fi

    require_commands curl jq unzip sha256sum sed grep git mono mktemp stat sort date
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

    local packed_list packed=()
    packed_list=$(packed_versions "$repo_root") || exit 1
    mapfile -t packed <<< "$packed_list"

    # When applying a fix to a package, only the fourth component undergoes
    # change: the archive, its checksum, the tag, and the release notes
    # remain tied to the original three-component release version.
    local package_version
    package_version=$(plan_push "$version" "$package_fix" "$(date -u +%Y%m%d)" "${packed[@]}") || exit 1

    local expected_digest
    expected_digest=$(github_asset_digest "$tag" "$WINDOWS_ASSET") || exit 1

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

    update_nuspec "$nuspec" "$package_version" "$version" || exit 1
    update_install_script "$install_script" "$version" "$checksum" || exit 1
    log "updated ${PACKAGE_ID}.nuspec and tools/chocolateyinstall.ps1"
    git -C "$repo_root" --no-pager diff --stat

    local nupkg="${repo_root}/${PACKAGE_ID}.${package_version}.nupkg"
    rm -f "$nupkg"
    mono "$choco_exe" pack "$nuspec" --output-directory="$repo_root" >/dev/null \
        || die "choco pack failed"
    validate_nupkg "$nupkg" "$package_version" "$checksum" "$version" || exit 1
    log "packed and validated ${nupkg#"${repo_root}/"}"

    if [[ $do_push -eq 0 ]]; then
        log "not pushing (--no-push)"
        return 0
    fi

    if [[ $assume_yes -eq 0 ]]; then
        local answer
        printf 'Push %s %s to %s? [y/N] ' "$PACKAGE_ID" "$package_version" "$PUSH_SOURCE"
        read -r answer
        [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die "aborted"
    fi

    mono "$choco_exe" push "$nupkg" --source "$PUSH_SOURCE" --api-key "$api_key" \
        || die "choco push failed"
    log "pushed ${PACKAGE_ID} ${package_version}; it now waits for moderation"
    commit_hint "$repo_root" "$package_version"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    main "$@"
fi
