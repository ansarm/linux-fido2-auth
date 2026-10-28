#!/usr/bin/env bash
#
# reverse-fido2-linux.sh
# Restore PAM/U2F/sudoers files from a backup created by configure-fido2-linux.sh.
#
# This script does not change LUKS, crypttab, systemd-cryptenroll, initramfs,
# boot settings, or enrolled authenticator credentials.
#
set -Eeuo pipefail
umask 077

readonly AUTHFILE="/etc/u2f_mappings"
readonly PAM_FILES=(/etc/pam.d/gdm-password /etc/pam.d/sudo)
readonly SUDOERS_DROPIN="/etc/sudoers.d/99-fido2-no-cache"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./reverse-fido2-linux.sh"
command -v visudo >/dev/null 2>&1 || die "visudo not found; install sudo."
command -v install >/dev/null 2>&1 || die "install command not found."

printf 'This restores PAM, U2F mapping, and sudoers files from a configuration backup.\n'
printf 'It does NOT undo LUKS/FIDO2 boot enrollment or erase credentials stored on the key.\n\n'
read -r -p "Path to backup directory printed by configure-fido2-linux.sh: " BACKUP_DIR
[[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || die "Backup directory does not exist."
[[ -f "$BACKUP_DIR/changed-files.txt" ]] || die "No changed-files.txt found in the selected backup directory."

for f in "${PAM_FILES[@]}"; do
    [[ -f "$BACKUP_DIR$f" ]] || die "Expected PAM backup missing: $BACKUP_DIR$f"
done

printf '\nThe following files will be restored or removed:\n'
for f in "${PAM_FILES[@]}" "$AUTHFILE" "$SUDOERS_DROPIN"; do
    if [[ -e "$BACKUP_DIR$f" ]]; then
        printf '  RESTORE %s\n' "$f"
    elif [[ "$f" == "$AUTHFILE" || "$f" == "$SUDOERS_DROPIN" ]]; then
        printf '  REMOVE  %s (it did not exist before configuration)\n' "$f"
    fi
done

printf '\nA safety snapshot of the current files will be saved under /var/backups.\n'
read -r -p "Type REVERSE to continue: " confirm
[[ "$confirm" == "REVERSE" ]] || die "Cancelled."

SAFETY_DIR="/var/backups/linux-fido2-reversal-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "$SAFETY_DIR"
for f in "${PAM_FILES[@]}" "$AUTHFILE" "$SUDOERS_DROPIN"; do
    if [[ -e "$f" ]]; then
        install -d -m 0700 "$SAFETY_DIR$(dirname "$f")"
        cp -a -- "$f" "$SAFETY_DIR$f"
    fi
done
printf '%s\n' "${PAM_FILES[@]}" "$AUTHFILE" "$SUDOERS_DROPIN" > "$SAFETY_DIR/files-snapshotted.txt"
info "Current-state safety snapshot: $SAFETY_DIR"

# Restore the exact pre-configuration files, or remove files created by the
# configuration script. LUKS and the authenticator itself are never modified.
for f in "${PAM_FILES[@]}" "$AUTHFILE" "$SUDOERS_DROPIN"; do
    if [[ -e "$BACKUP_DIR$f" ]]; then
        install -d -m 0755 "$(dirname "$f")"
        cp -a -- "$BACKUP_DIR$f" "$f"
    elif [[ "$f" == "$AUTHFILE" || "$f" == "$SUDOERS_DROPIN" ]]; then
        rm -f -- "$f"
    fi
done

if ! visudo -c; then
    printf 'ERROR: sudoers validation failed after restore; restoring the pre-reversal snapshot.\n' >&2
    for f in "${PAM_FILES[@]}" "$AUTHFILE" "$SUDOERS_DROPIN"; do
        if [[ -e "$SAFETY_DIR$f" ]]; then
            cp -a -- "$SAFETY_DIR$f" "$f"
        elif [[ "$f" == "$AUTHFILE" || "$f" == "$SUDOERS_DROPIN" ]]; then
            rm -f -- "$f"
        fi
    done
    die "Reversal was rolled back. Inspect $SAFETY_DIR and restore manually if needed."
fi

info "Restoration complete."
printf 'Restored PAM and mapping state from: %s\n' "$BACKUP_DIR"
printf 'Safety snapshot of the previous state: %s\n' "$SAFETY_DIR"
printf '\nNEXT STEPS:\n'
printf '  1. Keep this administrator session open.\n'
printf '  2. Test password-based sudo and desktop login in a separate session.\n'
printf '  3. Do not reboot or log out until recovery access is confirmed.\n'
printf '  4. LUKS/boot enrollment and FIDO2 credentials on the key were not changed.\n'
