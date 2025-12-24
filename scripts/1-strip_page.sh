#!/bin/bash
# Usage: ./strip_page_id.sh input.txt
# Overwrite input file with extracted page IDs.

set -eu

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
    echo "ไม่พบไฟล์: $INPUT_FILE"
    exit 1
fi

TMP_FILE=$(mktemp)

while IFS= read -r line || [ -n "$line" ]; do
    
    # ดึงทุก /pages/<digits> 
    ids=$(echo "$line" | grep -oE '/pages/[0-9]+' | sed 's#/pages/##')

    if [ -n "$ids" ]; then
        # ถ้ามีหลายอัน → ขึ้นบรรทัดเดียวคั่นด้วย space
        echo "$ids" | paste -sd ' ' - >> "$TMP_FILE"
    else
        # ถ้าไม่ใช่ลิงก์แบบ pages/<id> → เขียนเหมือนเดิม
        echo "$line" >> "$TMP_FILE"
    fi
    
done < "$INPUT_FILE"

mv "$TMP_FILE" "$INPUT_FILE"

echo "✓ เสร็จแล้ว → $INPUT_FILE"
