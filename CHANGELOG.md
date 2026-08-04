# Changelog

All notable changes to VPSGuard are documented here.

## [0.3.5] - 2026-08-03

### Security

- Handle `ssh.socket`, `ssh.service`, `sshd.service`, and legacy service modes before declaring an SSH port change successful.
- Keep the old SSH listener and UFW rule until the administrator explicitly confirms a second-terminal login with `YES`.
- Require user, public-key, sudo-group, password-state, standard sudo-policy, and interactive password-authentication validation before SSH root/password login is disabled.
- Remove the legacy VPSGuard `NOPASSWD: ALL` override and use Ubuntu's password-authenticated sudo group policy.
- Stop uninstall from globally disabling or resetting UFW and fail2ban, and remove only recognizable VPSGuard-managed files and recorded rules.

### Fixed

- Match UFW TCP ports exactly, including IPv6 output, so `22/tcp` never matches `2222/tcp`.
- Manage SSH policy through an atomic `00-vpsguard.conf` snippet and verify final values with `sshd -T`.
- Prepend a reversible exact Include so cloud-image SSH directives before the wildcard include cannot override VPSGuard policy.
- Manage a dedicated `ssh.socket` drop-in so Ubuntu 24.04 systemd socket listeners converge with the staged and final SSH ports.
- Replace permanent phase-marker skips with actual-state reconciliation on every run.
- Replace fixed success text with user, key, sudo, SSH, listener, UFW, fail2ban, and BBR acceptance checks.

### Added

- Require an explicitly selected administrator username; no hidden default account is created.
- Add safe existing-user reuse, parameterized `NEW_USER` selection with mandatory terminal password validation, and unified config persistence.
- Add native Linux BBR support detection, managed `fq + bbr` configuration, and explicit state classification.
- Add pre-install state tracking, managed UFW-rule tracking, real status reporting, isolated Shell tests, and GitHub Actions.

### Changed

- Use `hcloudlab/vpsguard` for current repository and installation links.
- Preserve prior SSH ports during a two-stage port migration.
- Use independent VPSGuard files for SSH, fail2ban, BBR sysctl, and modules-load configuration; VPSGuard no longer creates a sudoers override.
- Document Ubuntu 26.04 as experimental and not live-VPS-validated.

### Testing

- Add username validation, exact UFW matching, SSH mock, BBR, state, uninstall, and ten-run idempotency tests.
- Run Bash syntax, ShellCheck, and isolated tests on Ubuntu 22.04 and 24.04 GitHub-hosted runners.

## [0.3.4] - 2026-07-01

- Enabled best-effort native BBR configuration and added basic BBR status output.

[0.3.5]: https://github.com/hcloudlab/vpsguard/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/hcloudlab/vpsguard/releases/tag/v0.3.4
