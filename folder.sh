#!/usr/bin/env bash
set -euo pipefail

# --- FIXED PATHS ---
SRC="output"
DES="src"

# --- RESET DESTINATION ---
if [ -d "$DES" ]; then
    echo "Cleaning old destination: $DES"
    rm -rf "$DES"
fi

# สร้าง folder p1, p2, p3, p4
mkdir -p "$DES/p1" "$DES/p2" "$DES/p3" "$DES/p4"

# --- DEFINE GROUPS ---

GROUP1=(
"Browser Problem (Bug)"
"Data Engineer"
"Deploy Process"
"E-CRM ข้อมมูลลูกค้า"
"Express Informations"
"Investigate"
"Issue"
"Line Message APIs"
"Members"
"Meta"
"Mobile MyOrder (MODM)"
"MOD Release"
)

# DevOps ที่จะไป p2
GROUP2_DEVOPS=(
"5090"
"Ai-agentic"
"ArgoCD"
"Cloudflare"
"CloudSQL"
"Crossplane"
"env with vault"
"Envoy"
"firebase"
)

# กลุ่มหลัก p2
GROUP2=(
"Mongo"
"My Express"
"My Order Web"
"MyAI"
"Order Status Update"
"Payment Gateway"
"Product (คลังสินค้า)"
"Red"
"Release Note"
"Shopee"
"Tester"
"Training"
"Work Around"
)

# DevOps ที่จะไป p3
GROUP3_DEVOPS=(
"GCloud"
"Grafana"
"Helm-chart"
"Incident report"
"k8s"
"Kong"
"library"

# ใส่ชื่อ Folder ใน DevOps ที่ต้องการให้ไป p3 ที่นี่
)

# helper: membership check
in_group() {
    local val="$1"
    shift
    for v in "$@"; do
        if [ "$v" = "$val" ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------
#  COPY Markdown files (.md)
# ---------------------------
declare -A MD_P1_TOPS  # สำหรับ md ไม่มี folder

while IFS= read -r -d '' md; do
    rel="${md#$SRC/}"
    if [[ "$rel" == */* ]]; then
        top="${rel%%/*}"
    else
        top=""
    fi

    # Determine destination
    dest=""
    if in_group "$top" "${GROUP1[@]}" || [[ "$rel" != */* ]]; then
        dest="p1"
        # ถ้าไฟล์ md ไม่มี folder ให้บันทึกชื่อ top สำหรับ attachments
        if [[ "$rel" != */* ]]; then
            MD_P1_TOPS["${rel%.md}"]=1
        fi
    elif in_group "$top" "${GROUP2[@]}"; then
        dest="p2"
    elif [[ "$top" == "DevOps" ]]; then
        # Logic สำหรับ DevOps แยก 3 ทาง (p2, p3, p4)
        sub="$(echo "$rel" | cut -d/ -f2)"
        
        if in_group "$sub" "${GROUP2_DEVOPS[@]}"; then
            dest="p2"
        elif in_group "$sub" "${GROUP3_DEVOPS[@]}"; then
            dest="p3"
        else
            dest="p4" # ที่เหลือของ DevOps ไป p4
        fi
    else
        # ที่เหลือที่ไม่ใช่ DevOps และไม่อยู่ใน Group 1 หรือ 2 ให้ลง p2 (ตาม Logic เดิม)
        dest="p2"
    fi

    target_dir="$(dirname "$DES/$dest/$rel")"
    mkdir -p "$target_dir"
    cp "$md" "$DES/$dest/$rel"
    printf "Copied MD: %s -> %s\n" "$md" "$DES/$dest/$rel"
done < <(find "$SRC" -type f -name "*.md" -print0)

# ---------------------------
#  COPY ATTACHMENTS (preserve folder)
# ---------------------------
attachments_root="$SRC/attachments"
if [ -d "$attachments_root" ]; then
    while IFS= read -r -d '' img; do
        rel="${img#$attachments_root/}"   # path under attachments
        top="${rel%%/*}"

        dest=""
        if [[ -n "${MD_P1_TOPS[$top]:-}" ]]; then
            dest="p1"
        elif in_group "$top" "${GROUP1[@]}"; then
            dest="p1"
        elif in_group "$top" "${GROUP2[@]}"; then
            dest="p2"
        elif [[ "$top" == "DevOps" ]]; then
            # Logic DevOps สำหรับรูปภาพ (ต้องเหมือน MD)
            sub="$(echo "$rel" | cut -d/ -f2)"
            
            if in_group "$sub" "${GROUP2_DEVOPS[@]}"; then
                dest="p2"
            elif in_group "$sub" "${GROUP3_DEVOPS[@]}"; then
                dest="p3"
            else
                dest="p4"
            fi
        else
            dest="p2"
        fi

        dest_path="$DES/$dest/attachments/$rel"
        mkdir -p "$(dirname "$dest_path")"
        cp "$img" "$dest_path"
        printf "Copied IMG: %s -> %s\n" "$img" "$dest_path"
    done < <(find "$attachments_root" -type f -print0)
else
    echo "No attachments folder at: $attachments_root (skipping attachments copy)"
fi

echo "✅ Copy complete. Output base: $DES"