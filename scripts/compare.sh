#!/bin/bash
# ================= CONFIGURATION =================
# ใช้ Locale มาตรฐาน
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Step 1: โหลดค่า Config จากไฟล์ .env
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

# ตั้งค่าตัวแปรจาก .env (และกำหนด Default ถ้าไม่เจอ)
CONF_URL="${CONFLUENCE_URL%/}"       # ตัด / ท้ายออกถ้ามี
CONF_EMAIL="${CONFLUENCE_EMAIL}"
CONF_TOKEN="${CONFLUENCE_API_TOKEN}"

OUTLINE_URL="${OUTLINE_DOMAIN%/}"    # ตัด / ท้ายออกถ้ามี
OUTLINE_KEY="${OUTLINE_TOKEN}"

INPUT_FILE="${INPUT_FILE:-url_list.txt}"
OUTPUT_FILE="${OUTPUT_REPORT_FILE:-migration_report.html}"
MAX_LEN=76

# ตรวจสอบไฟล์ Input
if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Error: File $INPUT_FILE not found."
    exit 1
fi

declare -A CONF_MAP_ID
declare -A CONF_MAP_TITLE
declare -A OUTLINE_MAP
declare -A OUTLINE_MAP_TITLE

# ================= HELPER FUNCTIONS =================

# Step 2: ฟังก์ชัน Normalize Key (ทำชื่อให้เป็นมาตรฐานเดียวกัน)
# - แปลงเป็นตัวเล็ก
# - ลบอักขระพิเศษ (เก็บไว้แค่ a-z, 0-9, ก-๙)
normalize_key() {
    echo "$1" | perl -CS -Mutf8 -ne '
        chomp;
        $_ = lc($_);
        # ลบทุกอย่างที่ไม่ใช่ ไทย/อังกฤษ/ตัวเลข
        s/[^a-z0-9\x{0E00}-\x{0E7F}]//g;
        # ตัดความยาวไม่ให้เกิน MAX_LEN
        print substr($_, 0, '$MAX_LEN');
    '
}

# ฟังก์ชันแปลงตัวอักษรให้เป็น HTML Safe (เช่น <, >, &)
html_escape() {
    echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# =========================================================
# Step 3: ดึงข้อมูลจาก Confluence
# =========================================================
echo "🚀 [1/3] Processing Confluence List..."

while IFS= read -r page_id || [ -n "$page_id" ]; do
    clean_id=$(echo "$page_id" | tr -d '[:space:]')
    [ -z "$clean_id" ] && continue

    # ยิง API ไปหา Confluence
    response=$(curl -s -f -u "${CONF_EMAIL}:${CONF_TOKEN}" \
        -H "Accept: application/json" \
        "${CONF_URL}/wiki/rest/api/content/${clean_id}")

    if [ $? -eq 0 ]; then
        title=$(echo "$response" | jq -r '.title')
        
        if [ "$title" != "null" ] && [ -n "$title" ]; then
            key=$(normalize_key "$title")
            
            # [Check] ป้องกัน Key ว่าง (กรณีชื่อมีแต่สัญลักษณ์)
            if [ -z "$key" ]; then
                echo "⚠️ Skipping Confluence page with empty key. ID: $clean_id, Title: '$title'"
                continue
            fi

            CONF_MAP_ID["$key"]="$clean_id"
            CONF_MAP_TITLE["$key"]="$title"
            # echo "   Processing: $clean_id : $title"
        fi
    fi
    echo -ne "   Processing ID: $clean_id \r"
done < "$INPUT_FILE"
echo "" 

# =========================================================
# Step 4: ดึงข้อมูลจาก Outline (Loop ทุก Collection)
# =========================================================
echo "🚀 [2/3] Processing Outline Documents (Per Collection)..."

declare -A OUTLINE_MAP
declare -A OUTLINE_MAP_TITLE

# 4.1 ดึงรายชื่อ Collection ทั้งหมดก่อน
COLLECTIONS_RESPONSE=$(curl -s -X POST "${OUTLINE_URL}/api/collections.list" \
  -H "Authorization: Bearer ${OUTLINE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"limit": 100}')

if ! echo "$COLLECTIONS_RESPONSE" | jq -e '.ok == true' >/dev/null; then
    echo "❌ Failed to fetch collections"
    echo "$COLLECTIONS_RESPONSE"
    exit 1
fi

COLLECTION_IDS=$(echo "$COLLECTIONS_RESPONSE" | jq -r '.data[].id')
TOTAL_COLLECTIONS=$(echo "$COLLECTION_IDS" | wc -l | tr -d ' ')

echo "   📁 Found $TOTAL_COLLECTIONS collections"

# 4.2 วนลูปทีละ Collection เพื่อดึงเอกสาร
for COLLECTION_ID in $COLLECTION_IDS; do
    echo "   📂 Collection: $COLLECTION_ID"

    OFFSET=0
    LIMIT=100

    while true; do
        RESPONSE=$(curl -s -X POST "${OUTLINE_URL}/api/documents.list" \
          -H "Authorization: Bearer ${OUTLINE_KEY}" \
          -H "Content-Type: application/json" \
          -d "{
            \"collectionId\": \"$COLLECTION_ID\",
            \"limit\": $LIMIT,
            \"offset\": $OFFSET
          }")

        if ! echo "$RESPONSE" | jq -e '.ok == true' >/dev/null; then
            echo "⚠️ API error in collection $COLLECTION_ID"
            break
        fi

        COUNT=$(echo "$RESPONSE" | jq '.data | length')
        if [ "$COUNT" -eq 0 ]; then break; fi

       # Loop เก็บข้อมูล
        while IFS= read -r title; do
            [ -z "$title" ] && continue
            
            key=$(normalize_key "$title")

            # [Check] ป้องกัน Key ว่าง
            if [ -z "$key" ]; then
                # echo "      ⚠️  Skipping document with empty key."
                continue
            fi

            OUTLINE_MAP["$key"]=1
            OUTLINE_MAP_TITLE["$key"]="$title"
            
        done < <(echo "$RESPONSE" | jq -r '.data[].title')

        # Pagination Check
        if [ "$COUNT" -lt "$LIMIT" ]; then break; fi
        OFFSET=$((OFFSET + LIMIT))
    done
done

echo "   ✅ Outline documents processing complete."

# =========================================================
# Step 5: สร้าง Report (HTML)
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

# 5.1: เปรียบเทียบ Confluence -> Outline
for key in "${!CONF_MAP_ID[@]}"; do
    page_id="${CONF_MAP_ID[$key]}"
    conf_title=$(html_escape "${CONF_MAP_TITLE[$key]}")
    safe_key=$(html_escape "$key")

    if [[ -n "${OUTLINE_MAP[$key]}" ]]; then
        # เจอคู่ (Synced)
        outline_title=$(html_escape "${OUTLINE_MAP_TITLE[$key]}")
        echo "<tr>
            <td>$page_id</td>
            <td>$conf_title</td>
            <td class='key-cell match'>$safe_key</td>
            <td><span class='badge synced'>Synced</span></td>
            <td class='key-cell match'>$safe_key</td>
            <td>$outline_title</td>
        </tr>" >> "$OUTPUT_FILE"
        # ลบออกจาก Map เพื่อให้เหลือแต่ตัวที่เกินมา (Extra)
        unset OUTLINE_MAP["$key"]
    else
        # ไม่เจอคู่ (Missing)
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

# 5.2: แสดงรายการที่มีใน Outline แต่ไม่มีใน Confluence (Extra)
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

echo "🎉 Report Generated: $OUTPUT_FILE"