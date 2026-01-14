#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"
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

    echo "   ▶️  Running..."
    bash "$script_path" $args
    
    if [ $? -ne 0 ]; then
        echo ""
        echo "❌❌❌ MIGRATION FAILED at '$script_name' ❌❌❌"
        exit 1
    fi
    
    echo "   ✅ Finished."
    echo ""
    sleep 1
}

# ================= MAIN EXECUTION FLOW =================

echo "🏁 Starting Full Migration Process..."
echo "-------------------------------------------------------"

# 1. Sanitize URLs
run_step "1-prepare-urls.sh"

# 2. Fetch from Confluence
run_step "2-export-data.sh"

# 3. Fetch Authors
run_step "3-fetch-authors.sh"

# 4. Patch Videos
run_step "4-patch-videos.sh"

# 5. Split Parts (Folder Splitting)
run_step "5-split-parts.sh"

# 6. Transform Markdown (Fix links, inject authors, zip)
run_step "6-format-content.sh"

# 7. Import to Outline
run_step "7-import-data.sh" "migrate/packages"

# --- DELAY ---
echo "-------------------------------------------------------"
echo "⏳ Syncing: Waiting 30s for Outline backend..."
sleep 30
echo "   ✅ Ready."

# 8. Organize Collections
run_step "8-organize-collections.sh"

# 9. Cleanup Local Workspace
echo "-------------------------------------------------------"
echo "🧹 Cleaning up local temporary files..."
run_step "9-cleanup-workspace.sh"

echo "======================================================="
echo "🎉🎉🎉 ALL MIGRATION STEPS COMPLETED SUCCESSFULLY! 🎉🎉🎉"
echo "======================================================="