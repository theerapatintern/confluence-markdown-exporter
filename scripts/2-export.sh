#!/bin/bash

# ================= CONFIGURATION =================
FILE="url_list.txt"
VENV_ACTIVATE_SCRIPT="./venv/bin/activate"
OUTPUT_DIR="output"  # <--- ระบุชื่อโฟลเดอร์ Output ที่ต้องการลบ
# =================================================

# ตรวจสอบว่าไฟล์รายชื่อ Page IDs อยู่หรือไม่
if [ ! -f "$FILE" ]; then
    echo "File $FILE not found!"
    exit 1
fi

# ตรวจสอบและ Activate Virtual Environment
if [ -f "$VENV_ACTIVATE_SCRIPT" ]; then
    echo "Activating virtual environment..."
    # ใช้ 'source' หรือ '.' เพื่อรัน script ใน shell เดียวกัน 
    # ซึ่งจะตั้งค่า environment ให้พร้อมสำหรับการเรียกใช้ cf-export
    source "$VENV_ACTIVATE_SCRIPT" 
else
    echo "Error: Virtual environment activation script not found at $VENV_ACTIVATE_SCRIPT"
    echo "Please ensure the venv is created and the package is installed with 'pip install -e .' "
    exit 1
fi

# =================================================
# 🧹 CLEANUP OLD OUTPUT
# =================================================
if [ -d "$OUTPUT_DIR" ]; then
    echo "🧹 Cleaning old output directory: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi
# สร้างโฟลเดอร์ใหม่รอไว้ (ถ้า cf-export สร้างเองอยู่แล้ว บรรทัดนี้อาจไม่จำเป็น แต่ใส่ไว้กันเหนียว)
# mkdir -p "$OUTPUT_DIR" 

# =================================================
# 🚀 START EXPORT
# =================================================
echo "🚀 Starting export process..."

while IFS= read -r page_id || [ -n "$page_id" ]; do
    page_id=$(echo "$page_id" | xargs)  # ตัดช่องว่าง
    if [ -n "$page_id" ]; then
        echo "Exporting page $page_id..."
        
        cf-export pages-with-descendants "$page_id"
        
        if [ $? -ne 0 ]; then
            echo "Error exporting page $page_id"
        fi
    fi
done < "$FILE"