#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"
SCRIPT_DIR="scripts"

# Default: Run all steps (Set skip variables to false)
SKIP_1=false
SKIP_2=false
SKIP_3=false
SKIP_4=false
SKIP_5=false
SKIP_6=false
SKIP_7=false
SKIP_8=false
SKIP_9=false

# ================= ARGUMENT PARSING =================
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --skip-1    Skip Sanitize URLs"
    echo "  --skip-2    Skip Fetch from Confluence (Export)"
    echo "  --skip-3    Skip Fetch Authors"
    echo "  --skip-4    Skip Patch Videos"
    echo "  --skip-5    Skip Split Parts"
    echo "  --skip-6    Skip Transform Markdown"
    echo "  --skip-7    Skip Import to Outline"
    echo "  --skip-8    Skip Organize Collections"
    echo "  --skip-9    Skip Cleanup Local Workspace"
    echo "  --help      Show this help message"
    echo ""
    echo "Example: $0 --skip-1 --skip-2 (Start from Step 3)"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-1) SKIP_1=true ;;
        --skip-2) SKIP_2=true ;;
        --skip-3) SKIP_3=true ;;
        --skip-4) SKIP_4=true ;;
        --skip-5) SKIP_5=true ;;
        --skip-6) SKIP_6=true ;;
        --skip-7) SKIP_7=true ;;
        --skip-8) SKIP_8=true ;;
        --skip-9) SKIP_9=true ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "❌ Unknown parameter: $1"; show_help; exit 1 ;;
    esac
    shift
done

# ================= PRE-FLIGHT CHECK =================
if [ -f "$ENV_FILE" ]; then
    echo "⚙️  Loading configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found at $ENV_FILE"
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
if [ "$SKIP_1" = false ]; then
    run_step "1-prepare-urls.sh"
else
    echo "⏭️  Skipping Step 1: Sanitize URLs"
fi

# 2. Fetch from Confluence
if [ "$SKIP_2" = false ]; then
    run_step "2-export-data.sh"
else
    echo "⏭️  Skipping Step 2: Fetch from Confluence"
fi

# 3. Fetch Authors
if [ "$SKIP_3" = false ]; then
    run_step "3-fetch-authors.sh"
else
    echo "⏭️  Skipping Step 3: Fetch Authors"
fi

# 4. Patch Videos
if [ "$SKIP_4" = false ]; then
    run_step "4-patch-videos.sh"
else
    echo "⏭️  Skipping Step 4: Patch Videos"
fi

# 5. Split Parts
if [ "$SKIP_5" = false ]; then
    run_step "5-split-parts.sh"
else
    echo "⏭️  Skipping Step 5: Split Parts"
fi

# 6. Transform Markdown
if [ "$SKIP_6" = false ]; then
    run_step "6-format-content.sh"
else
    echo "⏭️  Skipping Step 6: Transform Markdown"
fi

# 7. Import to Outline
if [ "$SKIP_7" = false ]; then
    run_step "7-import-data.sh" "migrate/packages"
else
    echo "⏭️  Skipping Step 7: Import to Outline"
fi

# --- DELAY (Only wait if Step 7 was run AND Step 8 will be run) ---
if [ "$SKIP_7" = false ] && [ "$SKIP_8" = false ]; then
    echo "-------------------------------------------------------"
    echo "⏳ Syncing: Waiting 120s for Outline backend..."
    sleep 120
    echo "   ✅ Ready."
elif [ "$SKIP_7" = true ]; then
    echo "-------------------------------------------------------"
    echo "⏭️  Skipping Delay (Import was skipped)."
fi

# 8. Organize Collections
if [ "$SKIP_8" = false ]; then
    run_step "8-organize-collections.sh"
else
    echo "⏭️  Skipping Step 8: Organize Collections"
fi

# 9. Cleanup Local Workspace
if [ "$SKIP_9" = false ]; then
    echo "-------------------------------------------------------"
    echo "🧹 Cleaning up local temporary files..."
    run_step "9-cleanup-workspace.sh"
else
    echo "⏭️  Skipping Step 9: Cleanup"
fi

echo "======================================================="
echo "🎉🎉🎉 PROCESS COMPLETED! 🎉🎉🎉"
echo "======================================================="