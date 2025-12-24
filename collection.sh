#!/bin/bash

# ================= CONFIGURATION =================
DOMAIN="https://outline-dev.myorder.dev"
TOKEN="ol_api_0AShz5CHD6QWyZrujk689rFr1TGIfbrIqJwUYI"
TARGET_COLLECTIONS=("p1" "p2" "p3" "p4")
# =================================================

API_URL="${DOMAIN}/api"

api_post() {
    local response
    response=$(curl -s -X POST "${API_URL}/${1}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${2}")
    
    # Check if curl failed (empty response)
    if [ -z "$response" ]; then
        echo "{\"ok\": false, \"error\": \"curl_empty_response\", \"message\": \"No response from server. Check URL or network.\"}"
    else
        echo "$response"
    fi
}

# ฟังก์ชัน Trim whitespace
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

echo "🚀 Starting Smart Migration (Merge & Flatten)..."

# 1. สร้าง Cache ของ Collection (Map Name -> ID)
echo "🔍 Building collection cache..."
declare -A EXISTING_COLLS

# เรียก API
COLL_LIST_RES=$(api_post "collections.list" '{"limit": 100}')

# --- ERROR CHECKING ---
# ตรวจสอบว่า API ตอบกลับมาว่า ok: true หรือไม่
IS_OK=$(echo "$COLL_LIST_RES" | jq -r '.ok // false')
if [ "$IS_OK" != "true" ]; then
    echo "❌ CRITICAL ERROR: API Call Failed"
    echo "   Endpoint: collections.list"
    echo "   Response: $COLL_LIST_RES"
    echo "   Please check your TOKEN and DOMAIN configuration."
    exit 1
fi
# ----------------------

# Parse JSON to key=value lines and loop
while IFS="=" read -r name id; do
    clean_name=$(trim "$name")
    EXISTING_COLLS["$clean_name"]="$id"
done < <(echo "$COLL_LIST_RES" | jq -r '.data[] | "\(.name)=\(.id)"')

echo "   Found ${#EXISTING_COLLS[@]} existing collections."

# 2. เริ่มวนลูป p1 - p4
for source_coll_name in "${TARGET_COLLECTIONS[@]}"; do
    
    SOURCE_COLL_ID=${EXISTING_COLLS["$source_coll_name"]}
    
    if [ -z "$SOURCE_COLL_ID" ]; then
        echo "⚠️  Source Collection '$source_coll_name' not found (ID is empty). Skipping."
        continue
    fi

    echo "📂 Scanning Source: $source_coll_name ($SOURCE_COLL_ID)"

    # ดึง Tree structure ของ Source Collection
    DOCS_RES=$(api_post "collections.documents" "{\"id\": \"$SOURCE_COLL_ID\"}")
    
    # Check Error for this specific call
    IS_DOC_OK=$(echo "$DOCS_RES" | jq -r '.ok // false')
    if [ "$IS_DOC_OK" != "true" ]; then
        echo "   ❌ Error fetching documents for collection $source_coll_name"
        echo "   Response: $DOCS_RES"
        continue
    fi

    # ดึงเฉพาะ Root Docs (เช่น DevOps, MOD Release)
    ROOT_DOCS=$(echo "$DOCS_RES" | jq -r '.data[] | @base64')

    for row in $ROOT_DOCS; do
        _jq() {
             echo ${row} | base64 --decode | jq -r ${1}
        }

        ROOT_DOC_ID=$(_jq '.id')
        RAW_TITLE=$(_jq '.title')
        ROOT_DOC_TITLE=$(trim "$RAW_TITLE")
        
        # ดึง ID ของลูกๆ (Children IDs)
        CHILDREN_IDS=$(_jq '.children[].id')
        
        # ถ้า Folder นี้ไม่มีลูกเลย ข้ามไป (ไม่ย้าย Folder ว่าง)
        if [ -z "$CHILDREN_IDS" ] || [ "$CHILDREN_IDS" == "null" ]; then
            continue
        fi

        echo "   Target: '$ROOT_DOC_TITLE' (Container ID: $ROOT_DOC_ID)"

        # --- STEP A: ตรวจสอบ Destination Collection (Merge Logic) ---
        DEST_COLL_ID=${EXISTING_COLLS["$ROOT_DOC_TITLE"]}

        if [ -n "$DEST_COLL_ID" ]; then
            echo "      ✅ Collection '$ROOT_DOC_TITLE' exists ($DEST_COLL_ID). Merging content..."
        else
            echo "      📦 Creating NEW collection: '$ROOT_DOC_TITLE'..."
            SAFE_TITLE=$(echo "$ROOT_DOC_TITLE" | sed 's/"/\\"/g')
            CREATE_RES=$(api_post "collections.create" "{\"name\": \"$SAFE_TITLE\", \"permission\": \"read\", \"description\": \"Promoted from $source_coll_name\"}")
            DEST_COLL_ID=$(echo "$CREATE_RES" | jq -r '.data.id')
            
            if [ -n "$DEST_COLL_ID" ] && [ "$DEST_COLL_ID" != "null" ]; then
                EXISTING_COLLS["$ROOT_DOC_TITLE"]="$DEST_COLL_ID"
                echo "         Created ID: $DEST_COLL_ID"
            else
                echo "      ❌ Error creating collection. Response: $CREATE_RES"
                continue
            fi
        fi

        # --- STEP B: ย้ายลูกๆ (Move Children & Rename Duplicates) ---
        echo "      🚚 Moving children..."
        
        CHILD_LIST=$(echo ${row} | base64 --decode | jq -r '.children[] | "\(.id)|\(.title)"')

        SAVEIFS=$IFS
        IFS=$'\n'
        for child_item in $CHILD_LIST; do
            child_id=$(echo "$child_item" | cut -d'|' -f1)
            child_title=$(echo "$child_item" | cut -d'|' -f2)
            clean_child_title=$(trim "$child_title")

            if [ "$clean_child_title" == "$ROOT_DOC_TITLE" ]; then
                NEW_NAME="$ROOT_DOC_TITLE Overview"
                echo "         ⚠️  Renaming duplicate doc '$child_title' -> '$NEW_NAME'"
                api_post "documents.update" "{\"id\": \"$child_id\", \"title\": \"$NEW_NAME\"}" > /dev/null
            fi

            MOVE_RES=$(api_post "documents.move" "{\"id\": \"$child_id\", \"collectionId\": \"$DEST_COLL_ID\", \"parentDocumentId\": null}")
            IS_OK=$(echo "$MOVE_RES" | jq -r '.success // .ok')
            
            if [ "$IS_OK" == "true" ]; then
                printf "."
            else
                echo "x"
                echo "         Failed move ($child_title): $MOVE_RES"
            fi
        done
        IFS=$SAVEIFS
        echo "" # New line

        # --- STEP C: ลบ Folder แม่ที่ว่างเปล่า (Archive Container) ---
        echo "      🗑️  Archiving empty container..."
        api_post "documents.archive" "{\"id\": \"$ROOT_DOC_ID\"}" > /dev/null

    done
    echo "---------------------------------------------------------"
done

echo "🎉 Migration Complete!"