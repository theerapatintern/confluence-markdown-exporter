#!/usr/bin/env bash

set -euo pipefail

# Step 1: โหลดค่า Config จากไฟล์ .env
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    echo "⚙️  Loading configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  Warning: .env file not found. Using default values."
fi

# กำหนดค่าเริ่มต้น (เผื่อใน .env ลืมใส่มา)
INPUT_DIR="${MIGRATE_PARTS_DIR:-migrate/parts}"          # โฟลเดอร์ต้นทาง (ที่แบ่ง part แล้ว)
OUTPUT_DIR="${MIGRATE_READY_DIR:-migrate/ready_to_import}" # โฟลเดอร์ปลายทาง (พร้อม Import)
AUTHOR_FILE="${CREATOR_REPORT_FILE:-creator_report.txt}"   # ไฟล์จับคู่ชื่อคน

# ==========================================
# HELPER FUNCTIONS
# ==========================================

# Step 2: เตรียมฟังก์ชันสำหรับจัดการ Text (Normalize & Clean)
normalize_key() {
    local str="$1"
    echo "$str" \
        | sed 's/\.md$//' \
        | sed 's/[^a-zA-Z0-9ก-๙]//g' \
        | tr '[:upper:]' '[:lower:]'
}

# ฟังก์ชันล้างชื่อไฟล์ (ป้องกันอักขระแปลกปลอม เช่น \_)
clean_filename() {
    local str="$1"
    # เปลี่ยน \_ เป็น _ และลบ \ อื่นๆ ที่ไม่จำเป็น
    echo "$str" | sed 's/\\_/_/g' | sed 's/\\//g'
}

map_type() {
    local type_gfm="$1"
    case "$type_gfm" in
        IMPORTANT) echo "info" ;;
        WARNING)   echo "warning" ;;
        CAUTION)   echo "warning" ;;
        TIP)       echo "success" ;;
        NOTE)      echo "tip" ;;
        *)         echo "info" ;;
    esac
}


# Step 3: โหลดข้อมูลผู้แต่ง (Author) เข้า Memory
# เพื่อเอาไว้แปะท้ายไฟล์ว่าใครเป็นคนเขียน (Created By: ...)
declare -A AUTHOR_MAP

if [ -f "$AUTHOR_FILE" ]; then
    echo "📖 Loading authors from $AUTHOR_FILE..."
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # แกะชื่อผู้แต่งและ Title
        author=$(echo "$line" | sed 's/.*: //')
        title=$(echo "$line" | sed "s/: $author$//")

        # สร้าง Key สำหรับ map
        key=$(normalize_key "$title")
        clean_author="$(echo "$author" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        if [ -n "$key" ]; then
            AUTHOR_MAP["$key"]="$clean_author"
        fi
    done < "$AUTHOR_FILE"
    echo "   Loaded ${#AUTHOR_MAP[@]} authors into memory."
else
    echo "⚠️  Warning: Author file '$AUTHOR_FILE' not found."
fi

# Step 4: สแกนหา Part ทั้งหมดใน Input Directory
if [ ! -d "$INPUT_DIR" ]; then
    echo "❌ Error: Input directory '$INPUT_DIR' not found."
    exit 1
fi

echo "🔍 Detecting parts in '$INPUT_DIR'..."
PARTS=()
while IFS= read -r -d '' dir; do
    part_name="$(basename "$dir")"
    PARTS+=("$part_name")
done < <(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [ ${#PARTS[@]} -eq 0 ]; then
    echo "⚠️  Warning: No parts found in '$INPUT_DIR'."
    exit 0
fi

echo "✅ Found ${#PARTS[@]} parts: ${PARTS[*]}"

# Step 5: ล้างโฟลเดอร์ปลายทางให้สะอาดก่อนเริ่มงาน
if [ -z "$OUTPUT_DIR" ] || [ "$OUTPUT_DIR" = "/" ]; then
    echo "❌ Error: Bad OUTPUT_DIR ($OUTPUT_DIR). Aborting."
    exit 1
fi

if [ -d "$OUTPUT_DIR" ]; then
    echo "🧹 Cleaning old destination: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"


# Step 6: ฟังก์ชันแปลงไฟล์ Markdown ทีละไฟล์
process_md_file() {
    local input_file="$1"
    local rel="$2"
    local output_file="$3"

    mkdir -p "$(dirname "$output_file")"
    : > "$output_file" # Clear file

    # ตัวแปรสถานะต่างๆ
    local in_admonition=0
    local line_num=0
    local in_tags_block=0
    local table_buffer=""
    local regex_details="</?(details|summary)>"

    # ตัวแปรเก็บ Title ใหม่ที่ดึงจาก H1 (# Title)
    local extracted_title=""

    # --- อ่านไฟล์ทีละบรรทัด ---
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        line_num=$((line_num+1))
        local write_line=1

        # 6.1: จัดการ Frontmatter (ส่วนหัวไฟล์ที่มี ---)
        if [ "$line_num" -le 20 ]; then
            if [[ "$line" =~ ^---$ ]]; then
                if [ "$in_tags_block" -eq 1 ]; then in_tags_block=0; fi
                write_line=0
            fi
            if [[ "$line" =~ ^tags: ]]; then
                in_tags_block=1
                write_line=0
            fi
            if [ "$in_tags_block" -eq 1 ]; then
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]] || [[ -z "${line// }" ]]; then
                    write_line=0
                fi
            fi
            # ลบ Link แปลกๆ ที่ Outline ไม่รองรับ
            if [ "$write_line" -eq 1 ] && [[ "$line" =~ \[.*\]\(.*\.md\) ]]; then
                if [[ "$line" == *">"* ]] || [[ "$line" =~ ^\[\]\(.*\.md\) ]]; then
                    write_line=0
                fi
                trimmed_line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if [[ "$trimmed_line" =~ ^\[.*\]\(.*\.md\)$ ]]; then
                    write_line=0
                fi
            fi
        fi

        if [ "$write_line" -eq 0 ]; then continue; fi

        # 6.2: ดึงชื่อไฟล์จาก H1 (# Title) และลบบรรทัดนั้นทิ้ง
        # เอาชื่อนี้ไปตั้งเป็นชื่อไฟล์ตอนท้าย
        if [ -z "$extracted_title" ] && [[ "$line" =~ ^#[[:space:]]+(.+) ]]; then
            raw_title="${BASH_REMATCH[1]}"
            
            # Clean ชื่อให้ปลอดภัย
            clean_t="$(echo "$raw_title" | tr -d '/' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            
            # เรียกใช้ฟังก์ชัน clean_filename (แก้บั๊ก \_)
            extracted_title=$(clean_filename "$clean_t")

            # ข้ามบรรทัดนี้ไปเลย (ไม่เขียนลงไฟล์)
            continue
        fi

        # 6.3: ทำความสะอาด HTML 
        # แก้ Task List
        if [[ "$line" == *"inline-task-list"* ]]; then
            line="$(echo "$line" | perl -pe 's{<ul class="inline-task-list"[^>]*><li[^>]*><span[^>]*>(.*?)</span></li></ul>}{- [ ] $1}g')"
            line="$(echo "$line" | sed -E 's/<\/?code>//g')"
        fi

        # แก้ Underscore และ Break line
        line="${line//\\_/_}"
        line="${line//<br\/>/<br>}"

        # แก้ Unicode หลุด
        if [[ "$line" == *"\\u"* ]]; then
            line="$(echo "$line" | sed -E 's/^([#[:space:]]*)(\\u[0-9a-fA-F]{4})+[[:space:]]*/\1/g')"
        fi

        # ลบ Details/Summary tag
        if [[ "$line" =~ $regex_details ]]; then
            line="$(echo "$line" | sed -E 's/<\/?(details|summary)>//g')"
        fi

        # 6.4: จัดการตาราง 
        # ต้องรวมบรรทัดตารางเข้าด้วยกันเพื่อให้ Markdown render ถูก
        if [[ "$line" =~ ^[[:space:]]*\|([[:space:]]*\|)+[[:space:]]*$ ]] || \
           [[ "$line" =~ ^[[:space:]]*\|([[:space:]]*:?-+:?[[:space:]]*\|)+[[:space:]]*$ ]]; then
            if [ -z "$table_buffer" ]; then table_buffer="$line"; else table_buffer="$table_buffer"$'\n'"$line"; fi
            continue
        fi

        local is_trigger=0
        if [[ "$line" == *"|"* ]]; then
            if [[ "$line" == *"<ol"* ]] || [[ "$line" == *"> [!"* ]]; then is_trigger=1; fi
        fi

        if [ "$is_trigger" -eq 1 ]; then
            table_buffer=""
        else
            if [ -n "$table_buffer" ]; then echo "$table_buffer" >> "$output_file"; table_buffer=""; fi
        fi

        # แก้ HTML List <ul>
        if [[ "$line" == *"<ul>"* ]]; then
            line="$(echo "$line" | sed -E 's/<\/?ul>//g')"
            line="$(echo "$line" | sed -E 's/<li><p>/ * /g')"
            line="$(echo "$line" | sed -E 's/<\/p><\/li>//g')"
            line="$(echo "$line" | sed -E 's/<br>//g')"
        fi

        # แก้ Ordered List ในตาราง
        if [[ "$line" == *"|"* ]] && [[ "$line" == *"<ol"* ]]; then
            line="$(echo "$line" | perl -pe '
                if (m/\|.*<ol/) {
                    s/^\|.*<ol[^>]*>(.*?)<\/ol>.*$/$1/;
                    $i = 1;
                    s{<li><p>(.*?)</p></li>}{"\n" . $i++ . ". $1"}ge;
                    s{<strong>}{**}g; s{</strong>}{**}g;
                }
            ')"
        fi

        # 6.5: แก้ไข Path ของรูปภาพและไฟล์แนบ
        # เปลี่ยน attachments/ -> uploads/
        if [[ "$line" == *"!"* ]]; then
            line="$(echo "$line" | perl -pe 's{!\[[^]]*\]\(}{![](}g')"
        fi

        if [[ "$line" == *"attachments/"* ]]; then
            line="$(echo "$line" | perl -pe 's{(?:\.\./)*attachments/.*?/([^/)]+\.(?:png|jpg|jpeg|gif|mp4|mov|pdf|zip|docx|xlsx))}{uploads/$1}gi')"
        fi

        # ใส่ Double Newline หลังรูป
        if [[ "$line" == *"uploads/"* ]]; then
            line="$(echo "$line" | perl -pe 's{(\]\(uploads/[^)]+\))(?=\s*(?:!|\[))}{$1\n\n}g')"
        fi

        # 6.6: แปลง Admonition
        # เปลี่ยนจาก Confluence format เป็น Outline format (:::info)
        if [[ "$line" == *"|"* ]] && [[ "$line" == *"> [!"* ]]; then
            line="$(echo "$line" | perl -pe '
                BEGIN { %m=("IMPORTANT"=>"info","WARNING"=>"warning","CAUTION"=>"warning","TIP"=>"success","NOTE"=>"tip"); }
                s/>\s*\[\!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\](.*?)(?=\|)/\n:::$m{$1}\n$2\n:::/g
            ')"
        fi

        TYPE_GFM="$(echo "$line" | sed -nE 's/^>[[:space:]]*\[!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\][[:space:]]*$/\1/p')"
        if [ -n "$TYPE_GFM" ]; then
            if [ "$in_admonition" -eq 1 ]; then echo ":::" >> "$output_file"; echo "" >> "$output_file"; fi
            TYPE_NEW="$(map_type "$TYPE_GFM")"
            echo ":::${TYPE_NEW}" >> "$output_file"
            in_admonition=1
            continue
        fi

        if [ "$in_admonition" -eq 1 ] && [[ "$line" == ">"* ]]; then
            content="$(echo "$line" | sed -E 's/^>[[:space:]]*//')"
            echo "$content" >> "$output_file"
            continue
        fi

        if [ "$in_admonition" -eq 1 ]; then
            echo ":::" >> "$output_file"
            in_admonition=0
        fi

        echo "$line" >> "$output_file"
    done < "$input_file"

    if [ -n "$table_buffer" ]; then echo "$table_buffer" >> "$output_file"; fi
    if [ "$in_admonition" -eq 1 ]; then echo ":::" >> "$output_file"; fi

    # 6.7: ใส่ชื่อผู้แต่ง
    local filename=$(basename "$input_file")
    local file_key=$(normalize_key "$filename")
    local author_name=""
    if [ -n "$file_key" ]; then
        author_name="${AUTHOR_MAP["$file_key"]:-}"
    fi

    if [ -n "$author_name" ] && [ "$author_name" != "Unknown" ]; then
        local temp_final="${output_file}.final"
        echo "**Created By:** $author_name" > "$temp_final"
        echo "" >> "$temp_final"
        echo "---" >> "$temp_final"
        echo "" >> "$temp_final"
        cat "$output_file" >> "$temp_final"
        mv "$temp_final" "$output_file"
    fi

    # 6.8: เปลี่ยนชื่อไฟล์ตาม Title 
    if [ -n "$extracted_title" ]; then
        local new_filename="${extracted_title}.md"
        local final_dir=$(dirname "$output_file")
        local final_path="$final_dir/$new_filename"

        if [ "$output_file" != "$final_path" ]; then
            mv "$output_file" "$final_path"
        fi
    fi
}

# Step 7: เริ่มวนลูปทำทีละ Part
for part in "${PARTS[@]}"; do
    SRC="$INPUT_DIR/$part"
    DST="$OUTPUT_DIR/$part"

    echo
    echo "===== Processing part: $part ====="

    if [ ! -d "$SRC" ]; then
        echo "⚠️  Source part folder not found: $SRC (skipping)"
        continue
    fi

    mkdir -p "$DST"
    mkdir -p "$DST/uploads"

    # 7.1: ก๊อปปี้ไฟล์แนบ (Images/Videos/Docs)
    ATT_ROOT="$SRC/attachments"
    if [ -d "$ATT_ROOT" ]; then
        echo "📸 Copying media (images/videos/files) from $ATT_ROOT -> $DST/uploads"
        while IFS= read -r -d '' img; do
            base="$(basename "$img")"
            cp -n "$img" "$DST/uploads/$base"
        done < <(find "$ATT_ROOT" -type f \( \
            -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \
            -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.pdf' \
            -o -iname '*.zip' -o -iname '*.docx' -o -iname '*.xlsx' \
            \) -print0)
    else
        echo "   No attachments folder found in $SRC"
    fi

    # 7.2: ประมวลผลไฟล์ Markdown
    echo "📝 Processing .md files (Injecting Authors & Cleaning)..."
    count_files=0
    while IFS= read -r -d '' mdfile; do
        rel="${mdfile#$SRC/}"
        out="$DST/$rel"
        process_md_file "$mdfile" "$rel" "$out"
        count_files=$((count_files+1))
    done < <(find "$SRC" -type f -name "*.md" -print0)

    echo "   Processed $count_files Markdown files."
    
    # 7.3: สร้างไฟล์ Zip สำหรับแต่ละ Part
    echo "📦 Zipping part: $part ..."
    (
        cd "$OUTPUT_DIR"
        if command -v zip >/dev/null 2>&1; then
            zip -r -q "${part}.zip" "$part"
            echo "   ✅ Created zip: ${part}.zip"
        else
            echo "   ⚠️  Warning: 'zip' command not found. Skipping zip creation."
        fi
    )
done

echo
echo "🎉 All parts processed successfully."
echo "📂 Output Location: $OUTPUT_DIR"