# Changelog

## 1.3.0

### Host information and optional ECS metadata

- Summarize the operating system, CPU model and logical CPU count, and available memory at login in GiB; parse existing raw system information when loading older workspaces.
- Add an optional NightHawk CLI extension for Volcengine ECS details and directly related network resources, using the existing local CLI and SSO login.
- Verify instance, network interface and account associations, support explicit instance bindings, and show collection limits or partial failures.
- Choose and reorder metadata fields for the workspace or individual hosts. Display enabled cloud metadata before the operating system in Quick Look.
- Search system details, notes, jump hosts and all cached properties of enabled metadata extensions, including VPC information.

### Session arrangement

- Drag horizontal or vertical session tabs to reorder them.
- Drag a tab over another terminal's left, right, top or bottom area to preview and create a two-pane split. Click a tab to return to a single pane.
- Preserve sessions, scrollback and keyboard focus through rearrangement; remove the previous split menu.

### Extension framework and reliability

- Introduce a capability-based plugin registry with registration, activation, deactivation, workspace switching and unregistration. Keep NightHawk in its own module and document how to add plugins.
- Cancel plugin work on disable or workspace changes and reject stale metadata results without overwriting newer host observations.
- Refresh active history and pin searches when background records arrive, reject key-import results from a previous workspace, and limit host actions to visible selections.
- Preserve visible OSC hyperlink text in recorded output and clear hidden terminal command targets when returning to the workspace.
- Keep custom app output paths consistent across packaging, verification and installation, and link native regressions against current build dependencies.

## 1.2.1

### Reinstalled servers and changed SSH host keys

- Identify the destination or jump host whose SSH key changed, including failures reported by an inner SSH process.
- Add **Review Changed Host Key…** to terminal, SFTP and server-to-server connection failures. Verify the displayed fingerprint, reset that endpoint's saved key and reconnect to confirm the new key.
- Preserve keys for other hosts and routes, support hashed records and refuse resets when the trust database changed while the review was open.
- Keep changed keys blocked until explicitly reviewed; record these terminal failures as `host_key_changed` and stop automatic retries.

## 1.2.0

### Search and workspace organization

- Use Command-F to search logs, command history, pinned interactions, keys, snippets and known hosts, with matching text highlighted and previous/next navigation in output viewers.
- Start searching one second after typing stops. Match long text in the background, cancel obsolete searches and cache history and pin results.
- Organize keys in nested folders with rename, move and saved expansion state while preserving host references.
- Rename session tabs and switch between horizontal and vertical tab bars. Compact tabs keep the last six hostname characters visible.

### Local data backups

- Export and import versioned `.bozhoubackup` files containing hosts, folders, key records, snippets, history, pins, settings, fingerprints and logs.
- Validate backup integrity and restore into a new directory, retaining the previous workspace.
- Backups contain saved passwords and are not encrypted. External private key files and temporary sessions are excluded; the size limit is 512 MiB.

### In-app updates

- Check GitHub releases at launch or manually from the app menu and Settings, then download and install a newer Apple Silicon version.
- Verify checksums, archive paths, bundle identity, version, architecture and code signatures before installing.
- Wait for the app to quit, retain the previous app and restart after replacement. Replacement or launch-command failures restore the previous app.
- Upgrading from a published version without an update menu requires one manual installation. The preview with an update menu can download this release directly.

## 1.1.1

### SSH host key isolation

- Scope routed host fingerprints to the complete jump-host or network-proxy path, so identical addresses behind different routes can connect independently.
- Reuse each route fingerprint across terminal sessions, SFTP, reconnects and credential edits while preserving existing direct-connection trust records.
- Require a one-time fingerprint confirmation for routed hosts upgrading from address-only trust records; the old fingerprint database does not need to be deleted.

### Performance and reliability

- Stop monitoring SFTP stderr after EOF, preventing terminated SFTP processes from driving Bozhou to 100% CPU.
- Add route-isolation coverage and an end-to-end regression that verifies SFTP cancellation returns to idle CPU usage.

## 1.1.0

### Languages and documentation

- English is now the default for the UI and README, including when upgrading an existing workspace.
- Added Simplified Chinese translations for application text, menus, authentication prompts and errors. Choose the app language in Settings and restart to apply it.
- Preserved the Chinese README as `README.zh-CN.md`.
- SFTP error handling now uses transport state instead of matching translated messages.

### Terminal stability and diagnostics

- Retain terminal sessions, scrollback, alternate-screen state and background output across tab, workspace and split-layout changes.
- Prevent zero-size view layouts from reflowing and discarding scrollback.
- Reduce output buffering copies and skip unchanged font and color updates.
- Use native Zsh hook arrays with isolated options, preserving user `precmd`; avoid common user variable names in Bash hooks.
- Deliver final PTY output before reporting process termination.
- Keep terminal panes on nonzero or unknown exits and save exit status, terminal size, recent interactions and terminal/SSH output tails.
- View reports in **Logs → SSH & Exit Logs**. Keep up to 20 owner-only reports, including after tabs close.
- Added real PTY regressions for Bash, Zsh, existing Oh My Zsh, nested shells, Vim, paste, interrupts and resizing.

### Interface and installation

- Keep the terminal header on two rows: host identity and connection details above, connection status below.
- Source installation defaults to `/Applications/泊舟.app`. The bundle filename remains compatible with existing installations.

### Known limits

- Replacing Bash `PROMPT_COMMAND` or clearing Zsh hook arrays may stop automatic recording. Reconnect to reload hooks.
- The previously reported “invalid size” crash has not been reproduced exactly. Exit context reports support further diagnosis.
