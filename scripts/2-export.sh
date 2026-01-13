#!/bin/bash

# ----------------- CONFIGURATION -----------------
# Step 1: กำหนดตัวแปรและชื่อไฟล์ต่างๆ ที่ต้องใช้ใน Script
FILE="${INPUT_FILE:-url_list.txt}"
VENV_ACTIVATE_SCRIPT="./venv/bin/activate"
ENV_FILE=".env"
CUSTOM_CONFIG="custom_config.json"

# Step 2: โหลดค่า Key/Token จากไฟล์ .env 
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found!"
    exit 1
fi

# Step 3: สั่ง Activate Python Environment เพื่อเตรียมรันคำสั่ง cf-export
if [ -f "$VENV_ACTIVATE_SCRIPT" ]; then
    source "$VENV_ACTIVATE_SCRIPT" 
else
    echo "❌ Error: Virtual environment script not found!"
    exit 1
fi

# Step 4: เคลียร์โฟลเดอร์ Output เก่าทิ้ง
TARGET_DIR="${OUTPUT_FOLDER:-output}"
if [ -d "$TARGET_DIR" ]; then
    echo "🧹 Cleaning old output directory: $TARGET_DIR"
    rm -rf "$TARGET_DIR"
fi


# Step 5: ถ้า Script จบการทำงานให้ลบไฟล์ Config ที่มี Token ทิ้งทันที
cleanup() {
    if [ -f "$CUSTOM_CONFIG" ]; then
        rm "$CUSTOM_CONFIG"
        echo "🔒 Securely removed temporary config."
    fi
}
trap cleanup EXIT # สั่งให้เรียกฟังก์ชัน cleanup เสมอเมื่อ process จบ

# Step 6: สร้างไฟล์ Config ชั่วคราว
cat > "$CUSTOM_CONFIG" <<EOF
{
  "auth": {
    "confluence": {
      "url": "$CONFLUENCE_URL",
      "username": "$CONFLUENCE_EMAIL",
      "api_token": "$CONFLUENCE_API_TOKEN"
    },
    "jira": {
      "url": "$CONFLUENCE_URL",
      "username": "$CONFLUENCE_EMAIL",
      "api_token": "$CONFLUENCE_API_TOKEN"
    }
  },
  "export": {
    "output_path": "$TARGET_DIR",
    "page_href": "relative",
    "page_path": "{ancestor_titles}/{page_title}.md",
    "attachment_href": "relative",
    "attachment_path": "attachments/{ancestor_titles}/{attachment_file_id}{attachment_extension}",
    "page_breadcrumbs": true,
    "include_document_title": true,
    "filename_length": 255
  }
}
EOF
export CME_CONFIG_PATH="$(pwd)/$CUSTOM_CONFIG"


# Step 8: เช็คไฟล์ List แล้วนับจำนวนบรรทัดทั้งหมด
if [ -f "$FILE" ]; then
    # ใช้ grep -cve เพื่อนับเฉพาะบรรทัดที่มีข้อความ (ข้ามบรรทัดว่าง)
    TOTAL_PAGES=$(grep -cve '^\s*$' "$FILE")
else
    echo "❌ File $FILE not found!"
    exit 1
fi

CURRENT_PAGE=0
echo "🚀 Starting export process for $TOTAL_PAGES pages..."

# 🚀 START EXPORT LOOP
# Step 9: เริ่มวนลูปอ่าน Page ID ทีละบรรทัดแล้วสั่ง Export
while IFS= read -r page_id || [ -n "$page_id" ]; do
    page_id=$(echo "$page_id" | xargs)  # ตัดช่องว่างหน้าหลังทิ้ง
    
    if [ -n "$page_id" ]; then
        ((CURRENT_PAGE++))
        echo "---------------------------------------------------"
        echo "⏳ [$CURRENT_PAGE/$TOTAL_PAGES] Exporting page ID: $page_id"
        
        cf-export pages-with-descendants "$page_id"
        
        if [ $? -ne 0 ]; then
            echo "❌ Error exporting page $page_id"
        else
            echo "✅ Success"
        fi
    fi
done < "$FILE"

echo "🎉 All Done."
