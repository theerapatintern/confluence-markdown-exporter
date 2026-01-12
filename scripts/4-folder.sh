#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
SRC="output_new"
DES="migrate_new/parts"
MAX_SIZE_MB=100
# แปลง MB เป็น KB (1024 KB = 1 MB)
MAX_SIZE_KB=$((MAX_SIZE_MB * 1024))

# --- CLEANUP ---
if [ -d "$DES" ]; then
    echo "Cleaning old destination: $DES"
    rm -rf "$DES"
fi

# --- FUNCTION: Calculate Size ---
# คำนวณขนาดของ Item (MD/Folder) + Attachments ที่เกี่ยวข้อง
get_total_size_kb() {
    local item_path="$1"       # path ของไฟล์หรือโฟลเดอร์ใน output/
    local relative_path="${item_path#$SRC/}"
    local size_kb=0

    # 1. ขนาดของตัวไฟล์/โฟลเดอร์เอง
    if [ -e "$item_path" ]; then
        local s
        s=$(du -sk "$item_path" | cut -f1)
        size_kb=$((size_kb + s))
    fi

    # 2. ขนาดของ Attachments ที่เกี่ยวข้อง (ถ้ามี)
    local attach_path=""
    if [ -d "$item_path" ]; then
        # กรณีเป็น Folder
        attach_path="$SRC/attachments/$relative_path"
    else
        # กรณีเป็น File .md (ตัด .md ออกเพื่อหา folder ใน attachments)
        local no_ext="${relative_path%.md}"
        attach_path="$SRC/attachments/$no_ext"
    fi

    if [ -d "$attach_path" ]; then
        local s
        s=$(du -sk "$attach_path" | cut -f1)
        size_kb=$((size_kb + s))
    fi

    echo "$size_kb"
}

# --- FUNCTION: Copy Item ---
copy_item() {
    local item_path="$1"
    local part_dir="$2"
    local relative_path="${item_path#$SRC/}"

    # 1. Copy ตัว Content (File หรือ Folder)
    local dest_target="$part_dir/$relative_path"
    mkdir -p "$(dirname "$dest_target")"
    cp -r "$item_path" "$dest_target"

    # 2. Copy Attachments (ถ้ามี)
    local attach_src=""
    local attach_dest_rel=""
    
    if [ -d "$item_path" ]; then
        attach_src="$SRC/attachments/$relative_path"
        attach_dest_rel="attachments/$relative_path"
    else
        local no_ext="${relative_path%.md}"
        attach_src="$SRC/attachments/$no_ext"
        attach_dest_rel="attachments/$no_ext"
    fi

    if [ -d "$attach_src" ]; then
        local dest_attach="$part_dir/$attach_dest_rel"
        mkdir -p "$(dirname "$dest_attach")"
        cp -r "$attach_src" "$dest_attach"
    fi
}

# --- MAIN LOGIC ---

CURRENT_PART=1
CURRENT_SIZE_KB=0

echo "🔍 Scanning and Grouping files (Max $MAX_SIZE_MB MB per part)..."

# สร้าง Array เก็บรายการที่จะย้าย (Move List)
declare -a MOVE_LIST

# 1. วนลูปหาของใน output/
while IFS= read -r -d '' item; do
    rel="${item#$SRC/}"
    
    # ข้าม folder attachments หลัก
    if [[ "$rel" == "attachments" ]]; then
        continue
    fi

    if [[ "$rel" == "DevOps" ]]; then
        # --- SPECIAL CASE: DevOps ---
        echo "   -> Found 'DevOps' collection, splitting its contents..."
        while IFS= read -r -d '' subitem; do
            MOVE_LIST+=("$subitem")
        done < <(find "$item" -mindepth 1 -maxdepth 1 -print0)
    else
        # --- NORMAL CASE ---
        MOVE_LIST+=("$item")
    fi

done < <(find "$SRC" -mindepth 1 -maxdepth 1 -print0)

# 2. เริ่ม Process การย้ายลง part1, part2, part3...
# (แก้ไขตรงนี้: เปลี่ยนจาก p เป็น part)
mkdir -p "$DES/part$CURRENT_PART"

for item in "${MOVE_LIST[@]}"; do
    # คำนวณขนาด
    SIZE=$(get_total_size_kb "$item")
    
    # เช็คว่าถ้าใส่ item นี้ไปแล้วจะเกินโควต้าไหม?
    NEW_TOTAL=$((CURRENT_SIZE_KB + SIZE))
    
    if [ "$CURRENT_SIZE_KB" -gt 0 ] && [ "$NEW_TOTAL" -gt "$MAX_SIZE_KB" ]; then
        # (แก้ไขตรงนี้: เปลี่ยน Log และชื่อโฟลเดอร์เป็น part)
        echo "📦 Part part$CURRENT_PART full ($((CURRENT_SIZE_KB/1024)) MB). Switching to part$((CURRENT_PART + 1))..."
        CURRENT_PART=$((CURRENT_PART + 1))
        CURRENT_SIZE_KB=0
        mkdir -p "$DES/part$CURRENT_PART"
    fi

    # Copy ลง Part ปัจจุบัน
    # (แก้ไขตรงนี้: ส่ง path เป็น part)
    copy_item "$item" "$DES/part$CURRENT_PART"
    
    CURRENT_SIZE_KB=$((CURRENT_SIZE_KB + SIZE))
done

echo "------------------------------------------------"
echo "✅ Done! Created $CURRENT_PART parts in '$DES'."