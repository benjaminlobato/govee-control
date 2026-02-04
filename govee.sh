#!/bin/bash
# Govee Light Control Script
# Controls Govee lights via LAN API (requires LAN mode enabled in Govee app)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.json"
POWERSHELL="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: govee <command> [device] [options]"
    echo ""
    echo "Commands:"
    echo "  list                    List all configured devices"
    echo "  scan                    Scan network for Govee devices"
    echo "  on <device>             Turn device on"
    echo "  off <device>            Turn device off"
    echo "  color <device> <color>  Set color (hex like ff0000, or name: red/green/blue/white/warm/cool)"
    echo "  brightness <device> <0-100>  Set brightness"
    echo ""
    echo "Device can be specified by name (partial match) or IP address"
    echo ""
    echo "Examples:"
    echo "  govee list"
    echo "  govee on monitor"
    echo "  govee off \"living room\""
    echo "  govee color monitor ff5500"
    echo "  govee color tv blue"
    echo "  govee brightness monitor 50"
}

get_device_ip() {
    local search="$1"
    local ip=$(jq -r --arg s "$search" '.devices[] | select(.name | ascii_downcase | contains($s | ascii_downcase)) | .ip' "$DEVICES_FILE" 2>/dev/null | head -1)

    if [[ -z "$ip" ]]; then
        # Try matching by IP directly
        ip=$(jq -r --arg s "$search" '.devices[] | select(.ip == $s) | .ip' "$DEVICES_FILE" 2>/dev/null | head -1)
    fi

    echo "$ip"
}

get_device_name() {
    local ip="$1"
    jq -r --arg ip "$ip" '.devices[] | select(.ip == $ip) | .name' "$DEVICES_FILE" 2>/dev/null
}

send_command() {
    local ip="$1"
    local port="$2"
    local cmd="$3"

    $POWERSHELL -Command "
        \$udp = New-Object System.Net.Sockets.UdpClient
        \$endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('$ip'), $port)
        \$bytes = [System.Text.Encoding]::UTF8.GetBytes('$cmd')
        \$udp.Send(\$bytes, \$bytes.Length, \$endpoint) | Out-Null
        \$udp.Close()
    " 2>/dev/null
}

cmd_list() {
    echo -e "${BLUE}Configured Govee Devices:${NC}"
    echo ""
    jq -r '.devices[] | "  \(.name)\n    IP: \(.ip)  Model: \(.model)"' "$DEVICES_FILE"
}

cmd_scan() {
    echo -e "${BLUE}Scanning for Govee devices...${NC}"
    $POWERSHELL -Command '
        $udpClient = New-Object System.Net.Sockets.UdpClient(4002)
        $udpClient.EnableBroadcast = $true
        $udpClient.Client.ReceiveTimeout = 3000

        $msg = "{\"msg\":{\"cmd\":\"scan\",\"data\":{\"account_topic\":\"reserve\"}}}"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse("255.255.255.255"), 4001)
        $udpClient.Send($bytes, $bytes.Length, $endpoint) | Out-Null

        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        while ($true) {
            try {
                $data = $udpClient.Receive([ref]$remote)
                $text = [System.Text.Encoding]::UTF8.GetString($data)
                $json = $text | ConvertFrom-Json
                Write-Host "Found: $($json.msg.data.ip) - $($json.msg.data.sku) ($($json.msg.data.device))"
            } catch { break }
        }
        $udpClient.Close()
    ' 2>/dev/null
}

cmd_on() {
    local device="$1"
    local ip=$(get_device_ip "$device")

    if [[ -z "$ip" ]]; then
        echo -e "${RED}Device not found: $device${NC}"
        exit 1
    fi

    local name=$(get_device_name "$ip")
    local cmd='{"msg":{"cmd":"turn","data":{"value":1}}}'
    send_command "$ip" 4003 "$cmd"
    echo -e "${GREEN}✓${NC} Turned on: $name ($ip)"
}

cmd_off() {
    local device="$1"
    local ip=$(get_device_ip "$device")

    if [[ -z "$ip" ]]; then
        echo -e "${RED}Device not found: $device${NC}"
        exit 1
    fi

    local name=$(get_device_name "$ip")
    local cmd='{"msg":{"cmd":"turn","data":{"value":0}}}'
    send_command "$ip" 4003 "$cmd"
    echo -e "${GREEN}✓${NC} Turned off: $name ($ip)"
}

cmd_color() {
    local device="$1"
    local color="$2"
    local ip=$(get_device_ip "$device")

    if [[ -z "$ip" ]]; then
        echo -e "${RED}Device not found: $device${NC}"
        exit 1
    fi

    # Convert color names to hex
    case "${color,,}" in
        red)    color="ff0000" ;;
        green)  color="00ff00" ;;
        blue)   color="0000ff" ;;
        white)  color="ffffff" ;;
        warm)   color="ff7722" ;;
        cool)   color="aaccff" ;;
        purple) color="aa00ff" ;;
        orange) color="ff5500" ;;
        yellow) color="ffff00" ;;
        cyan)   color="00ffff" ;;
        pink)   color="ff55aa" ;;
    esac

    # Remove # if present
    color="${color#\#}"

    # Parse hex to RGB
    local r=$((16#${color:0:2}))
    local g=$((16#${color:2:2}))
    local b=$((16#${color:4:2}))

    local name=$(get_device_name "$ip")
    local cmd="{\"msg\":{\"cmd\":\"colorwc\",\"data\":{\"color\":{\"r\":$r,\"g\":$g,\"b\":$b},\"colorTemInKelvin\":0}}}"
    send_command "$ip" 4003 "$cmd"
    echo -e "${GREEN}✓${NC} Set color on $name to #$color (RGB: $r,$g,$b)"
}

cmd_brightness() {
    local device="$1"
    local level="$2"
    local ip=$(get_device_ip "$device")

    if [[ -z "$ip" ]]; then
        echo -e "${RED}Device not found: $device${NC}"
        exit 1
    fi

    if [[ ! "$level" =~ ^[0-9]+$ ]] || [[ "$level" -lt 0 ]] || [[ "$level" -gt 100 ]]; then
        echo -e "${RED}Brightness must be 0-100${NC}"
        exit 1
    fi

    local name=$(get_device_name "$ip")
    local cmd="{\"msg\":{\"cmd\":\"brightness\",\"data\":{\"value\":$level}}}"
    send_command "$ip" 4003 "$cmd"
    echo -e "${GREEN}✓${NC} Set brightness on $name to $level%"
}

# Main
case "$1" in
    list)       cmd_list ;;
    scan)       cmd_scan ;;
    on)         cmd_on "$2" ;;
    off)        cmd_off "$2" ;;
    color)      cmd_color "$2" "$3" ;;
    brightness) cmd_brightness "$2" "$3" ;;
    -h|--help|help|"")  usage ;;
    *)          echo -e "${RED}Unknown command: $1${NC}"; usage; exit 1 ;;
esac
