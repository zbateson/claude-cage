# CLAUDE.md

Documentation for `claude-cage` - a lightweight sandboxed git workflow for Claude Code.

## Overview

`claude-cage` creates an isolated sandbox for Claude Code using git-based file isolation. It creates a sanitized copy of your project (excluding sensitive files) and uses git to sync changes back.

**Key features:**
- No sudo required - runs as current user
- Git-based sync - uses git archive + fresh init
- File exclusion at archive time (no history of excluded files)
- Network filtering via iptables (optional)

## Platform Support

| Platform | bwrap mode | Docker mode |
|----------|------------|-------------|
| Linux | ✅ | ✅ |
| Windows (WSL 2) | ✅ | ✅ |
| macOS | ❌ | ✅ |

**macOS users:** Use `mode = "docker"` in your config. bwrap requires Linux kernel features not available on macOS.

**Windows users:** WSL 2 is required. Both modes work since WSL 2 runs a real Linux kernel.

### Installation

**Linux / WSL 2 (bwrap mode):**
```bash
sudo apt install bubblewrap slirp4netns
```

**All platforms (Docker mode):**
- Install [Docker Desktop](https://docs.docker.com/get-docker/)
- On Windows, enable WSL 2 backend

## Architecture

```
Source Project                    ~/.cache/.../intermediary        ~/.cache/.../work
(your actual repo)                (sanitized, fresh git)           (Claude's workspace)
       │                                   │                              │
       │  git ls-files + tar               │     git clone                │
       │  (excludes applied)               │                              │
       └──────────────────────────────────>│──────────────────────────────>
                                           │                              │
                                           │<────── git push ─────────────┤
                                           │     (Claude commits)         │
                                           │                              │
       │<──── format-patch/git-am ─────────┤                              │
       │     (via named pipe)              │                              │
```

### Three-Repository Model

1. **Source** - Your actual project with full git history
2. **Intermediary** (`~/.cache/claude-cage/branches/<branch>/intermediary/<project-path>/`) - Fresh git repo on `claude` branch, excluded files removed, no history of sensitive data
3. **Work** (`~/.cache/claude-cage/branches/<branch>/work/<project-path>/`) - Clone of intermediary on `claude` branch where Claude works

Each source branch gets its own isolated cache directories, allowing concurrent sessions on different branches. Inside the sandbox, each project's work directory is mounted at its original path, and intermediaries are mounted at `/run<project-path>`, so git origins are accessible there.

Both intermediary and work use a single `claude` branch. Intermediary has `receive.denyCurrentBranch=updateInstead` to allow pushing to the checked-out branch.

### Why Intermediary?

The intermediary repo serves as a buffer:
- Claude's git remote points here, not your source
- Post-receive hook triggers sync to source
- Prevents accidental direct access to source history
- Clean slate - no git history containing excluded files
- Located in `~/.cache/` - no `.gitignore` entry needed in your project

## Source Files

| File | Purpose |
|------|---------|
| `src/header.sh` | Shebang and script header |
| `src/helpers.sh` | `run`, `run_quiet`, color codes, dry-run support |
| `src/banner.sh` | ASCII art banner (print_banner) |
| `src/config-builder.sh` | Interactive config generator when no config exists |
| `src/config.sh` | Lua-based config parsing (system, user, ancestors, local) |
| `src/git-clone.sh` | `create_intermediary_clone()` - archives source with excludes |
| `src/git-hooks.sh` | Git hooks for communication pipe and commit sync |
| `src/git-patches.sh` | Failed patch recovery: save, list, interactive apply |
| `src/git-sync.sh` | `sync_to_source()`, pipe listener, manual merge |
| `src/network.sh` | Network isolation via slirp4netns/iptables |
| `src/mounts.sh` | Shared mount logic for bwrap and docker |
| `src/bwrap.sh` | `run_in_bwrap()` - bubblewrap sandbox |
| `src/docker.sh` | `run_in_docker()` - Docker container sandbox |
| `src/main.sh` | Entry point - wires everything together |

### Build Output

`dist/claude-cage` is the concatenated script. Files are concatenated in dependency order:

1. `header.sh` - Shebang
2. `helpers.sh` - Colors, run/run_quiet, help
3. `banner.sh` - ASCII art
4. `config-builder.sh` - Interactive config
5. `config.sh` - Lua parsing
6. `git-clone.sh` - Intermediary creation
7. `git-hooks.sh` - Hook setup
8. `git-patches.sh` - Patch recovery
9. `git-sync.sh` - Manual merge
10. `network.sh` - Network isolation
11. `mounts.sh` - Shared mount logic
12. `bwrap.sh` - Bwrap sandbox
13. `docker.sh` - Docker sandbox
14. `main.sh` - Orchestration

```bash
make        # Build dist/claude-cage
make clean  # Remove built file
```

## Sync Mechanism

### Outbound (Claude -> Source)

When `autoMerge = true`:

1. Claude makes commits in the work directory
2. Claude runs `git push origin`
3. Intermediary's `post-receive` hook fires
4. Hook writes `<refname> <newrev>` to named pipe (mounted at `/tmp/claude-cage/pipe` inside sandbox)
5. Pipe listener on host reads the message
6. `sync_to_source()` runs:
   - Skips initial commit (just a copy)
   - Uses `git format-patch` on intermediary
   - Applies to source with `git am --3way`

### Inbound (Source -> Intermediary)

When you commit to source:

1. `post-commit` hook on source fires
2. Creates patch excluding sensitive files using pathspec excludes
3. Applies patch to intermediary's `claude` branch with `git am`
4. Claude runs `git pull` when ready to get changes

If commit only contains excluded files, shows: "Only excluded files in this commit, nothin' to sync."

### Commit Separation

`pre-commit` hook on source prevents mixing excluded and included files in the same commit. This ensures patches can be cleanly created without sensitive data.

### Multiple Sessions

Multiple claude-cage sessions can run concurrently on the same project (even on different branches). Session tracking prevents cleanup race conditions:

1. **Session registration** - Each session creates a PID file in `$XDG_RUNTIME_DIR/claude-cage/sessions/<branch>/<path-hash>/`
2. **Hook dispatcher** - Source hooks use a dispatcher pattern (`.git/hooks/post-commit` runs all scripts in `post-commit.d/`)
3. **Branch-specific hooks** - Each branch gets its own hook file: `post-commit.d/claude-cage-<branch>`
4. **Safe cleanup** - Hooks are only removed when no other sessions need them

This means:
- Two sessions on `main` branch share the same hook (safe, content is identical)
- One session on `main`, another on `feature` → separate hooks, no conflict
- Exiting one session doesn't break another session's hooks

### Failed Patch Recovery

When patches fail to apply (conflicts, user switched branches, etc.):

1. Patch is saved to `<source>/claude-cage-failed-patches/<branch>/`
2. Filename includes timestamp and commit subject: `20250131-143022_Fix_bug.patch`
3. At next startup, you get an interactive prompt:

```
Hold up. You've got failed patches waitin' to be applied:

  main: 2 patch(es)
  feature/login: 1 patch(es)

What do you wanna do?
  1) Apply patches one-by-one
  2) Delete all pending patches
  3) Continue without applyin'
  q) Quit
```

**If your working directory is dirty**, option 1 changes to "I've cleaned up - check again" since you need to commit/stash/reset before applying patches.

**When applying patches:**
- Switches to target branch if needed (and back when done)
- Uses `git am --3way` to apply with conflict detection
- On conflict: shows the diff, offers shell access to resolve, skip, or abort
- Successfully applied patches are deleted automatically
- Empty patch directories are cleaned up

## Configuration

Config files are loaded and merged in order (later values override, arrays merge):

| Level | Path | Required? |
|-------|------|-----------|
| System | `/etc/claude-cage.conf` | No |
| User | `~/.config/claude-cage/config` | No |
| Ancestors | `.claude-cage` in any ancestor directory | No |
| Local | `.claude-cage` (current directory) | No |

### Hierarchical Config Resolution

Config walks from the filesystem root down to your current directory, loading any `.claude-cage` files found along the way. This lets you set up shared config for all projects under a directory.

Example for CWD = `/home/user/projects/public/my-app/`:
```
/etc/claude-cage.conf                              (system)
~/.config/claude-cage/config                       (user)
/.claude-cage                                      (if exists)
/home/.claude-cage                                 (if exists)
/home/user/projects/.claude-cage                   (if exists)
/home/user/projects/public/.claude-cage            (if exists)
/home/user/projects/public/my-app/.claude-cage     (local/CWD)
```

Closer configs override farther ones for scalar values. Arrays (like `exclude`) merge across all levels.

**No config?** If no config exists at any level, an interactive builder walks you through creating one. It prompts for sandbox mode, common excludes, auto-merge, and optional tool-specific mounts (e.g., Claude Code's `~/.claude`).

Example `.claude-cage`:

```lua
claude_cage {
    exclude = { ".env", "secrets/**", "application-*.properties" },
    mode = "bwrap",  -- or "docker"
    autoMerge = true,  -- enable real-time sync
    allowNonGit = true,  -- allow non-git directories
    showBanner = true,

    -- Network filtering
    networkMode = "allowlist",  -- "disabled", "allowlist", or "blocklist"
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" },
        networks = { "10.0.0.0/8" }
    },
    block = {
        domains = { "internal.company.com" },
        ips = { "169.254.169.254" }  -- AWS metadata
    }
}
```

Array options (`exclude`, `allow`, `block`, `additionalMounts`) merge across all config levels. Scalar options are overridden by later configs.

### Key Options

| Option | Default | Description |
|--------|---------|-------------|
| `launch` | `"claude"` | Command to run inside sandbox |
| `exclude` | `{}` | Patterns to exclude from archive |
| `mode` | `"bwrap"` | Sandbox mode: `"bwrap"` or `"docker"` |
| `autoMerge` | `false` | Enable real-time sync via named pipe |
| `allowNonGit` | unset | Allow running in non-git directories (see below) |
| `directMount` | `false` | Mount source directly without git sync (see below) |
| `isolated` | `false` | Only mount single project instead of all same-branch projects |
| `showBanner` | `true` | Show ASCII banner |
| `hideConfirmationPrompt` | `false` | Skip the auto-merge info message and key press when autoMerge is off |
| `createCagedDir` | `false` | Create `.caged/` symlinks to branch caches (see below) |
| `additionalMounts` | `{}` | Extra mounts for sandbox (see below) |
| `networkMode` | `"disabled"` | Network filtering: `"disabled"`, `"allowlist"`, `"blocklist"` |
| `allow` | `{}` | Allowed destinations (domains, ips, networks with optional ports) |
| `block` | `{}` | Blocked destinations (domains, ips, networks with optional ports) |
| `dockerImage` | `"node:lts-slim"` | Docker image to use (docker mode only) |

### Direct Mount Mode

By default, claude-cage creates an intermediary clone and uses git to sync changes. But sometimes you just want to sandbox a directory directly - no cloning, no syncing.

**Three ways to trigger direct mount mode:**

1. **`--direct-mount` flag** - CLI option for one-off direct mount
2. **`directMount = true`** - Config option to always mount source directly (even for git repos)
3. **`allowNonGit = true`** - Allow non-git directories (triggers direct mount automatically)

| Option | Default | Behavior |
|--------|---------|----------|
| `directMount` | `false` | When `true`, always mount source directly without git sync |
| `allowNonGit` | unset | When `true`, allow non-git dirs. When `false`, require git. When unset, prompt. |

**Note:** `allowNonGit` only applies when you're truly outside a git repo. Subdirectories inside a git repo are still detected as git repos and run in normal git mode. Use `directMount` or `--direct-mount` if you want direct mount inside a git repo.

**In direct mount mode:**
- The source directory is mounted directly into the sandbox (read-write)
- No intermediary or work directory is created
- No git hooks or sync mechanism
- Changes made inside the sandbox immediately affect the source files
- `autoMerge`, `createCagedDir`, and `exclude` are ignored

**Example configs:**

```lua
-- Skip git sync entirely, even for git repos
claude_cage {
    directMount = true,
    mode = "bwrap"
}

-- Allow non-git directories (direct mount triggered automatically)
claude_cage {
    allowNonGit = true,
    mode = "bwrap"
}
```

If `allowNonGit` is unset and you run claude-cage in a non-git directory, you'll be prompted to mount it directly. The setting isn't saved automatically - you'll see where to add `allowNonGit = true` in your config to skip the prompt next time.

### Additional Mounts

The `additionalMounts` option lets you mount extra paths into the sandbox. By default, mounts are read-only. Use `mode = "rw"` for writable mounts.

```lua
claude_cage {
    additionalMounts = {
        -- Simple string (read-only, same path inside sandbox)
        "~/.gitconfig",

        -- Object with source and destination
        { source = "~/.ssh", as = "~/.ssh" },

        -- Writable mount (required for Claude Code's ~/.claude directory)
        { source = "~/.claude", mode = "rw" },
        { source = "~/.claude.json", mode = "rw" },
    }
}
```

| Field | Description |
|-------|-------------|
| `source` | Path on host (supports `~` expansion) |
| `as` / `dest` | Path inside sandbox (defaults to source) |
| `mode` | `"ro"` (default) or `"rw"` |

### Caged Directory Shortcuts

When `createCagedDir = true`, claude-cage creates a `.caged/` directory in your project root with symlinks to each branch's cache directories. This provides easy visibility into your sandboxed branches without changin' where the actual storage lives.

```
project/.caged/
├── .gitignore           # Self-ignoring: contains "* \n !.gitignore"
├── main/
│   ├── work         → ~/.cache/claude-cage/branches/main/work/<project-path>/
│   └── intermediary → ~/.cache/claude-cage/branches/main/intermediary/<project-path>/
├── feature--foo/
│   ├── work         → ~/.cache/.../branches/feature--foo/work/<project-path>/
│   └── intermediary → ~/.cache/.../branches/feature--foo/intermediary/<project-path>/
```

**Benefits:**
- `ls .caged/` shows all caged branches at a glance
- `ls .caged/<branch>/` shows work and intermediary - exactly what you need to poke around
- Symlinks point directly to project-specific paths (no noise from other projects)
- `rm -rf .caged/` only removes symlinks, actual cache data stays safe
- Multi-project visibility preserved (storage still in `~/.cache/`)
- Defense in depth: both self-ignoring `.gitignore` AND config builder offers to add to root `.gitignore`

**Note:** The `.caged/` directory contains a self-ignoring `.gitignore`, so it won't pollute your git status. The config builder also offers to add `.caged/` to your project's root `.gitignore` for extra insurance.

## CLI Usage

```bash
# Basic usage - creates intermediary + work, shows sandbox info
./claude-cage

# Pass arguments through to launch command
./claude-cage --resume
./claude-cage --dangerously-skip-permissions

# Drop into sandbox shell for testing
./claude-cage --test

# Direct mount - skip git sync, mount source directly
./claude-cage --direct-mount

# Manual merge (fetch refs from intermediary)
./claude-cage git-merge

# Clean up cached branches
./claude-cage clean                    # Interactive selection
./claude-cage clean --branch main      # Specific branch
./claude-cage clean-all                # All branches for this project

# Shell completions
./claude-cage completion bash          # Output bash completion script
./claude-cage completion zsh           # Output zsh completion script
./claude-cage install-completions      # Auto-install completions for current shell

# Dry run (show commands without executing)
./claude-cage --dry-run

# Verbose output
./claude-cage --verbose
./claude-cage -v

# Debug mode (verbose + show command output)
./claude-cage --debug
```

### Shell Completions

The `install-completions` command auto-detects your shell and installs completions:

| Shell | Completion File |
|-------|-----------------|
| Bash | `~/.local/share/bash-completion/completions/claude-cage` |
| Zsh | `~/.zsh/completions/_claude-cage` |

For Zsh, the installer will offer to add the completions directory to your `fpath` in `~/.zshrc` if needed.

## Current State

### Implemented

- [x] Config parsing (Lua-based, same as main claude-cage)
- [x] `create_intermediary_clone()` - git ls-files + tar with excludes
- [x] Fresh git init (no history of excluded files)
- [x] Work directory clone with `claude` branch
- [x] `run_in_bwrap()` - full bwrap sandbox
- [x] `run_in_docker()` - Docker container sandbox
- [x] Named pipe communication (`$XDG_RUNTIME_DIR/claude-cage/pipes/`)
- [x] `post-receive` hook on intermediary
- [x] `sync_to_source()` using format-patch/git-am
- [x] Pipe listener background process
- [x] `pre-commit` hook (prevents mixed commits)
- [x] `post-commit` hook (syncs source -> intermediary)
- [x] `manual_git_merge()` for manual sync
- [x] Cleanup on exit
- [x] `receive.denyCurrentBranch=updateInstead` for push to checked-out branch
- [x] Network isolation via slirp4netns (bwrap mode, no sudo required)
- [x] Comprehensive test suite (155 tests across 12 files)
- [x] Cache-based directory structure (`~/.cache/claude-cage/`) - no .gitignore needed
- [x] Multi-project visibility (same-branch projects see each other in sandbox)
- [x] Subdirectory support (run from any subdirectory, hooks install at git root)
- [x] Sparse checkout support (only copies files that exist in working tree)
- [x] Optional `.caged/` symlinks for easy cache access (`createCagedDir` option)
- [x] Shell completions for bash and zsh (`completion` and `install-completions` commands)
- [x] Cache cleanup commands (`clean`, `clean --branch`, `clean-all`)
- [x] Direct mount mode for non-git directories or skipping git sync

### Known Issues / TODO

- [x] Configurable launch command (defaults to `claude`, use `--test` for shell)
- [x] Build script (`make`) - concatenates src/ to dist/
- [x] Instance tracking (multiple concurrent runs via session PIDs)
- [x] Network filtering for Docker mode (uses iptables with privilege drop)
- [x] Shell completions (bash and zsh)
- [x] Clean commands for cache management
- [ ] Testing on actual Claude Code workflow
- [ ] More graceful conflict resolution when git-am fails

## Network Isolation

Both bwrap and Docker modes support network filtering using iptables. Same config options work for both.

### bwrap mode (Linux / WSL 2)

Uses slirp4netns to create an isolated network namespace, then configures iptables inside that namespace. No root/sudo required.

### Requirements

- `slirp4netns` - Install: `sudo apt install slirp4netns`
- `iptables` - Usually pre-installed
- **Unprivileged user namespaces** - Must be enabled in kernel

To check/enable user namespaces:
```bash
# Check current setting (1 = enabled)
cat /proc/sys/kernel/unprivileged_userns_clone

# Enable temporarily
sudo sysctl -w kernel.unprivileged_userns_clone=1

# Enable permanently
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/userns.conf
sudo sysctl --system
```

### How It Works

1. **Domain resolution on host** - Domains in `allow`/`block` are resolved to IPs before entering namespace (uses `getent ahosts`, supports `/etc/hosts`)
2. Creates user+network namespace via `unshare --user --map-root-user --net`
3. Attaches slirp4netns to provide network connectivity
4. Configures iptables rules (we have CAP_NET_ADMIN inside the namespace)
5. Drops into bwrap sandbox (which drops all capabilities)

**Host loopback access:** Rules targeting `127.0.0.1` are automatically translated to `10.0.2.2` (slirp4netns host gateway) so you can allow access to services on your host machine.

### slirp4netns Address Mapping

| Address | Maps to |
|---------|---------|
| 10.0.2.2 | Host loopback (127.0.0.1) |
| 10.0.2.3 | DNS resolver |
| 10.0.2.15 | Sandbox's own IP |

### Network Modes

| Mode | Behavior |
|------|----------|
| `disabled` | No network filtering (default) |
| `allowlist` | Block everything except specified destinations |
| `blocklist` | Allow everything except specified destinations |

### Port Syntax

Destinations can include optional ports:
- `github.com:443` - Single port
- `192.168.1.0/24:80,443` - Multiple ports
- `10.0.0.1` - All ports

### Docker mode (Linux / WSL 2 / macOS)

Docker mode supports network filtering using iptables. Works everywhere Docker runs.

### How It Works

1. Container starts as root with `--cap-add=NET_ADMIN`
2. Configures iptables rules (same allowlist/blocklist logic as bwrap)
3. Drops to unprivileged user via `su`
4. User cannot modify iptables rules (no root, no NET_ADMIN)

### Security Model

- `NET_ADMIN` capability is scoped to the container's network namespace
- Container cannot modify host's iptables
- After privilege drop, the running user has no way to change the rules
- Same effective security as bwrap mode

### Docker DNS

Docker's internal DNS resolver is at `127.0.0.11`. This is automatically allowed in both allowlist and blocklist modes so domain resolution works.

### Configuration

Same config options as bwrap mode:

```lua
claude_cage {
    mode = "docker",
    networkMode = "allowlist",
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" }
    }
}
```

## File Locations

```
~/.cache/claude-cage/
└── branches/
    └── <branch>/                         # Sanitized branch name (e.g., "main", "feature--foo")
        ├── intermediary/<project-path>/  # Sanitized repo (git origin for work)
        │   └── .git/hooks/post-receive   # Triggers sync
        ├── work/<project-path>/          # Claude's working directory
        └── state-<path-hash>             # Last processed source commit ID (12-char md5)

$XDG_RUNTIME_DIR/claude-cage/           # Runtime files (typically /run/user/$UID/)
├── pipes/<branch>/<project-path>       # Named pipe for communication
└── sessions/<branch>/<path-hash>/      # Session tracking (PID files)
    └── <pid>                           # One file per active session

project/
├── .claude-cage                        # Project config file (optional with ancestors)
├── .caged/                             # Optional symlinks to cache (createCagedDir = true)
│   ├── .gitignore                      # Self-ignoring (* and !.gitignore)
│   └── <branch>/                       # One directory per caged branch
│       ├── work         → ~/.cache/.../work/<project-path>/
│       └── intermediary → ~/.cache/.../intermediary/<project-path>/
└── .git/hooks/
    ├── pre-commit                      # Dispatcher (runs all in pre-commit.d/)
    ├── pre-commit.d/
    │   └── claude-cage-<branch>        # Branch-specific hook
    ├── post-commit                     # Dispatcher (runs all in post-commit.d/)
    └── post-commit.d/
        └── claude-cage-<branch>        # Branch-specific hook
```

### Sandbox Mount Structure

Inside the sandbox, directories are mounted to preserve original paths:

| Host Path | Sandbox Path | Purpose |
|-----------|--------------|---------|
| `branches/<branch>/work/` | `/` | All same-branch work dirs visible at original paths |
| `branches/<branch>/intermediary/` | `/run` | All same-branch intermediaries as git origins |
| Named pipe | `/tmp/claude-cage/pipe` | Git hook communication |

This means if you have projects at `/home/user/project-a` and `/home/user/project-b` on the same branch, both are visible inside the sandbox at their original paths, and their git origins are at `/run/home/user/project-a` and `/run/home/user/project-b`.

With `isolated = true`, only the single project's work and intermediary are mounted.

Branch names are sanitized for filesystem paths: `/` becomes `--`, other special chars become `-`.

### Environment Variables

**User-configurable:**
- `CLAUDE_CAGE_CACHE` - Override cache directory (default: `~/.cache/claude-cage`)
- `CLAUDE_CAGE_RUNTIME` - Override runtime directory (default: `$XDG_RUNTIME_DIR/claude-cage`)
- `CLAUDE_CAGE_BRANCH` - Override branch name for path construction (auto-detected from source)

**Internal (set by claude-cage):**
- `CLAUDE_CAGE_SOURCING` - Set to `1` when sourcing script for function definitions only
- `SLIRP_NETWORK` - Set to `1` inside slirp4netns network namespace
- `BWRAP_REAL_UID`, `BWRAP_REAL_GID`, `BWRAP_REAL_USER`, `BWRAP_REAL_HOME` - Capture real user info before entering network namespace

## Debugging

```bash
# Verbose mode shows all commands
./claude-cage --verbose --test

# Debug mode shows command output (not just commands)
./claude-cage --debug --test

# Check what would run without executing
./claude-cage --dry-run
```

## Testing

Run the test suite:
```bash
bash tests/run-all.sh
```

| Test File | Component | Tests |
|-----------|-----------|-------|
| test-helpers.sh | helpers.sh | 7 |
| test-config.sh | config.sh | 12 |
| test-banner.sh | banner.sh | 6 |
| test-git-clone.sh | git-clone.sh | 14 |
| test-git-hooks.sh | git-hooks.sh | 10 |
| test-git-patches.sh | git-patches.sh | 12 |
| test-git-sync.sh | git-sync.sh | 14 |
| test-network.sh | network.sh | 31 |
| test-bwrap.sh | bwrap.sh | 13 |
| test-docker.sh | docker.sh | 17 |
| test-clean.sh | clean commands | 11 |
| test-direct-mount.sh | direct mount mode | 8 |

**Total: 155 tests across 12 files**

Note: bwrap execution tests are skipped if user namespaces are unavailable.

## Next Steps

1. Test full workflow with actual Claude Code session
2. Handle git-am conflicts more gracefully (currently saves to failed-patches)

## Gotchas / Technical Notes

### Git Pathspec Excludes

When using git pathspec to exclude files (e.g., in `git format-patch`), be aware:

- **`:!pattern` vs `:(exclude,glob)pattern`**: The short form `:!**/foo` does NOT match `foo` at the repository root. The `**` only matches one or more directories, not zero. Use `:(exclude,glob)**/foo` for proper glob behavior where `**` matches zero or more directories.

- **Don't use `.` before excludes**: `git format-patch -- . :!pattern` breaks exclude matching. Use `git format-patch -- :!pattern` instead.

- **`-1 HEAD` vs `HEAD~1..HEAD`**: When pathspec excludes all files from a commit, `git format-patch -1 HEAD -- :!pattern` outputs the parent commit instead of empty. Use `HEAD~1..HEAD` for correct behavior.

### Branch-Switching Sync

When syncing commits from intermediary to source, if the user has switched branches:
- We use a temp index (`.git/claude-cage-tmp-index`) to apply changes without checkout
- Commits are applied to the original branch the user started on
- User's current checkout remains untouched

## Voice/Style

All user-facing text uses Nic Cage's voice from Con Air. This applies to:

- **Commit messages** - The subject line only, not the body/details below
- **README.md** - Prose text only (not example code, config, or comments within code blocks)
- **Tool output in source code** - Echo statements, error messages, banners

Example commit: `Cleanin' house - this is the main show now`

Example output: `Hold on now. I need bubblewrap (bwrap) installed for sandboxing.`

This does NOT apply to:
- Code comments
- Other documentation files (just README.md)
- Config examples
- Technical error messages from git/system commands
