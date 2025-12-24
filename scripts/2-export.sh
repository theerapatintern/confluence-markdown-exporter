#!/bin/bash

# ไฟล์ list page IDs
FILE="url_list.txt"
# Path ไปยัง Script สำหรับ Activate Venv
VENV_ACTIVATE_SCRIPT="./venv/bin/activate" 

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