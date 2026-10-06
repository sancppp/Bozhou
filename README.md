<h1 align="center">Bozhou</h1>

<p align="center"><strong>A native macOS SSH workspace for managing multiple hosts</strong></p>

<p align="center">Keep hosts, terminals, file transfers and the context of your work in one local app.</p>

<p align="center"><code>macOS 14+</code> · <code>Apple Silicon</code> · <code>SwiftUI</code> · <code>OpenSSH</code> · <code>MIT</code></p>

<p align="center">
  <a href="#installation">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#examples">Examples</a> ·
  <a href="#development">Contribute</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

**English is the default language**, including on Chinese macOS installations. Choose **Settings → Language → App language → 简体中文** and restart Bozhou to use Simplified Chinese. The preference is saved in the current workspace. Host names, commands and server output retain their original text.

![Bozhou host workspace](Screenshots/usage/01-host-workspace.png)

> These screenshots show the Simplified Chinese interface in an isolated demo workspace. All hosts, accounts, addresses and metrics are fictional.

## Features

- **Organize hosts:** nested folders, tags, favorites, search and sorting. Custom names are stored separately from the hostname, OS, kernel, CPU and memory collected at login.
- **Build connection chains:** passwords, private keys, SSH Agent and Kerberos, with up to 12 jump hosts. Each hop keeps its own username, port and authentication method.
- **Connect across networks:** SOCKS5, HTTP CONNECT and local port forwarding. Confirm each host fingerprint on first connection; changed fingerprints block connections.
- **Work in parallel:** tabs, horizontal and vertical splits, local Zsh, automatic reconnection, raw SSH logs and native input method support.
- **Keep command context:** Bash/Zsh command, output and exit status recording, snippets, searchable history, pins, side-by-side diffs and Markdown export.
- **Transfer files:** SFTP browsing, upload, download and remote file management, plus single-file server-to-server transfers relayed through local memory.

Bozhou uses macOS `/usr/bin/ssh` with a separate configuration for each connection and a workspace-specific host fingerprint database. It does not read `~/.ssh/config`, change your `known_hosts`, require an account or install an agent on your servers.

## Installation

See [CHANGELOG.md](CHANGELOG.md) for release changes.

### Download a release

1. Download `Bozhou-<version>-macOS-arm64.zip`, `SHA256SUMS` and `MD5SUMS` from [Releases](https://github.com/sancppp/Bozhou/releases).
2. Verify the download. Prefer SHA-256; MD5 is provided for compatibility with other integrity checks.

```sh
shasum -a 256 -c SHA256SUMS
md5 -r Bozhou-*-macOS-arm64.zip | diff - MD5SUMS
```

3. Extract the archive and move `泊舟.app` to `/Applications`. The bundle keeps this filename for compatibility with existing installations; its English display name is Bozhou.

> [!NOTE]
> Releases use ad-hoc signatures and are not signed with an Apple Developer ID or notarized. macOS may block the first launch. Verify the source and checksum, then follow the instructions in **System Settings → Privacy & Security** to allow opening it.

### Install from source

Requires macOS, Xcode 26 or a newer toolchain with the macOS 26 SDK, Git and Python 3.10+.

```sh
git clone --recurse-submodules https://github.com/sancppp/Bozhou.git
cd Bozhou
bash Scripts/install.sh
open "/Applications/泊舟.app"
```

Quit Bozhou before installing. The installer defaults to `/Applications`, backs up an existing app with a timestamp, and preserves the workspace.

## Quick start

1. Import a private key in **Keys**, or prepare a password, SSH Agent or Kerberos ticket.
2. Select **New Host** and enter its name, address, port, remote username and authentication method.
3. For jump hosts, save those hosts first, then add them to the destination's **Jump Host Chain** in connection order.
4. Select **Save and Connect** and verify the first server fingerprint through a trusted channel.
5. Pin useful interactions from the terminal sidebar, or return to the workspace for SFTP, History and Pins.

Snippets insert text into the terminal; review it before executing. Automatic reconnection retries after 5, 10, 30, 60 and 120 seconds, then requires manual reconnection. It starts a new remote shell without replaying commands.

Switching tabs, returning to the workspace or changing split layouts retains existing sessions and scrollback. Background output continues to arrive. Scrollback has a capacity limit; clearing the screen, closing a session or reconnecting clears or replaces terminal content.

Select a host in the list or grid and press **Space** for Quick Look. Use **↑↓** to switch hosts and **Space / Esc** to close it. Host labels display `name(hostname)`, abbreviating long hostnames to their last six characters when needed. Hover for the full name. Before the first login, the connection address serves as the hostname.

The terminal header shows host identity, connection address, username, folder and status. **⌘− / ⌘=** changes the focused pane's font size from 10 to 36 pt. Zoom lasts for the session; the size in Settings is the default for new sessions. A shell exiting with status 0 closes its tab or pane. Nonzero or unknown exits keep the terminal available for inspection and manual reconnection.

Unexpected exits save a report accessible from **Exit Context** in the terminal or **Logs → SSH & Exit Logs**. Reports include exit status, shell, terminal size, output and SSH log tails, and the latest five interactions from that connection. The workspace keeps up to 20 reports in `logs/*.terminal-context.json`, even after the tab closes.

## Examples

The demo workspace models a release check across Singapore, Tokyo, Frankfurt and Beijing, with production, staging and disaster recovery hosts running several Linux distributions, macOS and FreeBSD. A payment API connection passes through two jump hosts and uses local port forwarding.

### Check production and disaster recovery in parallel

Run a cluster check in the payment API session and open a PostgreSQL recovery session in a split pane. Each session has independent focus, terminal size and interaction history.

![Payment and PostgreSQL sessions in a split terminal](Screenshots/usage/02-split-terminal.png)

### Distribute files over SFTP

Open SFTP from a host to browse local and remote files side by side. Upload, download, create directories or select **Server-to-Server Transfer** to copy a file between two hosts.

![Local and remote files in the SFTP browser](Screenshots/usage/03-sftp-transfer.png)

### Compare results before and after a release

Pin a baseline and a canary check, then select both to compare output. Version, instance count, latency and error rate changes are highlighted by line.

![Pinned command outputs compared side by side](Screenshots/usage/04-interaction-diff.png)

## Data and security

> [!IMPORTANT]
> Host passwords are currently stored in plain text in the local SQLite database. Prefer private keys, SSH Agent or Kerberos, and restrict access to the workspace and its backups.

- The default workspace is `~/Library/Application Support/Bozhou/`. Settings can migrate it to an empty directory while retaining the original.
- Only private key paths are stored. Passphrases and verification codes are not persisted or written to process arguments, environment variables or logs.
- History and pins may contain sensitive output. Disable history recording or clear history in the app.
- Exit context is saved independently of the history preference, with owner-only file permissions. Terminal and SSH tails are limited to 64 KiB and 16 KiB. Reports redact the current host's saved password, but may contain other sensitive output; review before sharing.
- Local port forwarding listens only on `127.0.0.1`; a port conflict fails the connection.
- The app does not modify persistent local or remote shell configuration or install remote plugins.
- Report security issues through GitHub private vulnerability reporting; see [SECURITY.md](SECURITY.md).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` / `⌘T` | New host / local terminal |
| `⌘⇧F` | Search hosts |
| `⌘⇧R` / `⌘⇧W` | Reconnect / close current session |
| `⌘⇧P` | Pin latest interaction |
| `⌘K` | Clear screen and scrollback, retaining recorded interactions |
| `⌘−` / `⌘=` (or `⌘+`) | Decrease / increase terminal font size |
| `Space` / `Esc` | Preview a selected host / close preview |
| `⌘C` / `⌘V` / `Ctrl-C` | Copy / paste / interrupt |
| `⌘,` | Open Settings |

## Current limits

- Release builds target Apple Silicon and macOS 14+. Intel and every supported macOS version have not been individually verified.
- SFTP transfers one file at a time, without recursive directory transfer, resume or parallel queues. Only empty directories can be deleted.
- Automatic recording supports Bash and Zsh. Other shells use manual snapshots; shells inside tmux do not receive recording hooks automatically.
- Replacing Bash `PROMPT_COMMAND` or clearing Zsh hook arrays can stop recording. Reconnect to reload the hooks. Bozhou does not intercept these configuration changes.
- Each interaction stores at most 256 KiB of output and cannot reproduce the screen layout of programs such as Vim or top.
- Diffs totaling more than 4000 lines use positional highlighting rather than semantic alignment.

## Development

Reproducible issues and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and commit conventions and [AGENT.md](AGENT.md) for implementation invariants.

```sh
bash Scripts/build.sh release
bash Scripts/test.sh --unit
bash Scripts/test.sh --shell-stability
bash Scripts/test.sh
bash Scripts/test_regressions.sh
bash Scripts/test_native.sh
python3 Scripts/test_install.py
python3 Scripts/verify_package.py
```

Python 3.10+ is required. Set `BOZHOU_PYTHON` to another interpreter if necessary. Integration tests use random loopback ports and a project-local AsyncSSH environment, without starting the system `sshd` or connecting to real servers.

Translations live in `Sources/BozhouCore/Resources/Localization/`. Use `L10n.tr("English text")` for app-owned text, with Swift interpolations for values; catalogs use `{0}`, `{1}`, etc. Keep protocol strings and user data outside localization. Add matching keys and placeholders in both catalogs. Localization tests check catalog parity, interpolation, saved preferences and the AskPass language environment.

Push a signed `release/vX.Y.Z` tag matching `VERSION` to run release tests, build the Apple Silicon app and publish the ZIP with SHA-256 and MD5 checksums. Republishing an existing tag updates its release notes and replaces the three assets after verification.

Bozhou is built with SwiftUI, AppKit, system OpenSSH, SwiftTerm and SQLite, and released under the [MIT license](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependencies and licenses.

GPT-6-Astra assists with development, code review and documentation.
