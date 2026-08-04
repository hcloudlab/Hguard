# Changelog

All notable changes to VPSGuard are documented here.

## [0.3.5] - 2026-08-04

### Security

- Handle `ssh.socket`, `ssh.service`, `sshd.service`, and legacy service modes before declaring an SSH port change successful.
- Keep the old SSH listener and UFW rule until the administrator explicitly confirms a second-terminal login with `YES`.
- Require public-key and real sudo behavior validation before SSH root/password login is disabled, and persist `SUDO_MODE` only after the selected mode succeeds.
- Make password sudo the default and require exact `I UNDERSTAND` confirmation for the high-risk passwordless mode without creating an empty Linux password.
- Preserve a passwordless sudoers file during uninstall when no safe password-authenticated fallback can be proven, and report a partial uninstall.
- Stop uninstall from globally disabling or resetting UFW and Fail2ban, and remove only recognizable VPSGuard-managed files and recorded rules.

### Fixed

- Match UFW TCP ports exactly, including IPv6 output, so `22/tcp` never matches `2222/tcp`.
- Manage SSH policy through an atomic `00-vpsguard.conf` snippet and verify final values with `sshd -T`.
- Prepend a reversible exact Include so cloud-image SSH directives before the wildcard include cannot override VPSGuard policy.
- Manage a dedicated `ssh.socket` drop-in so Ubuntu 24.04 systemd socket listeners converge with the staged and final SSH ports.
- Keep invalid interactive username warnings out of the selected value so a valid retry is accepted.
- Recreate `/run/sshd` after package upgrades before validating the hardened SSH configuration.
- Validate Fail2ban configuration, install the Ubuntu 22.04 `python3-systemd` backend dependency, and wait for the `sshd` jail to become ready after restart.
- Report deduplicated effective SSH listeners and avoid reporting inactive `ssh.socket` configuration as a live port.
- Prevent successful reruns from reopening the finalized old SSH port.
- Restore the old effective sudo mode when a password/passwordless migration fails.
- Omit `SUDO_MODE` on a failed fresh install until a mode passes real behavior validation.
- Replace permanent phase-marker skips with actual-state reconciliation on every run.
- Replace fixed success text with user, key, sudo, SSH, listener, UFW, fail2ban, and BBR acceptance checks.

### Added

- Require an explicitly selected administrator username; no hidden default account is created.
- Add password and passwordless sudo modes with transactional bidirectional migration and rollback.
- Add an atomic, `root:root 440`, `visudo`-validated VPSGuard sudoers file for explicitly selected passwordless mode.
- Add safe existing-user reuse, parameterized `NEW_USER` selection with mandatory terminal password validation, and validated config persistence.
- Add native Linux BBR support detection, managed `fq + bbr` configuration, and explicit state classification.
- Add behavior-based sudo checks to `status.sh`, pre-install state tracking, managed UFW-rule tracking, isolated Shell tests, and GitHub Actions.

### Changed

- Use `hcloudlab/vpsguard` for current repository and installation links.
- Preserve prior SSH ports during a two-stage port migration.
- Use Ubuntu's standard sudo group and user password in the default password mode; create an independent VPSGuard sudoers file only for explicitly selected passwordless mode.
- Use independent VPSGuard files for SSH, Fail2ban, BBR sysctl, and modules-load configuration.
- Document Ubuntu 26.04 as experimental and not live-VPS-validated.

### Testing

- Complete real VPS validation on Ubuntu 22.04.5 LTS and Ubuntu 24.04.4 LTS across `ssh.service`, `ssh.socket`, both sudo modes, bidirectional migration, failure rollback, reruns, reboot persistence, and safe uninstall.
- Add username validation, exact UFW matching, SSH mock, sudo transaction, BBR, state, uninstall, fresh-failure persistence, and ten-run idempotency tests.
- Run Bash syntax, ShellCheck, and isolated tests on Ubuntu 22.04 and 24.04 GitHub-hosted runners.

## [0.3.4] - 2026-07-01

- Enabled best-effort native BBR configuration and added basic BBR status output.

[0.3.5]: https://github.com/hcloudlab/vpsguard/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/hcloudlab/vpsguard/releases/tag/v0.3.4
