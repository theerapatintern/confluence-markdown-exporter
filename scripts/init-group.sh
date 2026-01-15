#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"

# Load Config
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    # Fallback checking
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
    echo "Usage: ./scripts/util-create-groups-only.sh <group_list_file>"
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

echo "🚀 Starting Group Creation (Groups Only)..."
echo "-------------------------------------------------------"

COUNT_CREATED=0
COUNT_SKIPPED=0
COUNT_FAILED=0

while IFS= read -r line || [ -n "$line" ]; do
    # 1. ทำความสะอาดบรรทัด (Trim)
    line=$(echo "$line" | xargs)
    if [[ -z "$line" ]]; then continue; fi

    # 2. [LOGIC ใหม่] เช็คว่าบรรทัดนี้ขึ้นต้นด้วย org.role. หรือไม่?
    # ถ้าไม่ใช่ ให้ข้ามไปเลย (พวกบรรทัดที่มี | ก็จะโดนข้ามตรงนี้)
    if [[ "$line" != "org.role."* ]]; then
        continue
    fi

    # 3. จัดการชื่อ (Clean Name)
    # - sed 's/^org\.role\.//'  -> ลบ prefix "org.role."
    # - sed 's/@.*//'           -> ลบตั้งแต่ @ เป็นต้นไปจนจบ
    # - xargs                   -> ลบช่องว่างหน้าหลัง
    GROUP_NAME=$(echo "$line" | sed 's/^org\.role\.//' | sed 's/@.*//' | xargs)

    # เช็คความยาวชื่อหลังตัด
    if [ ${#GROUP_NAME} -lt 2 ]; then
        echo "⚠️  Skipping invalid name: '$GROUP_NAME' (Original: $line)"
        continue
    fi

    # ยิง API สร้าง Group
    RES=$(api_post "groups.create" "{\"name\": \"$GROUP_NAME\"}")
    IS_OK=$(echo "$RES" | jq -r '.ok // .success // false')

    if [ "$IS_OK" == "true" ]; then
        GROUP_ID=$(echo "$RES" | jq -r '.data.id')
        echo "   ✅ Created: $GROUP_NAME (ID: $GROUP_ID)"
        ((COUNT_CREATED++))
    else
        # เช็ค Error
        ERR_MSG=$(echo "$RES" | jq -r '.error // .message // "Unknown Error"')
        
        # ถ้า Error เพราะชื่อซ้ำ ให้ถือว่าผ่าน (Optional: หรือจะนับเป็น Failed ก็ได้)
        if [[ "$ERR_MSG" == *"already exists"* ]]; then
             echo "   ℹ️  Exists: $GROUP_NAME"
        else
             echo "   ❌ Failed: $GROUP_NAME ($ERR_MSG)"
             ((COUNT_FAILED++))
        fi
    fi

done < "$INPUT_FILE"

echo "-------------------------------------------------------"
echo "📊 Summary:"
echo "   Created: $COUNT_CREATED"
echo "   Failed:  $COUNT_FAILED"
echo "======================================================="