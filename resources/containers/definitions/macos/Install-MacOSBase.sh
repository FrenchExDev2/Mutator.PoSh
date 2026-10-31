#!/bin/bash
set -euo pipefail
if [ "$EUID" -eq 0 ]; then echo 'Run as the macOS provisioning user; sudo is used only for package installation.' >&2; exit 1; fi
xcode-select -p >/dev/null || { echo 'Install Apple Command Line Tools first.' >&2; exit 1; }
test -d /Volumes/shared || sudo mount_9p shared
source_dir=/Volumes/shared/mutator
metadata="$source_dir/runtime.json"
temporary=$(mktemp -d)
trap 'rm -f "$temporary/powershell.pkg" "$temporary/dotnet.pkg" "$temporary/homebrew.sh"; rmdir "$temporary"' EXIT
# Read one pinned runtime value from the shared metadata. Missing keys fail under
# the script's strict error policy before a package can be accepted for install.
get_value() { /usr/bin/plutil -extract "$1" raw -o - "$metadata"; }
curl -fsSL "$(get_value PowerShell.Uri)" -o "$temporary/powershell.pkg"
printf '%s  %s\n' "$(get_value PowerShell.Sha256)" "$temporary/powershell.pkg" | shasum -a 256 -c -
sudo installer -pkg "$temporary/powershell.pkg" -target /
curl -fsSL "$(get_value Dotnet.Uri)" -o "$temporary/dotnet.pkg"
printf '%s  %s\n' "$(get_value Dotnet.Sha512)" "$temporary/dotnet.pkg" | shasum -a 512 -c -
sudo installer -pkg "$temporary/dotnet.pkg" -target /
if ! command -v /usr/local/bin/brew >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$temporary/homebrew.sh"
    printf '%s  %s\n' "$(get_value HomebrewSha256)" "$temporary/homebrew.sh" | shasum -a 256 -c -
    NONINTERACTIVE=1 /bin/bash "$temporary/homebrew.sh"
fi
sudo /usr/local/bin/pwsh -NoLogo -NoProfile -File "$source_dir/Initialize-MacOSBase.ps1" -ProvisioningUser "$USER" -SharedRoot "$source_dir"
