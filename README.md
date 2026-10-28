# Linux FIDO2 Authentication

Configure Linux authentication with a FIDO2 security key for:

- LUKS disk unlock at boot (when supported by your existing initramfs and systemd setup)
- GNOME/GDM desktop login through PAM
- `sudo` authentication through PAM

**Tested with Ubuntu 26.10. Use at your own risk.**

> **Important:** Authentication and disk-encryption changes can lock you out of your system or make encrypted data inaccessible. Read this README, keep a working password and recovery method, and maintain a tested backup before making changes. This project is provided without warranty.

## Scope

The intended configuration uses a FIDO2 security key and requires PIN verification where the installed key, `libfido2`, `pam-u2f`, and registration tools support it.

- The desktop-login and `sudo` portions use `pam_u2f.so`.
- The LUKS portion is separate and typically uses `systemd-cryptenroll` with systemd's FIDO2 support.
- Do not assume that setting up PAM also configures LUKS, or vice versa.
- Keep password authentication available as a recovery path until every test succeeds.
- This project does not guarantee that every key, PAM stack, display manager, initramfs, or distribution configuration behaves identically.

## Usage

Review the script before running it. From the repository directory:

```bash
chmod +x configure-fido2-linux.sh
sudo ./configure-fido2-linux.sh
```

Before changing authentication files, the script checks for required packages and automatically runs `apt-get update` and installs any missing `libpam-u2f` and `sudo` packages on Debian/Ubuntu systems. This requires an internet connection and working APT repositories. Other distributions are not automatically supported; install the equivalent packages manually before running the script.

The script then enrolls a PIN-verification credential using `pamu2fcfg -N`, merges it into `/etc/u2f_mappings` for the selected account, and configures the PAM rule for GNOME/GDM and `sudo`. It also sets `timestamp_timeout=0` so separate `sudo` invocations authenticate again. Keep an administrator session open and test password fallback before logging out.

**The script intentionally does not configure or change LUKS/boot unlock.** If LUKS FIDO2 unlock is already working, it is left untouched. LUKS enrollment is a separate, high-risk operation and must be managed and tested independently.

## Prerequisites

Before starting, make sure you have:

- Ubuntu 26.10 or a compatible Linux distribution.
- A supported FIDO2 security key with a configured PIN.
- Local administrator access and a working account password.
- A current backup and a recovery path for any LUKS-encrypted data.
- Physical access to the computer while changing authentication settings.
- APT repositories and network access on Debian/Ubuntu, so the script can install missing `libpam-u2f` and `sudo` packages automatically.
- A supported FIDO2 security key with a configured PIN.
- For optional LUKS management outside this script, the relevant `cryptsetup` and systemd tools.

The PAM setup script does not need `fido2-tools` for its own enrollment flow. Package names and tool options can differ by distribution and version. On non-Debian/Ubuntu systems, install the equivalent PAM U2F and sudo packages manually. Check your installed manual pages before using any command.

## Before you change authentication

1. Back up the files you plan to edit, especially `/etc/pam.d/gdm-password`, `/etc/pam.d/sudo`, and the U2F mapping file.
2. Keep a root-capable terminal open while testing.
3. Confirm you know your account password.
4. For LUKS, verify your recovery passphrase works before adding or changing a token.
5. Do not remove existing working LUKS credentials or password-based PAM access as part of initial testing.

## PIN verification notes

PAM U2F registration and runtime options must match the installed versions of `pamu2fcfg` and `pam_u2f.so`. Check the local documentation:

```bash
man pamu2fcfg
man pam_u2f
```

Some versions support registering a credential for PIN verification with `pamu2fcfg -N` and requesting PIN verification using `pinverification=1` in the PAM module. Do not copy options blindly: confirm that your installed version supports them and test with your specific key. PIN verification is not the same as requiring a touch, and it does not necessarily mean the key's PIN will be requested on every operation unless the credential and authenticator support that behavior.

## Reverse the PAM configuration

To restore the PAM files, U2F mapping file, and sudoers drop-in from the backup created during setup:

```bash
chmod +x reverse-fido2-linux.sh
sudo ./reverse-fido2-linux.sh
```

Enter the full backup directory path printed by `configure-fido2-linux.sh` and confirm with `REVERSE`. The reversal script makes a safety snapshot of the current files before restoring the backup. Keep your current administrator session open and verify password-based desktop login and `sudo` before logging out.

**This reverses the local PAM/sudo configuration only.** It does not remove FIDO2 credentials from the security key and does not undo LUKS/FIDO2 boot enrollment. The configuration script in this repository does not modify LUKS in the first place.

## Testing checklist

Test each component separately. Keep an existing authenticated session open throughout.

### Desktop login

- [ ] Confirm password login still works.
- [ ] Test the security key at the login screen.
- [ ] Confirm the expected PIN/touch behavior.
- [ ] Test a second login before closing the recovery session.

### `sudo`

- [ ] Open a second terminal.
- [ ] Run `sudo -k` to invalidate the current sudo timestamp.
- [ ] Run a harmless command such as `sudo -v` and verify the intended authentication prompt.
- [ ] If configuring `timestamp_timeout=0`, note that it disables sudo timestamp caching for separate invocations; commands within an already-open root shell do not reauthenticate individually.

### LUKS unlock

- [ ] Confirm the recovery passphrase works.
- [ ] Confirm the FIDO2 key unlocks the intended encrypted volume at boot.
- [ ] Test only when you have physical access and a known recovery path.
- [ ] Do not remove the passphrase slot or other working recovery method just because key-based unlock succeeds once.

## Recovery

If PAM changes prevent desktop login:

1. Try another already-open administrator session or a recovery/TTY login.
2. Restore the backups of the PAM files and U2F mapping file.
3. If you cannot authenticate, use your distribution's recovery mode or a trusted live environment and follow its documented recovery process.
4. Validate sudo configuration after restoring it, for example with `visudo -c`.
5. Reboot only after password-based login and administrator access have been verified.

If FIDO2-based LUKS unlock fails, use the known-good LUKS passphrase or another previously configured recovery method. Do not erase keyslots or token metadata until you have confirmed that your data is accessible and your backup is usable.

## Security and limitations

- A lost, damaged, blocked, or unavailable key can prevent authentication if no fallback method remains.
- A PIN requirement depends on authenticator and software support; verify actual behavior on your own system.
- PAM configuration is security-critical. Incorrect control flags or module options can weaken security or lock users out.
- This repository is a personal-use project, not a security audit or a guarantee of compatibility.
- Review scripts before running them, and do not run them on a production or irreplaceable system without a tested recovery plan.

## Disclaimer

**Use at your own risk.** The software and instructions are provided “as is,” without warranties or guarantees of any kind. You are responsible for reviewing the code, verifying compatibility, protecting your recovery credentials, and ensuring you can recover your system and data.
