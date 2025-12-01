#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (locked) ----------
SRC_ROOT="src"
DES_ROOT="des"

# เพิ่ม "p4" เข้าไปในรายการ
PARTS=( "p1" "p2" "p3" "p4" )

# safety: don't accidentally rm /
if [ -z "$DES_ROOT" ] || [ "$DES_ROOT" = "/" ]; then
    echo "Bad DES_ROOT ($DES_ROOT). Aborting."
    exit 1
fi

# ---------- reset destination ----------
if [ -d "$DES_ROOT" ]; then
    echo "Cleaning old destination: $DES_ROOT"
    rm -rf "$DES_ROOT"
fi
mkdir -p "$DES_ROOT"

# ---------- helper functions ----------
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
    
    # State flags for Header cleaning
    local line_num=0
    local in_tags_block=0

    # Buffer for table headers to conditionally delete them
    local table_buffer=""

    # Define regex pattern in variable to avoid syntax errors with < >
    local regex_details="</?(details|summary)>"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"  # strip CR for Windows files
        line_num=$((line_num+1))
        local write_line=1  # Default: write this line unless logic says otherwise

        # ================================================
        # PREPROCESSING: Header Cleanup (First 20 lines)
        # ================================================
        if [ "$line_num" -le 20 ]; then

            # --- 1) Handle Frontmatter & Tags Removal ---
            if [[ "$line" =~ ^---$ ]]; then
                if [ "$in_tags_block" -eq 1 ]; then
                    in_tags_block=0
                fi
                write_line=0
            fi

            if [[ "$line" =~ ^tags: ]]; then
                in_tags_block=1
                write_line=0
            fi

            if [ "$in_tags_block" -eq 1 ]; then
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
                    write_line=0
                elif [[ -z "${line// }" ]]; then
                    write_line=0
                fi
            fi

            # --- 2) Handle Breadcrumb / Navigation Links ---
            if [ "$write_line" -eq 1 ] && [[ "$line" =~ \[.*\]\(.*\.md\) ]]; then
                if [[ "$line" == *">"* ]]; then
                    write_line=0
                fi
                if [[ "$line" =~ ^\[\]\(.*\.md\) ]]; then
                     write_line=0
                fi
                trimmed_line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if [[ "$trimmed_line" =~ ^\[.*\]\(.*\.md\)$ ]]; then
                    write_line=0
                fi
            fi
        fi

        if [ "$write_line" -eq 0 ]; then
            continue
        fi

        # ================================================
        # 3) Clean Inline Task Lists (Specific Class)
        # ================================================
        if [[ "$line" == *"inline-task-list"* ]]; then
             line="$(echo "$line" | perl -pe 's{<ul class="inline-task-list"[^>]*><li[^>]*><span[^>]*>(.*?)</span></li></ul>}{- [ ] $1}g')"
             line="$(echo "$line" | sed -E 's/<\/?code>//g')"
             count_inline_task=$((count_inline_task+1))
        fi

        # ================================================
        # 3.5) General Text Cleanup
        # ================================================
        line="${line//\\_/_}"
        line="${line//<br\/>/<br>}"

        # ================================================
        # 3.6) Clean Unicode Escaped Headers (UPDATED)
        # Pattern: ## \uD83D\uDDD3 Date -> ## Date
        # ================================================
        if [[ "$line" == *"\\u"* ]]; then
            # Capture Group 1: Start with # (any amount) or spaces
            # Capture Group 2: The unicode sequence \uXXXX (one or more)
            # Match optional spaces after unicode
            # Replace with: Just Group 1 (the # part)
            line="$(echo "$line" | sed -E 's/^([#[:space:]]*)(\\u[0-9a-fA-F]{4})+[[:space:]]*/\1/g')"
        fi

        # ================================================
        # 4) Remove <details> and <summary> tags (GLOBAL)
        # ================================================
        if [[ "$line" =~ $regex_details ]]; then
            line="$(echo "$line" | sed -E 's/<\/?(details|summary)>//g')"
            count_details=$((count_details+1))
        fi

        # ================================================
        # [NEW LOGIC] Table Header Buffering
        # ================================================
        if [[ "$line" =~ ^[[:space:]]*\|([[:space:]]*\|)+[[:space:]]*$ ]] || \
           [[ "$line" =~ ^[[:space:]]*\|([[:space:]]*:?-+:?[[:space:]]*\|)+[[:space:]]*$ ]]; then
            if [ -z "$table_buffer" ]; then
                table_buffer="$line"
            else
                table_buffer="$table_buffer"$'\n'"$line"
            fi
            continue
        fi

        local is_trigger=0
        if [[ "$line" == *"|"* ]]; then
            if [[ "$line" == *"<ol"* ]] || [[ "$line" == *"> [!"* ]]; then
                is_trigger=1
            fi
        fi

        if [ "$is_trigger" -eq 1 ]; then
            table_buffer=""
        else
            if [ -n "$table_buffer" ]; then
                echo "$table_buffer" >> "$output_file"
                table_buffer=""
            fi
        fi

        # ================================================
        # 5) Clean HTML Lists in Tables (Unordered <ul>)
        # ================================================
        if [[ "$line" == *"<ul>"* ]]; then
            line="$(echo "$line" | sed -E 's/<\/?ul>//g')"
            # เปลี่ยน <li> เป็น " * " โดยไม่ใส่ <br>
            line="$(echo "$line" | sed -E 's/<li><p>/ * /g')"
            line="$(echo "$line" | sed -E 's/<\/p><\/li>//g')"
            
            # ลบ <br> ทั้งหมดในบรรทัดนี้ทิ้ง
            line="$(echo "$line" | sed -E 's/<br>//g')"
            
            count_html_list=$((count_html_list+1))
        fi

        # ================================================
        # 5.5) Clean HTML Ordered Lists in Tables (Ordered <ol>)
        # ================================================
        if [[ "$line" == *"|"* ]] && [[ "$line" == *"<ol"* ]]; then
            line="$(echo "$line" | perl -pe '
                if (m/\|.*<ol/) {
                    s/^\|.*<ol[^>]*>(.*?)<\/ol>.*$/$1/;
                    $i = 1;
                    s{<li><p>(.*?)</p></li>}{"\n" . $i++ . ". $1"}ge;
                    s{<strong>}{**}g; 
                    s{</strong>}{**}g;
                }
            ')"
        fi

        # ================================================
        # 6) Remove alt text in images & Fix Paths
        # ================================================
        if [[ "$line" == *"!"* ]]; then
            line="$(echo "$line" | sed -E 's/!\[[^]]*\]\(([^)]+)\)/![](\1)/g')"
            count_image=$((count_image+1))
            line="$(echo "$line" | perl -pe 's{(?:\.\./)*attachments/(?:.+?/)*([^/\)]+\.(?:png|jpg|jpeg|gif))}{uploads/$1}gi')"
            count_path=$((count_path+1))
        fi

        # ================================================
        # 6.5) Handle Admonitions inside Tables
        # ================================================
        if [[ "$line" == *"|"* ]] && [[ "$line" == *"> [!"* ]]; then
            line="$(echo "$line" | perl -pe '
                BEGIN { %m=("IMPORTANT"=>"info","WARNING"=>"warning","CAUTION"=>"warning","TIP"=>"success","NOTE"=>"tip"); }
                s/>\s*\[\!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\](.*?)(?=\|)/\n:::$m{$1}\n$2\n:::/g
            ')"
        fi

        # ================================================
        # 7) Start Admonition
        # ================================================
        TYPE_GFM="$(echo "$line" | sed -nE 's/^>[[:space:]]*\[!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\][[:space:]]*$/\1/p')"
        if [ -n "$TYPE_GFM" ]; then
            if [ "$in_admonition" -eq 1 ]; then
                echo ":::" >> "$output_file"
                echo "" >> "$output_file"
            fi
            TYPE_NEW="$(map_type "$TYPE_GFM")"
            echo ":::${TYPE_NEW}" >> "$output_file"
            in_admonition=1
            count_admonition=$((count_admonition+1))
            continue
        fi

        # ================================================
        # 8) Inside Admonition
        # ================================================
        if [ "$in_admonition" -eq 1 ] && [[ "$line" == ">"* ]]; then
            content="$(echo "$line" | sed -E 's/^>[[:space:]]*//')"
            echo "$content" >> "$output_file"
            continue
        fi

        # ================================================
        # 9) End Admonition
        # ================================================
        if [ "$in_admonition" -eq 1 ]; then
            echo ":::" >> "$output_file"
            in_admonition=0
        fi

        # Write normal line
        echo "$line" >> "$output_file"
    done < "$input_file"

    # Flush remaining buffer at EOF
    if [ -n "$table_buffer" ]; then
        echo "$table_buffer" >> "$output_file"
    fi

    # Close open admonition at EOF
    if [ "$in_admonition" -eq 1 ]; then
        echo ":::" >> "$output_file"
    fi

    echo "Processing: $rel -> [Tasks:$count_inline_task Img:$count_image Lists:$count_html_list]"
}


# ---------- core loop for each part ----------
for part in "${PARTS[@]}"; do
    SRC="$SRC_ROOT/$part"
    DST="$DES_ROOT/$part"

    echo
    echo "===== Processing part: $part ====="

    if [ ! -d "$SRC" ]; then
        echo "Source part folder not found: $SRC  (skipping)"
        continue
    fi

    mkdir -p "$DST"
    mkdir -p "$DST/uploads"

    # 1) copy images (flatten)
    ATT_ROOT="$SRC/attachments"
    if [ -d "$ATT_ROOT" ]; then
        echo "Copying images from $ATT_ROOT -> $DST/uploads (flatten)"
        while IFS= read -r -d '' img; do
            base="$(basename "$img")"
            cp "$img" "$DST/uploads/$base"
        done < <(find "$ATT_ROOT" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \) -print0)
    else
        echo "  No attachments in $SRC (skipping image copy)"
    fi

    # 2) process md files
    echo "Processing .md files under $SRC"
    while IFS= read -r -d '' mdfile; do
        rel="${mdfile#$SRC/}"
        out="$DST/$rel"
        process_md_file "$mdfile" "$rel" "$out"
    done < <(find "$SRC" -type f -name "*.md" -print0)

    echo "===== Done part: $part ====="
done

echo
echo "✅ All parts processed. Output base: $DES_ROOT"