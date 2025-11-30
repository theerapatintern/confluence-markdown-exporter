#!/bin/bash

# ============================
#      CHECK ARGUMENTS
# ============================
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <src_folder> <des_folder>"
    exit 1
fi

SRC="${1%/}"
DES="${2%/}"

if [ ! -d "$SRC" ]; then
    echo "Source folder not found: $SRC"
    exit 1
fi

mkdir -p "$DES/uploads"

echo "🔍 Copying all images → uploads/"

# Copy all images to des/uploads
find "$SRC/attachments" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \) |
while read -r IMG; do
    base=$(basename "$IMG")
    cp "$IMG" "$DES/uploads/$base"
    echo "📦 Copied: $base"
done

echo "----------------------------------------"
echo "🔧 Processing Markdown files"
echo "----------------------------------------"

# Admonition mapping
MAPPING=(
    "IMPORTANT:info"
    "WARNING:warning"
    "CAUTION:warning"
    "TIP:success"
    "NOTE:tip"
)

map_type() {
    local type_gfm="$1"
    for map_pair in "${MAPPING[@]}"; do
        if [[ "$map_pair" =~ ^"${type_gfm}": ]]; then
            echo "${map_pair#*:}"
            return
        fi
    done
    echo "info"
}

process_md() {
    local input_file="$1"
    local rel="$2"
    local output_file="$3"

    mkdir -p "$(dirname "$output_file")"
    > "$output_file"

    in_admonition=0
    count_admonition=0
    count_image=0
    count_path=0

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | tr -d '\r')
        original="$line"

        # 0) REMOVE ALT + FIX IMAGE PATHS → uploads/<image>
        if [[ "$line" =~ "!" ]]; then
            # Remove alt text
            line=$(echo "$line" | sed -E 's/!\[[^]]*\]\(([^)]+)\)/![](\1)/g')
            ((count_image++))

            # Fix path to uploads/<image.png>
            line=$(echo "$line" | perl -pe 's{(?:\.\./)*attachments/.+?/([^/\)]+\.(?:png|jpg|jpeg|gif))}{uploads/$1}g')
            ((count_path++))
        fi

        # 1) START ADMONITION
        TYPE_GFM=$(echo "$line" | sed -nE 's/^>[[:space:]]*\[!(IMPORTANT|WARNING|CAUTION|TIP|NOTE)\][[:space:]]*$/\1/p')
        if [ -n "$TYPE_GFM" ]; then
            [ "$in_admonition" -eq 1 ] && echo ":::" >> "$output_file"
            TYPE_NEW=$(map_type "$TYPE_GFM")
            echo ":::$TYPE_NEW" >> "$output_file"
            in_admonition=1
            ((count_admonition++))
            continue
        fi

        # 2) INSIDE ADMONITION
        if [ "$in_admonition" -eq 1 ] && [[ "$line" == ">"* ]]; then
            content=$(echo "$line" | sed -E 's/^>[[:space:]]*//')
            echo "$content" >> "$output_file"
            continue
        fi

        # 3) END ADMONITION
        [ "$in_admonition" -eq 1 ] && echo ":::" >> "$output_file" && in_admonition=0

        echo "$line" >> "$output_file"
    done < "$input_file"

    [ "$in_admonition" -eq 1 ] && echo ":::" >> "$output_file"

    # LOGGING
    msg="Processing: $rel"
    detail="Admonitions: $count_admonition, Images: $count_image, Paths: $count_path"
    echo "$msg -> [Fixed: $detail]"
}

# Process all Markdown files
find "$SRC" -type f -name "*.md" | while read -r FILE; do
    REL="${FILE#$SRC/}"
    DEST="$DES/$REL"
    process_md "$FILE" "$REL" "$DEST"
done

echo "✅ DONE! All markdown and uploads processed."
