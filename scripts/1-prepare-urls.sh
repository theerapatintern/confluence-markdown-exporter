#!/bin/bash
set -eu

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"

if [ -f "$ENV_FILE" ]; then
    # Load config without exporting everything to child processes
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  Warning: .env file not found."
fi

TARGET_FILE="${1:-${INPUT_FILE:-url_list.txt}}"

# ================= VALIDATION =================
if [ ! -f "$TARGET_FILE" ]; then
    echo "❌ Error: ไม่พบไฟล์ '$TARGET_FILE'"
    echo "   กรุณาตรวจสอบไฟล์ .env หรือระบุชื่อไฟล์"
    exit 1
fi

echo "🔍 Processing file: $TARGET_FILE"

# ================= MAIN LOGIC =================
TMP_FILE=$(mktemp)

while IFS= read -r line || [ -n "$line" ]; do
    
    # ดึงเฉพาะตัวเลขหลัง /pages/
    # ตัวอย่าง: .../pages/123456/Title -> 123456
    ids=$(echo "$line" | grep -oE '/pages/[0-9]+' | sed 's#/pages/##')

    if [ -n "$ids" ]; then
        # กรณี 1 บรรทัดมีหลาย Link (หรือ Link เดียว) ให้เรียงเป็นบรรทัดเดียวคั่นด้วย Space
        echo "$ids" | paste -sd ' ' - >> "$TMP_FILE"
    else
        # ถ้าหา pattern ไม่เจอก็เขียนบรรทัดเดิมลงไป (หรือจะข้ามก็ได้ แล้วแต่ logic)
        echo "$line" >> "$TMP_FILE"
    fi
    
done < "$TARGET_FILE"

# เขียนทับไฟล์เดิม
mv "$TMP_FILE" "$TARGET_FILE"

echo "✅ เสร็จแล้ว: แปลง URL เป็น ID เรียบร้อย ($TARGET_FILE)"