#!/bin/bash

# ================= CONFIGURATION =================
# Step 1: โหลดค่า Config จากไฟล์ .env
ENV_FILE=".env"
SCRIPT_DIR="scripts"

if [ -f "$ENV_FILE" ]; then
    echo "⚙️  Loading configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found."
    exit 1
fi

# ตรวจสอบโฟลเดอร์ scripts
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "❌ Error: Directory '$SCRIPT_DIR' not found."
    exit 1
fi

# ================= HELPER FUNCTION =================
run_step() {
    local script_name="$1"
    local args="$2"
    local script_path="$SCRIPT_DIR/$script_name"
    
    echo "-------------------------------------------------------"
    echo "🚀 Step: $script_name"
    
    if [ ! -f "$script_path" ]; then
        echo "❌ Error: Script '$script_path' not found."
        exit 1
    fi

    echo "   ▶️  Running: $script_path $args"
    
    # รัน Script และส่ง Arguments (ถ้ามี)
    bash "$script_path" $args
    
    # ตรวจสอบ Exit Code
    if [ $? -ne 0 ]; then
        echo ""
        echo "❌❌❌ MIGRATION FAILED at '$script_name' ❌❌❌"
        exit 1
    fi
    
    echo "   ✅ Finished: $script_name"
    echo ""
    sleep 1
}

# ================= MAIN EXECUTION FLOW =================

echo "🏁 Starting Full Migration Process..."
echo "-------------------------------------------------------"

# 1. Strip Page ID (Clean URL list)
run_step "1-strip_page.sh"

# 2. Export Markdown
run_step "2-export.sh"

# 3. List Owner
run_step "3-list-owner.sh"

# 4. Fix Video
run_step "4-fix-video.sh"

# 5. Fix Markdown / Split Parts
# หมายเหตุ: เช็คชื่อไฟล์ดีๆ นะครับ ในโค้ดเก่าเป็น 5-fix.sh แต่อันนี้เป็น 5-folder.sh
# ผมยึดตามที่คุณส่งมาล่าสุดครับ
run_step "5-folder.sh"

# 6. Folder Structure / Fix Links
run_step "6-fix.sh"

# 7. Import to Outline
# ตรวจสอบว่ามีค่า MIGRATE_READY_DIR หรือไม่
if [ -z "$MIGRATE_READY_DIR" ]; then
    echo "⚠️  Warning: MIGRATE_READY_DIR is not set. Using default 'migrate/ready_to_import'"
    TARGET_DIR="migrate/ready_to_import"
else
    TARGET_DIR="$MIGRATE_READY_DIR"
fi
run_step "7-import.sh" "$TARGET_DIR"

# =======================================================
# ⏳ DELAY BLOCK (รอให้ Server ประมวลผล Import ให้เสร็จ)
# =======================================================
echo "-------------------------------------------------------"
echo "⏳ Syncing: Waiting 30s for Outline backend to finalize imports..."
echo "   (This prevents errors in the next step)"
sleep 30
echo "   ✅ Ready to organize collections."

# 8. Collection Creation / Organization
run_step "8-collection.sh"


# 9. CLEANUP LOCAL FILES
echo "-------------------------------------------------------"
echo "🧹 Cleaning up local temporary files..."
run_step "9-cleanup_local.sh"

echo "======================================================="
echo "🎉🎉🎉 ALL MIGRATION STEPS COMPLETED SUCCESSFULLY! 🎉🎉🎉"
echo "======================================================="