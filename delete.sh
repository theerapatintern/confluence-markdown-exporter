#!/bin/bash

# ================= CONFIGURATION =================
DOMAIN="https://outline-dev.myorder.dev"
TOKEN="ol_api_kY6SKBI7Fv2NfphUTMIteXce758QOTdWe57ERi"
# =================================================

API_URL="${DOMAIN}/api"

api_post() {
    local response
    response=$(curl -s -X POST "${API_URL}/${1}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${2}")
    
    if [ -z "$response" ]; then
        echo "{\"ok\": false, \"error\": \"curl_error\"}"
    else
        echo "$response"
    fi
}

# =================================================
# Parse Flags
# =================================================
DELETE_ACTIVE=false
DELETE_ARCHIVED=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --active) DELETE_ACTIVE=true ;;
        --archived) DELETE_ARCHIVED=true ;;
        --all) DELETE_ACTIVE=true; DELETE_ARCHIVED=true ;;
        *)
            echo "Unknown flag: $1"
            echo "Usage: $0 [--active | --archived | --all]"
            exit 1
            ;;
    esac
    shift
done

# ถ้าไม่ระบุ flag → default = ลบทั้งหมด
if [ "$DELETE_ACTIVE" = false ] && [ "$DELETE_ARCHIVED" = false ]; then
    DELETE_ACTIVE=true
    DELETE_ARCHIVED=true
fi

echo "⚠️  WARNING: This script will PERMANENTLY DELETE Outline Collections!"
echo "   Targets:"
[ "$DELETE_ACTIVE" = true ] && echo "     - Active collections"
[ "$DELETE_ARCHIVED" = true ] && echo "     - Archived collections"
echo "   Press Ctrl+C to cancel within 5 seconds..."
sleep 5
echo "🚀 Starting Cleanup..."

# =========================================================
# Function to Delete a List of Collections
# =========================================================
delete_collections() {
    local list_json="$1"
    local type_label="$2"

    ITEMS=$(echo "$list_json" | jq -r '.data[] | @base64')

    if [ -z "$ITEMS" ] || [ "$ITEMS" == "null" ]; then
        echo "   ✨ No $type_label collections found."
        return
    fi

    for row in $ITEMS; do
        _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
        
        COLL_ID=$(_jq '.id')
        COLL_NAME=$(_jq '.name')
        
        echo "   🗑️  Deleting ($type_label): $COLL_NAME ($COLL_ID)..."
        
        # Try Delete Directly
        DEL_RES=$(api_post "collections.delete" "{\"id\": \"$COLL_ID\"}")
        IS_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
        
        if [ "$IS_OK" != "true" ]; then
            echo "      ❌ Delete failed. Trying to Archive first..."
            
            api_post "collections.archive" "{\"id\": \"$COLL_ID\"}" > /dev/null
            DEL_RES_2=$(api_post "collections.delete" "{\"id\": \"$COLL_ID\"}")
            IS_OK_2=$(echo "$DEL_RES_2" | jq -r '.success // .ok')
            
            if [ "$IS_OK_2" == "true" ]; then
                echo "      ✅ Archived & Deleted."
            else
                echo "      ❌ Failed to delete: $DEL_RES_2"
            fi
        else
            echo "      ✅ Deleted."
        fi
    done
}

# =========================================================
# 1. Delete Active Collections (optional)
# =========================================================
if [ "$DELETE_ACTIVE" = true ]; then
    echo "search 1: Fetching Active Collections..."
    ACTIVE_RES=$(api_post "collections.list" '{"limit": 100, "sort": "updatedAt", "direction": "DESC"}')
    delete_collections "$ACTIVE_RES" "Active"
fi

# =========================================================
# 2. Delete Archived Collections (optional)
# =========================================================
if [ "$DELETE_ARCHIVED" = true ]; then
    echo "search 2: Fetching Archived Collections..."
    ARCHIVED_RES=$(api_post "collections.list" '{"limit": 100, "sort": "updatedAt", "direction": "DESC", "statusFilter": ["archived"]}')
    delete_collections "$ARCHIVED_RES" "Archived"
fi

echo "🎉 Done."
