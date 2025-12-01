#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (locked) ----------
SRC_ROOT="src"
DES_ROOT="des"

PARTS=( "p1" "p2" "p3" )

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
    
    # State flags for Header cleaning
    local line_num=0
    local in_tags_block=0

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
            
            # Detect Start/End of Frontmatter (---)
            if [[ "$line" =~ ^---$ ]]; then
                # If we are strictly inside a tags block, this ends it
                if [ "$in_tags_block" -eq 1 ]; then
                    in_tags_block=0
                fi
                # User wants to remove the --- wrapper as well
                write_line=0
            fi

            # Detect "tags:" keyword
            if [[ "$line" =~ ^tags: ]]; then
                in_tags_block=1
                write_line=0
            fi

            # Handle logic INSIDE tags block
            if [ "$in_tags_block" -eq 1 ]; then
                # If line starts with "-" (list item), skip it
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
                    write_line=0
                elif [[ -z "${line// }" ]]; then
                    # Skip empty lines inside tags block
                    write_line=0
                fi
            fi


            # --- 2) Handle Breadcrumb / Navigation Links ---
            
            if [ "$write_line" -eq 1 ] && [[ "$line" =~ \[.*\]\(.*\.md\) ]]; then
                
                # Case A: Contains ">" (Breadcrumb chain)
                if [[ "$line" == *">"* ]]; then
                    write_line=0
                fi

                # Case B: Empty text link
                if [[ "$line" =~ ^\[\]\(.*\.md\) ]]; then
                     write_line=0
                fi

                # Case C: Standalone Link (Navigation Header)
                trimmed_line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if [[ "$trimmed_line" =~ ^\[.*\]\(.*\.md\)$ ]]; then
                    write_line=0
                fi
            fi
        fi

        # If flagged to skip, continue to next line
        if [ "$write_line" -eq 0 ]; then
            continue
        fi

        # ================================================
        # 3) Remove <details> and <summary> tags (GLOBAL)
        # ================================================
        # Use the variable $regex_details here
        if [[ "$line" =~ $regex_details ]]; then
            line="$(echo "$line" | sed -E 's/<\/?(details|summary)>//g')"
            count_details=$((count_details+1))
        fi

        # ================================================
        # 4) Clean HTML Lists in Tables (GLOBAL)
        # Target: <ul><li><p>Text</p></li></ul> -> <br>* Text
        # ================================================
        if [[ "$line" == *"<ul>"* ]]; then
            # Remove <ul> and </ul>
            line="$(echo "$line" | sed -E 's/<\/?ul>//g')"
            
            # Replace <li><p> with <br>* (Using <br> forces line break in rendered MD tables)
            line="$(echo "$line" | sed -E 's/<li><p>/<br>* /g')"
            
            # Remove closing </p></li>
            line="$(echo "$line" | sed -E 's/<\/p><\/li>//g')"
            
            count_html_list=$((count_html_list+1))
        fi

        # ================================================
        # 5) Remove alt text in images & Fix Paths
        # ================================================
        if [[ "$line" == *"!"* ]]; then
            # Convert ![alt](path) -> ![](path)
            line="$(echo "$line" | sed -E 's/!\[[^]]*\]\(([^)]+)\)/![](\1)/g')"
            count_image=$((count_image+1))

            # Update path to uploads/<image.png>
            line="$(echo "$line" | perl -pe 's{(?:\.\./)*attachments/(?:.+?/)*([^/\)]+\.(?:png|jpg|jpeg|gif))}{uploads/$1}gi')"
            count_path=$((count_path+1))
        fi

        # ================================================
        # 6) Start Admonition
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
        # 7) Inside Admonition
        # ================================================
        if [ "$in_admonition" -eq 1 ] && [[ "$line" == ">"* ]]; then
            content="$(echo "$line" | sed -E 's/^>[[:space:]]*//')"
            echo "$content" >> "$output_file"
            continue
        fi

        # ================================================
        # 8) End Admonition
        # ================================================
        if [ "$in_admonition" -eq 1 ]; then
            echo ":::" >> "$output_file"
            in_admonition=0
        fi

        # Write normal line
        echo "$line" >> "$output_file"
    done < "$input_file"

    # Close open admonition at EOF
    if [ "$in_admonition" -eq 1 ]; then
        echo ":::" >> "$output_file"
    fi

    echo "Processing: $rel -> [Admonitions:$count_admonition Img:$count_image CleanHTML:$count_html_list]"
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

    # 1) copy images (flatten) from part/attachments -> dst/uploads
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

    # 2) process md files under part (preserve tree)
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