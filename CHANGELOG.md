# Changelog

All notable changes to VPSGuard are documented here.

## [0.3.7] - 2026-10-08

Real-machine tested on AWS (Ubuntu 24.04, `ssh.socket`, cloud-init) and Vultr
(Ubuntu 24.04, `ssh.service`, a pre-existing proxy service).

### Security

- Never copy a forced-command SSH key (as shipped in root's `authorized_keys`
  on AWS and other cloud images) into the new administrator's
  `authorized_keys` - that key cannot be used for interactive login and
  would lock the administrator out on first login; fall back to the
  sudo-invoking user's key when root has none usable.
- Fix a bug where, after a rerun, the administrator's `~/.ssh` directory
  could end up owned by `root` instead of the administrator, silently
  blocking all public-key login even though the install reported success.
- Close a symlink-race window where a managed directory swapped for a
  symlink between a safety check and the actual ownership/permission change
  could make a privileged operation act on an attacker-chosen path instead.

### Fixed

- Never enable UFW before allowing existing non-SSH listeners; add `ALLOW_PORTS` and `--ssh-only` for non-interactive installs, avoiding cutting off an already-running service such as a proxy.
- Validate root's SSH key before touching the system, not partway through `configure_authorized_keys`.
- Apply the conntrack profile once, after BBR, inside the normal install flow, instead of as a separate pre-invocation.
- Pin `CORE_URL` to a version tag (`v<VERSION>`) instead of a commit SHA, and verify in CI that the tag matches `VERSION`.
- Warn and downgrade the install status to `success-with-warnings` if the old SSH port stays open after migration finalization.
- Refuse password-sudo mode when a foreign cloud-init NOPASSWD sudoers file exists for the managed user.
- Refuse a symlinked `~/.ssh` directory or `authorized_keys` file.
- Only run a full `apt-get upgrade` on first install, not on reruns.
- Only sync root's pubkey to the admin on first install or when the admin's `authorized_keys` is empty.
- Only reload or restart managed services (sshd/ssh.socket, fail2ban, BBR sysctl, conntrack) when their configuration actually changed; fixes a trailing-newline bug in `atomic_write`'s own change-detection that previously made every multi-line managed file register as "changed" on every run.
- Use `apt-get` (not the deprecated `apt` command) with conservative dpkg options (`--force-confdef`, `--force-confold`) and `NEEDRESTART_MODE=l` for unattended upgrades.
- Report the server IP from `hostname -I` only; remove the external `api.ipify.org` network call from the install summary.
- Put the shebang first in the conntrack runtime helper script; the ownership marker is now recognized on line 1 or line 2 for compatibility with both old and new files.
- Omit the IPv6 `ListenStream` line from the `ssh.socket` override when IPv6 is unavailable (`/proc/net/if_inet6` absent).
- Also reload or restart a managed service when its actual runtime state is wrong, not only when its configuration file content changed.
- Restrict supported Ubuntu releases to 22.04 and 24.04; refuse to run, before making any change, on an untested release such as 26.04.
- Check for a conflicting cloud-init passwordless-sudo grant before running the (potentially multi-minute) system upgrade, not after.
- Fix the interactive "which ports to allow" prompt so a bare port number allows every protocol detected listening on it, instead of silently keeping only the first one found when both TCP and UDP were listening on the same port.
- Install missing dependency packages, including kernel packages such as `linux-aws`, during the first-install system upgrade instead of silently keeping them back; warn after install if a reboot is required to fully apply the update.
- Fix `ss` output parsing so it works whether or not a protocol column is present, correcting both the non-SSH port survey (which previously misreported loopback-bound UDP ports as foreign TCP listeners) and the SSH listener check used by status reporting.
- Only report the conntrack health check once per install, and never claim a first install's pre-install state was "already recorded" from an earlier run.
- Stop needlessly reapplying - and logging as reapplied - an already-correct conntrack profile on every rerun.
- Automatically exempt the installer's own SSH connection IP from fail2ban, so testing login with several local SSH keys in a row can no longer ban the installer's own address for an hour.

### Improved

- Skip the redundant "type YES to continue" confirmation when rerunning with the same already-managed administrator; it is now only asked when taking over a different, previously unmanaged existing account.
- Warn that some cloud images enforce password-strength policies, and suggest a randomly generated password when setting up password-based sudo.
- Show the same resolved IP - a real address when known, or a `SERVER_IP` placeholder with a hint to use the provider console's public IP for a private/VPC-internal address - in both the port-migration prompt and the final install summary, instead of only one of them doing so.

## [0.3.6] - 2026-08-21

### Added

- Add a conntrack health check to `status.sh`, including current count, maximum, usage percentage, hash buckets, conntrack table-exhaustion evidence in currently accessible kernel logs, and `OK` / `NOTICE` / `WARNING` / `CRITICAL` / `UNAVAILABLE` status.
- Add a read-only conntrack check at the end of installation; default installs do not modify conntrack kernel parameters.
- Add explicit `sudo bash install.sh --optimize-conntrack` support for a conservative VPSGuard-managed conntrack profile.
- Add dedicated managed files for optional conntrack optimization: `/etc/sysctl.d/99-vpsguard-conntrack.conf`, `/etc/modprobe.d/vpsguard-nf-conntrack.conf`, `/etc/modules-load.d/vpsguard-conntrack.conf`, `/etc/vpsguard/apply-conntrack-profile.sh`, and `/etc/systemd/system/vpsguard-conntrack.service`.

### Security

- Preserve user-owned conntrack sysctl/modprobe configuration and refuse to silently overwrite it.
- Never lower an existing `nf_conntrack_max` or `hashsize` value when applying the optional profile.
- Avoid unloading `nf_conntrack` or changing UFW service-port behavior while applying conntrack settings.
- Extend uninstall cleanup to remove only recognizable VPSGuard-managed conntrack files while preserving unknown user configuration.

### Fixed

- Fix Ubuntu 24.04 reboot persistence for conntrack timeouts by loading `nf_conntrack` before `systemd-sysctl` and adding a VPSGuard-managed systemd oneshot/helper for runtime profile application.
- Replace static `net.netfilter.nf_conntrack_max = 65536` persistence with a dynamic runtime floor that raises values below `65536` and preserves `65536` or higher.
- Report `Runtime profile: drift detected` in `status.sh` when VPSGuard conntrack config exists but runtime max, hashsize, or timeout values do not match the opt-in profile.
- Add standalone conntrack cleanup so managed conntrack artifacts can still be safely removed when the main VPSGuard config is missing, and stop the `RemainAfterExit` oneshot before deleting it to avoid an `active (exited)` residue after uninstall.

### Testing

- Add isolated conntrack tests for normal, notice, warning, critical, table-full, unavailable, high-existing-value, custom-config protection, module-before-sysctl boot ordering, dynamic max floor, timeout drift, reboot-equivalent helper apply, idempotency, and uninstall behavior.

## [0.3.5] - 2026-08-04

### Security

- Handle `ssh.socket`, `ssh.service`, `sshd.service`, and legacy service modes before declaring an SSH port change successful.
- Keep the old SSH listener and UFW rule until the administrator explicitly confirms a second-terminal login with `YES`.
- Require public-key and real sudo behavior validation before SSH root/password login is disabled, and persist `SUDO_MODE` only after the selected mode succeeds.
- Make password sudo the default and require exact `I UNDERSTAND` confirmation for the high-risk passwordless mode without creating an empty Linux password.
- Preserve a passwordless sudoers file during uninstall when no safe password-authenticated fallback can be proven, and report a partial uninstall.
- Stop uninstall from globally disabling or resetting UFW and Fail2ban, and remove only recognizable VPSGuard-managed files and recorded rules.

### Fixed

- Distinguish `not-started`, `pending`, `incomplete`, and `complete` SSH port-finalization states in `status.sh`; failures before SSH configuration no longer report port migration as complete.
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

[0.3.6]: https://github.com/hcloudlab/vpsguard/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/hcloudlab/vpsguard/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/hcloudlab/vpsguard/releases/tag/v0.3.4
