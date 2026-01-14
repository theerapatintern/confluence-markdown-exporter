#!/usr/bin/env bash
set -euo pipefail

# ----------------- CONFIGURATION -----------------
# Step 1: โหลดตัวแปรจากไฟล์ .env 
ENV_FILE="workspace/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env required!"
    exit 1
fi

# ถ้าใน .env ไม่ได้ระบุ OUTPUT_FOLDER จะใช้ค่า default เป็น "output"
TARGET_DIR="${OUTPUT_FOLDER:-output}"
CONF_DOMAIN=$(echo "$CONFLUENCE_URL" | awk -F/ '{print $3}')
CONF_EMAIL="$CONFLUENCE_EMAIL"
CONF_TOKEN="$CONFLUENCE_API_TOKEN"

# Step 2: ตรวจสภาพความพร้อมของเครื่องมือ 
if ! command -v jq &> /dev/null; then 
    echo "❌ Error: jq required (ติดตั้งด้วย brew install jq )"
    exit 1
fi

# เช็ค ffprobe (ส่วนหนึ่งของ ffmpeg) เอาไว้ดูขนาดวิดีโอ (กว้างxสูง)
HAS_FFPROBE=0
if command -v ffprobe &> /dev/null; then HAS_FFPROBE=1; fi

# Step 3: Cleanup
# ลบไฟล์วิดีโอเก่าที่อาจจะเคยโหลดมาผิดๆ หรือค้างอยู่ในโฟลเดอร์ทิ้งไปก่อน
if [ -d "$TARGET_DIR" ]; then
    echo "🧹 Clean up old existing video (.mp4, .mov) in '$TARGET_DIR'..."
    find "$TARGET_DIR" -type f \( -name "*.mp4" -o -name "*.mov" \) -delete
fi

# Helper Functions
# ถอดรหัส URL (เช่น %20 เป็น ช่องว่าง)
urldecode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

# คำนวณหา Path แบบ Relative (จากไฟล์ Markdown วิ่งไปหาไฟล์วิดีโอ)
get_relative_path() {
    local source="$1"
    local target="$2"
    local source_dir
    source_dir=$(dirname "$source")
    python3 -c "import sys, os.path; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$target" "$source_dir"
}

# หาขนาดวิดีโอ (Width x Height) เพื่อเอาไปแปะใน Markdown
get_video_dimensions() {
    local file_path="$1"
    if [ "$HAS_FFPROBE" -eq 1 ]; then
        ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$file_path"
    else
        echo ""
    fi
}

# Step 4: Loop ไฟล์ Markdown ทุกไฟล์
echo "🚀 Starting Video Downloader & Link Fixer (Strict Mode)..."
echo "📂 Target Directory: $TARGET_DIR"
echo "🌐 Target Domain: $CONF_DOMAIN"

find "$TARGET_DIR" -type f -name "*.md" | while read -r md_file; do
    
    # คำนวณ Path สำหรับเก็บไฟล์แนบ (Attachments) ของไฟล์นั้นๆ
    rel_path_from_root="${md_file#$TARGET_DIR/}"
    rel_path_no_ext="${rel_path_from_root%.md}"
    ATTACH_DIR="$TARGET_DIR/attachments/$rel_path_no_ext"
    
    modified=0
    temp_file="${md_file}.tmp"
    : > "$temp_file" # สร้างไฟล์ชั่วคราวว่างๆ รอไว้

    # อ่านไฟล์ทีละบรรทัด
    while IFS= read -r line || [ -n "$line" ]; do
        
        # Step 5: สแกนหา Link วิดีโอของ Confluence ในบรรทัดนี้
        # Pattern: /wiki/download/attachments/xxxx/name.mp4
        matches=$(echo "$line" | grep -oE '/wiki/download/attachments/[0-9]+/[^)]+\.(mp4|mov)[^)]*' || true)

        if [ -n "$matches" ]; then
            echo "   🎥 Found video in: $md_file"
            
            # เก็บเนื้อหาบรรทัดเดิมไว้ก่อน เดี๋ยวเราจะค่อยๆ แก้ Link ทีละตัวในบรรทัดนี้
            current_line_content="$line"

            # วน Loop ตามจำนวน Link ที่เจอในบรรทัดเดียว
            while IFS= read -r full_url_path; do
                [ -z "$full_url_path" ] && continue

                # Step 6: แกะข้อมูล Page ID และชื่อไฟล์จาก URL
                page_id=$(echo "$full_url_path" | cut -d'/' -f5)
                raw_filename_param=$(echo "$full_url_path" | cut -d'/' -f6)
                raw_filename=$(echo "$raw_filename_param" | cut -d'?' -f1)
                filename=$(urldecode "$raw_filename")
                
                # Step 7: ดาวน์โหลดไฟล์ (ถ้ายังไม่มี)
                mkdir -p "$ATTACH_DIR"
                local_video_path="$ATTACH_DIR/$filename"
                
                if [ ! -f "$local_video_path" ]; then
                    api_url="https://${CONF_DOMAIN}/wiki/rest/api/content/${page_id}/child/attachment?filename=${raw_filename}&expand=history.lastUpdated"
                    json_resp=$(curl -s -u "${CONF_EMAIL}:${CONF_TOKEN}" "$api_url")
                    
                    # แกะ Link จาก JSON
                    download_path=$(echo "$json_resp" | jq -r '.results[0]._links.download // empty')
                    
                    if [ -n "$download_path" ]; then
                        # โหลดไฟล์ของจริงมาเก็บลงเครื่อง
                        curl -s -L -u "${CONF_EMAIL}:${CONF_TOKEN}" "https://${CONF_DOMAIN}/wiki${download_path}" -o "$local_video_path"
                    else
                        echo "      ❌ Error: หา URL ดาวน์โหลดไม่เจอสำหรับ $filename (ข้ามไปก่อน)"
                        continue
                    fi
                fi
                
                # Step 8: เตรียมข้อมูลใหม่ (Path & Label)
                # หาขนาดวิดีโอ
                dimensions=$(get_video_dimensions "$local_video_path")
                if [ -n "$dimensions" ]; then
                    new_label="$filename $dimensions"
                else
                    new_label="$filename"
                fi

                # คำนวณ Relative Path และ Encode URL (เช่น ช่องว่าง -> %20)
                abs_md_file=$(cd "$(dirname "$md_file")" && pwd)/$(basename "$md_file")
                abs_video_path=$(cd "$(dirname "$local_video_path")" && pwd)/$(basename "$local_video_path")
                rel_link=$(get_relative_path "$abs_md_file" "$abs_video_path")
                rel_link_encoded=$(echo "$rel_link" | sed 's/ /%20/g; s/(/%28/g; s/)/%29/g')

                # Step 9: แทนที่ Link
                export URL_OLD="$full_url_path"
                export PATH_NEW="$rel_link_encoded"
                export LABEL_NEW="$new_label"
                
                # Regex logic:
                # หา [...](\URL_OLD)
                # โดย [...] ต้องไม่มี ] อยู่ข้างใน 
                # แล้วแทนที่ด้วย [LABEL_NEW](PATH_NEW)
                current_line_content=$(echo "$current_line_content" | perl -pe 's/\[[^]]*?\]\(\Q$ENV{URL_OLD}\E\)/[$ENV{LABEL_NEW}]($ENV{PATH_NEW})/g')
                
                modified=1

            done <<< "$matches"
            
            # บันทึกบรรทัดที่แก้เสร็จแล้วลงไฟล์ temp
            echo "$current_line_content" >> "$temp_file"
        else
            # ถ้าไม่มีวิดีโอ ก็ก๊อปบรรทัดเดิมลงไปเลย
            echo "$line" >> "$temp_file"
        fi

    done < "$md_file"

    # Step 10: ถ้ามีการแก้ไขให้เซฟทับไฟล์จริง
    if [ "$modified" -eq 1 ]; then
        mv "$temp_file" "$md_file"
        echo "      ✅ Updated: $md_file"
    else
        rm "$temp_file"
    fi

done

echo "🎉 Done! Images preserved, Videos fixed."