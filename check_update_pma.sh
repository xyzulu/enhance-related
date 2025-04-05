#!/usr/bin/env bash

set -euo pipefail

VERSION_FILE_NAME="Version.php"
SEARCH_ROOT="/var/www"
LATEST_VERSION_URL="https://www.phpmyadmin.net/home_page/version.txt"
LATEST_TARBALL_URL="https://files.phpmyadmin.net/phpMyAdmin"
TMP_DIR=$(mktemp -d /tmp/phpmyadmin_update.XXXXXX)
PRESERVE_FILES=("config.inc.php" "signon.php")

get_phpmyadmin_version() {
    local version_file; version_file="$1"
    local version_line; version_line=$(grep -E "public const VERSION\s*=" "$version_file" 2>/dev/null)

    if [[ -z "$version_line" ]]; then
        printf "Error: VERSION line not found in %s\n" "$version_file" >&2
        return 1
    fi

    local version; version=$(sed -nE "s/.*VERSION\s*=\s*'([^']+)'.*/\1/p" <<< "$version_line")

    if [[ -z "$version" ]]; then
        printf "Error: Could not extract version from %s\n" "$version_file" >&2
        return 1
    fi

    printf "%s\n" "$version"
}

find_version_files() {
    find "$SEARCH_ROOT" -type f -path "*/libraries/classes/$VERSION_FILE_NAME"
}

fetch_latest_version() {
    local latest_raw; latest_raw=$(curl -fsSL "$LATEST_VERSION_URL" 2>/dev/null)

    if [[ -z "$latest_raw" ]]; then
        printf "Error: Empty response from %s\n" "$LATEST_VERSION_URL" >&2
        return 1
    fi

    local latest; latest=$(tr -dc '0-9.\n' <<< "$latest_raw" | head -n1)

    if [[ -z "$latest" ]]; then
        printf "Error: Could not parse version from response: '%s'\n" "$latest_raw" >&2
        return 1
    fi

    if ! grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$latest"; then
        printf "Error: Invalid version format fetched: '%s'\n" "$latest" >&2
        return 1
    fi

    printf "%s\n" "$latest"
}

compare_versions() {
    local current="$1"
    local latest="$2"

    [[ "$current" == "$latest" ]] && return 0
    [[ "$(printf "%s\n%s" "$current" "$latest" | sort -V | head -n1)" == "$latest" ]] && return 1
    return 0
}

download_latest_tarball() {
    local latest="$1"
    local tarball; tarball="$TMP_DIR/phpMyAdmin-${latest}-all-languages.tar.gz"
    local url; url="${LATEST_TARBALL_URL}/${latest}/phpMyAdmin-${latest}-all-languages.tar.gz"

    if ! curl -fLo "$tarball" --retry 3 --retry-delay 2 "$url"; then
        printf "Error: Failed to download tarball from %s\n" "$url" >&2
        return 1
    fi

    printf "%s\n" "$tarball"
}

extract_tarball() {
    local tarball="$1"
    local extract_dir; extract_dir="$TMP_DIR/extracted"

    mkdir -p "$extract_dir"

    if ! tar -xzf "$tarball" -C "$extract_dir" --strip-components=1; then
        printf "Error: Failed to extract tarball: %s\n" "$tarball" >&2
        return 1
    fi

    printf "%s\n" "$extract_dir"
}

preserve_files() {
    local src_dir="$1"
    local dest_dir="$2"

    for file in "${PRESERVE_FILES[@]}"; do
        if [[ -f "$src_dir/$file" ]]; then
            cp -p "$src_dir/$file" "$dest_dir/"
        fi
    done
}

update_phpmyadmin() {
    local target_dir="$1"
    local extract_dir="$2"

    local backup_dir; backup_dir="${target_dir}_backup_$(date +%s)"
    mv "$target_dir" "$backup_dir" || return 1

    mkdir -p "$target_dir"
    cp -a "$extract_dir/." "$target_dir/"
    preserve_files "$backup_dir" "$target_dir"

    printf "✔ Updated %s\n" "$target_dir"
}

main() {
    local version_files; version_files=$(find_version_files)
    if [[ -z "$version_files" ]]; then
        printf "No phpMyAdmin version files found under %s\n" "$SEARCH_ROOT" >&2
        rm -rf "$TMP_DIR"
        return 1
    fi

    local latest_version; latest_version=$(fetch_latest_version) || { rm -rf "$TMP_DIR"; return 1; }

    local needs_update=0
    local tarball=""
    local extract_dir=""

    local file; while IFS= read -r file; do
        local version; version=$(get_phpmyadmin_version "$file") || continue
        local install_dir; install_dir=$(dirname "$(dirname "$(dirname "$file")")")

        printf "phpMyAdmin installation: %s\nVersion: %s\n" "$install_dir" "$version"

        if ! compare_versions "$version" "$latest_version"; then
            printf "✘ Outdated (latest: %s)\n" "$latest_version"
            if [[ "$needs_update" -eq 0 ]]; then
                tarball=$(download_latest_tarball "$latest_version") || { rm -rf "$TMP_DIR"; return 1; }
                extract_dir=$(extract_tarball "$tarball") || { rm -rf "$TMP_DIR"; return 1; }
                needs_update=1
            fi
            if update_phpmyadmin "$install_dir" "$extract_dir"; then
                printf "✔ Upgrade successful: %s → %s\n" "$version" "$latest_version"
            else
                printf "Error: Upgrade failed for %s\n" "$install_dir" >&2
            fi
        else
            printf "✔ Up-to-date\n"
        fi

        printf "\n"
    done <<< "$version_files"

    rm -rf "$TMP_DIR"
    return 0
}

main "$@"
