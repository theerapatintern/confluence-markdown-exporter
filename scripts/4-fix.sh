#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURATION
# ==========================================
# INPUT_DIR: โฟลเดอร์ต้นทางที่เก็บไฟล์ดิบ (เช่น p1, p2 ที่ export มา)
INPUT_DIR="migrate/parts" 

# OUTPUT_DIR: โฟลเดอร์ปลายทางสำหรับไฟล์ที่แก้ไขเสร็จแล้ว (พร้อม migrate)
OUTPUT_DIR="migrate/ready_to_import"

# ==========================================
# AUTO-DETECT PARTS
# ==========================================
# ตรวจสอบว่ามี Input Dir จริงไหม
if [ ! -d "$INPUT_DIR" ]; then
    echo "❌ Error: Input directory '$INPUT_DIR' not found."
    exit 1
fi

echo "🔍 Detecting parts in '$INPUT_DIR'..."
PARTS=()
# ใช้ find หาเฉพาะ Directory ชั้นแรก (maxdepth 1)
while IFS= read -r -d '' dir; do
    # ตัด path ออกเอาแค่ชื่อ folder (เช่น p1, p2)
    part_name="$(basename "$dir")"
    PARTS+=("$part_name")
done < <(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [ ${#PARTS[@]} -eq 0 ]; then
    echo "⚠️  Warning: No parts (subdirectories) found in '$INPUT_DIR'."
    exit 0
fi

echo "✅ Found ${#PARTS[@]} parts: ${PARTS[*]}"

# ==========================================
# SAFETY & CLEANUP
# ==========================================
if [ -z "$OUTPUT_DIR" ] || [ "$OUTPUT_DIR" = "/" ]; then
    echo "❌ Error: Bad OUTPUT_DIR ($OUTPUT_DIR). Aborting."
    exit 1
fi

if [ -d "$OUTPUT_DIR" ]; then
    echo "🧹 Cleaning old destination: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# ==========================================
# HELPER FUNCTIONS
# ==========================================
map_type() {
    local type_gfm="$1"
    case "$type_gfm" in
        IMPORTANT) echo "info" ;;
        WARNING) echo "warning" ;;
        CAUTION) echo "warning" ;;
        TIP) echo "success" ;;
        NOTE) echo "tip" ;;
        *) echo "info" ;;
    esac
}

process_md_file() {
    local input_file="$1"
    local rel="$2"
    local output_file="$3"

    mkdir -p "$(dirname "$output_file")"
    : > "$output_file"

    local in_admonition=0
    local count_admonition=0
    local count_image=0
    local count_path=0
    local count_details=0
    local count_html_list=0
    local count_inline_task=0
    
    local line_num=0
    local in_tags_block=0
    local table_buffer=""
    local regex_details="</?(details|summary)>"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        line_num=$((line_num+1))
        local write_line=1

        # --- PREPROCESSING (Header/Frontmatter) ---
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
            # Handle Breadcrumb / Navigation Links
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

        # --- CLEANUP LOGIC ---
        
        # Inline Task Lists
        if [[ "$line" == *"inline-task-list"* ]]; then
             line="$(echo "$line" | perl -pe 's{<ul class="inline-task-list"[^>]*><li[^>]*><span[^>]*>(.*?)</span></li></ul>}{- [ ] $1}g')"
             line="$(echo "$line" | sed -E 's/<\/?code>//g')"
             count_inline_task=$((count_inline_task+1))
        fi

        # General Text
        line="${line//\\_/_}"
        line="${line//<br\/>/<br>}"

        # Clean Unicode Headers
        if [[ "$line" == *"\\u"* ]]; then
            line="$(echo "$line" | sed -E 's/^([#[:space:]]*)(\\u[0-9a-fA-F]{4})+[[:space:]]*/\1/g')"
        fi

        # Remove details/summary
        if [[ "$line" =~ $regex_details ]]; then
            line="$(echo "$line" | sed -E 's/<\/?(details|summary)>//g')"
            count_details=$((count_details+1))
        fi

        # --- TABLE BUFFERING ---
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

        # Clean HTML Lists (<ul>)
        if [[ "$line" == *"<ul>"* ]]; then
            line="$(echo "$line" | sed -E 's/<\/?ul>//g')"
            line="$(echo "$line" | sed -E 's/<li><p>/ * /g')"
            line="$(echo "$line" | sed -E 's/<\/p><\/li>//g')"
            line="$(echo "$line" | sed -E 's/<br>//g')"
            count_html_list=$((count_html_list+1))
        fi

        # Clean HTML Lists (<ol>) inside tables
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

        # Images & Paths
        if [[ "$line" == *"!"* ]]; then
            line="$(echo "$line" | sed -E 's/!\[[^]]*\]\(([^)]+)\)/![](\1)/g')"
            count_image=$((count_image+1))
            line="$(echo "$line" | perl -pe 's{(?:\.\./)*attachments/(?:.+?/)*([^/\)]+\.(?:png|jpg|jpeg|gif))}{uploads/$1}gi')"
            count_path=$((count_path+1))
        fi

        # Admonitions in Tables
        if [[ "$line" == *"|"* ]] && [[ "$line" == *"> [!"* ]]; then
            line="$(echo "$line" | perl -pe '
                BEGIN { %m=("IMPORTANT"=>"info","WARNING"=>"warning","CAUTION"=>"warning","TIP"=>"success","NOTE"=>"tip"); }
                s/>\s*\[\!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\](.*?)(?=\|)/\n:::$m{$1}\n$2\n:::/g
            ')"
        fi

        # Admonitions Block
        TYPE_GFM="$(echo "$line" | sed -nE 's/^>[[:space:]]*\[!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\][[:space:]]*$/\1/p')"
        if [ -n "$TYPE_GFM" ]; then
            if [ "$in_admonition" -eq 1 ]; then echo ":::" >> "$output_file"; echo "" >> "$output_file"; fi
            TYPE_NEW="$(map_type "$TYPE_GFM")"
            echo ":::${TYPE_NEW}" >> "$output_file"
            in_admonition=1
            count_admonition=$((count_admonition+1))
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

    # ==========================================
    # [NEW LOGIC] RENAME FILE TO TITLE
    # ==========================================
    if [ -n "$extracted_title" ]; then
        local new_filename="${extracted_title}.md"
        local final_dir=$(dirname "$output_file")
        local final_path="$final_dir/$new_filename"
        
        # เปลี่ยนชื่อไฟล์ถ้าชื่อไม่เหมือนเดิม
        if [ "$output_file" != "$final_path" ]; then
            mv "$output_file" "$final_path"
        fi
    fi
}

# ==========================================
# MAIN LOOP
# ==========================================
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

    # 1) Copy images (flatten structure)
    ATT_ROOT="$SRC/attachments"
    if [ -d "$ATT_ROOT" ]; then
        echo "📸 Copying images from $ATT_ROOT -> $DST/uploads"
        # ใช้ find + cp เพื่อความชัวร์เรื่อง subdirectories ใน attachments
        while IFS= read -r -d '' img; do
            base="$(basename "$img")"
            # ใช้ -n เพื่อไม่ให้ overwrite ถ้าชื่อซ้ำ (หรือลบ -n ออกถ้าอยากให้ทับ)
            cp -n "$img" "$DST/uploads/$base"
        done < <(find "$ATT_ROOT" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \) -print0)
    else
        echo "   No attachments folder found in $SRC"
    fi

    # 2) Process .md files
    echo "📝 Processing .md files..."
    count_files=0
    while IFS= read -r -d '' mdfile; do
        rel="${mdfile#$SRC/}"
        out="$DST/$rel"
        process_md_file "$mdfile" "$rel" "$out"
        count_files=$((count_files+1))
    done < <(find "$SRC" -type f -name "*.md" -print0)
    
    echo "   Processed $count_files Markdown files."
done

echo
echo "🎉 All parts processed successfully."
echo "📂 Output Location: $OUTPUT_DIR"