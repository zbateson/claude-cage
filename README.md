# ![claude-cage](https://zbateson.github.io/claude-cage/claude-cage-lo.png)

A bash script that creates a secure, bidirectional file synchronization environment for Claude Code, enabling it to work on your projects in a sandboxed directory restricted by user permissions outside the `claude` environment.

## What It Does

`claude-cage` sets up a three-layer architecture that allows Claude Code to safely modify files while keeping them synchronized with your original project:

1. **Source directory** - Your original project files
2. **Sync directory** - A synchronized copy maintained by `unison`
3. **Mounted directory** - Where Claude Code operates, with permission mapping via `bindfs`

Changes made by Claude Code automatically sync back to your source directory, while protecting certain files/folders you specify.

## ⚠️ Important Warning

**This tool uses bidirectional synchronization via `unison`.** Changes made in either directory (source or sync) will propagate to the other, **including deletions**.

**Before first use:**
- ✅ **Commit and push all changes to git** (or your version control system)
- ✅ **Create a backup** of your project directory
- ✅ **Test with a non-critical project first** to understand the sync behavior
- ✅ **Carefully configure your exclude patterns** to protect sensitive files

**Unison will:**
- Synchronize file modifications bidirectionally
- **Delete files** on one side if they're deleted on the other
- Propagate changes immediately when using watch mode

If you're unsure about your configuration, start with a test project or a git-committed copy of your work.

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

See `examples/example-system-config` and `examples/example-user-config` for templates.

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
    excludePath = { "target", "dist", ".env" },
    excludeName = { "*.tmp", ".DS_Store" },
    excludeRegex = { ".*\\.log$" },
    belowPath = { "node_modules" },

    -- Mounted directory name created under the user's home directory
    mounted = "my-directory"
}
```

### Configuration Options

- **user**: User account to run Claude Code as (default: `"claude"`)
- **source**: Source directory to sync (can be overridden via command-line)
- **sync**: Sync directory name (auto-generated if empty)
- **syncprepend**: Prefix for auto-generated sync directory (default: `"claude-"`)
- **mounted**: Directory name under `/home/<user>/` where files will be mounted

**Exclude Options** (all are optional arrays):

- **excludePath**: Ignore exact paths (e.g., `["target", ".env"]`)
- **excludeName**: Ignore by name anywhere (e.g., `["*.tmp", "node_modules"]`)
- **excludeRegex**: Ignore by regex pattern (e.g., `[".*\\.log$"]`)
- **belowPath**: Ignore entire directory trees (e.g., `["build/"]` ignores files below 'build')

See "Common Exclude Patterns" section below for examples.

### Config Merging

- **Simple values** (user, source, etc.): Later configs override earlier ones
- **Arrays** (all exclude options): Values are **merged** across all config levels

Example: If system config has `excludePath = [".git"]` and local config has `excludePath = ["secrets.txt"]`, the final excludePath list will be `[".git", "secrets.txt"]`.

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

### Excluded Files Check

When you run `claude-cage`, it automatically checks if any files in the sync directory match your current exclude patterns. This is useful when:
- You change your exclude configuration between runs
- Files were previously synced but should now be excluded

If excluded files are found, you'll see:
```
WARNING: Found files/directories in sync directory that are now excluded:
  - claude-my-directory/target
  - claude-my-directory/.env

These files may have been created in a previous run with different exclude settings.
They should be removed from the sync directory before continuing.

Remove these files? [y/N]
```

Choose `y` to automatically remove them, or `N` to exit and manually handle them.

## Recommended: Use Sandbox Mode

For additional security and reduced permission prompts, enable Claude Code's sandbox mode:

```bash
/sandbox
```

Sandbox mode provides its own filesystem isolation but also:
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
       excludePath = { ".env", "dist" },
       belowPath = { "node_modules" }
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
-- Build artifacts at specific paths
-- Useful so Claude can build its own versions, and also if
-- certain private files are compiled in your version
excludePath = { "target", "build", "dist", "out" }

-- Secrets at specific locations
excludePath = { ".env", "credentials.json" }

-- IDE files at specific locations
excludePath = { ".idea", ".vscode" }

-- Temporary files by name anywhere in the tree
excludeName = { "*.tmp", "*.swp", ".DS_Store" }

-- Node modules or large dependency folders (ignore entire tree)
belowPath = { "node_modules", "vendor" }

-- Log files using regex
excludeRegex = { ".*\\.log$", ".*\\.log\\..*" }

-- Comprehensive example combining multiple types
excludePath = {
    "target",
    ".env",
    "src/main/resources/application-local.properties"
}
excludeName = {
    "*.tmp",
    ".DS_Store"
}
belowPath = {
    "node_modules"
}
excludeRegex = {
    ".*\\.log$"
}
```

### Choosing the Right Exclude Type

- Use **excludePath** for specific files/directories at known locations
- Use **excludeName** for files that appear in multiple places with the same name
- Use **belowPath** for entire directory trees (more efficient than excludePath)
- Use **excludeRegex** for complex patterns that wildcards can't handle

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
