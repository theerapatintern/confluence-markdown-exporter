#!/bin/bash

# ================= CONFIGURATION =================
DOMAIN="https://outline-dev.myorder.dev"
TOKEN="ol_api_bJF3MBaNFmK5VGNo3eA5SdNMJIqemoCGpz6hlW"

TARGET_COLLECTIONS=("part1" "part2" "part3" "part4" "part5" "part6")
NO_PARENT_NAME="No Parent"  # ชื่อ Collection สำหรับไฟล์ที่ไม่มี Folder ครอบ
# =================================================

API_URL="${DOMAIN}/api"

api_post() {
    local response
    response=$(curl -s -X POST "${API_URL}/${1}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${2}")
    
    if [ -z "$response" ]; then
        echo "{\"ok\": false, \"error\": \"curl_empty_response\", \"message\": \"No response from server.\"}"
    else
        echo "$response"
    fi
}

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

# Helper Function: Get or Create Collection ID by Name
get_or_create_collection_id() {
    local target_name="$1"
    local clean_target_name=$(trim "$target_name") # ตัด space ให้ชัวร์
    local existing_id=${EXISTING_COLLS["$clean_target_name"]}

    if [ -n "$existing_id" ]; then
        echo "$existing_id"
        return
    fi

    # ================= [ADDED FIX START] =================
    # แก้ปัญหา Subshell: ลองค้นหาจาก API อีกรอบก่อนสร้าง (เผื่อสร้างไปแล้วใน part ก่อนหน้าแต่ Cache ไม่จำ)
    local SAFE_SEARCH=$(echo "$clean_target_name" | sed 's/"/\\"/g')
    
    # 1. ยิง Search ไปหา Outline
    local SEARCH_RES=$(api_post "collections.list" "{\"query\": \"$SAFE_SEARCH\", \"limit\": 5}")
    
    # 2. กรองหาตัวที่ชื่อตรงเป๊ะๆ
    local FOUND_ID=$(echo "$SEARCH_RES" | jq -r --arg n "$clean_target_name" '.data[] | select(.name == $n) | .id' | head -n 1)

    if [ -n "$FOUND_ID" ]; then
        echo "$FOUND_ID"
        return
    fi
    # ================= [ADDED FIX END] ===================

    # ถ้าหาไม่เจอจริงๆ ค่อยสร้าง Collection ใหม่
    SAFE_TITLE=$(echo "$clean_target_name" | sed 's/"/\\"/g')
    CREATE_RES=$(api_post "collections.create" "{\"name\": \"$SAFE_TITLE\", \"permission\": \"read\", \"description\": \"Auto-generated\"}")
    NEW_ID=$(echo "$CREATE_RES" | jq -r '.data.id')
    
    if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
        # ตรงนี้ update cache ได้ แต่จะอยู่แค่ใน subshell นี้ (ไม่ส่งผลต่อรอบหน้า)
        # แต่เรามี logic search ข้างบนกันไว้แล้ว รอบหน้ามันจะ search เจอเอง
        EXISTING_COLLS["$clean_target_name"]="$NEW_ID" 
        echo "$NEW_ID"
    else
        echo ""
    fi
}

echo "🚀 Starting Smart Migration (Merge, Flatten, Orphan & Cleanup)..."

# ---------------------------------------------------------
# 1. สร้าง Cache ของ Collection (Map Name -> ID)
# ---------------------------------------------------------
echo "🔍 Building collection cache..."
declare -A EXISTING_COLLS

COLL_LIST_RES=$(api_post "collections.list" '{"limit": 100}')
IS_OK=$(echo "$COLL_LIST_RES" | jq -r '.ok // false')

if [ "$IS_OK" != "true" ]; then
    echo "❌ CRITICAL ERROR: API Call Failed"
    exit 1
fi

while IFS="=" read -r name id; do
    clean_name=$(trim "$name")
    EXISTING_COLLS["$clean_name"]="$id"
done < <(echo "$COLL_LIST_RES" | jq -r '.data[] | "\(.name)=\(.id)"')

echo "   Found ${#EXISTING_COLLS[@]} existing collections."

# ---------------------------------------------------------
# 2. เตรียม "No Parent" Collection ไว้ก่อนเลย (ทำทีเดียว)
# ---------------------------------------------------------
echo "🔨 Preparing '$NO_PARENT_NAME' collection..."
NO_PARENT_ID=$(get_or_create_collection_id "$NO_PARENT_NAME")

if [ -z "$NO_PARENT_ID" ]; then
    echo "❌ CRITICAL ERROR: Could not create or find '$NO_PARENT_NAME' collection."
    exit 1
fi
echo "   ✅ Using '$NO_PARENT_NAME' ID: $NO_PARENT_ID"

# ---------------------------------------------------------
# 3. เริ่มวนลูป Source Collections (p1 - pX)
# ---------------------------------------------------------
for source_coll_name in "${TARGET_COLLECTIONS[@]}"; do
    
    SOURCE_COLL_ID=${EXISTING_COLLS["$source_coll_name"]}
    
    if [ -z "$SOURCE_COLL_ID" ]; then
        echo "⚠️  Source Collection '$source_coll_name' not found. Skipping."
        continue
    fi

    echo "📂 Scanning Source: $source_coll_name ($SOURCE_COLL_ID)"
    DOCS_RES=$(api_post "collections.documents" "{\"id\": \"$SOURCE_COLL_ID\"}")
    
    ROOT_DOCS=$(echo "$DOCS_RES" | jq -r '.data[] | @base64')

    # --- Loop through Documents in Source ---
    for row in $ROOT_DOCS; do
        _jq() {
             echo ${row} | base64 --decode | jq -r ${1}
        }

        ROOT_DOC_ID=$(_jq '.id')
        RAW_TITLE=$(_jq '.title')
        ROOT_DOC_TITLE=$(trim "$RAW_TITLE")
        CHILDREN_IDS=$(_jq '.children[].id')

        # ================= LOGIC CHECK =================
        if [ -n "$CHILDREN_IDS" ] && [ "$CHILDREN_IDS" != "null" ]; then
            # CASE A: มีลูก (Folder) -> สร้าง Collection ใหม่ -> ย้ายลูก -> Archive แม่
            
            # เรียกฟังก์ชัน (ซึ่งตอนนี้มี Search Logic กันเหนียวแล้ว)
            DEST_COLL_ID=$(get_or_create_collection_id "$ROOT_DOC_TITLE")
            
            if [ -z "$DEST_COLL_ID" ]; then
                echo "      ❌ Failed to get/create destination collection."
                continue
            fi
            
            echo "   🔹 Merging Folder: '$ROOT_DOC_TITLE' -> Collection ($DEST_COLL_ID)"

            # Move children
            CHILD_LIST=$(echo ${row} | base64 --decode | jq -r '.children[] | "\(.id)|\(.title)"')
            
            SAVEIFS=$IFS
            IFS=$'\n'
            for child_item in $CHILD_LIST; do
                child_id=$(echo "$child_item" | cut -d'|' -f1)
                child_title=$(echo "$child_item" | cut -d'|' -f2)
                clean_child_title=$(trim "$child_title")

                # Rename if duplicate
                if [ "$clean_child_title" == "$ROOT_DOC_TITLE" ]; then
                    NEW_NAME="$ROOT_DOC_TITLE Overview"
                    api_post "documents.update" "{\"id\": \"$child_id\", \"title\": \"$NEW_NAME\"}" > /dev/null
                fi

                api_post "documents.move" "{\"id\": \"$child_id\", \"collectionId\": \"$DEST_COLL_ID\", \"parentDocumentId\": null}" > /dev/null
                printf "."
            done
            IFS=$SAVEIFS
            echo "" 

            # Archive Folder แม่
            api_post "documents.archive" "{\"id\": \"$ROOT_DOC_ID\"}" > /dev/null

        else
            # CASE B: ไม่มีลูก (File) -> ย้ายไป No Parent (ใช้ ID ที่เตรียมไว้แล้ว)
            echo "   🔸 Found Loose Doc: '$ROOT_DOC_TITLE' -> Moving to '$NO_PARENT_NAME'"

            MOVE_RES=$(api_post "documents.move" "{\"id\": \"$ROOT_DOC_ID\", \"collectionId\": \"$NO_PARENT_ID\", \"parentDocumentId\": null}")
            
            IS_MOVE_OK=$(echo "$MOVE_RES" | jq -r '.success // .ok')
            if [ "$IS_MOVE_OK" == "true" ]; then
                echo "      ✅ Moved."
            else
                echo "      ❌ Failed: $MOVE_RES"
            fi
        fi
        # ===============================================
    done

    # ---------------------------------------------------------
    # 4. ลบ Collection ต้นทาง (p1, p2...) หลังย้ายเสร็จ
    # ---------------------------------------------------------
    echo "💣 Deleting source collection '$source_coll_name'..."
    DEL_RES=$(api_post "collections.delete" "{\"id\": \"$SOURCE_COLL_ID\"}")
    
    IS_DEL_OK=$(echo "$DEL_RES" | jq -r '.success // .ok')
    if [ "$IS_DEL_OK" == "true" ]; then
        echo "   ✅ Deleted '$source_coll_name'."
    else
        echo "   ⚠️ Failed to delete '$source_coll_name': $DEL_RES"
    fi

    echo "---------------------------------------------------------"
done

echo "🎉 Migration & Cleanup Complete!"