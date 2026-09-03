#!/usr/bin/env bash
# Install Chocolatey CLI for use under mono on Linux. See README.md.
set -euo pipefail

CHOCO_REPO='chocolatey/choco'
CHOCO_API="https://api.github.com/repos/${CHOCO_REPO}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: scripts/install-choco.sh [options]

Downloads the Chocolatey CLI release tarball and unpacks it, so that
scripts/release.sh can drive it through mono.

Options:
  --version VERSION  Chocolatey version to install (default: latest release)
  --prefix DIR       Where to unpack it
                     (default: $CHOCOLATEY_HOME, or ~/.local/lib/chocolatey)
  -h, --help         Show this help
USAGE
}

main() {
    local version='' prefix="${CHOCOLATEY_HOME:-$HOME/.local/lib/chocolatey}"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) version=${2:?--version needs a value}; shift 2 ;;
            --prefix)  prefix=${2:?--prefix needs a value}; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *)         usage >&2; die "unknown argument: $1" ;;
        esac
    done

    local cmd
    for cmd in curl jq tar sha256sum mono; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing required command: ${cmd}"
    done

    if [[ -z $version ]]; then
        version=$(curl -fsSL "${CHOCO_API}/releases/latest" | jq -re '.tag_name') \
            || die "cannot ask GitHub for the latest Chocolatey release"
        log "latest Chocolatey release is ${version}"
    fi

    local asset="chocolatey.v${version}.tar.gz"
    local json digest
    json=$(curl -fsSL "${CHOCO_API}/releases/tags/${version}") \
        || die "Chocolatey release ${version} does not exist"
    digest=$(printf '%s\n' "$json" \
        | jq -re --arg a "$asset" '.assets[] | select(.name == $a) | .digest // ""')
    [[ $digest == sha256:* ]] \
        || die "release ${version} has no asset ${asset} with a sha256 digest"

    local workdir
    workdir=$(mktemp -d) || die "cannot create a temporary directory"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" EXIT

    log "downloading ${asset}"
    curl -fsSL -o "${workdir}/${asset}" \
        "https://github.com/${CHOCO_REPO}/releases/download/${version}/${asset}" \
        || die "cannot download ${asset}"

    local checksum
    checksum=$(sha256sum "${workdir}/${asset}" | cut -d' ' -f1)
    [[ $checksum == "${digest#sha256:}" ]] \
        || die "${asset} hashes to ${checksum}, but GitHub reports ${digest#sha256:}"
    log "checksum ${checksum} confirmed against the GitHub asset digest"

    mkdir -p "$prefix" || die "cannot create ${prefix}"
    tar xzf "${workdir}/${asset}" -C "$prefix" || die "cannot unpack ${asset} into ${prefix}"

    # Without these two directories, choco prints a warning on every
    # invocation, which would bury the output of the release script in noise.
    mkdir -p "${prefix}/lib" "${prefix}/config"

    local reported
    export ChocolateyInstall="$prefix"
    reported=$(mono "${prefix}/choco.exe" --version 2>/dev/null | tail -n 1) \
        || die "the unpacked choco.exe does not run under mono"
    [[ $reported == "$version" ]] \
        || die "the unpacked choco.exe reports version ${reported}, expected ${version}"

    log "Chocolatey ${reported} installed in ${prefix}"
    if [[ ${CHOCOLATEY_HOME:-$HOME/.local/lib/chocolatey} != "$prefix" ]]; then
        log "set CHOCOLATEY_HOME=${prefix} or pass --choco-home ${prefix} to scripts/release.sh"
    fi
}

main "$@"
