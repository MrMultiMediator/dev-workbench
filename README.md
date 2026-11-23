# Development Workbench

A portable collection of development environment configuration and tools for machines or containers you work on, from a workstation or a frequently replaced laptop to a remote cloud instance. It currently includes Bash and Vim preferences and an installer for the command-line tools used alongside them.

> **Designed for Linux:** package installation is supported on Ubuntu and Debian. Dotfile copying itself is Bash-based, but the setup operations use `apt`.

Prefer a standalone, styled version? Open [README.html](README.html).

## What’s included

| File | Purpose |
| --- | --- |
| `.bashrc` | Interactive Bash defaults, aliases, completion, and optional Cargo environment loading |
| `.vimrc` | Vim editing preferences |
| `.vim/colors/gruvbox.vim` | Gruvbox color scheme used by `.vimrc` |
| `setup.sh` | Copy dotfiles and/or install micromamba, stable Rust, GitHub CLI, and Docker |
| `Dockerfile` | Disposable Ubuntu environment for testing the setup or working in an isolated agent container |
| `LICENSE` | MIT license for this repository |
| `THIRD_PARTY_NOTICES.md` | MIT/X11 notice for the bundled Gruvbox Vim theme |

This repository is licensed under MIT; see `LICENSE`. The bundled `.vim/colors/gruvbox.vim` theme retains its upstream attribution and license, documented separately in `THIRD_PARTY_NOTICES.md`.

## Quick start

From a clone of this repository, run:

```bash
./setup.sh
```

With no options, the script:

1. Copies `.bashrc`, `.vimrc`, and the Gruvbox theme into your home directory.
2. Backs up any files it will replace.
3. Installs micromamba, the stable Rust toolchain (`rustc` and Cargo) via rustup, GitHub CLI (`gh`), Docker Engine, the Docker CLI, Buildx, and the Compose plugin.
4. Initializes micromamba for Bash.
5. Prints Docker build/run/exec commands for creating the agent container, and copies them to your clipboard if a supported desktop clipboard is available.

The installer supports **Ubuntu and Debian only** and requires network access, `apt`, and either root privileges or `sudo`. Package installation may prompt for your sudo password. Rust and micromamba are installed for the current user; only system packages use `sudo`.

### Choose what to run

```bash
./setup.sh --copy-only
```

Copy the dotfiles and skip package installation.

```bash
./setup.sh --setup-only
```

Install and initialize the tools without copying repository dotfiles. Micromamba initialization still updates the current user's `~/.bashrc`.

```bash
./setup.sh --no-backup
```

Run the default copy-and-setup flow, but replace destination files without backing them up. This flag can also be combined with `--copy-only`; it has no effect with `--setup-only`.

```bash
./setup.sh --sv /workspace/mirror "$HOME/path/to/my/dir"
```

Run the default flow and print Docker commands that bind-mount the host directory at `/workspace/mirror` in the agent container. The generated commands create the host directory if it does not exist. Only that directory is shared; writes and deletions there affect the host. Ensure it is writable by the container's `dotfiles` user. The option prints commands without launching Docker; mounts must be specified when a new container is created, not added to an existing one.

```bash
./setup.sh --help
```

Show all options. `--copy-only` and `--setup-only` cannot be used together. `--sv` accepts an absolute container path and a host directory; paths cannot contain commas or newlines.

## Backups and safety

By default, before replacing a destination file, the script saves it under a unique, timestamped directory in:

```text
~/.dotfiles-backups/
```

For example, an existing `.bashrc` is preserved at `~/.dotfiles-backups/<timestamp>.<unique-suffix>/.bashrc`. The script prints the exact backup directory. If no destination files exist, no backup directory is created. Existing unrelated Vim files and plugin directories are left alone; only the tracked Gruvbox theme is copied.

Use `--no-backup` to skip this step entirely. Existing files are then replaced without a recovery copy.

The installer adds the official GitHub CLI and Docker package repositories, installs micromamba from its official download endpoint and Rust via the official rustup installer, and reports errors rather than silently continuing. Rustup selects the stable toolchain, providing `rustc` and Cargo in `~/.cargo/bin`. The installer does not remove conflicting pre-installed Docker packages; if it detects any, it stops and asks you to remove them manually. It also does not add your account to the `docker` group: membership grants root-equivalent privileges. Use `sudo docker ...` unless you have deliberately chosen to grant that access.

## Test in a disposable Ubuntu container

The included Dockerfile creates an Ubuntu 24.04 container with Vim and Copilot CLI installed, plus a regular user with passwordless `sudo` for package setup. To get Docker host commands without installing packages on the host, run:

```bash
./setup.sh --copy-only
```

Run the printed commands on the Docker host. If clipboard access is available, the script also copies the commands to the clipboard. To create a container with a shared directory, pass `--sv`:

```bash
./setup.sh --copy-only --sv /workspace/mirror "$HOME/path/to/my/dir"
```

Then run the generated Docker commands on the host. The image has no SSH server and does not run a Docker daemon; starting one would require a separate privileged Docker-in-Docker configuration and is intentionally not part of this test setup. The mounted directory is the only host directory shared with the container, but the agent can change or delete any contents in it.

Authenticate Copilot from inside the container with `copilot` and `/login`. Authentication is not performed during image build.

When finished, leave the shell and remove the disposable container:

```bash
exit
docker rm -f dotfiles-agent
```

To verify Vim inside the container:

```bash
vim
```

Then, inside Vim, run `:echo g:colors_name`. It should print `gruvbox`. If you previously built the container, rerun the generated `docker build` command (optionally with `--no-cache`) and recreate it.

## After setup

Start a new Bash session (or run `source ~/.bashrc`) to load the copied settings and micromamba hook. Open Vim and confirm the Gruvbox theme loads:

```bash
vim
```

Verify the Rust toolchain with `rustc --version` and `cargo --version`.

On a regular Ubuntu/Debian host, Docker's package scripts generally start the service when systemd is available. If needed, start it with `sudo systemctl enable --now docker`. The Docker daemon will not start in the included test container. For Vim plugins, add or manage them separately; this repository only tracks the current color scheme and Vim settings.
