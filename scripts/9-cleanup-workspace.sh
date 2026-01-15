#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"

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
if [ -z "$OUTPUT_FOLDER" ]; then
    echo "❌ Error: cleanup paths are not fully defined in .env"
    exit 1
fi

echo "⚠️  WARNING: This will DELETE local temporary migration files:"
echo "   🗑️  Output Folder:  $OUTPUT_FOLDER"
echo "   🗑️  Migrate Folder:   migrate"
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
if [ -d "migrate" ]; then
    rm -rf "migrate"
    echo "   ✅ Deleted: migrate"
else
    echo "   ✨ Skipped (Not found): migrate"
fi

echo "-------------------------------------------------------"
echo "🧹 Local Workspace Cleaned."