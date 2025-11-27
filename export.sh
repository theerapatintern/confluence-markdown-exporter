#!/bin/bash

# ไฟล์ list page IDs
FILE="url_list.txt"

if [ ! -f "$FILE" ]; then
    echo "File $FILE not found!"
    exit 1
fi

while IFS= read -r page_id || [ -n "$page_id" ]; do
    page_id=$(echo "$page_id" | xargs)  # trim whitespace
    if [ -n "$page_id" ]; then
        echo "Exporting page $page_id..."
        cf-export pages-with-descendants "$page_id"
        if [ $? -ne 0 ]; then
            echo "Error exporting page $page_id"
        fi
    fi
done < "$FILE"
