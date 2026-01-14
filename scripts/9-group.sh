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

# ตรวจสอบตัวแปรสำคัญ
if [ -z "$OUTLINE_DOMAIN" ] || [ -z "$OUTLINE_TOKEN" ]; then
    echo "❌ Error: Missing OUTLINE_DOMAIN or OUTLINE_TOKEN in .env"
    exit 1
fi

DOMAIN="${OUTLINE_DOMAIN}"
TOKEN="${OUTLINE_TOKEN}"
INPUT_FILE="${INPUT_GROUP_FILE:-groups.txt}" # Default เป็น groups.txt

API_URL="${DOMAIN}/api"

# ================= HELPER FUNCTIONS =================

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

# ================= MAIN LOGIC =================

# Step 2: ตรวจสอบไฟล์ Input
if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Error: File '$INPUT_FILE' not found!"
    echo "   Please create the file or check .env settings."
    exit 1
fi

echo "🚀 Starting Group Creation from '$INPUT_FILE'..."
echo "------------------------------------------------"

# Step 3: วนลูปอ่านไฟล์ทีละบรรทัด
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    
    # 3.1 Clean string: ตัดช่องว่างหน้าหลัง และตัด \r (เผื่อไฟล์มาจาก Windows)
    GROUP_NAME=$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')

    # ถ้าบรรทัดว่าง ให้ข้าม
    if [ -z "$GROUP_NAME" ]; then
        continue
    fi

    # 3.2 ยิง API สร้าง Group
    # JSON Payload: { "name": "ชื่อกลุ่ม" }
    # หมายเหตุ: เราต้อง Escape ชื่อกลุ่มเผื่อมี quote
    SAFE_NAME=$(echo "$GROUP_NAME" | sed 's/"/\\"/g')
    
    RES=$(api_post "groups.create" "{\"name\": \"$SAFE_NAME\"}")

    # 3.3 เช็คผลลัพธ์
    IS_OK=$(echo "$RES" | jq -r '.success // .ok')

    if [ "$IS_OK" == "true" ]; then
        NEW_ID=$(echo "$RES" | jq -r '.data.id')
        echo "   ✅ Created: '$GROUP_NAME' (ID: $NEW_ID)"
    else
        ERROR_MSG=$(echo "$RES" | jq -r '.message // .error')
        # เช็คว่าเป็น error ชื่อซ้ำหรือไม่ (Optional)
        if [[ "$ERROR_MSG" == *"already exists"* ]]; then
            echo "   ⚠️  Exists:  '$GROUP_NAME' already exists."
        else
            echo "   ❌ Failed:  '$GROUP_NAME' -> $ERROR_MSG"
        fi
    fi
    
    # sleep นิดหน่อยกัน Rate Limit
    sleep 0.1

done < "$INPUT_FILE"

echo "------------------------------------------------"
echo "🎉 Group Creation Complete."