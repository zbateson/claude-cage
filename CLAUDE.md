# CLAUDE.md

Lightweight sandboxed git workflow for Claude Code. Creates an isolated copy of your project (excluding sensitive files) via git fast-export/fast-import, syncs changes back via format-patch/git-am. No sudo required. Supports bwrap (Linux/WSL2) and Docker (all platforms) sandbox modes. Network filtering via iptables (optional).

## Architecture

```
Source Project                    ~/.cache/.../intermediary        ~/.cache/.../work
(your actual repo)                (bare repo, shared)              (Claude's workspace)
       │                                   │                              │
       │  fast-export + pathspec excludes   │     git clone                │
       │  (excludes stripped, N commits)   │                              │
       └──────────────────────────────────>│──────────────────────────────>
                                           │                              │
                                           │<────── git push ─────────────┤
                                           │     (Claude commits)         │
                                           │                              │
       │<──── format-patch/git-am ─────────┤                              │
       │     (via named pipe)              │                              │
```

### Three-Repository Model

1. **Source** — Your actual project with full git history
2. **Intermediary** (`~/.cache/claude-cage/intermediary/<project-path>/`) — Persistent bare repo with real commit history (configurable depth). Excluded file content is filtered via `:(exclude,glob)` pathspec during fast-export. Acts as a buffer: Claude's git remote points here, not your source. Post-receive hook triggers sync to source via named pipe. Persistent across sessions, only rebuilt when exclude patterns change.
3. **Work** (`~/.cache/claude-cage/sessions/<timestamp>/work/<project-path>/`) — Clone of intermediary where Claude works. Per-session (timestamp-identified), allowing concurrent sessions.

The intermediary is created by `create_intermediary_clone()` using `git fast-export` with `:(exclude,glob)` pathspec piped into `git fast-import`. Key properties:
- **1:1 commit mapping**: Every source commit maps to exactly one intermediary commit (or `0` for excluded-only commits)
- **Incremental updates**: Existing intermediaries updated via `--import-marks`/`--export-marks`
- **Exclude hash tracking**: Intermediary rebuilt automatically if exclude patterns change

Inside the sandbox, work directories are mounted at their original paths, intermediaries at `/run<intermediary-path>`.

## Source Files

| File | Purpose |
|------|---------|
| `src/header.sh` | Shebang and script header |
| `src/helpers.sh` | `run`, `run_quiet`, color codes, dry-run support |
| `src/banner.sh` | ASCII art banner (print_banner) |
| `src/config-builder.sh` | Interactive config generator when no config exists |
| `src/config.sh` | Lua-based config parsing (system, user, includeIf, local) |
| `src/git-clone.sh` | `create_intermediary_clone()`, `build_exclude_pathspecs()` — bare repo via fast-export/fast-import with pathspec excludes |
| `src/git-hooks.sh` | Git hooks for communication pipe and commit sync |
| `src/git-patches.sh` | Failed patch recovery: save, list, interactive apply |
| `src/git-sync.sh` | `sync_to_source()`, `copy_carry_files()`, pipe listener, manual merge |
| `src/network.sh` | Network isolation via slirp4netns/iptables |
| `src/mounts.sh` | Shared mount logic for bwrap and docker |
| `src/bwrap.sh` | `run_in_bwrap()` — bubblewrap sandbox |
| `src/docker.sh` | `run_in_docker()` — Docker container sandbox |
| `src/main.sh` | Entry point — wires everything together |

## Build

```bash
make        # Concatenates src/*.sh → dist/claude-cage (dependency order)
make clean  # Remove built file
```

## Sync Mechanism

### Outbound (Claude → Source)

When `autoSync = true` (default): Claude commits + pushes → intermediary's `post-receive` hook writes to named pipe → pipe listener calls `sync_to_source()` → walks `oldrev..newrev`, skips commits already in mapping (loop prevention), applies each via `git format-patch` + `git am --3way` (same branch) or temp-index + `git update-ref` (user switched branches). New branches created on source from mapped parent. If user is on the target branch and `syncActiveBranch` is not `true`: skip (suggest `claude-cage git-merge`). With `syncActiveBranch`: stash/apply/pop cycle around the sync.

### Inbound (Source → Intermediary)

Source `post-commit` / `post-merge` hooks fire → check commit mapping (skip if already mapped) → call `claude-cage-sync-commit` helper → `git fast-export -1 <hash>` with pathspec excludes to temp file → detect excluded-only commits (no `commit` or no `from` line) → if valid, `git fast-import` on intermediary → update marks + commit mapping. Claude runs `git pull` when ready.

### Sessions

One canonical shared session named `default` lives at `$CACHE/sessions/default/`. Every project joins it by, well, default. The rare case where this project is already running in `default` falls back to a **per-project alternate** at `$CACHE/sessions/<project-key>-<N>/` (`<project-key>` is `<basename>-<6-hex-md5-of-source>`). `N` is picked at allocation time by scanning existing `<project-key>-*` dirs and taking `max(N) + 1` (or `2` if none) — no persistent counter, so slots recycle once every alternate has exited. The atomic claim is via `mkdir`; concurrent racers retry on the next available `N`.

`select_session` (`src/git-clone.sh`) collapses the whole flow to a single decision: `--attach-session` resolves a user-facing name (`default`, `session.N`, or a legacy timestamp) to its cache id; otherwise check whether `default` has a live PID for this `source_dir`; if not, land in `default`; if so, prompt over inactive dirty alternates for the project (or allocate a fresh one).

PID-based session tracking still lives at `$XDG_RUNTIME_DIR/claude-cage/sessions/<session-id>/<pid>` (file content = `source_dir`). `session_is_active_for_source` is the source-scoped liveness check.

Display layer: every user-facing surface (`Joinin'…`, dirty prompt, `claude-cage clean` listings, `.caged/sessions/<name>/`, completions) renders via `display_session_name`, which maps `default` → `default`, `<project-key>-<N>` → `session.<N>`, and passes anything else (legacy timestamps, unknown formats) through unchanged.

**Cleanup contract.** Default's work dir is preserved on clean exit for reuse next time (existing match-clean tear-down still applies for dirty-matching-source). Alternates are ephemeral: clean exit (or dirty-matching-source) tears the whole alternate session dir down — runtime PID dir, log file, and `.caged` sidecar — so the slot is immediately recyclable. A dirty alternate is left for the next startup's prompt.

**Mount layering.** `enumerate_projects` scans `$CACHE/sessions/default/work` for cross-project visibility regardless of which session we're actually in (see `get_default_work_root`). When in an alternate, the alternate's own `work_dir` is the first `CAGE_WORK_PROJECTS` entry and wins for its own `project_path`; other projects come from `default`'s tree. When in `default`, the scan trivially produces the same set.

**`isolated = true`** opts a project into its own dedicated session at `$CACHE/sessions/<project-key>-isolated/`. The user-facing label is `isolated`. Key properties:

- The isolated session never mounts default's work tree (mount layering's cross-project visibility is skipped via the existing `cfg_isolated` branches in `enumerate_projects` / `build_mount_specs`).
- The isolated project never enters default's tree, so other projects running in default never see it either.
- Stickiness: `select_session` treats the project as isolated when *either* `cfg_isolated=true` *or* `$CACHE/sessions/<project-key>-isolated/` already exists. Removing `isolated = true` from config doesn't accidentally re-expose the project's work — the isolated cache wins and `cfg_isolated` is force-set true at runtime. To genuinely un-isolate, run `claude-cage clean isolated` and start over.
- Canonical-vs-alternate semantics still apply: the isolated session is the canonical session for that project (preserved on clean exit, like default), and alternates allocated when it's busy follow the normal `<project-key>-N` numbering (torn down on clean exit).
- Symmetry: the isolation works in both leak directions. Users with mostly-public projects use it to keep work files out of OSS cages. Users with a single private-secrets project use it to keep secrets out of their other cages. Same mechanism either way: don't participate in default.

`resolve_session_name "isolated" "$source_dir"` → `<project-key>-isolated`. `display_session_name` maps the cache id back to `isolated`. Both `--attach-session isolated` and `claude-cage clean isolated` work via the same name pair. The on-disk name embeds the project key so `claude-cage clean` listings across multiple isolated projects stay unambiguous.

**Migration.** Pre-existing timestamp-named sessions (`2026-05-16_09-22-31/`) are ignored by discovery (`select_session` never auto-joins them) but remain visible to `claude-cage clean`. `display_session_name` passes them through unchanged so listings stay readable. Users do a `claude-cage clean --all` post-upgrade if they want a clean slate.

`--attach-session` keeps working in both forms: with no arg, it lists every attachable session (`default` + each on-disk alternate for this project) and prompts; with a name, it accepts `default` / `session.N` / legacy timestamp.

### Failed Patches

When `git am` fails, patches are saved to `<source>/claude-cage-failed-patches/from-intermediary/<branch>/`. At next startup, an interactive prompt offers to apply, delete, or skip them.

### Startup Dirty Carry

Independent of `syncActiveBranch`. When `bringDirty = true` (or `--with-dirty` is passed), `copy_dirty_files_to_work` walks `git status --porcelain -z` on the source and replays modifications, deletions, renames, and untracked files into the cage work dir. Skipped if the work is already dirty (reused session) or if we're attaching. Default is off — when source is dirty but the flag isn't set, startup prints a one-line hint pointing at `--with-dirty` / `bringDirty`. Exclude patterns are applied via `build_exclude_pathspecs`.

`enumerate_source_dirty_pairs` is the shared porcelain-walk helper: it emits NUL-separated `(src_path, dest_path)` records (scope-translated, renames expanded to delete+create). `copy_dirty_files_to_work` consumes the stream and acts; `work_matches_source_dirty` consumes the same stream to verify content equivalence via `cmp -s` plus a separate work-side porcelain walk to confirm the cage has no dirty paths outside source's set.

### Match-Clean Exit

`cleanup_on_exit` calls `work_matches_source_dirty` for any cage that's exiting dirty (with no unpushed commits). If every dirty path in the cage matches the source byte-for-byte, the cage is torn down via `cleanup_current_session_workdir` — nothing's lost because source already holds every change. Triggers in both the `has_other_sessions=true` branch and the solo-session branch; the solo path only cleans on a match (clean solo work dirs are still preserved for reuse).

### Subdir Auto-Routing

When `claude-cage` is invoked from a subdir of a git repo without `--scoped`, `main.sh` detects the situation (via `git rev-parse --show-toplevel`) and either silently routes `cfg_source` to the git root or prompts. The route-vs-prompt decision is driven by `is_caged_repo` (`src/git-clone.sh`), which returns true on any of: `.claude-cage` config at the root, an existing `$CACHE/intermediary$git_root/`, or a `repos.list` entry. The relative subpath is stashed in `cage_start_subdir`, which `run_in_bwrap` / `run_in_docker` append to `project_path` for `--chdir` / `-w`, so the shell starts at the original invocation cwd inside the cage. Non-interactive invocations from a fresh subdir exit with a hint rather than guessing intent.

### Dirty-Session Context Block

When the dirty-session prompt fires (`src/main.sh` in the `"dirty"` branch), `print_session_context` (`src/git-clone.sh`) renders up to three subsections before the choice menu so the user can decide informed: the latest synced commit from source (`git log --oneline -1`), unpushed commits in the cage (`git log --oneline origin/<branch>..HEAD`, truncated to 20), and workspace state (`git status --short`, truncated to 20). Each subsection is suppressed when empty; failures in any of the three queries are silently skipped so a damaged work dir still gets a prompt. In the multi-dirty branch, only the latest entry's context is surfaced (labelled `Latest session (<id>):`) to keep the prompt scannable.

### Index-Refresh in Dirty Classifiers

`is_work_dirty` (`src/git-clone.sh`) and `source_is_dirty` (`src/git-sync.sh`) call `git update-index --refresh -q --unmerged` before reading `git status --porcelain`. The refresh is silent on the happy path and idempotent; it kills false-positive "dirty" classifications when the index's stat cache is stale relative to the working tree (suspend/resume, file-mode flips, backup restores, content-preserving `touch`).

### Scoped Work-Dir Tree

Work dirs are routed by scope the same way intermediaries are. Unscoped runs land at `$CACHE/sessions/<id>/work$source_dir/`; scoped runs land in a sibling tree at `$CACHE/sessions/<id>/scoped$git_root/$scope_path/`. This parallels the intermediary side's `intermediary/` vs `scoped/.bare/` split and prevents scoped work dirs from nesting inside their unscoped siblings under the same git root. Three helpers in `src/git-clone.sh` compute the path:

- `get_scoped_work_path(source_dir, scope_path)` — current session.
- `session_work_dir(session_dir, source_dir, git_root)` — arbitrary session, scope inferred from `source_dir` vs `git_root`.
- `session_work_dir_by_scope(session_dir, source_dir, scope_path)` — arbitrary session when scope is already known (e.g. iterating `REUSE_*_SESSIONS` entries or cached_sessions output).

Cleanup helpers (`cleanup_current_session_workdir`, `cleanup_stale_sessions`, `clean_session_cache`) walk both `work/` and `scoped/` trees so empty parents in either get pruned. Session discovery (`find_reusable_session`, `list_cached_sessions`, completion scanners in `src/helpers.sh`) checks both trees too.

## Configuration

Config files loaded and merged in order (later values override, arrays merge): system (`/etc/claude-cage.conf`) → user (`~/.config/claude-cage/config`) → includeIf (directory-scoped, declared in system/user config) → local (`.claude-cage` at git root). No config triggers an interactive builder.

Example `.claude-cage`:

```lua
claude_cage {
    exclude = { ".env", "secrets/**", "application-*.properties" },
    carry = {
        "CLAUDE.md",                                          -- same path in source and work
        { source = "config/instructions.md", as = "CLAUDE.md" },  -- different dest in work
    },
    mode = "bwrap",  -- or "docker"
    autoSync = true,
    -- syncActiveBranch = false,  -- EXPERIMENTAL: also sync active branch (stash/apply/pop)
    -- bringDirty = false,  -- copy uncommitted source files into the cage at startup
    showBanner = true,

    networkMode = "allowlist",  -- "disabled", "allowlist", or "blocklist"
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" },
        networks = { "10.0.0.0/8" }
    },
    block = {
        domains = { "internal.company.com" },
        ips = { "169.254.169.254" }
    },

    git = {
        historyDepth = 50,
        defaultBranch = "auto",
        blockForceAdd = true,
    },

    bwrap = {
        systemMounts = { "/etc", "/usr", "/bin", "/lib", "/lib64", "/sbin" },
        maskPaths = {
            "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/sudoers.d",
            "/etc/ssl/private", "/etc/pki/tls/private", "/etc/pki/nssdb",
            "/etc/letsencrypt", "/etc/security",
            "/etc/openvpn", "/etc/wireguard", "/etc/ipsec.d", "/etc/ipsec.secrets",
            "/etc/NetworkManager/system-connections", "/etc/wpa_supplicant", "/etc/ppp",
            "/etc/docker", "/etc/samba", "/etc/krb5.keytab", "/etc/machine-id",
        },
    },

    additionalMounts = {
        "~/.gitconfig",
        { source = "~/.claude", mode = "rw" },
    },
}
```

### Key Options

| Option | Default | Description |
|--------|---------|-------------|
| `launch` | `"claude"` | Command to run inside sandbox |
| `exclude` | `{}` | Patterns to exclude from intermediary |
| `carry` | `{}` | Files copied source↔work at startup/exit. String or `{ source, as/dest }` table. |
| `mode` | `"bwrap"` | Sandbox mode: `"bwrap"` or `"docker"` |
| `autoSync` | `true` | Real-time sync of non-active branches via named pipe |
| `syncActiveBranch` | `false` | **EXPERIMENTAL** Also sync active branch (stash/apply/pop) |
| `bringDirty` | `false` | Copy uncommitted source files into the cage at startup (CLI: `--with-dirty`) |
| `allowNonGit` | unset | Allow non-git directories (triggers direct mount) |
| `directMount` | `false` | Mount source directly, skip git sync entirely |
| `isolated` | `false` | Route this project to its own sealed `<project-key>-isolated` session instead of the shared `default`. The isolated session never mounts default's work tree, and other projects in default never see the isolated one — works in both leak directions (sensitive content in *this* project shouldn't reach others, or sensitive content in *other* projects shouldn't reach this one). Sticky: once an isolated cache exists, the project keeps using it even if the flag is removed, until the cache is cleaned. |
| `showBanner` | `true` | Show ASCII banner |
| `hideConfirmationPrompt` | `false` | Skip confirmation prompt before entering sandbox |
| `createCagedDir` | `false` | Create `.caged/` symlinks to session caches |
| `additionalMounts` | `{}` | Extra mounts (`source`, `as`/`dest`, `mode: "ro"/"rw"`) |
| `networkMode` | `"disabled"` | `"disabled"`, `"allowlist"`, or `"blocklist"` |
| `allow` / `block` | `{}` | Network destinations (domains, ips, networks with optional ports) |
| `bwrap.systemMounts` | `{"/etc", "/usr", "/bin", "/lib", "/lib64", "/sbin"}` | Host dirs mounted read-only in bwrap mode |
| `bwrap.maskPaths` | *(see below)* | Sensitive host paths masked (dirs→tmpfs, files→/dev/null) |
| `docker.image` | `"node:lts-slim"` | Docker image (docker mode only) |
| `docker.packages` | `{"curl", "iputils-ping"}` | Packages to install in Docker container |
| `git.historyDepth` | `50` | First-parent depth on default branch |
| `git.defaultBranch` | `"auto"` | Branch for history anchoring |
| `git.blockForceAdd` | `true` | Block commits with force-added gitignored files |

Array options (`exclude`, `carry`, `allow`, `block`, `additionalMounts`, `docker.packages`, `bwrap.systemMounts`, `bwrap.maskPaths`) merge across config levels. Scalar options are overridden by later configs.

## CLI Usage

```bash
./claude-cage                                      # Basic usage
./claude-cage --resume                             # Pass args to launch command
./claude-cage --test                               # Shell inside sandbox
./claude-cage --direct-mount                       # Skip git sync
./claude-cage --with-dirty                         # Carry uncommitted source files into the cage
./claude-cage git-merge [<branch>|--all]            # Sync intermediary commits to source
./claude-cage --attach-session [default|session.N] # Attach to a session (no arg = pick)
./claude-cage clean [default|session.N|--all]      # Clean cached sessions
./claude-cage completion bash|zsh                  # Output completion script
./claude-cage install-completions                  # Auto-install completions
./claude-cage --dry-run                            # Show commands without executing
./claude-cage --verbose|-v                         # Verbose output
./claude-cage --debug                              # Verbose + show command output
```

## File Locations

```
~/.cache/claude-cage/
├── intermediary/<project-path>/          # Shared bare repo (unscoped)
├── scoped/<git-root>/<scope-path>/.bare/ # Scoped bare repo
│   ├── hooks/{post-receive,pre-receive}
│   ├── claude-cage-commit-map            # <intermediary-hash> <source-hash>
│   ├── claude-cage-{source,import}-marks # Fast-export/import marks
│   ├── claude-cage-source-branches       # Source branch names (pre-receive guard)
│   ├── claude-cage-exclude-hash          # Rebuild detection
│   └── sync.log
├── logs/<session-id>.log                 # Per-session operational log
└── sessions/
    ├── default/                          # Canonical shared session (every project joins by default)
    │   ├── work/<project>/               # Unscoped work dir
    │   └── scoped/<git-root>/<scope>/    # Scoped work dir (sibling tree)
    ├── <basename>-<6hex>-isolated/       # Per-project sealed session when isolated = true (no default mount)
    │   ├── work/<project>/
    │   └── scoped/<git-root>/<scope>/
    └── <basename>-<6hex>-<N>/            # Per-project alternate (e.g. claude-cage-a3f7b2-2)
        ├── work/<project>/
        └── scoped/<git-root>/<scope>/

$XDG_RUNTIME_DIR/claude-cage/
├── pipes/<session-id>/<project-path>     # Named pipe
└── sessions/<session-id>/<pid>            # Session tracking (content = source_dir)

project/.git/hooks/
├── post-commit.d/claude-cage-<hash>      # Source→intermediary sync
└── post-merge.d/claude-cage-<hash>       # Merge sync
```

### Environment Variables

**User-configurable:** `CLAUDE_CAGE_CACHE` (cache dir), `CLAUDE_CAGE_RUNTIME` (runtime dir), `CLAUDE_CAGE_SESSION` (session ID), `CLAUDE_CAGE_MOUNTED_PIPE` (pipe path in hooks), `CLAUDE_CAGE_ALLOW_IGNORED` (override blockForceAdd).

**Internal:** `CLAUDE_CAGE_VERSION`, `CLAUDE_CAGE_SOURCING` (sourcing for function defs), `CLAUDE_CAGE_SYNCING` (suppress hook re-sync during git-am), `SLIRP_NETWORK` (inside slirp namespace), `BWRAP_REAL_{UID,GID,USER,HOME}` (real user info in network namespace).

## Testing

```bash
bash tests/run-all.sh
```

| Test File | Component | Tests |
|-----------|-----------|-------|
| test-helpers.sh | helpers.sh | 7 |
| test-config.sh | config.sh | 28 |
| test-banner.sh | banner.sh | 6 |
| test-git-clone.sh | git-clone.sh | 34 |
| test-git-filter-stream.sh | pathspec exclude filtering | 23 |
| test-git-hooks.sh | git-hooks.sh | 29 |
| test-git-patches.sh | git-patches.sh | 13 |
| test-git-sync.sh | git-sync.sh | 82 |
| test-network.sh | network.sh | 1 |
| test-bwrap.sh | bwrap.sh | 15 |
| test-docker.sh | docker.sh | 18 |
| test-clean.sh | clean commands | 16 |
| test-direct-mount.sh | direct mount mode | 8 |
| test-scoped.sh | scoped intermediary | 70 |
| test-session-log.sh | per-session logging | 17 |
| test-cross-session.sh | cross-project session sharing | 11 |
| test-subdir-routing.sh | subdir auto-routing | 10 |
| test-session-naming.sh | session naming + allocation | 19 |

**~407 assertions across 18 files.** bwrap tests skipped if user namespaces unavailable.

## Documentation surfaces

When the user says "update the docs" (or any phrase about documentation), it refers to **all** of these — keep them in sync:

| File | Audience | What it covers |
|------|----------|----------------|
| `README.md` | End users | Prose intro, getting started, feature explanations, CLI reference, troubleshooting. Con Air voice. |
| `CLAUDE.md` | This file | Architecture, internals, design rationale, build/test commands, file map. Technical voice. |
| `.claude-cage.example` | End users | Annotated project-level config template. Every option commented inline. |
| `examples/example-user-config` | End users | User-level config template (`~/.config/claude-cage/config`) with includeIf usage. |
| `examples/example-system-config` | End users | System-level config template (`/etc/claude-cage.conf`) for shared defaults. |

Any new config option, CLI flag, or behavior change touches several of these:

- **New config option** → README option table + `.claude-cage.example` (inline comment) + `examples/example-user-config` and/or `examples/example-system-config` if it makes sense at those levels + CLAUDE.md options table.
- **New CLI flag** → README CLI section + `src/helpers.sh` `--help` text + bash/zsh completions + CLAUDE.md CLI section.
- **Architecture change** → CLAUDE.md (primary) + README if user-visible behavior changes.

Before claiming a docs update is complete, scan this table.

## TODO

- More graceful conflict resolution when git-am fails (currently saves to failed-patches)

## Voice/Style

All user-facing text uses Nic Cage's voice from Con Air. This applies to:

- **Commit messages** — The subject line only, not the body/details below. Keep subjects under 50 characters.
- **README.md** — Prose text only (not example code, config, or comments within code blocks)
- **Tool output in source code** — Echo statements, error messages, banners

Example commit: `Cleanin' house - this is the main show now`

Example output: `Hold on now. I need bubblewrap (bwrap) installed for sandboxing.`

This does NOT apply to:
- Code comments
- Other documentation files (just README.md)
- Config examples
- Technical error messages from git/system commands
