#!/bin/bash

# Step 1: โหลดค่า Config จากไฟล์ .env
ENV_FILE="workspace/.env"

if [ -f "$ENV_FILE" ]; then
    echo "⚙️  Loading configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  Warning: .env file not found. Please create one."
    exit 1
fi

# ตรวจสอบตัวแปรสำคัญ
if [ -z "$OUTLINE_DOMAIN" ] || [ -z "$OUTLINE_TOKEN" ]; then
    echo "❌ Error: Missing OUTLINE_DOMAIN or OUTLINE_TOKEN in .env"
    exit 1
fi

DOMAIN="${OUTLINE_DOMAIN}"
TOKEN="${OUTLINE_TOKEN}"
NO_PARENT_NAME="${NO_PARENT_NAME:-General}" # Default เป็น General
# แปลง String ใน .env ให้เป็น Array
TARGET_COLLECTIONS=("part1" "part2" "part3" "part4" "part5" "part6")

API_URL="${DOMAIN}/api"

# ฟังก์ชันยิง API (Curl Wrapper)
api_post() {
    local endpoint="$1"
    local payload="$2"
    
    local response
    response=$(curl -s -X POST "${API_URL}/${endpoint}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}")
    
    if [ -z "$response" ]; then
        echo "{\"ok\": false, \"error\": \"curl_empty_response\", \"message\": \"No response from server.\"}"
    else
        echo "$response"
    fi
}

# ฟังก์ชันตัดช่องว่างหน้า-หลัง
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

# Step 2: ฟังก์ชันหาหรือสร้าง Collection ใหม่
get_or_create_collection_id() {
    local target_name="$1"
    local clean_target_name=$(trim "$target_name")
    local existing_id=${EXISTING_COLLS["$clean_target_name"]}

    # 2.1 ถ้ามี Cache อยู่แล้ว ให้ใช้เลย
    if [ -n "$existing_id" ]; then
        echo "$existing_id"
        return
    fi

    # 2.2 ถ้าไม่มีใน Cache ลอง Search ดูอีกที
    local SAFE_SEARCH=$(echo "$clean_target_name" | sed 's/"/\\"/g')
    local SEARCH_RES=$(api_post "collections.list" "{\"query\": \"$SAFE_SEARCH\", \"limit\": 5}")
    local FOUND_ID=$(echo "$SEARCH_RES" | jq -r --arg n "$clean_target_name" '.data[] | select(.name == $n) | .id' | head -n 1)

    if [ -n "$FOUND_ID" ]; then
        echo "$FOUND_ID"
        return
    fi

    # 2.3 ถ้าไม่มีจริงๆ ให้สร้างใหม่
    
    # - แปลงชื่อเป็นตัวใหญ่ทั้งหมด
    local UPPER_NAME=$(echo "$clean_target_name" | tr '[:lower:]' '[:upper:]')
    
    # - แต่ง Description เป็น H1
    local FANCY_DESC="# 📚 ${UPPER_NAME}\\n\\n✨ **Central Knowledge Hub**\\nOfficial documentation, guidelines, and resources curated for the team."
    
    local SAFE_TITLE=$(echo "$clean_target_name" | sed 's/"/\\"/g')
    
    # - ยิง API สร้าง
    CREATE_RES=$(api_post "collections.create" "{\"name\": \"$SAFE_TITLE\", \"permission\": \"read\", \"description\": \"$FANCY_DESC\"}")
    
    NEW_ID=$(echo "$CREATE_RES" | jq -r '.data.id')
    
    if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
        # อัปเดต Cache
        EXISTING_COLLS["$clean_target_name"]="$NEW_ID" 
        echo "$NEW_ID"
    else
        echo ""
    fi
}

echo "🚀 Starting Smart Migration (Merge, Flatten, Orphan & Cleanup)..."

# Step 3: สร้าง Cache ของ Collection ที่มีอยู่แล้ว
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

# Step 4: เตรียม Collection ปลายทางสำหรับไฟล์ที่ไม่มี Collection
echo "🔨 Preparing '$NO_PARENT_NAME' collection..."
NO_PARENT_ID=$(get_or_create_collection_id "$NO_PARENT_NAME")

if [ -z "$NO_PARENT_ID" ]; then
    echo "❌ CRITICAL ERROR: Could not create or find '$NO_PARENT_NAME' collection."
    exit 1
fi
echo "   ✅ Using '$NO_PARENT_NAME' ID: $NO_PARENT_ID"

# Step 5: เริ่มวนลูป Source Collections (part1, part2, ...)
for source_coll_name in "${TARGET_COLLECTIONS[@]}"; do
    
    SOURCE_COLL_ID=${EXISTING_COLLS["$source_coll_name"]}
    
    if [ -z "$SOURCE_COLL_ID" ]; then
        echo "⚠️  Source Collection '$source_coll_name' not found. Skipping."
        continue
    fi

    echo "📂 Scanning Source: $source_coll_name ($SOURCE_COLL_ID)"
    DOCS_RES=$(api_post "collections.documents" "{\"id\": \"$SOURCE_COLL_ID\"}")
    
    # ดึงเอกสารชั้นบนสุด (Root Documents) มาวนลูป
    ROOT_DOCS=$(echo "$DOCS_RES" | jq -r '.data[] | @base64')

    for row in $ROOT_DOCS; do
        _jq() {
             echo ${row} | base64 --decode | jq -r ${1}
        }

        ROOT_DOC_ID=$(_jq '.id')
        RAW_TITLE=$(_jq '.title')
        ROOT_DOC_TITLE=$(trim "$RAW_TITLE")
        CHILDREN_IDS=$(_jq '.children[].id')

        if [ -n "$CHILDREN_IDS" ] && [ "$CHILDREN_IDS" != "null" ]; then
            # --- CASE A: เป็น Folder -> แปลงร่างเป็น Collection ใหม่ ---
            DEST_COLL_ID=$(get_or_create_collection_id "$ROOT_DOC_TITLE")
            
            if [ -z "$DEST_COLL_ID" ]; then
                echo "      ❌ Failed to get/create destination collection."
                continue
            fi
            
            echo "   🔹 Merging Folder: '$ROOT_DOC_TITLE' -> Collection ($DEST_COLL_ID)"

            # ย้ายลูกๆ (Children) ไปยัง Collection ใหม่
            CHILD_LIST=$(echo ${row} | base64 --decode | jq -r '.children[] | "\(.id)|\(.title)"')
            
            SAVEIFS=$IFS
            IFS=$'\n'
            for child_item in $CHILD_LIST; do
                child_id=$(echo "$child_item" | cut -d'|' -f1)
                child_title=$(echo "$child_item" | cut -d'|' -f2)
                clean_child_title=$(trim "$child_title")

                # ถ้าชื่อไฟล์ซ้ำกับชื่อ Folder (ที่กลายเป็น Collection) ให้เปลี่ยนชื่อไฟล์
                if [ "$clean_child_title" == "$ROOT_DOC_TITLE" ]; then
                    NEW_NAME="$ROOT_DOC_TITLE Overview"
                    api_post "documents.update" "{\"id\": \"$child_id\", \"title\": \"$NEW_NAME\"}" > /dev/null
                fi

                # สั่งย้าย
                api_post "documents.move" "{\"id\": \"$child_id\", \"collectionId\": \"$DEST_COLL_ID\", \"parentDocumentId\": null}" > /dev/null
                printf "."
            done
            IFS=$SAVEIFS
            echo "" 

            # Archive Folder ตัวเก่า (ตอนนี้กลายเป็น Collection ใหม่แล้ว)
            api_post "documents.archive" "{\"id\": \"$ROOT_DOC_ID\"}" > /dev/null

        else
            # --- CASE B: เป็นไฟล์เดี่ยว (Loose File) -> ย้ายไป General ---
            echo "   🔸 Found Loose Doc: '$ROOT_DOC_TITLE' -> Moving to '$NO_PARENT_NAME'"

            MOVE_RES=$(api_post "documents.move" "{\"id\": \"$ROOT_DOC_ID\", \"collectionId\": \"$NO_PARENT_ID\", \"parentDocumentId\": null}")
            
            IS_MOVE_OK=$(echo "$MOVE_RES" | jq -r '.success // .ok')
            if [ "$IS_MOVE_OK" == "true" ]; then
                echo "      ✅ Moved."
            else
                echo "      ❌ Failed: $MOVE_RES"
            fi
        fi
    done

    # 5.2 ลบ Collection ต้นทางทิ้งเมื่อย้ายของหมดแล้ว
    echo "💣 Deleting source collection '$source_coll_name'..."
    DEL_RES=$(api_post "collections.delete" "{\"id\": \"$SOURCE_COLL_ID\"}")
    echo "   ✅ Deleted '$source_coll_name'."

    echo "---------------------------------------------------------"
done

# Step 6: Post-Process จัดเรียงเอกสาร
echo "🧹 [Post-Process] Configuring Collections to sort documents (A-Z)..."

# ดึงรายชื่อ Collection ทั้งหมดอีกครั้ง
FINAL_COLL_LIST=$(api_post "collections.list" '{"limit": 100}')
ALL_ITEMS=$(echo "$FINAL_COLL_LIST" | jq -r '.data[] | "\(.id)|\(.name)"')

COUNT=0
SAVEIFS=$IFS
IFS=$'\n'

for item in $ALL_ITEMS; do
    c_id=$(echo "$item" | cut -d'|' -f1)
    c_name=$(echo "$item" | cut -d'|' -f2)
    
    safe_name=$(echo "$c_name" | sed 's/"/\\"/g')

    # sleep ป้องกัน Rate Limit
    sleep 0.2
    
    # ตั้งค่า Sort: field=title, direction=asc 
    UPDATE_RES=$(api_post "collections.update" "{
        \"id\": \"$c_id\",
        \"name\": \"$safe_name\",
        \"sort\": { \"field\": \"title\", \"direction\": \"asc\" }
    }")
    
    IS_SORT_OK=$(echo "$UPDATE_RES" | jq -r '.success // .ok')
    
    if [ "$IS_SORT_OK" == "true" ]; then
        ((COUNT++))
        printf "."
    else
        echo ""
        echo "   ⚠️ Failed to sort collection: $c_name ($c_id)"
        ERR_MSG=$(echo "$UPDATE_RES" | jq -r '.message // .error')
        echo "      Reason: $ERR_MSG"
    fi
done
IFS=$SAVEIFS
echo ""
echo "✅ Sorted $COUNT collections and their documents (A-Z)."

echo "🎉 Migration, Cleanup & Sorting Complete!"