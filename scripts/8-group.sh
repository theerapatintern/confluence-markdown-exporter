#!/bin/bash

# ================= CONFIGURATION =================
DOMAIN="https://outline-dev.myorder.dev"
TOKEN=""
INPUT_FILE="groups.txt"  # 👈 ชื่อไฟล์ที่มีรายชื่อ Group
# =================================================

API_URL="${DOMAIN}/api"

# Function ยิง API (ใช้ตัวเดิม)
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

# ตรวจสอบว่ามีไฟล์ input หรือไม่
if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Error: File '$INPUT_FILE' not found!"
    echo "   Please create a text file listed in CONFIGURATION."
    exit 1
fi

echo "🚀 Starting Group Creation from '$INPUT_FILE'..."
echo "------------------------------------------------"

# อ่านไฟล์ทีละบรรทัด
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Clean string: ตัดช่องว่างหน้าหลัง และตัด \r (เผื่อไฟล์มาจาก Windows)
    GROUP_NAME=$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')

    # ถ้าบรรทัดว่าง ให้ข้าม
    if [ -z "$GROUP_NAME" ]; then
        continue
    fi

    # ยิง API สร้าง Group
    # JSON Payload: { "name": "ชื่อกลุ่ม" }
    RES=$(api_post "groups.create" "{\"name\": \"$GROUP_NAME\"}")

    # เช็คผลลัพธ์
    IS_OK=$(echo "$RES" | jq -r '.success // .ok')

    if [ "$IS_OK" == "true" ]; then
        NEW_ID=$(echo "$RES" | jq -r '.data.id')
        echo "   ✅ Created: '$GROUP_NAME' (ID: $NEW_ID)"
    else
        ERROR_MSG=$(echo "$RES" | jq -r '.message // .error')
        echo "   ❌ Failed:  '$GROUP_NAME' -> $ERROR_MSG"
    fi

done < "$INPUT_FILE"

echo "------------------------------------------------"
echo "🎉 Done."