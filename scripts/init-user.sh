#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"

# Load Config
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    if [ -f ".env" ]; then source ".env"; 
    elif [ -f "../.env" ]; then source "../.env"; 
    else echo "❌ Error: .env file not found."; exit 1; fi
fi

DOMAIN="${OUTLINE_DOMAIN}"
TOKEN="${OUTLINE_TOKEN}"
API_URL="${DOMAIN}/api"
INPUT_FILE="$1"

# ================= VALIDATION =================
if [ -z "$INPUT_FILE" ]; then
    echo "Usage: ./scripts/util-invite-and-assign.sh <user_list_file>"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Error: Input file '$INPUT_FILE' not found."
    exit 1
fi

# ================= HELPER FUNCTIONS =================
api_post() {
    curl -s -X POST "${API_URL}/${1}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${2}"
}

# ================= MAIN LOGIC =================

echo "🚀 Starting Bulk User Onboarding..."
echo "-------------------------------------------------------"

# ---------------------------------------------------------
# STEP 1: Prepare & Send Bulk Invites
# ---------------------------------------------------------
echo "1️⃣  Preparing Invite List..."
INVITE_TEMP=$(mktemp)

while IFS= read -r line || [ -n "$line" ]; do
    if [[ -z "${line// }" ]] || [[ "$line" == "org.role."* ]]; then continue; fi

    if [[ "$line" == *"|"* ]]; then
        USER_NAME=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
        USER_EMAIL=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
        
        if [ -n "$USER_EMAIL" ]; then
            jq -n \
                --arg name "$USER_NAME" \
                --arg email "$USER_EMAIL" \
                --arg role "viewer" \
                '{name: $name, email: $email, role: $role}' >> "$INVITE_TEMP"
        fi
    fi
done < "$INPUT_FILE"

INVITE_PAYLOAD=$(jq -s '{invites: .}' "$INVITE_TEMP")
USER_COUNT=$(jq '.invites | length' <<< "$INVITE_PAYLOAD")

echo "   📧 Sending invites to $USER_COUNT users..."
INVITE_RES=$(api_post "users.invite" "$INVITE_PAYLOAD")
rm -f "$INVITE_TEMP"

IS_INVITE_OK=$(echo "$INVITE_RES" | jq -r '.ok // .success // false')
if [ "$IS_INVITE_OK" == "true" ]; then
    echo "   ✅ Invites sent successfully."
else
    echo "   ⚠️  Invite response: $(echo "$INVITE_RES" | jq -r '.error // .message // "Possible partial success or duplicate"')"
fi

echo "   ⏳ Waiting 5s for database sync..."
sleep 5

# ---------------------------------------------------------
# STEP 2: Fetch & Cache Groups and Users (With Pagination)
# ---------------------------------------------------------
echo "-------------------------------------------------------"
echo "2️⃣  Caching System Data (with Pagination)..."

declare -A MAP_GROUPS
declare -A MAP_USERS

# --- 2.1 Cache Groups ---
echo "   📥 Fetching Groups..."
OFFSET=0
LIMIT=100 # API Max Limit
GROUP_COUNT=0

while true; do
    # Fetch batch
    RES=$(api_post "groups.list" "{\"limit\": $LIMIT, \"offset\": $OFFSET, \"sort\": \"updatedAt\", \"direction\": \"DESC\"}")
    
    # Check Valid JSON
    IS_OK=$(echo "$RES" | jq -r '.ok // .success // false')
    if [ "$IS_OK" != "true" ]; then
        echo "      ❌ Error fetching groups: $(echo "$RES" | jq -r '.error')"
        break
    fi

    # Extract items
    ITEMS=$(echo "$RES" | jq -r '.data.groups[] | "\(.name)=\(.id)"')
    
    # Break if empty
    if [ -z "$ITEMS" ]; then break; fi

    # Store in Map
    while IFS="=" read -r name id; do
        if [ -n "$name" ]; then MAP_GROUPS["$name"]="$id"; ((GROUP_COUNT++)); fi
    done <<< "$ITEMS"

    # Check Pagination info to see if we need to continue
    # Some API versions return total/nextPath, but checking retrieved count is safer
    BATCH_COUNT=$(echo "$RES" | jq '.data.groups | length')
    if [ "$BATCH_COUNT" -lt "$LIMIT" ]; then break; fi
    
    # Next Page
    OFFSET=$((OFFSET + LIMIT))
done
echo "      ✅ Cached $GROUP_COUNT groups."

# --- 2.2 Cache Users ---
echo "   📥 Fetching Users..."
OFFSET=0
USER_TOTAL_COUNT=0

while true; do
    # Fetch batch
    RES=$(api_post "users.list" "{\"limit\": $LIMIT, \"offset\": $OFFSET, \"sort\": \"updatedAt\", \"direction\": \"DESC\"}")

    IS_OK=$(echo "$RES" | jq -r '.ok // .success // false')
    if [ "$IS_OK" != "true" ]; then
        echo "      ❌ Error fetching users: $(echo "$RES" | jq -r '.error')"
        break
    fi

    # Extract items
    ITEMS=$(echo "$RES" | jq -r '.data[] | "\(.email)=\(.id)"')
    
    if [ -z "$ITEMS" ]; then break; fi

    while IFS="=" read -r email id; do
        if [ -n "$email" ]; then MAP_USERS["$email"]="$id"; ((USER_TOTAL_COUNT++)); fi
    done <<< "$ITEMS"

    BATCH_COUNT=$(echo "$RES" | jq '.data | length')
    if [ "$BATCH_COUNT" -lt "$LIMIT" ]; then break; fi
    
    OFFSET=$((OFFSET + LIMIT))
done
echo "      ✅ Cached $USER_TOTAL_COUNT users."

# ---------------------------------------------------------
# STEP 3: Assign Members to Groups
# ---------------------------------------------------------
echo "-------------------------------------------------------"
echo "3️⃣  Assigning Members to Groups..."

CURRENT_GROUP_ID=""
CURRENT_GROUP_NAME=""

while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | xargs)
    if [[ -z "$line" ]]; then continue; fi

    # === CASE: GROUP HEADER ===
    if [[ "$line" == "org.role."* ]]; then
        GROUP_NAME=$(echo "$line" | sed 's/^org\.role\.//' | sed 's/@.*//' | xargs)
        
        CURRENT_GROUP_ID="${MAP_GROUPS["$GROUP_NAME"]}"
        CURRENT_GROUP_NAME="$GROUP_NAME"

        echo "   📂 Group: $GROUP_NAME"
        if [ -z "$CURRENT_GROUP_ID" ]; then
            echo "      ⚠️  Group ID not found in cache! Skipping members..."
        else
            echo "      ✅ ID: $CURRENT_GROUP_ID"
        fi
        continue
    fi

    # === CASE: USER LINE ===
    if [[ "$line" == *"|"* ]]; then
        if [ -z "$CURRENT_GROUP_ID" ]; then continue; fi

        USER_EMAIL=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
        
        USER_ID="${MAP_USERS["$USER_EMAIL"]}"

        if [ -n "$USER_ID" ]; then
            RES=$(api_post "groups.add_user" "{\"id\": \"$CURRENT_GROUP_ID\", \"userId\": \"$USER_ID\"}")
            IS_OK=$(echo "$RES" | jq -r '.ok // .success // false')

            if [ "$IS_OK" == "true" ]; then
                echo "      👤 Added: $USER_EMAIL"
            else
                ERR=$(echo "$RES" | jq -r '.error // .message')
                # Ignore "User already in group" errors to keep log clean
                echo "      ℹ️  Skipped: $USER_EMAIL ($ERR)"
            fi
        else
            echo "      ❌ User ID not found for: $USER_EMAIL"
        fi
    fi
done < "$INPUT_FILE"

echo "-------------------------------------------------------"
echo "🎉 Process Completed!"