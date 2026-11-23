#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOME_DIR="${HOME:?HOME must be set}"
MODE=both
NO_BACKUP=0
SV_CONTAINER_PATH=
SV_HOST_PATH=
TEMP_DIR=

usage() {
    cat <<'USAGE'
Usage: ./setup.sh [--copy-only | --setup-only]
                 [--no-backup] [--sv <container-path> <host-path>]

With no option, copy the dotfiles and install/setup micromamba, the stable
Rust toolchain (rustc and Cargo), GitHub CLI, and Docker Engine, CLI, and
Compose. Existing files are backed up before replacement unless --no-backup
is specified.

Options:
  --copy-only   Copy the tracked dotfiles; do not install packages.
  --setup-only  Install packages and initialize micromamba; do not copy dotfiles.
  --no-backup   Replace files without creating backups.
  --sv PATH DIR Print Docker commands with DIR bind-mounted at PATH.
  -h, --help    Show this help.
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

while (($#)); do
    case "$1" in
        --sv)
            (($# >= 3)) || fail "--sv requires a container path and a host directory."
            [[ -z "$SV_CONTAINER_PATH" ]] || fail "--sv may only be specified once."
            SV_CONTAINER_PATH="$2"
            SV_HOST_PATH="$3"
            [[ "$SV_CONTAINER_PATH" == /* ]] ||
                fail "--sv container path must be absolute."
            [[ "$SV_HOST_PATH" != *,* && "$SV_CONTAINER_PATH" != *,* ]] ||
                fail "--sv paths cannot contain commas."
            [[ "$SV_HOST_PATH" != *$'\n'* && "$SV_CONTAINER_PATH" != *$'\n'* ]] ||
                fail "--sv paths cannot contain newlines."
            [[ ! -e "$SV_HOST_PATH" || -d "$SV_HOST_PATH" ]] ||
                fail "--sv host path must be a directory: $SV_HOST_PATH"
            if [[ "$SV_HOST_PATH" != /* ]]; then
                SV_HOST_PATH="$PWD/$SV_HOST_PATH"
            fi
            shift 3
            continue
            ;;
        --copy-only)
            [[ "$MODE" == both ]] || fail "Choose only one of --copy-only and --setup-only."
            MODE=copy
            ;;
        --setup-only)
            [[ "$MODE" == both ]] || fail "Choose only one of --copy-only and --setup-only."
            MODE=setup
            ;;
        --no-backup)
            NO_BACKUP=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown option: $1"
            ;;
    esac
    shift
done

copy_dotfiles() {
    local relative source target parent component current backup_dir=
    local -a files=(.bashrc .vimrc .vim/colors/gruvbox.vim)
    local -a path_parts

    for relative in "${files[@]}"; do
        source="$SCRIPT_DIR/$relative"
        [[ -f "$source" ]] || fail "Required repository file is missing: $relative"
    done

    for relative in "${files[@]}"; do
        source="$SCRIPT_DIR/$relative"
        target="$HOME_DIR/$relative"
        parent="$(dirname -- "$target")"

        current="$HOME_DIR"
        IFS='/' read -r -a path_parts <<< "${relative%/*}"
        if [[ "$relative" == */* ]]; then
            for component in "${path_parts[@]}"; do
                current="$current/$component"
                [[ ! -L "$current" ]] || fail "Refusing to copy through symlinked directory: $current"
            done
        fi

        if [[ -d "$target" && ! -L "$target" ]]; then
            fail "Expected a file but found a directory: $target"
        fi

        if ((NO_BACKUP == 0)) && [[ -e "$target" || -L "$target" ]]; then
            if [[ -z "$backup_dir" ]]; then
                mkdir -p -- "$HOME_DIR/.dotfiles-backups"
                backup_dir="$(mktemp -d "$HOME_DIR/.dotfiles-backups/$(date +%Y%m%d-%H%M%S).XXXXXX")"
            fi
            mkdir -p -- "$backup_dir/$(dirname -- "$relative")"
            cp -a -- "$target" "$backup_dir/$relative"
        fi

        mkdir -p -- "$parent"
        if [[ -L "$target" ]]; then
            rm -- "$target"
        fi
        cp -- "$source" "$target"
        printf 'Copied %s\n' "$relative"
    done

    if ((NO_BACKUP)); then
        printf 'Backups disabled (--no-backup).\n'
    elif [[ -n "$backup_dir" ]]; then
        printf 'Existing files backed up to %s\n' "$backup_dir"
    else
        printf 'No existing files needed backup.\n'
    fi
}

as_root() {
    if ((EUID == 0)); then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "System package setup requires root or sudo."
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

check_docker_conflicts() {
    local package status
    local -a conflicts=()
    for package in docker.io docker-compose docker-compose-v2 docker-doc \
        docker-buildx podman-docker containerd runc; do
        status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
        if [[ "$status" == ii* ]]; then
            conflicts+=("$package")
        fi
    done
    if ((${#conflicts[@]})); then
        printf 'Conflicting Docker packages are installed: %s\n' "${conflicts[*]}" >&2
        fail "Remove these packages manually before installing Docker Engine from Docker's repository."
    fi
}

prepare_system() {
    [[ -r /etc/os-release ]] || fail "Cannot identify this Linux distribution."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) fail "This setup supports Ubuntu and Debian only (detected: ${ID:-unknown})." ;;
    esac
    [[ -n "${VERSION_CODENAME:-}" || -n "${UBUNTU_CODENAME:-}" ]] ||
        fail "Could not determine the distribution codename."

    require_command apt-get
    require_command dpkg
    require_command dpkg-query
    check_docker_conflicts
    as_root apt-get update
    as_root apt-get install -y ca-certificates curl gnupg
    require_command curl
    require_command tar
}

install_micromamba() {
    local platform archive_url micromamba_bin

    if command -v micromamba >/dev/null 2>&1; then
        micromamba_bin="$(command -v micromamba)"
    elif [[ -x "$HOME_DIR/.local/bin/micromamba" ]]; then
        micromamba_bin="$HOME_DIR/.local/bin/micromamba"
    else
        case "$(uname -m)" in
            x86_64) platform=linux-64 ;;
            aarch64|arm64) platform=linux-aarch64 ;;
            *) fail "Micromamba setup does not support architecture: $(uname -m)" ;;
        esac
        archive_url="https://micro.mamba.pm/api/micromamba/$platform/latest"
        mkdir -p -- "$HOME_DIR/.local/bin"
        printf 'Downloading micromamba for %s...\n' "$platform"
        curl -fsSL "$archive_url" | tar -xj -C "$TEMP_DIR" bin/micromamba
        install -m 0755 "$TEMP_DIR/bin/micromamba" "$HOME_DIR/.local/bin/micromamba"
        micromamba_bin="$HOME_DIR/.local/bin/micromamba"
    fi

    mkdir -p -- "$HOME_DIR"
    touch "$HOME_DIR/.bashrc"
    "$micromamba_bin" shell init -s bash -r "$HOME_DIR/micromamba"
}

install_rust() {
    local rustup_bin
    if [[ -x "$HOME_DIR/.cargo/bin/rustup" ]]; then
        rustup_bin="$HOME_DIR/.cargo/bin/rustup"
    elif command -v rustup >/dev/null 2>&1; then
        rustup_bin="$(command -v rustup)"
    else
        curl -fsSL https://sh.rustup.rs -o "$TEMP_DIR/rustup-init.sh"
        sh "$TEMP_DIR/rustup-init.sh" -y --profile default --default-toolchain stable
        return
    fi

    "$rustup_bin" toolchain install stable
    "$rustup_bin" default stable
}

add_github_cli_repository() {
    local architecture
    architecture="$(dpkg --print-architecture)"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o "$TEMP_DIR/githubcli-archive-keyring.gpg"
    as_root install -d -m 0755 /etc/apt/keyrings
    as_root install -m 0644 "$TEMP_DIR/githubcli-archive-keyring.gpg" \
        /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$architecture" |
        as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
}

add_docker_repository() {
    local architecture codename docker_os
    # shellcheck disable=SC1091
    . /etc/os-release
    docker_os="$ID"
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    architecture="$(dpkg --print-architecture)"

    curl -fsSL "https://download.docker.com/linux/$docker_os/gpg" |
        as_root gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    as_root chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$architecture" "$docker_os" "$codename" |
        as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
}

setup_software() {
    prepare_system
    TEMP_DIR="$(mktemp -d)"
    install_micromamba
    install_rust
    add_github_cli_repository
    add_docker_repository
    as_root apt-get update
    as_root apt-get install -y gh docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    printf 'Installed micromamba, stable Rust (rustc and Cargo), GitHub CLI, and Docker packages.\n'
    printf 'Docker service startup and non-root access are managed separately; see README.md.\n'
}

print_docker_commands() {
    local mount_spec

    printf '# Run these commands on the Docker host:\n'
    printf 'docker build -t dotfiles-agent -f %q %q\n' \
        "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
    if [[ -n "$SV_CONTAINER_PATH" ]]; then
        mount_spec="type=bind,source=$SV_HOST_PATH,target=$SV_CONTAINER_PATH"
        printf 'mkdir -p -- %q\n' "$SV_HOST_PATH"
        printf 'docker run -d --name dotfiles-agent --mount %q dotfiles-agent\n' \
            "$mount_spec"
    else
        printf 'docker run -d --name dotfiles-agent dotfiles-agent\n'
    fi
    printf 'docker exec -it dotfiles-agent bash\n'
}

copy_to_clipboard() {
    local commands="$1"

    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
        if printf '%s\n' "$commands" | wl-copy >/dev/null 2>&1; then
            printf 'Docker commands copied to clipboard with wl-copy.\n' >&2
            return
        fi
    fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
        if printf '%s\n' "$commands" | xclip -selection clipboard >/dev/null 2>&1; then
            printf 'Docker commands copied to clipboard with xclip.\n' >&2
            return
        fi
    fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
        if printf '%s\n' "$commands" | xsel --clipboard --input >/dev/null 2>&1; then
            printf 'Docker commands copied to clipboard with xsel.\n' >&2
            return
        fi
    fi
    printf 'Clipboard unavailable; copy the Docker commands from the output above.\n' >&2
}

case "$MODE" in
    both|copy) copy_dotfiles ;;
esac
case "$MODE" in
    both|setup) setup_software ;;
esac

DOCKER_COMMANDS="$(print_docker_commands)"
copy_to_clipboard "$DOCKER_COMMANDS"
printf '%s\n' "$DOCKER_COMMANDS"
