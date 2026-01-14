#!/bin/bash

# ================= CONFIGURATION =================

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
if [ -z "$CONFLUENCE_EMAIL" ] || [ -z "$CONFLUENCE_API_TOKEN" ]; then
    echo "❌ Error: Missing CONFLUENCE credentials in .env"
    exit 1
fi

CONF_DOMAIN="${CONFLUENCE_URL%/}" # ตัด / ท้ายออกถ้ามี
EMAIL="${CONFLUENCE_EMAIL}"
TOKEN="${CONFLUENCE_API_TOKEN}"

INPUT_ID="${INPUT_FILE:-url_list.txt}"
OUTPUT_FILE="confluence_markdown_exporter/creator_report.txt"

# ================= MAIN LOGIC =================

# Step 2: ตรวจสอบไฟล์ Input
if [ ! -f "$INPUT_ID" ]; then
    echo "❌ Error: Input file '$INPUT_ID' not found!"
    exit 1
fi

echo "🚀 Starting to fetch Title & Author..."
echo "📂 Input:  $INPUT_ID"
echo "📂 Output: $OUTPUT_FILE"
echo "--------------------------------------"

# Step 3: เตรียมไฟล์ Output (ล้างค่าเก่าทิ้ง)
: > "$OUTPUT_FILE"

# Step 4: วนลูปอ่าน ID ทีละบรรทัด
while IFS= read -r page_id || [ -n "$page_id" ]; do
    
    # 4.1 Clean ID (ตัดช่องว่าง)
    clean_id=$(echo "$page_id" | tr -d '[:space:]')
    
    # ข้ามบรรทัดว่าง
    [ -z "$clean_id" ] && continue

    # 4.2 ยิง API ไปที่ Confluence
    # ใช้ expand=history.createdBy เพื่อดึงชื่อคนสร้าง
    response=$(curl -s -u "${EMAIL}:${TOKEN}" \
        -H "Accept: application/json" \
        "${CONF_DOMAIN}/wiki/rest/api/content/${clean_id}?expand=history.createdBy")

    # 4.3 ประมวลผลผลลัพธ์
    if [ -n "$response" ]; then
        # ใช้ jq ดึง Title และ DisplayName ของคนสร้าง
        title=$(echo "$response" | jq -r '.title')
        author=$(echo "$response" | jq -r '.history.createdBy.displayName // "Unknown"')
        
        # เช็คว่า title valid หรือไม่ (ถ้า page id ผิด API จะ return error หรือ null)
        if [ "$title" != "null" ] && [ -n "$title" ]; then
            # 4.4 บันทึกลงไฟล์ Format: "Title: AuthorName"
            echo "${title}: ${author}" >> "$OUTPUT_FILE"
            echo "   ✅ $clean_id -> ${title}: ${author}"
        else
            # กรณีหาไม่เจอหรือไม่มีสิทธิ์เข้าถึง
            echo "   ❌ Error: $clean_id not found or permission denied"
        fi
    else
        echo "   ❌ Error: No response for ID $clean_id"
    fi

done < "$INPUT_ID"

echo "--------------------------------------"
echo "🎉 Done! Saved to: $OUTPUT_FILE"