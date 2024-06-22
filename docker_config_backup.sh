#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# User-configurable variables
BACKUP_DIR=""                  # Directory where backups will be stored
CONFIG_DIR=""                  # Directory containing configuration files to be backed up
DOCKER_COMPOSE_FILE=""         # Path to the docker-compose.yml file
TELEGRAM_TOKEN=""              # Telegram Bot API token
TELEGRAM_CHAT_ID=""            # Telegram Chat ID to send messages to
MAX_SIZE_GB=6                  # Maximum allowed backup size in GB
UPLOAD_SPEED_MBPS=125          # Upload speed in Mbps (default is 1 Gbps = 125 MB/s)

# Script variables (do not modify)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="docker_config_backup_${TIMESTAMP}.tar.gz"
SIMULATE=false

# Check for --sim flag to run in simulation mode
if [[ "$1" == "--sim" ]]; then
    SIMULATE=true
fi

# Function to send Telegram message
send_telegram_message() {
    local MESSAGE="$1"
    
    # Add simulation warning if in simulation mode
    if $SIMULATE; then
        MESSAGE="⚠️ <b>[ SIMULATION ]</b> ⚠️

${MESSAGE}"
    fi
    
    echo "Original message:"
    echo "$MESSAGE"
    echo "Message length: ${#MESSAGE} characters"
    
    # Split message if it's too long (Telegram limit is 4096 characters)
    if [ ${#MESSAGE} -gt 4000 ]; then
        echo "Message is too long, splitting..."
        local PARTS=()
        while [ ${#MESSAGE} -gt 0 ]; do
            PARTS+=("${MESSAGE:0:4000}")
            MESSAGE="${MESSAGE:4000}"
        done
        
        # Send each part of the split message
        for PART in "${PARTS[@]}"; do
            local ESCAPED_MESSAGE=$(echo -n "$PART" | jq -sRr @uri)
            echo "Sending part (${#PART} characters):"
            echo "$PART"
            
            # Send message to Telegram
            local RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                -d chat_id="${TELEGRAM_CHAT_ID}" \
                -d text="${ESCAPED_MESSAGE}" \
                -d parse_mode="HTML")
            
            echo "Telegram API Response:"
            echo "$RESPONSE"
            
            # Check if message was sent successfully
            if [[ $(echo "$RESPONSE" | jq -r '.ok') != "true" ]]; then
                echo "Error sending Telegram message: $(echo "$RESPONSE" | jq -r '.description')"
            else
                echo "Message part sent successfully"
            fi
            
            sleep 1  # Wait a bit between messages to avoid rate limiting
        done
    else
        # Send the entire message if it's not too long
        local ESCAPED_MESSAGE=$(echo -n "$MESSAGE" | jq -sRr @uri)
        echo "Sending message (${#MESSAGE} characters):"
        echo "$MESSAGE"
        
        # Send message to Telegram
        local RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${ESCAPED_MESSAGE}" \
            -d parse_mode="HTML")
        
        echo "Telegram API Response:"
        echo "$RESPONSE"
        
        # Check if message was sent successfully
        if [[ $(echo "$RESPONSE" | jq -r '.ok') != "true" ]]; then
            echo "Error sending Telegram message: $(echo "$RESPONSE" | jq -r '.description')"
        else
            echo "Message sent successfully"
        fi
    fi
}

# Function to get directory sizes and total size
get_directory_sizes() {
    local dir_list=""
    local total_size=0
    
    # Iterate through all directories in the CONFIG_DIR
    for dir in "$CONFIG_DIR"/*; do
        if [ -d "$dir" ]; then
            # Calculate size of each directory
            size=$(du -sk "$dir" | cut -f1)
            human_size=$(numfmt --from-unit=1K --to=iec --format="%.1f" $size)
            dir_name=$(basename "$dir")
            dir_list="${dir_list}📁 ${dir_name}: <code>${human_size}</code>
"
            total_size=$((total_size + size))
        fi
    done
    
    # Add docker-compose file size
    compose_size=$(du -sk "$DOCKER_COMPOSE_FILE" | cut -f1)
    total_size=$((total_size + compose_size))
    total_human_size=$(numfmt --from-unit=1K --to=iec --format="%.1f" $total_size)
    
    # Calculate estimated transfer time
    transfer_time_seconds=$(echo "scale=2; ($total_size * 1024) / ($UPLOAD_SPEED_MBPS * 1000000)" | bc)
    transfer_time_seconds=$(echo "$transfer_time_seconds" | awk '{print ($0-int($0)<0.5)?int($0):int($0)+1}')
    if (( transfer_time_seconds < 1 )); then
        transfer_time="1 second"
    elif (( transfer_time_seconds < 60 )); then
        transfer_time="${transfer_time_seconds} seconds"
    else
        transfer_time="$(echo "scale=1; $transfer_time_seconds / 60" | bc) minutes"
    fi
    
    # Return the formatted directory list and total size
    echo "${dir_list}
<b>📊 Total Size:</b> <code>${total_human_size}</code>
<b>⏱ Estimated Transfer Time:</b> <code>${transfer_time}</code>"
}

# Main script execution
echo "Starting backup script..."

# Get directory sizes and total size
echo "Calculating directory sizes..."
DIR_SIZES=$(get_directory_sizes)
TOTAL_SIZE=$(echo "$DIR_SIZES" | grep "Total Size:" | sed -E 's/.*<code>(.*)<\/code>.*/\1/')

echo "Total size: $TOTAL_SIZE"

# Check if total size exceeds the limit
if (( $(echo "$(echo $TOTAL_SIZE | sed 's/[^0-9.]//g') > $MAX_SIZE_GB" | bc -l) )); then
    WARNING_MESSAGE="⚠️ Warning: Backup size (<code>${TOTAL_SIZE}</code>) exceeds <code>${MAX_SIZE_GB} GB</code> limit.

Backup operation cancelled."
    send_telegram_message "$WARNING_MESSAGE"
    exit 1
fi

if $SIMULATE; then
    echo "Running in simulation mode..."
    SUCCESS_MESSAGE="✅ Backup simulation completed successfully!

<b>📄 Filename:</b> <code>${BACKUP_FILE}</code>
<b>📊 Simulated Size:</b> <code>${TOTAL_SIZE}</code>
<b>🕒 Date:</b> <code>$(TZ='America/Los_Angeles' date '+%Y-%m-%d %I:%M:%S %p PST')</code>

<b>Directories to be backed up:</b>
${DIR_SIZES}"
    send_telegram_message "$SUCCESS_MESSAGE"
else
    echo "Creating backup..."
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # Create tar.gz archive of config directory and docker-compose file
    tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")" "$DOCKER_COMPOSE_FILE"

    # Check if backup was successful
    if [ $? -eq 0 ]; then
        BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
        SUCCESS_MESSAGE="✅ Backup completed successfully!

<b>📄 Filename:</b> <code>${BACKUP_FILE}</code>
<b>📊 Size:</b> <code>${BACKUP_SIZE}</code>
<b>🕒 Date:</b> <code>$(TZ='America/Los_Angeles' date '+%Y-%m-%d %I:%M:%S %p PST')</code>

<b>Backed up directories:</b>
${DIR_SIZES}"
        send_telegram_message "$SUCCESS_MESSAGE"
    else
        FAIL_MESSAGE="❌ Backup failed. Please check the logs."
        send_telegram_message "$FAIL_MESSAGE"
    fi
fi

echo "Backup script completed."
