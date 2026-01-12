#!/bin/bash

# ================= CONFIGURATION =================
CONF_DOMAIN="myorder-ecrm.atlassian.net"
EMAIL=""
# ใส่ API Token ของคุณที่นี่
API_TOKEN=""    
INPUT_FILE="url_list_2.txt"
OUTPUT_FILE="creator_report_2.txt"
# =================================================

if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Error: ไม่พบไฟล์ $INPUT_FILE"
    exit 1
fi

echo "🚀 Starting to fetch Title & Author..."
echo "--------------------------------------"

# ล้างไฟล์เก่า (ไม่ต้องเขียน Header บรรทัดแรก เพื่อให้ parsing ง่ายขึ้น หรือถ้าเขียนต้องข้ามตอนอ่าน)
: > "$OUTPUT_FILE"

while IFS= read -r page_id || [ -n "$page_id" ]; do
    clean_id=$(echo "$page_id" | tr -d '[:space:]')
    [ -z "$clean_id" ] && continue

    response=$(curl -s -u "${EMAIL}:${API_TOKEN}" \
        -H "Accept: application/json" \
        "https://${CONF_DOMAIN}/wiki/rest/api/content/${clean_id}?expand=history.createdBy")

    if [ -n "$response" ]; then
        # [FIX] เปลี่ยน format เป็น "Title: AuthorName"
        title=$(echo "$response" | jq -r '.title')
        author=$(echo "$response" | jq -r '.history.createdBy.displayName // "Unknown"')
        
        if [ "$title" != "null" ] && [ -n "$title" ]; then
            # เขียนลงไฟล์แบบ: Title: Author
            echo "${title}: ${author}" >> "$OUTPUT_FILE"
            echo "   ✅ $clean_id -> ${title}: ${author}"
        else
            echo "   ❌ Error: $clean_id not found or permission denied"
        fi
    fi

done < "$INPUT_FILE"

echo "--------------------------------------"
echo "🎉 Done! Saved to: $OUTPUT_FILE"