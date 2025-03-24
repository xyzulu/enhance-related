#!/bin/bash

# *********************************************************************************************
# Use at your own risk. This script uses the Enhance API to import a BIND formatted DNS zone. 
# You will need to provide at least the API url, ORG_ID and Access Token.
# 
# Usage: import_dns_zone.sh zonefile.txt
#
# During the script you will also need to specify the website ID and the domain ID. 
# Hopefully you know how to find these.
# *********************************************************************************************


API_URL="https://control.domain.com/api"
ORG_ID="xxxx"
ACCESS_TOKEN="xxxx"

AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"
CONTENT_TYPE="Content-Type: application/json"

declare -A SAVED_RECORDS
declare -a NEW_RECORDS

ZONE_FILE="$1"

if [[ -z "$ZONE_FILE" ]]; then
    printf "Usage: %s <zone_file_path>\n" "$0" >&2
    exit 1
fi

read -rp "Enter Website ID: " WEBSITE_ID
read -rp "Enter Domain ID: " DOMAIN_ID

ZONE_API="$API_URL/orgs/$ORG_ID/websites/$WEBSITE_ID/domains/$DOMAIN_ID/dns-zone"

validate_zone_file() {
    if [[ ! -f "$ZONE_FILE" ]]; then
        printf "Zone file not found at: %s\n" "$ZONE_FILE" >&2
        return 1
    fi
}

get_zone_records() {
    local response; response=$(curl -s -H "$AUTH_HEADER" "$ZONE_API")
    if [[ -z "$response" ]]; then
        printf "API returned empty response.\n" >&2
        return 1
    fi
    if jq -e 'has("records")' <<< "$response" >/dev/null; then
        response=$(jq -c '.records' <<< "$response")
    elif jq -e 'has("data")' <<< "$response" >/dev/null; then
        response=$(jq -c '.data' <<< "$response")
    elif [[ "$(jq -r 'type' <<< "$response")" != "array" ]]; then
        printf "Expected JSON array or object with 'records' or 'data'.\n" >&2
        return 1
    fi
    printf "Current DNS Records:\n%s\n" "$response"
    printf "Press Enter to continue...\n"
    read -r
}

save_essential_records() {
    local response; response=$(curl -s -H "$AUTH_HEADER" "$ZONE_API")
    if [[ -z "$response" ]]; then
        printf "API returned empty response during record save.\n" >&2
        return 1
    fi
    if jq -e 'has("records")' <<< "$response" >/dev/null; then
        response=$(jq -c '.records' <<< "$response")
    elif jq -e 'has("data")' <<< "$response" >/dev/null; then
        response=$(jq -c '.data' <<< "$response")
    fi

    local found=0
    while IFS= read -r record; do
        local kind; kind=$(jq -r '.kind' <<< "$record")
        local name; name=$(jq -r '.name' <<< "$record")
        local value; value=$(jq -r '.value' <<< "$record")
        value=$(sed 's/"/\\"/g' <<< "$value")
        if [[ "$kind" == "A" && "$name" == "@" ]]; then
            SAVED_RECORDS["$name"]="{\"kind\": \"$kind\", \"name\": \"$name\", \"value\": \"$value\", \"ttl\": 3600}"
            found=1
        elif [[ "$kind" == "CNAME" && "$name" == "www" ]]; then
            SAVED_RECORDS["$name"]="{\"kind\": \"$kind\", \"name\": \"$name\", \"value\": \"$value\", \"ttl\": 3600}"
            found=1
        fi
    done < <(jq -c '.[]' <<< "$response")

    if [[ $found -eq 0 ]]; then
        printf "No @ A record or www CNAME found to save.\n" >&2
        return 1
    fi
}

parse_zone_file() {
    local parsed_output=""
    local zone_root
    zone_root=$(awk '/IN[[:space:]]+SOA/ { print $1 }' "$ZONE_FILE" | sed 's/\.$//')
    [[ -z "$zone_root" ]] && zone_root=$(basename "$ZONE_FILE" | cut -d'.' -f1-2)

    local py_script json
    py_script=$(mktemp)

    cat > "$py_script" <<'PYTHON_EOF'
import re, sys, json

def parse_zone_file(path):
    try:
        with open(path) as f:
            content = f.read()
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        return

    records = []
    origin = ''
    default_ttl = '300'

    lines = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith(';') or line.startswith(';;'):
            continue
        clean = ''
        in_quotes = False
        for c in line:
            if c == '"': in_quotes = not in_quotes
            if c == ';' and not in_quotes:
                break
            clean += c
        lines.append(clean.strip())

    # Collapse multiline
    zone = []
    buf = ''
    parens = 0
    for line in lines:
        parens += line.count('(')
        parens -= line.count(')')
        buf += ' ' + line
        if parens <= 0:
            zone.append(buf.strip())
            buf = ''
    if buf:
        zone.append(buf.strip())

    for line in zone:
        if line.upper().startswith('$ORIGIN'):
            origin = line.split()[1]
            continue
        if line.upper().startswith('$TTL'):
            default_ttl = line.split()[1]
            continue

        fields = line.split()
        idx = 0

        name = '@'
        if not re.match(r'^(IN|A|AAAA|MX|CNAME|NS|SOA|TXT|SRV|CAA)$', fields[0], re.I):
            name = fields[idx]
            idx += 1

        ttl = default_ttl
        if idx < len(fields) and fields[idx].isdigit():
            ttl = fields[idx]
            idx += 1

        if idx < len(fields) and re.match(r'^(IN|CH|HS)$', fields[idx], re.I):
            idx += 1

        if idx >= len(fields):
            continue

        rtype = fields[idx].upper()
        idx += 1
        rdata = ' '.join(fields[idx:]).strip()

        if rtype == 'TXT':
            rdata = ' '.join(re.findall(r'"([^"]*)"', rdata))

        records.append({
            "name": name,
            "ttl": ttl,
            "type": rtype,
            "value": rdata
        })

    print(json.dumps(records))

if __name__ == '__main__':
    parse_zone_file(sys.argv[1])
PYTHON_EOF

    if ! json=$(python3 "$py_script" "$ZONE_FILE" 2>&1); then
        printf "Python failed:\n%s\n" "$json" >&2
        rm -f "$py_script"
        return 1
    fi
    rm -f "$py_script"

    if [[ "$json" =~ error ]]; then
        printf "Zone file parse error: %s\n" "$json" >&2
        return 1
    fi

    if ! jq -e . >/dev/null 2>&1 <<< "$json"; then
        printf "Zone file parsing failed or returned invalid JSON:\n%s\n" "$json" >&2
        return 1
    fi

    local record name type ttl value
    while IFS= read -r record; do
        type=$(jq -r '.type' <<< "$record")
        name=$(jq -r '.name' <<< "$record")
        ttl="3600"
        value=$(jq -r '.value' <<< "$record")

        [[ "$type" == "SOA" || "$type" == "NS" ]] && continue
        [[ "$type" == "A" && "$name" == "@" ]] && continue
        [[ "$type" == "CNAME" && "$name" == "www" ]] && continue

        # Normalize name relative to zone
name="${name%.}"
name="${name%%.$zone_root}"
name="${name%%.${zone_root}.}"
[[ "$name" == "$zone_root" || "$name" == "" ]] && name="@"

# Skip any @ A or www CNAME coming from the zone file
if [[ "$type" == "A" && "$name" == "@" ]]; then continue; fi
if [[ "$type" == "CNAME" && "$name" == "www" ]]; then continue; fi

        local record_json
        record_json=$(printf '{"kind": "%s", "name": "%s", "value": "%s", "ttl": %s}' "$type" "$name" "$value" "$ttl")
        NEW_RECORDS+=("$record_json")
        parsed_output+="$record_json"$'\n'
    done < <(jq -c '.[]' <<< "$json")

    if [[ ${#NEW_RECORDS[@]} -eq 0 ]]; then
        printf "No records parsed from zone file.\n" >&2
        return 1
    fi

    printf "Parsed records from zone file:\n%s\n" "$parsed_output"
    printf "Press Enter to continue with import...\n"
    read -r
}

create_new_records() {
    local create_url="$ZONE_API/records"
    for record in "${SAVED_RECORDS[@]}"; do
        local resp; resp=$(curl -s -w "\n%{http_code}" -X POST -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -d "$record" "$create_url")
        local body; body=$(head -n1 <<< "$resp")
        local code; code=$(tail -n1 <<< "$resp")
        if [[ "$code" != "200" && "$code" != "201" ]]; then
            printf "Failed to create saved record: %s (HTTP %s)\n" "$record" "$code" >&2
        else
            printf "Created saved record: %s\n" "$record"
        fi
    done
    for record in "${NEW_RECORDS[@]}"; do
        local resp; resp=$(curl -s -w "\n%{http_code}" -X POST -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -d "$record" "$create_url")
        local body; body=$(head -n1 <<< "$resp")
        local code; code=$(tail -n1 <<< "$resp")
        if [[ "$code" != "200" && "$code" != "201" ]]; then
            printf "Failed to create zone file record: %s (HTTP %s)\n" "$record" "$code" >&2
        else
            printf "Created zone file record: %s\n" "$record"
        fi
    done
}

delete_all_records() {
    local response; response=$(curl -s -H "$AUTH_HEADER" "$ZONE_API")
    if [[ -z "$response" ]]; then
        printf "Failed to fetch existing records for deletion.\n" >&2
        return 1
    fi

    if jq -e 'has("records")' <<< "$response" >/dev/null; then
        response=$(jq -c '.records' <<< "$response")
    elif jq -e 'has("data")' <<< "$response" >/dev/null; then
        response=$(jq -c '.data' <<< "$response")
    elif [[ "$(jq -r 'type' <<< "$response")" != "array" ]]; then
        printf "Unexpected format in API response.\n" >&2
        return 1
    fi

    local deleted=0
    while IFS= read -r record; do
        local id kind name value
        id=$(jq -r '.id' <<< "$record")
        kind=$(jq -r '.kind' <<< "$record")
        name=$(jq -r '.name' <<< "$record")
        value=$(jq -r '.value' <<< "$record")

        local del_url="$ZONE_API/records/$id"
        local code; code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "$AUTH_HEADER" "$del_url")

        if [[ "$code" == "200" || "$code" == "204" ]]; then
            ((deleted++))
        else
            printf "Failed to delete record %s (%s %s %s): HTTP %s\n" "$id" "$kind" "$name" "$value" "$code" >&2
        fi
    done < <(jq -c '.[]' <<< "$response")

    printf "Deleted %s record(s)\n" "$deleted"
}

main() {
    if ! validate_zone_file; then return 1; fi
    if ! get_zone_records; then return 1; fi
    if ! save_essential_records; then return 1; fi
    if ! parse_zone_file; then return 1; fi

printf "\nWARNING: All existing DNS records will be deleted before import.\n"
read -rp "Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    printf "Aborting as per user input.\n" >&2
    return 1
fi

if ! delete_all_records; then return 1; fi
    if ! create_new_records; then return 1; fi
}

main
