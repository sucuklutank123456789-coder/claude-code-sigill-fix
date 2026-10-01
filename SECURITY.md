# Security policy

## What this repository touches

The fix scripts change files that other programs run, so a bug in them can matter for security:

- They rename Claude Code's native binaries and write wrapper scripts or compiled wrappers in their place.
- On Linux they can call `sudo` to install QEMU or Intel SDE with the distribution's package manager.
- They download Intel SDE from Intel's servers (Linux: the newest release; Windows: SDE 9.48.0) and check its SHA-256 where a known hash is available.
- On Windows they compile a small C# wrapper with .NET Framework's `csc.exe` and edit npm shims.
- They patch the startup timeouts in the VS Code extension's `extension.js`.

## Supported versions

Only the newest release (the newest `vX.Y.Z` tag, see [CHANGELOG.md](CHANGELOG.md)) gets fixes. The agent skills always check out the newest release.

## Reporting a problem

Please do **not** open a public issue for a security problem. Report it privately through GitHub instead:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the problem, the affected script and version (`--version` / `-Version`), and how to reproduce it.

The report stays private until a fix is released. It can then be published as a security advisory, with credit if you want it.

Problems in Claude Code itself, QEMU or Intel SDE belong to their own projects:

- Claude Code: <https://github.com/anthropics/claude-code/security>
- QEMU: <https://www.qemu.org/contribute/security-process/>
- Intel SDE: <https://www.intel.com/content/www/us/en/security-center/default.html>
