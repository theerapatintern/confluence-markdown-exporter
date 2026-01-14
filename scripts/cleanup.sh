#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    echo "⚙️  Loading configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  Warning: .env file not found. Please create one."
    exit 1
fi

DOMAIN="${OUTLINE_DOMAIN}"
TOKEN="${OUTLINE_TOKEN}"
SKIP_NAME="${SKIP_COLLECTION_NAME:-Welcome}" 

if [ -z "$DOMAIN" ] || [ -z "$TOKEN" ]; then
    echo "❌ Error: DOMAIN or TOKEN is missing in .env"
    exit 1
fi

API_URL="${DOMAIN}/api"
# =================================================

api_post() {
    local endpoint="$1"
    local payload="$2"
    local response
    
    response=$(curl -s -X POST "${API_URL}/${endpoint}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}")
    
    if [ -z "$response" ]; then
        echo "{\"ok\": false, \"error\": \"curl_error\"}"
    else
        echo "$response"
    fi
}

DELETE_ACTIVE=false
DELETE_ARCHIVED=false
DELETE_TRASH=false
DELETE_IMPORTS=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --active) DELETE_ACTIVE=true ;;
        --archived) DELETE_ARCHIVED=true ;;
        --trash) DELETE_TRASH=true ;;
        --imports) DELETE_IMPORTS=true ;;
        --all) 
            DELETE_ACTIVE=true
            DELETE_ARCHIVED=true
            DELETE_TRASH=true
            DELETE_IMPORTS=true
            ;;
        *)
            echo "Unknown flag: $1"
            echo "Usage: $0 [--active | --archived | --trash | --imports | --all]"
            exit 1
            ;;
    esac
    shift
done

if [ "$DELETE_ACTIVE" = false ] && [ "$DELETE_ARCHIVED" = false ] && [ "$DELETE_TRASH" = false ] && [ "$DELETE_IMPORTS" = false ]; then
    DELETE_ACTIVE=true
    DELETE_ARCHIVED=true
    DELETE_TRASH=true
    DELETE_IMPORTS=true
fi

echo "⚠️  WARNING: This script will PERMANENTLY DELETE:"
[ "$DELETE_ACTIVE" = true ] && echo "     - Active collections (Except '$SKIP_NAME')"
[ "$DELETE_ARCHIVED" = true ] && echo "     - Archived collections"
[ "$DELETE_TRASH" = true ] && echo "     - EVERYTHING in Trash (Collections + Documents)"
[ "$DELETE_IMPORTS" = true ] && echo "     - File Imports (fileOperations)"
echo "   Press Ctrl+C to cancel within 5 seconds..."
sleep 5
echo "🚀 Starting Cleanup..."

# Function A: ลบ Collection
delete_collections() {
    local list_json="$1"
    local type_label="$2"
    local count=0

    ITEMS=$(echo "$list_json" | jq -r '(.data // [])[] | @base64')

    if [ -z "$ITEMS" ] || [ "$ITEMS" == "null" ]; then
        echo "   ✨ No $type_label collections found."
        return
    fi

    for row in $ITEMS; do
        _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
        
        COLL_ID=$(_jq '.id')
        COLL_NAME=$(_jq '.name')

        if [[ "$COLL_NAME" == "$SKIP_NAME" ]]; then
            echo "   🛡️  Skipping protected: $COLL_NAME"
            continue
        fi
        
        echo "   🗑️  Deleting ($type_label): $COLL_NAME..."
        
        DEL_RES=$(api_post "collections.delete" "{\"id\": \"$COLL_ID\"}")
        IS_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
        
        if [ "$IS_OK" != "true" ]; then
            echo "      ❌ Direct delete failed. Archiving first..."
            api_post "collections.archive" "{\"id\": \"$COLL_ID\"}" > /dev/null
            DEL_RES_2=$(api_post "collections.delete" "{\"id\": \"$COLL_ID\"}")
        fi
        ((count++))
    done
    
    # [FIX 1] เพิ่มเวลาหลังจากลบ Collection เสร็จ เป็น 10 วินาที
    if [ "$count" -gt 0 ]; then
        echo "   ⏳ Deleted $count collections. Waiting 10s for backend processing..."
        sleep 10
    fi
}

# Function B: ลบ Import
delete_file_imports() {
    echo "🔍 Fetching File Operations..."
    OPS_RES=$(api_post "fileOperations.list" '{"limit": 100, "type": "import"}')
    ITEMS=$(echo "$OPS_RES" | jq -r '(.data // [])[] | @base64')

    if [ -z "$ITEMS" ] || [ "$ITEMS" == "null" ]; then
        echo "   ✨ No imports found."
        return
    fi

    for row in $ITEMS; do
        _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
        OP_ID=$(_jq '.id')
        OP_NAME=$(_jq '.name // "Unknown"')
        echo "   🗑️  Deleting Import: $OP_NAME..."
        api_post "fileOperations.delete" "{\"id\": \"$OP_ID\"}" > /dev/null
    done
}

# Function C: Empty Trash (Aggressive Loop)
empty_global_trash() {
    echo "🗑️  Emptying Global Document Trash (Aggressive Mode)..."
    
    # [FIX 2] วนลูปยิงคำสั่งล้างถังขยะ 3 รอบ
    for i in {1..3}; do
        echo "   👉 Attempt $i/3: Sending empty_trash command..."
        DEL_RES=$(api_post "documents.empty_trash" "{}")
        IS_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
        
        if [ "$IS_OK" == "true" ]; then
            echo "      ✅ Command Accepted."
        else
            echo "      ⚠️  Failed: $DEL_RES"
        fi
        
        # ถ้ารอบสุดท้ายไม่ต้องรอ
        if [ "$i" -lt 3 ]; then
            echo "      ⏳ Waiting 5s for background job..."
            sleep 5
        fi
    done
}

# =========================================================
# MAIN EXECUTION FLOW
# =========================================================

# Step 4: Active Collections
if [ "$DELETE_ACTIVE" = true ]; then
    echo "----------------------------------------"
    echo "📂 Processing Active Collections..."
    ACTIVE_RES=$(api_post "collections.list" '{"limit": 100, "sort": "updatedAt", "direction": "DESC"}')
    delete_collections "$ACTIVE_RES" "Active"
fi

# Step 5: Archived Collections
if [ "$DELETE_ARCHIVED" = true ]; then
    echo "----------------------------------------"
    echo "🗄️  Processing Archived Collections..."
    ARCHIVED_RES=$(api_post "collections.list" '{"limit": 100, "sort": "updatedAt", "direction": "DESC", "statusFilter": ["archived"]}')
    delete_collections "$ARCHIVED_RES" "Archived"
fi

# Step 6: Trash
if [ "$DELETE_TRASH" = true ]; then
    echo "----------------------------------------"
    echo "🗑️  Processing Trash..."
    
    # 6.1 ลบ Collection ที่ค้างใน Trash (Permanent Delete)
    echo "   👉 Scanning Trashed Collections..."
    TRASH_COLLS_RES=$(api_post "collections.list" '{"limit": 100, "statusFilter": ["deleted"]}')
    delete_collections "$TRASH_COLLS_RES" "Trashed"

    # [FIX 3] รออีกนิดก่อนล้างถังขยะรวม
    if [ "$DELETE_ACTIVE" = true ] || [ "$DELETE_ARCHIVED" = true ]; then
        echo "   ⏳ Syncing: Final 5s wait before emptying documents..."
        sleep 5
    fi

    # 6.2 ล้างเอกสารในถังขยะ (Loop 3 รอบ)
    empty_global_trash
fi

# Step 7: Imports
if [ "$DELETE_IMPORTS" = true ]; then
    echo "----------------------------------------"
    echo "📥 Processing File Imports..."
    delete_file_imports
fi

echo "----------------------------------------"
echo "🎉 Cleanup Complete."