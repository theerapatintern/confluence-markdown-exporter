#!/bin/bash
# ================= CONFIGURATION =================
# ใช้ Locale มาตรฐาน
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

CONF_DOMAIN="myorder-ecrm.atlassian.net"
CONF_EMAIL=""
CONF_TOKEN=""
INPUT_ID_FILE="url_list.txt"

OUTLINE_DOMAIN="https://outline-dev.myorder.dev"
OUTLINE_TOKEN=""

OUTPUT_FILE="migration_report.html"
MAX_LEN=76
# =================================================

if [ ! -f "$INPUT_ID_FILE" ]; then
    echo "❌ Error: File $INPUT_ID_FILE not found."
    exit 1
fi

declare -A CONF_MAP_ID
declare -A CONF_MAP_TITLE
declare -A OUTLINE_MAP
declare -A OUTLINE_MAP_TITLE

# --- UPDATED NORMALIZATION LOGIC ---
normalize_key() {
    echo "$1" | perl -CS -Mutf8 -ne '
        chomp;
        
        # 1. แปลงเป็นตัวเล็ก (Lowercase) ก่อนเลย
        $_ = lc($_);

        # 2. [IMPORTANT] ลบทุกอย่างที่ "ไม่ใช่" (ภาษาไทย / อังกฤษ / ตัวเลข) ทิ้งให้หมด
        # - \x{0E00}-\x{0E7F} = ภาษาไทย
        # - a-z0-9 = อังกฤษและตัวเลข
        # ผลลัพธ์: /, -, space, ., (), [], emojis จะหายไปหมด
        s/[^a-z0-9\x{0E00}-\x{0E7F}]//g;
        
        # 3. ตัดเหลือ Max Len (เผื่อ title ยาวเกิน)
        print substr($_, 0, '$MAX_LEN');
    '
}

html_escape() {
    echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# =========================================================
# 1. Fetch Confluence
# =========================================================
echo "🚀 [1/3] Processing Confluence List..."
while IFS= read -r page_id || [ -n "$page_id" ]; do
    clean_id=$(echo "$page_id" | tr -d '[:space:]')
    [ -z "$clean_id" ] && continue

    response=$(curl -s -f -u "${CONF_EMAIL}:${CONF_TOKEN}" \
        -H "Accept: application/json" \
        "https://${CONF_DOMAIN}/wiki/rest/api/content/${clean_id}")

    if [ $? -eq 0 ]; then
        title=$(echo "$response" | jq -r '.title')
        if [ "$title" != "null" ]; then
            key=$(normalize_key "$title")
            CONF_MAP_ID["$key"]="$clean_id"
            CONF_MAP_TITLE["$key"]="$title"
            # Debug: ปริ้นท์ Key ออกมาดูว่าตัด / ออกจริงไหม
            # echo "   [DEBUG] $title -> $key" 
            echo "   Processing: $title"
        fi
    fi
done < "$INPUT_ID_FILE"

# =========================================================
# 2. Fetch Outline
# =========================================================
echo "🚀 [2/3] Processing Outline Documents..."
OFFSET=0
LIMIT=100
while true; do
    RESPONSE=$(curl -s -X POST "${OUTLINE_DOMAIN}/api/documents.list" \
        -H "Authorization: Bearer ${OUTLINE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"limit\": $LIMIT, \"offset\": $OFFSET}")

    # [DEBUG] เพิ่ม 3 บรรทัดนี้เพื่อดูว่า Server ตอบอะไรมา
    if ! echo "$RESPONSE" | jq -e . >/dev/null 2>&1; then
        echo "❌ Server returned non-JSON response:"
        echo "$RESPONSE"
        break
    fi

    IS_OK=$(echo "$RESPONSE" | jq -r '.ok // false')
    if [ "$IS_OK" != "true" ]; then 
        echo "⚠️ API Error: $(echo "$RESPONSE" | jq -r '.message // "Unknown error"')"
        break 
    fi

    while IFS= read -r line; do
        key=$(normalize_key "$line")
        OUTLINE_MAP["$key"]=1
        OUTLINE_MAP_TITLE["$key"]="$line"
    done < <(echo "$RESPONSE" | jq -r '.data[].title')

    NUM_FETCHED=$(echo "$RESPONSE" | jq '.data | length')
    [ "$NUM_FETCHED" -eq 0 ] && break
    OFFSET=$((OFFSET + LIMIT))
done

# =========================================================
# 3. Generate Report
# =========================================================
echo "🚀 [3/3] Generating Report..."

cat <<EOF > "$OUTPUT_FILE"
<!DOCTYPE html>
<html lang="th">
<head>
    <meta charset="UTF-8">
    <title>Migration Clean Report</title>
    <style>
        body { font-family: 'Sarabun', sans-serif; margin: 20px; background-color: #f4f5f7; font-size: 13px; }
        h1 { color: #333; }
        table { width: 100%; border-collapse: collapse; background: white; table-layout: fixed; }
        th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #ddd; word-wrap: break-word; vertical-align: top; }
        th { background-color: #253858; color: white; }
        tr:hover { background-color: #f8f9fa; }
        .badge { padding: 4px 8px; border-radius: 4px; color: white; font-weight: bold; display: block; text-align: center;}
        .synced { background-color: #36b37e; }
        .missing { background-color: #ff5630; }
        .extra { background-color: #ffab00; color: #333; }
        .key-cell { font-family: monospace; font-size: 11px; color: #555; background: #fafafa; border-right: 1px solid #eee; overflow-wrap: break-word;}
        .match { background-color: #e3fcef; color: #006644; }
    </style>
    <link href="https://fonts.googleapis.com/css2?family=Sarabun:wght@400;700&display=swap" rel="stylesheet">
</head>
<body>
    <h1>📊 Migration Report (Strict Normalization)</h1>
    <p>Rule: Keep only a-z, 0-9, Thai. Remove all symbols (/, -, ., etc).</p>
    <table>
        <thead>
            <tr>
                <th width="5%">ID</th>
                <th width="20%">Confluence Title</th>
                <th width="22%">Normalized Key (CF)</th>
                <th width="6%">Status</th>
                <th width="22%">Normalized Key (OL)</th>
                <th width="25%">Outline Title</th>
            </tr>
        </thead>
        <tbody>
EOF

# --- COMPARE ---
for key in "${!CONF_MAP_ID[@]}"; do
    page_id="${CONF_MAP_ID[$key]}"
    conf_title=$(html_escape "${CONF_MAP_TITLE[$key]}")
    safe_key=$(html_escape "$key")

    if [[ -n "${OUTLINE_MAP[$key]}" ]]; then
        # SYNCED
        outline_title=$(html_escape "${OUTLINE_MAP_TITLE[$key]}")
        echo "<tr>
            <td>$page_id</td>
            <td>$conf_title</td>
            <td class='key-cell match'>$safe_key</td>
            <td><span class='badge synced'>Synced</span></td>
            <td class='key-cell match'>$safe_key</td>
            <td>$outline_title</td>
        </tr>" >> "$OUTPUT_FILE"
        unset OUTLINE_MAP["$key"]
    else
        # MISSING
        echo "<tr>
            <td>$page_id</td>
            <td>$conf_title</td>
            <td class='key-cell'>$safe_key</td>
            <td><span class='badge missing'>Missing</span></td>
            <td class='key-cell' style='text-align:center;'>-</td>
            <td style='color:#ccc;'>-</td>
        </tr>" >> "$OUTPUT_FILE"
    fi
done

# --- EXTRAS ---
for key in "${!OUTLINE_MAP[@]}"; do
    outline_title=$(html_escape "${OUTLINE_MAP_TITLE[$key]}")
    safe_key=$(html_escape "$key")
    echo "<tr>
        <td>-</td>
        <td style='color:#ccc;'>-</td>
        <td class='key-cell' style='text-align:center;'>-</td>
        <td><span class='badge extra'>Extra</span></td>
        <td class='key-cell'>$safe_key</td>
        <td>$outline_title</td>
    </tr>" >> "$OUTPUT_FILE"
done

cat <<EOF >> "$OUTPUT_FILE"
        </tbody>
    </table>
</body>
</html>
EOF

echo "🎉 Strict Report Generated: $OUTPUT_FILE"