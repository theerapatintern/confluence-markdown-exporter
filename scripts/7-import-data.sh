#!/bin/bash

# ================= CONFIGURATION =================
ENV_FILE="workspace/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found."
    exit 1
fi

DOMAIN="${OUTLINE_DOMAIN}"
TOKEN="${OUTLINE_TOKEN}"
API_URL="${DOMAIN}/api"
INPUT_TARGET="$1"

# ================= VALIDATION =================
if [ -z "$INPUT_TARGET" ]; then
    echo "Usage: ./import_fixed.sh <folder_path OR file.zip>"
    exit 1
fi

if [ ! -e "$INPUT_TARGET" ]; then
    echo "❌ Error: '$INPUT_TARGET' not found."
    exit 1
fi

api_post() {
    curl -s -X POST "${API_URL}/${1}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${2}"
}

# ================= CORE FUNCTION =================
process_zip_file() {
    local ZIP_FILE="$1"
    
    if [[ "$ZIP_FILE" != /* ]]; then
        ZIP_FILE="$(pwd)/$ZIP_FILE"
    fi

    local BASENAME=$(basename "$ZIP_FILE")
    
    echo "-------------------------------------------------------"
    echo "📦 Processing: $BASENAME"

    # --- STEP 1: Create Attachment ---
    local FILE_SIZE=$(wc -c < "$ZIP_FILE" | tr -d ' ')
    local MIME_TYPE="application/zip"

    local PAYLOAD_1=$(jq -n \
        --arg preset "workspaceImport" \
        --arg contentType "$MIME_TYPE" \
        --argjson size "$FILE_SIZE" \
        --arg name "$BASENAME" \
        '{preset: $preset, contentType: $contentType, size: $size, name: $name}')

    local RES_1=$(api_post "attachments.create" "$PAYLOAD_1")
    local IS_OK=$(echo "$RES_1" | jq -r '.ok // false')
    
    if [ "$IS_OK" != "true" ]; then
        echo "   ❌ Failed to register attachment."
        echo "      Debug: $RES_1"
        return 1
    fi

    local UPLOAD_URL=$(echo "$RES_1" | jq -r '.data.uploadUrl')
    local ATTACHMENT_ID=$(echo "$RES_1" | jq -r '.data.attachment.id')

    # --- STEP 2: Upload Binary (Multipart POST - SAFE MODE) ---
    local CURL_ARGS=("-X" "POST" "$UPLOAD_URL")
    
    # ใช้ jq print key และ value สลับบรรทัดกัน แล้วใช้ read วนลูปทีละ 2 บรรทัด
    while read -r key; do
        read -r value
        CURL_ARGS+=("-F" "$key=$value")
    done < <(echo "$RES_1" | jq -r '.data.form | to_entries | .[] | .key, .value')
    
    # Force content-type
    CURL_ARGS+=("-F" "file=@$ZIP_FILE;type=$MIME_TYPE")

    # สร้างไฟล์ temp เก็บ Error
    local ERR_FILE=$(mktemp)
    
    local HTTP_CODE=$(curl -s -w "%{http_code}" -o "$ERR_FILE" "${CURL_ARGS[@]}")

    if [[ "$HTTP_CODE" -ne 200 && "$HTTP_CODE" -ne 201 && "$HTTP_CODE" -ne 204 ]]; then
        echo "   ❌ Upload Failed (HTTP $HTTP_CODE)."
        echo "   🛑 Server Response:"
        cat "$ERR_FILE"
        echo ""
        rm -f "$ERR_FILE"
        return 1
    fi
    rm -f "$ERR_FILE"

    # --- STEP 3: Trigger Import ---
    local PAYLOAD_3=$(jq -n \
        --arg attachmentId "$ATTACHMENT_ID" \
        --arg format "outline-markdown" \
        '{attachmentId: $attachmentId, format: $format, permission: null}')

    local RES_3=$(api_post "collections.import" "$PAYLOAD_3")
    local IS_IMPORT_OK=$(echo "$RES_3" | jq -r '.ok // .success // false')
    local OPERATION_ID=$(echo "$RES_3" | jq -r '.data.fileOperation.id // .data.id')

    if [ "$IS_IMPORT_OK" == "true" ]; then
        if [ "$OPERATION_ID" == "null" ] || [ -z "$OPERATION_ID" ]; then
            echo "   ✅ Triggered (Silent Success)."
            return 0
        else
            echo "   ✅ Started (Op ID: $OPERATION_ID)."
            sleep 2
            local RES_INFO=$(api_post "fileOperations.info" "{\"id\": \"$OPERATION_ID\"}")
            local STATE=$(echo "$RES_INFO" | jq -r '.data.state')
            echo "      ℹ️  Current Status: $STATE"
            return 0
        fi
    else
        echo "   ❌ Failed to trigger import."
        echo "      Debug: $RES_3"
        return 1
    fi
}

# ================= MAIN LOGIC =================
FILES_TO_PROCESS=()

if [ -f "$INPUT_TARGET" ]; then
    echo "🚀 Starting Single File Import: '$INPUT_TARGET'"
    FILES_TO_PROCESS+=("$INPUT_TARGET")
elif [ -d "$INPUT_TARGET" ]; then
    echo "🚀 Starting Bulk Import from folder: '$INPUT_TARGET'"
    shopt -s nullglob
    for f in "$INPUT_TARGET"/*.zip; do
        FILES_TO_PROCESS+=("$f")
    done
    shopt -u nullglob
    if [ ${#FILES_TO_PROCESS[@]} -eq 0 ]; then
        echo "⚠️  No .zip files found."
        exit 0
    fi
else
    echo "❌ Error: Invalid input."
    exit 1
fi

COUNT_TOTAL=0
COUNT_SUCCESS=0
COUNT_FAIL=0
TOTAL_FILES=${#FILES_TO_PROCESS[@]}

for zip_file in "${FILES_TO_PROCESS[@]}"; do
    ((COUNT_TOTAL++))
    
    if process_zip_file "$zip_file"; then
        ((COUNT_SUCCESS++))
    else
        ((COUNT_FAIL++))
    fi
    
    # Cooldown
    if [ "$TOTAL_FILES" -gt 1 ] && [ "$COUNT_TOTAL" -lt "$TOTAL_FILES" ]; then
        echo "   ⏳ Cooldown: 3s..."
        sleep 3
    fi
done

echo "======================================================="
echo "📊 Summary:"
echo "   Total:   $COUNT_TOTAL"
echo "   Success: $COUNT_SUCCESS"
echo "   Failed:  $COUNT_FAIL"
echo "======================================================="