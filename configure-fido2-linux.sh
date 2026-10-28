#!/usr/bin/env bash
#
# configure-fido2-linux.sh
# Configure PAM U2F/FIDO2 authentication for GNOME/GDM and sudo.
#
# This script deliberately does NOT modify LUKS, crypttab, systemd-cryptenroll,
# initramfs, or boot configuration. If FIDO2 LUKS unlock is already working,
# it leaves that setup untouched.
#
# Review this script before running it. Keep a working password/recovery path.
#
set -Eeuo pipefail
umask 077

readonly AUTHFILE="/etc/u2f_mappings"
readonly PAM_MODULE_LINE="auth sufficient pam_u2f.so authfile=/etc/u2f_mappings cue pinverification=1 userverification=0"
readonly PAM_FILES=(/etc/pam.d/gdm-password /etc/pam.d/sudo)
readonly SUDOERS_DROPIN="/etc/sudoers.d/99-fido2-no-cache"

BACKUP_DIR=""
CHANGED_FILES=()

die() { printf 'ERROR: %s\n' "$*" >&2; rollback; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

rollback() {
    local f
    if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
        warn "Attempting to restore changed files from $BACKUP_DIR"
        for f in "${CHANGED_FILES[@]:-}"; do
            [[ -n "$f" ]] || continue
            if [[ -e "$BACKUP_DIR${f}" ]]; then
                cp -a -- "$BACKUP_DIR${f}" "$f" || warn "Could not restore $f"
            elif [[ "$f" == "$AUTHFILE" || "$f" == "$SUDOERS_DROPIN" ]]; then
                rm -f -- "$f" || warn "Could not remove newly created $f"
            fi
        done
    fi
}

on_error() {
    local rc=$?
    trap - ERR
    warn "An error occurred (exit $rc)."
    rollback
    exit "$rc"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
command -v pamu2fcfg >/dev/null 2>&1 || die "pamu2fcfg not found. Install the PAM U2F package first."
command -v visudo >/dev/null 2>&1 || die "visudo not found; install sudo."
command -v install >/dev/null 2>&1 || die "install command not found."
command -v awk >/dev/null 2>&1 || die "awk not found."

for f in "${PAM_FILES[@]}"; do
    [[ -f "$f" ]] || die "Required PAM file not found: $f"
    grep -Eq '^[[:space:]]*@include[[:space:]]+common-auth([[:space:]]|$)' "$f" ||
        die "$f does not contain '@include common-auth'; refusing to guess where to insert the rule."
done

# Verify that installed tools advertise the options this script relies on.
pamu2fcfg --help 2>&1 | grep -q -- '--pin-verification' ||
    die "Your pamu2fcfg does not advertise --pin-verification (-N)."
if ! grep -Rqs 'pinverification' /usr/share/man/man8/pam_u2f* /usr/share/doc/libpam-u2f 2>/dev/null; then
    warn "Could not find pinverification in local documentation. Continuing only after explicit confirmation."
    read -r -p "Have you verified that your installed pam_u2f.so supports pinverification=1? Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || die "Stopped without changes."
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    read -r -p "Linux account to enroll (for example, sysop): " TARGET_USER
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "Choose a non-root user account."
id "$TARGET_USER" >/dev/null 2>&1 || die "Account does not exist: $TARGET_USER"

printf '\nThis will configure FIDO2/PIN authentication for %s in GDM and sudo.\n' "$TARGET_USER"
printf 'Password authentication remains as a fallback. LUKS/boot settings will NOT be changed.\n'
printf 'Keep a working administrator session open while testing.\n\n'
read -r -p "Type CONFIGURE to continue: " confirm
[[ "$confirm" == "CONFIGURE" ]] || die "Cancelled."

BACKUP_DIR="/var/backups/linux-fido2-auth-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "$BACKUP_DIR"
for f in "${PAM_FILES[@]}"; do
    install -d -m 0700 "$BACKUP_DIR$(dirname "$f")"
    cp -a -- "$f" "$BACKUP_DIR$f"
done
if [[ -e "$AUTHFILE" ]]; then
    install -d -m 0700 "$BACKUP_DIR$(dirname "$AUTHFILE")"
    cp -a -- "$AUTHFILE" "$BACKUP_DIR$AUTHFILE"
fi
if [[ -e "$SUDOERS_DROPIN" ]]; then
    install -d -m 0700 "$BACKUP_DIR$(dirname "$SUDOERS_DROPIN")"
    cp -a -- "$SUDOERS_DROPIN" "$BACKUP_DIR$SUDOERS_DROPIN"
fi
printf '%s\n' "$AUTHFILE" "${PAM_FILES[@]}" "$SUDOERS_DROPIN" > "$BACKUP_DIR/changed-files.txt"
info "Backups stored in $BACKUP_DIR"

# Enroll a PIN-verification credential. The command prompts for authenticator
# interaction and may prompt for the FIDO2 PIN.
info "Register your FIDO2 key with PIN verification"
tmp_mapping="$(mktemp)"
trap 'rm -f -- "${tmp_mapping:-}"' EXIT
pamu2fcfg -N -u "$TARGET_USER" > "$tmp_mapping"
[[ -s "$tmp_mapping" ]] || die "pamu2fcfg returned no mapping; no configuration applied."
registration="$(cat "$tmp_mapping")"
[[ "$registration" == *:* ]] || die "Unexpected pamu2fcfg output; expected username:credential."
reg_user="${registration%%:*}"
reg_cred="${registration#*:}"
reg_cred="${reg_cred# }"
[[ "$reg_user" == "$TARGET_USER" && -n "$reg_cred" ]] ||
    die "pamu2fcfg output username/credential did not match the selected account."

# Build a temporary mapping file, merging the new credential into an existing
# user line rather than replacing previously registered keys.
map_tmp="$(mktemp)"
if [[ -f "$AUTHFILE" ]]; then
    awk -v user="$TARGET_USER" -v cred="$reg_cred" '
        BEGIN { found=0 }
        {
            sep=index($0, ":")
            if (sep > 0 && substr($0,1,sep-1) == user) {
                if (!found) {
                    existing=substr($0,sep+1)
                    sub(/^[[:space:]]+/, "", existing)
                    print user ": " existing ":" cred
                    found=1
                }
                next
            }
            print
        }
        END { if (!found) print user ": " cred }
    ' "$AUTHFILE" > "$map_tmp"
else
    printf '%s\n' "$registration" > "$map_tmp"
fi
install -o root -g root -m 0600 "$map_tmp" "$AUTHFILE"
rm -f -- "$map_tmp"
CHANGED_FILES+=("$AUTHFILE")

# Update a target PAM file safely: replace an existing matching rule, or insert
# immediately before @include common-auth. Other PAM lines are retained.
for f in "${PAM_FILES[@]}"; do
    tmp_pam="$(mktemp)"
    awk -v rule="$PAM_MODULE_LINE" '
        BEGIN { replaced=0; inserted=0 }
        /^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_u2f\.so[[:space:]].*authfile=\/etc\/u2f_mappings([[:space:]]|$)/ {
            if (!replaced) print rule
            replaced=1
            next
        }
        /^[[:space:]]*@include[[:space:]]+common-auth([[:space:]]|$)/ {
            if (!replaced && !inserted) { print rule; inserted=1 }
        }
        { print }
        END { if (!replaced && !inserted) exit 42 }
    ' "$f" > "$tmp_pam" || { rm -f "$tmp_pam"; die "Could not safely update $f"; }
    cat "$tmp_pam" > "$f"
    rm -f "$tmp_pam"
    CHANGED_FILES+=("$f")
    info "Configured $f"
done

# Disable sudo timestamp caching so each new sudo invocation runs PAM again.
# This does not reauthenticate commands inside an already-open root shell.
printf '%s\n' 'Defaults timestamp_timeout=0' > "$SUDOERS_DROPIN"
chmod 0440 "$SUDOERS_DROPIN"
chown root:root "$SUDOERS_DROPIN"
CHANGED_FILES+=("$SUDOERS_DROPIN")

if ! visudo -c; then
    die "visudo validation failed."
fi

# Basic structural check; do not attempt to simulate a PAM authentication.
for f in "${PAM_FILES[@]}"; do
    grep -Fqx "$PAM_MODULE_LINE" "$f" || die "Expected PAM rule not found in $f"
done
[[ "$(stat -c '%a' "$AUTHFILE")" == "600" ]] || die "Unexpected permissions on $AUTHFILE"

trap - ERR
info "Configuration completed."
printf 'Mapping file: %s (root-owned, mode 0600)\n' "$AUTHFILE"
printf 'Backup directory: %s\n' "$BACKUP_DIR"
printf '\nNEXT STEPS — DO NOT CLOSE THIS SESSION YET:\n'
printf '  1. Keep this administrator session open. Open another terminal.\n'
printf '  2. Test sudo with: sudo -k -v\n'
printf '  3. Test a new desktop login only after sudo and password fallback work.\n'
printf '  4. Confirm password fallback works before rebooting.\n'
printf '  5. LUKS/boot configuration was not changed by this script.\n'
printf '\nRecovery: restore the backed-up PAM files, mapping file, and sudoers drop-in from %s.\n' "$BACKUP_DIR"
printf 'If this script failed mid-change, inspect the files and restore backups manually before logging out.\n'
