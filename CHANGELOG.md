# Changelog

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
