#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    echo "⚙️  Loading configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found."
    exit 1
fi

# ================= SAFETY CHECK =================
# ป้องกันการลบ root หรือ path ที่ไม่ได้ตั้งค่า
if [ -z "$OUTPUT_FOLDER" ] || [ -z "$MIGRATE_PARTS_DIR" ] || [ -z "$MIGRATE_READY_DIR" ]; then
    echo "❌ Error: cleanup paths are not fully defined in .env"
    exit 1
fi

echo "⚠️  WARNING: This will DELETE local temporary migration files:"
echo "   🗑️  Output Folder:  $OUTPUT_FOLDER"
echo "   🗑️  Parts Folder:   $MIGRATE_PARTS_DIR"
echo "   🗑️  Ready Folder:   $MIGRATE_READY_DIR"
echo "   🗑️  Creator File:   $CREATOR_REPORT_FILE"
echo ""
echo "   Waiting 5 seconds... (Press Ctrl+C to cancel)"
sleep 5

# ================= CLEANUP LOGIC =================

echo "🚀 Starting Local Cleanup..."

# 1. ลบ Output Folder (Markdown ดิบ)
if [ -d "$OUTPUT_FOLDER" ]; then
    rm -rf "$OUTPUT_FOLDER"
    echo "   ✅ Deleted: $OUTPUT_FOLDER"
else
    echo "   ✨ Skipped (Not found): $OUTPUT_FOLDER"
fi

# 2. ลบ Parts Folder (Markdown ที่แบ่งแล้ว)
if [ -d "$MIGRATE_PARTS_DIR" ]; then
    rm -rf "$MIGRATE_PARTS_DIR"
    echo "   ✅ Deleted: $MIGRATE_PARTS_DIR"
else
    echo "   ✨ Skipped (Not found): $MIGRATE_PARTS_DIR"
fi

# 3. ลบ Ready Folder (Zip Files)
if [ -d "$MIGRATE_READY_DIR" ]; then
    rm -rf "$MIGRATE_READY_DIR"
    echo "   ✅ Deleted: $MIGRATE_READY_DIR"
else
    echo "   ✨ Skipped (Not found): $MIGRATE_READY_DIR"
fi

# 4. ลบ Creator Report File
if [ -f "$CREATOR_REPORT_FILE" ]; then
    rm -f "$CREATOR_REPORT_FILE"
    echo "   ✅ Deleted: $CREATOR_REPORT_FILE"
else
    echo "   ✨ Skipped (Not found): $CREATOR_REPORT_FILE"
fi

echo "-------------------------------------------------------"
echo "🧹 Local Workspace Cleaned."