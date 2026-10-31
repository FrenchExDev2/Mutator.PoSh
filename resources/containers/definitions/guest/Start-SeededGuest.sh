#!/usr/bin/env bash
set -euo pipefail
storage="${STORAGE:-/storage}"
fingerprint=$(jq -er .Fingerprint /seed/base.json)
test "$fingerprint" = "$MUTATOR_BASE_FINGERPRINT" || { echo 'Wrong guest base fingerprint' >&2; exit 1; }
mkdir -p "$storage"
if [ -f "$storage/mutator-base" ]; then
    test "$(cat "$storage/mutator-base")" = "$fingerprint" || { echo 'Storage belongs to another guest base' >&2; exit 1; }
else
    test -z "$(find "$storage" -mindepth 1 -maxdepth 1 -print -quit)" || { echo 'Refusing to overwrite nonempty guest storage' >&2; exit 1; }
    while IFS= read -r file; do
        source="/seed/storage/$file"
        target="$storage/$file"
        case "/$file/" in *"/../"*|*"/./"*|*\\*|//* ) echo 'Invalid seed file name' >&2; exit 1;; esac
        mkdir -p "$(dirname "$target")"
        checksum=$(jq -er --arg p "$file" '.Files[] | select(.Path == $p) | .Sha256' /seed/base.json)
        printf '%s  %s\n' "$checksum" "$source" | sha256sum -c - >/dev/null
        case "$file" in
            *.qcow2) qemu-img create -f qcow2 -F qcow2 -b "$source" "$target" >/dev/null ;;
            *.iso) ln -s "$source" "$target" ;;
            *) cp -- "$source" "$target" ;;
        esac
    done < <(jq -er '.Files[].Path' /seed/base.json)
    printf '%s' "$fingerprint" > "$storage/mutator-base"
fi
exec /run/entry.sh "$@"
