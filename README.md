# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

A bash script that creates a secure, bidirectional file synchronization environment for Claude Code, enabling it to work on your projects in a sandboxed directory restricted by user permissions outside the `claude` environment.

## What It Does

`claude-cage` sets up a three-layer architecture that allows Claude Code to safely modify files while keeping them synchronized with your original project:

1. **Source directory** - Your original project files
2. **Sync directory** - A synchronized copy maintained by `unison`
3. **Mounted directory** - Where Claude Code operates, with permission mapping via `bindfs`

Changes made by Claude Code automatically sync back to your source directory, while protecting certain files/folders you specify.

## Prerequisites

**Supported Platforms:** Linux (Ubuntu/Debian/Fedora/RHEL/CentOS)

**Note:** This tool is Linux-only. While `unison` works on macOS, `bindfs` requires FUSE which is problematic on macOS and has been disabled in Homebrew since 2021.

Install the required dependencies:

```bash
# Ubuntu/Debian
sudo apt install unison bindfs lua

# RHEL/CentOS
sudo yum install unison bindfs lua
```

## Installation

1. Clone or download this repository
2. Make the script executable:
   ```bash
   chmod +x claude-cage
   ```

### Installing to PATH (Optional)

To make `claude-cage` available from anywhere:

**User-specific:**
```bash
cp claude-cage ~/.local/bin/
```

**System-wide:**
```bash
sudo cp claude-cage /usr/local/bin/
```

After installing to PATH, you can run:
```bash
sudo claude-cage
```

**Note:** The `claude-cage.config` file must be in the directory where you run the command.

## Configuration

### Configuration Hierarchy

`claude-cage` supports a three-tier configuration system:

1. **System config** (optional): `/etc/claude-cage/config`
   - System-wide defaults for all users
   - Requires root to modify

2. **User config** (optional): `~/.config/claude-cage/config`
   - Per-user preferences that override system defaults

3. **Local config** (**required**): `./claude-cage.config`
   - Project-specific settings
   - **Must exist** in the directory where you run the script
   - Overrides all other configs

**Security**: The local config requirement prevents accidentally running the script in unintended directories.

### Global Configs (Optional)

- **System config**: `/etc/claude-cage/config` - defaults for all users
- **User config**: `~/.config/claude-cage/config` - personal preferences

See `example-system-config` and `example-user-config` for templates.

### Local Config (Required)

Create `claude-cage.config` in your project directory:

```lua
claude_cage {
    -- User to run Claude Code as
    user = "claude",

    -- Source directory under current directory to allow reading from
    -- If not provided, source must be provided as a command-line argument
    source = "my-directory",

    -- Sync directory for unison to sync source with
    -- If empty, will use syncprepend + source
    sync = "claude-my-directory",

    -- Prefix for auto-generated sync directory name
    -- If sync is empty, sync directory will be: syncprepend + source
    syncprepend = "claude-",

    -- Files/folders that Claude should not have access to and should not be synced
    exclude = { "target", "src/main/resources/application-*.properties" },

    -- Mounted directory name created under the user's home directory
    mounted = "my-directory"
}
```

### Configuration Options

- **user**: User account to run Claude Code as (default: `"claude"`)
- **source**: Source directory to sync (can be overridden via command-line)
- **sync**: Sync directory name (auto-generated if empty)
- **syncprepend**: Prefix for auto-generated sync directory (default: `"claude-"`)
- **exclude**: Array of paths to exclude from sync (supports wildcards)
- **mounted**: Directory name under `/home/<user>/` where files will be mounted

### Config Merging

- **Simple values** (user, source, etc.): Later configs override earlier ones
- **Arrays** (exclude): Values are **merged** across all config levels

Example: If system config excludes `[".git"]` and local config excludes `["secrets.txt"]`, the final exclude list will be `[".git", "secrets.txt"]`.

## Usage

### First Run

On first run, if the configured user doesn't exist, the script will prompt you to create it:

```
User 'claude' does not exist.
Create user 'claude'? [y/N]
```

The user is created with `--disabled-login` (no interactive login) but can still run processes via `su`, which is how the script launches Claude Code.

### Basic Usage

Run from the directory containing your `claude-cage.config`:

```bash
sudo claude-cage
```

### Override Source Directory

You can override the source directory from the config file, useful if you want to run claude-cage from a directory claude can have access to all projects under it (e.g. a public directory containing open source projects) but want it to open on a specific project:

```bash
cd public
sudo claude-cage mail-mime-parser
```

## Recommended: Use Sandbox Mode

For additional security and reduced permission prompts, enable Claude Code's sandbox mode:

```bash
/sandbox
```

Sandbox mode provides:
- **Filesystem isolation**: Claude can only access specific directories
- **Network isolation**: Claude can only connect to approved servers
- **84% fewer permission prompts** (based on Anthropic's internal usage)
- **Auto-allow mode**: Bash commands run automatically inside the sandbox

Learn more: [https://code.claude.com/docs/en/sandboxing](https://code.claude.com/docs/en/sandboxing)

## How It Works

1. **Unison** runs in watch mode, continuously syncing `source` ↔ `sync` directories
2. **Bindfs** mounts the sync directory with permission mapping:
   - Files created by the Claude user appear as owned by you
   - Ensures proper permissions when files sync back to source
3. **Claude Code** runs in the mounted directory, working on your files
4. **Changes sync bidirectionally** in real-time

## Example Workflow

1. Configure your project:
   ```lua
   claude_cage {
       source = "my-web-app",
       exclude = { "node_modules", ".env", "dist" }
   }
   ```

2. Run claude-cage:
   ```bash
   sudo ./claude-cage
   ```

3. Claude Code starts in `/home/claude/my-web-app`
4. Make changes with Claude Code
5. Changes automatically appear in `./my-web-app`

## Common Exclude Patterns

```lua
-- Build artifacts
-- this is useful so claude can build its own versions, and also if
-- certain private files are compiled in your version, they may be
-- copied to target
exclude = { "target", "build", "dist", "out" }

-- Secrets
exclude = { ".env", "*.key", "credentials.json" }

-- IDE files
exclude = { ".idea", ".vscode" }

-- Mixed example
exclude = {
    "target",
    ".env",
    "src/main/resources/application-*.properties"
}
```

## Troubleshooting

**Error: lua is required but not installed**
```bash
sudo apt install lua
```

**Error: source directory does not exist**
- Check that the source directory exists in the current directory
- Or provide the correct path as a command-line argument

**Permission issues**
- Ensure you run with `sudo`

## License

BSD 2-Clause
