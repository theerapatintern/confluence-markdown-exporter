#!/bin/bash

# ================= CONFIGURATION =================
# Step 1: โหลดค่า Config จากไฟล์ .env
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

# กำหนดตัวแปรจาก Environment Variable
DOMAIN="${OUTLINE_DOMAIN}"
TOKEN="${OUTLINE_TOKEN}"
SKIP_NAME="${SKIP_COLLECTION_NAME:-Welcome}" 

if [ -z "$DOMAIN" ] || [ -z "$TOKEN" ]; then
    echo "❌ Error: DOMAIN or TOKEN is missing in .env"
    exit 1
fi

API_URL="${DOMAIN}/api"
# =================================================

# Step 2: เตรียมฟังก์ชันยิง API (Curl Wrapper)
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

# Step 3: ตรวจสอบ Arguments (Flags)
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

# ไม่ใส่ flag -> ถือว่าลบ "ทั้งหมด" 
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

# Function A: ลบ Collection (ใช้ได้ทั้ง Active, Archive, Trash)
delete_collections() {
    local list_json="$1"
    local type_label="$2"

    ITEMS=$(echo "$list_json" | jq -r '.data[] | @base64')

    if [ -z "$ITEMS" ] || [ "$ITEMS" == "null" ]; then
        echo "   ✨ No $type_label collections found."
        return
    fi

    for row in $ITEMS; do
        # ใช้ jq แกะค่าออกมาจาก base64
        _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
        
        COLL_ID=$(_jq '.id')
        COLL_NAME=$(_jq '.name')

        # ป้องกันการลบ Collection ที่สำคัญ (เช่น Welcome)
        if [[ "$COLL_NAME" == "$SKIP_NAME" ]]; then
            echo "   🛡️  Skipping protected collection: $COLL_NAME ($COLL_ID)"
            continue
        fi
        
        echo "   🗑️  Deleting ($type_label): $COLL_NAME ($COLL_ID)..."
        
        # ยิงคำสั่ง Delete
        # หมายเหตุ: ถ้า item อยู่ใน trash แล้ว การ delete ซ้ำคือการลบถาวร (Permanent Delete)
        DEL_RES=$(api_post "collections.delete" "{\"id\": \"$COLL_ID\"}")
        IS_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
        
        if [ "$IS_OK" != "true" ]; then
            # ถ้าลบไม่ได้ (เช่น เป็น Active อยู่) ต้อง Archive ก่อน
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

# Function B: ลบประวัติการ Import
delete_file_imports() {
    echo "🔍 Fetching File Operations (Imports)..."
    
    # ดึงเฉพาะ type="import"
    OPS_RES=$(api_post "fileOperations.list" '{"limit": 100, "type": "import"}')
    ITEMS=$(echo "$OPS_RES" | jq -r '.data[] | @base64')

    if [ -z "$ITEMS" ] || [ "$ITEMS" == "null" ]; then
        echo "   ✨ No file imports/operations found."
        return
    fi

    for row in $ITEMS; do
        _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
        
        OP_ID=$(_jq '.id')
        OP_STATE=$(_jq '.state')
        OP_TYPE=$(_jq '.type')
        OP_NAME=$(_jq '.name // "Unknown"')

        echo "   🗑️  Deleting Operation: [$OP_TYPE] $OP_NAME ($OP_STATE) - ID: $OP_ID..."
        
        DEL_RES=$(api_post "fileOperations.delete" "{\"id\": \"$OP_ID\"}")
        IS_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
        
        if [ "$IS_OK" == "true" ]; then
            echo "      ✅ Deleted."
        else
            echo "      ❌ Failed: $DEL_RES"
        fi
    done
}

# Function C: ล้างถังขยะเอกสาร (Empty Trash API)
empty_global_trash() {
    echo "🗑️  Emptying Global Document Trash..."
    
    DEL_RES=$(api_post "documents.empty_trash" "{}")
    IS_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
    
    if [ "$IS_OK" == "true" ]; then
        echo "   ✅ Trash Emptied Successfully."
    else
        echo "   ❌ Failed to empty trash: $DEL_RES"
    fi
}

# =========================================================
# MAIN EXECUTION FLOW
# =========================================================

# Step 4: ลบ Active Collections
if [ "$DELETE_ACTIVE" = true ]; then
    echo "----------------------------------------"
    echo "📂 Processing Active Collections..."
    # sort by updatedAt DESC เพื่อให้เห็นตัวล่าสุด
    ACTIVE_RES=$(api_post "collections.list" '{"limit": 100, "sort": "updatedAt", "direction": "DESC"}')
    delete_collections "$ACTIVE_RES" "Active"
fi

# Step 5: ลบ Archived Collections
if [ "$DELETE_ARCHIVED" = true ]; then
    echo "----------------------------------------"
    echo "🗄️  Processing Archived Collections..."
    # filter status=["archived"]
    ARCHIVED_RES=$(api_post "collections.list" '{"limit": 100, "sort": "updatedAt", "direction": "DESC", "statusFilter": ["archived"]}')
    delete_collections "$ARCHIVED_RES" "Archived"
fi

# Step 6: ล้างถังขยะ (Trash)
if [ "$DELETE_TRASH" = true ]; then
    echo "----------------------------------------"
    echo "🗑️  Processing Trash..."
    
    # 6.1 ลบ Collection ที่ค้างใน Trash (Permanent Delete)
    echo "   👉 Scanning Trashed Collections..."
    TRASH_COLLS_RES=$(api_post "collections.list" '{"limit": 100, "statusFilter": ["deleted"]}')
    delete_collections "$TRASH_COLLS_RES" "Trashed"

    # 6.2 ล้างเอกสารในถังขยะ (Documents)
    echo "   👉 Emptying Document Trash..."
    empty_global_trash
fi

# Step 7: ลบประวัติการ Import
if [ "$DELETE_IMPORTS" = true ]; then
    echo "----------------------------------------"
    echo "📥 Processing File Imports..."
    delete_file_imports
fi

echo "----------------------------------------"
echo "🎉 Cleanup Complete."