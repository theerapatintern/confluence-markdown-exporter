#!/usr/bin/env bash
set -euo pipefail

# ================= CONFIGURATION =================
# โฟลเดอร์เป้าหมาย (แก้ที่นี่ให้ตรงกับที่ใช้งานจริง)
TARGET_DIR="output"

# Confluence API Config
CONF_DOMAIN="myorder-ecrm.atlassian.net"
CONF_EMAIL=""
CONF_TOKEN=""
# =================================================

# Check Dependencies
if ! command -v jq &> /dev/null; then echo "❌ Error: 'jq' required."; exit 1; fi

HAS_FFPROBE=0
if command -v ffprobe &> /dev/null; then HAS_FFPROBE=1; fi

# 1. CLEANUP OLD VIDEOS
if [ -d "$TARGET_DIR" ]; then
    echo "🧹 Cleaning up old video files (.mp4, .mov) in '$TARGET_DIR'..."
    find "$TARGET_DIR" -type f \( -name "*.mp4" -o -name "*.mov" \) -delete
fi

# HELPER FUNCTIONS
urldecode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

get_relative_path() {
    local source="$1"
    local target="$2"
    python3 -c "import os.path; print(os.path.relpath('$target', '$(dirname "$source")'))"
}

get_video_dimensions() {
    local file_path="$1"
    if [ "$HAS_FFPROBE" -eq 1 ]; then
        ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$file_path"
    else
        echo ""
    fi
}

echo "🚀 Starting Video Downloader & Link Fixer (Strict Mode)..."

find "$TARGET_DIR" -type f -name "*.md" | while read -r md_file; do
    
    rel_path_from_root="${md_file#$TARGET_DIR/}"
    rel_path_no_ext="${rel_path_from_root%.md}"
    ATTACH_DIR="$TARGET_DIR/attachments/$rel_path_no_ext"
    
    modified=0
    temp_file="${md_file}.tmp"
    : > "$temp_file"

    while IFS= read -r line || [ -n "$line" ]; do
        
        # ค้นหา Link ที่เป็น Video ของ Confluence เท่านั้น
        matches=$(echo "$line" | grep -oE '/wiki/download/attachments/[0-9]+/[^)]+\.(mp4|mov)[^)]*' || true)

        if [ -n "$matches" ]; then
            echo "   🎥 Processing Line in: $md_file"
            
            # ใช้ตัวแปรนี้เก็บค่าบรรทัดที่กำลังแก้ (แก้ซ้ำๆ จนกว่าจะครบทุก link ในบรรทัด)
            current_line_content="$line"

            while IFS= read -r full_url_path; do
                [ -z "$full_url_path" ] && continue

                # 1. Extract Info
                page_id=$(echo "$full_url_path" | cut -d'/' -f5)
                raw_filename_param=$(echo "$full_url_path" | cut -d'/' -f6)
                raw_filename=$(echo "$raw_filename_param" | cut -d'?' -f1)
                filename=$(urldecode "$raw_filename")
                
                # 2. Download
                mkdir -p "$ATTACH_DIR"
                local_video_path="$ATTACH_DIR/$filename"
                
                if [ ! -f "$local_video_path" ]; then
                    api_url="https://${CONF_DOMAIN}/wiki/rest/api/content/${page_id}/child/attachment?filename=${raw_filename}&expand=history.lastUpdated"
                    json_resp=$(curl -s -u "${CONF_EMAIL}:${CONF_TOKEN}" "$api_url")
                    download_path=$(echo "$json_resp" | jq -r '.results[0]._links.download // empty')
                    
                    if [ -n "$download_path" ]; then
                        curl -s -L -u "${CONF_EMAIL}:${CONF_TOKEN}" "https://${CONF_DOMAIN}/wiki${download_path}" -o "$local_video_path"
                    else
                        echo "      ❌ Error: Video URL not found for $filename"
                        continue
                    fi
                fi
                
                # 3. Dimensions
                dimensions=$(get_video_dimensions "$local_video_path")
                if [ -n "$dimensions" ]; then
                    new_label="$filename $dimensions"
                else
                    new_label="$filename"
                fi

                # 4. Path Calculation
                abs_md_file=$(cd "$(dirname "$md_file")" && pwd)/$(basename "$md_file")
                abs_video_path=$(cd "$(dirname "$local_video_path")" && pwd)/$(basename "$local_video_path")
                rel_link=$(get_relative_path "$abs_md_file" "$abs_video_path")
                rel_link_encoded=$(echo "$rel_link" | sed 's/ /%20/g; s/(/%28/g; s/)/%29/g')

                # 5. STRICT REPLACEMENT
                export URL_OLD="$full_url_path"
                export PATH_NEW="$rel_link_encoded"
                export LABEL_NEW="$new_label"
                
                # Regex สำคัญที่แก้:
                # \[           -> วงเล็บเปิด
                # [^]]*?       -> Match อะไรก็ได้ข้างใน *ยกเว้น* วงเล็บปิด (ป้องกันการกินรวบ)
                # \]           -> วงเล็บปิด
                # \(           -> วงเล็บเปิด URL
                # \Q...\E      -> URL เดิมเป๊ะๆ
                # \)           -> วงเล็บปิด URL
                
                current_line_content=$(echo "$current_line_content" | perl -pe 's/\[[^]]*?\]\(\Q$ENV{URL_OLD}\E\)/[$ENV{LABEL_NEW}]($ENV{PATH_NEW})/g')
                
                modified=1

            done <<< "$matches"
            
            # เขียนบรรทัดที่แก้เสร็จแล้ว (รูปอื่นยังอยู่ครบ) ลงไฟล์
            echo "$current_line_content" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi

    done < "$md_file"

    if [ "$modified" -eq 1 ]; then
        mv "$temp_file" "$md_file"
        echo "      ✅ Updated: $md_file"
    else
        rm "$temp_file"
    fi

done

echo "🎉 Done! Images preserved, Videos fixed."