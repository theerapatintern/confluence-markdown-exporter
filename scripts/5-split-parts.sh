#!/usr/bin/env bash
set -euo pipefail

# Step 1: โหลดค่า Config จากไฟล์ .env
ENV_FILE="workspace/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "⚠️ Warning: .env file not found. Using default values."
fi

# กำหนดค่าเริ่มต้น
SRC="${OUTPUT_FOLDER:-output}"          # โฟลเดอร์ต้นทาง
DES="migrate/stagings" # โฟลเดอร์ปลายทางที่จะให้สร้าง Part
MAX_SIZE_MB="${MAX_SPLIT_SIZE_MB:-100}"  # ขนาดสูงสุดต่อ Part (MB)

# แปลง MB เป็น KB (1024 KB = 1 MB)
MAX_SIZE_KB=$((MAX_SIZE_MB * 1024))

echo "📂 Source: $SRC"
echo "📂 Dest:   $DES"
echo "📦 Max Size: $MAX_SIZE_MB MB/part"
# =================================================

# Step 2: เคลียร์ folder ปลายทาง
if [ -d "$DES" ]; then
    echo "🧹 Cleaning old destination: $DES"
    rm -rf "$DES"
fi

# =================================================
# FUNCTIONS
# =================================================

# Step 3: ฟังก์ชันคำนวณขนาด (รวม Attachments)
get_total_size_kb() {
    local item_path="$1"       
    local relative_path="${item_path#$SRC/}"
    local size_kb=0

    # 3.1 ขนาดของตัวไฟล์/โฟลเดอร์เอง
    if [ -e "$item_path" ]; then
        # ใช้ awk '{print $1}' ปลอดภัยกว่า cut กรณี du มีช่องว่างนำหน้า
        local s
        s=$(du -sk "$item_path" | awk '{print $1}')
        size_kb=$((size_kb + s))
    fi

    # 3.2 เช็คว่ามี Attachments ที่คู่กันไหม?
    local attach_path=""
    if [ -d "$item_path" ]; then
        # กรณีเป็น Folder -> Attachment จะชื่อเหมือน Folder
        attach_path="$SRC/attachments/$relative_path"
    else
        # กรณีเป็น File .md -> Attachment จะชื่อเหมือนไฟล์ (ตัด .md)
        local no_ext="${relative_path%.md}"
        attach_path="$SRC/attachments/$no_ext"
    fi

    # ถ้าเจอ Folder Attachments ให้บวกขนาดเพิ่มเข้าไปด้วย
    if [ -d "$attach_path" ]; then
        local s
        s=$(du -sk "$attach_path" | awk '{print $1}')
        size_kb=$((size_kb + s))
    fi

    echo "$size_kb"
}

# Step 4: ฟังก์ชันย้ายของ
# copy Content และ Attachments ไปลง Part ปลายทาง
copy_item() {
    local item_path="$1"
    local part_dir="$2"
    local relative_path="${item_path#$SRC/}"

    # 4.1 Copy ตัว Content (File หรือ Folder)
    local dest_target="$part_dir/$relative_path"
    mkdir -p "$(dirname "$dest_target")"
    cp -r "$item_path" "$dest_target"

    # 4.2 Copy Attachments
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

# =================================================
# MAIN LOGIC
# =================================================

CURRENT_PART=1
CURRENT_SIZE_KB=0

echo "🔍 Scanning and Grouping files..."

# Step 5: สร้างรายการไฟล์ที่จะย้าย
# หาของใน output/ แล้วเก็บใส่ Array ไว้ก่อน
declare -a MOVE_LIST

while IFS= read -r -d '' item; do
    rel="${item#$SRC/}"
    
    # ข้าม folder 'attachments' ที่เป็น Root
    if [[ "$rel" == "attachments" ]]; then
        continue
    fi

    # --- SPECIAL CASE: DevOps ---
    # ถ้าเจอ Folder 'DevOps' ให้แตกไส้ในออกมาแยกเป็นชิ้นๆ 
    if [[ "$rel" == "DevOps" ]]; then
        echo "   -> Found 'DevOps' collection, splitting its contents..."
        while IFS= read -r -d '' subitem; do
            MOVE_LIST+=("$subitem")
        done < <(find "$item" -mindepth 1 -maxdepth 1 -print0)
    else
        # --- NORMAL CASE ---
        # เก็บรายการปกติ
        MOVE_LIST+=("$item")
    fi

done < <(find "$SRC" -mindepth 1 -maxdepth 1 -print0)

# Step 6: เริ่มกระบวนการจัด
mkdir -p "$DES/part$CURRENT_PART"

echo "🚀 Processing ${#MOVE_LIST[@]} items..."

for item in "${MOVE_LIST[@]}"; do
    # คำนวณขนาดจริง (Item + Attachments)
    SIZE=$(get_total_size_kb "$item")
    
    # คำนวณว่าถ้าใส่ก้อนนี้ลงไป ขนาดรวมจะเกินลิมิตไหม?
    NEW_TOTAL=$((CURRENT_SIZE_KB + SIZE))
    
    # ถ้าเกินลิมิต -> ให้ขึ้น Part ใหม่
    if [ "$CURRENT_SIZE_KB" -gt 0 ] && [ "$NEW_TOTAL" -gt "$MAX_SIZE_KB" ]; then
        echo "📦 Part part$CURRENT_PART full ($((CURRENT_SIZE_KB/1024)) MB). Switching to part$((CURRENT_PART + 1))..."
        
        CURRENT_PART=$((CURRENT_PART + 1))
        CURRENT_SIZE_KB=0
        mkdir -p "$DES/part$CURRENT_PART"
    fi

    # สั่ง Copy ลง Part ปัจจุบัน
    copy_item "$item" "$DES/part$CURRENT_PART"
    
    # อัปเดตขนาดปัจจุบัน
    CURRENT_SIZE_KB=$((CURRENT_SIZE_KB + SIZE))
done

echo "------------------------------------------------"
echo "✅ Done! Created $CURRENT_PART parts in '$DES'."