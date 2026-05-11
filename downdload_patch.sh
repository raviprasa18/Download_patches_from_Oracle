#!/usr/bin/env bash

set -euo pipefail

FILE="patch.html"

# Uncomment these lines if you are behind a proxy server
#export https_proxy=http://your-proxy-server:proxy-port
#export http_proxy=http://your-proxy-server:proxy-port

read -p "Enter Patch Number , for example 38832610: " PATCH_NUMBER
read -p "Enter Email-ID (your-email@oracle.com): " EMAIL_ID
read -s -p "Enter password (your SSO Password): " PASSWORD

echo
echo "Patch Number : $PATCH_NUMBER and Email ID is : $EMAIL_ID"

download_patch_file() {
    local aru
    local patch_file
    local download_url

    aru=$(grep -o 'name="aru" value="[0-9]*"' "$FILE" | awk -F'"' '{print $4}' | head -n 1)
    patch_file=$(grep -o 'patch_file=p[^"&]*\.zip' "$FILE" | awk -F= '{print $2}' | head -n 1)

    if [ -z "$aru" ] || [ -z "$patch_file" ]; then
        echo "Failed to retrieve patch information. Please check the patch number and credentials."
        exit 1
    fi

    download_url="https://updates.oracle.com/Orion/Services/download/${patch_file}?aru=${aru}&patch_file=${patch_file}"

    echo "Downloading from URL: $download_url"
    curl -L -u "$EMAIL_ID:$PASSWORD" -o "$patch_file" "$download_url"
}

get_hidden_value() {
    local field_name="$1"

    tr '\n' ' ' < "$FILE" |
        sed -n "s/.*name=\"${field_name}\"[[:space:]]*value=\"\([^\"]*\)\".*/\1/p" |
        head -n 1
}

has_select() {
    local select_name="$1"

    grep -q "<select[[:space:]]\+name=${select_name}" "$FILE"
}

get_select_options() {
    local select_name="$1"

    awk -v select_name="$select_name" '
        $0 ~ "<select[[:space:]]+name=" select_name { in_block=1; next }
        /<\/select>/ { in_block=0 }
        in_block && /<option/ { print }
    ' "$FILE" |
    sed -E 's/.*value="([^"]*)".*>([^<]*).*/\1|\2/' |
    sed 's/[[:space:]]*$//' |
    awk -F'|' '
        $1 == "" { next }
        $2 ~ /^[[:space:]-]+$/ { next }
        { print }
    '
}

select_option() {
    local select_name="$1"
    local prompt="$2"
    local choice
    local index
    local -a options

    mapfile -t options < <(get_select_options "$select_name")

    if [ ${#options[@]} -eq 0 ]; then
        echo "No selectable $prompt options found."
        return 1
    fi

    echo "$prompt"
    echo "-------------------"

    for i in "${!options[@]}"; do
        SELECTED_TEXT="${options[$i]##*|}"
        printf "%d) %s\n" $((i+1)) "$SELECTED_TEXT"
    done

    echo
    read -p "Enter choice number: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#options[@]}" ]; then
        echo "Invalid selection"
        exit 1
    fi

    index=$((choice-1))
    SELECTED_VALUE="${options[$index]%%|*}"
    SELECTED_TEXT="${options[$index]##*|}"

    echo
    echo "You selected:"
    echo "Text  : $SELECTED_TEXT"
    echo "Value : $SELECTED_VALUE"

    return 0
}

handle_release_change() {
    local change_url

    select_option "release" "Select a Release:" || return 1

    change_url="https://updates.oracle.com/Orion/PatchDetails/handle_rel_change?release=$SELECTED_VALUE&patch_num=$PATCH_NUMBER"

    echo "URL for selected release: $change_url"
    curl -s -L -u "$EMAIL_ID:$PASSWORD" -o "$FILE" "$change_url"

    return 0
}

handle_plat_lang_change() {
    local aru
    local patch_num
    local patch_num_id
    local default_release
    local default_plat_lang
    local change_url

    select_option "plat_lang" "Select a Platform/Language:" || return 1

    aru=$(get_hidden_value "aru")
    patch_num=$(get_hidden_value "patch_num")
    patch_num_id=$(get_hidden_value "patch_num_id")
    default_release=$(get_hidden_value "default_release")
    default_plat_lang=$(get_hidden_value "default_plat_lang")

    echo "Retrieved ARU: $aru"
    echo "Retrieved patch_num: $patch_num"
    echo "Retrieved patch_num_id: $patch_num_id"
    echo "Retrieved default_release: $default_release"
    echo "Retrieved default_plat_lang: $default_plat_lang"

    change_url="https://updates.oracle.com/Orion/PatchDetails/handle_plat_lang_change?plat_lang=$default_plat_lang&aru=$aru&patch_num=$patch_num&patch_num_id=$patch_num_id&default_release=$default_release&default_plat_lang=$SELECTED_VALUE"

    echo "URL for selected platform/language: $change_url"
    curl -s -L -u "$EMAIL_ID:$PASSWORD" -o "$FILE" "$change_url"

    return 0
}

echo "Downloading patch details for patch number $PATCH_NUMBER..."
curl -s -o "$FILE" -u "$EMAIL_ID:$PASSWORD" "https://updates.oracle.com/ARULink/PatchDetails/process_form?patch_num=$PATCH_NUMBER"

if grep -q "401 Authorization Required" "$FILE"; then
    echo "Error: 401 Authorization Required , user authentication failed. Please check your email ID and password."
    exit 1
fi

handled_selection="false"

if has_select "release"; then
    handle_release_change && handled_selection="true"
fi

if has_select "plat_lang"; then
    handle_plat_lang_change && handled_selection="true"
fi

if [ "$handled_selection" = "false" ]; then
    echo "No release or platform/language options found. Downloading the default patch."
fi

download_patch_file

