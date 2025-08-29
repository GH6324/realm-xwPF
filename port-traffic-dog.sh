#!/bin/bash

set -euo pipefail

# 全局变量
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="端口流量犬"
readonly SCRIPT_PATH="$(realpath "$0")"
readonly CONFIG_DIR="/etc/port-traffic-dog"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly DATA_DIR="$CONFIG_DIR/data"
readonly SNAPSHOT_DIR="$DATA_DIR/snapshots"
readonly LOG_FILE="$CONFIG_DIR/logs/traffic.log"

# 颜色定义
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# 下载源配置
readonly DOWNLOAD_SOURCES=(
    ""
    "https://ghfast.top/"
    "https://gh.222322.xyz/"
    "https://ghproxy.gpnu.org/"
)

# 超时配置
readonly SHORT_CONNECT_TIMEOUT=5
readonly SHORT_MAX_TIMEOUT=7
readonly SCRIPT_URL="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh"
readonly SHORTCUT_COMMAND="dog"

# 检测系统类型
detect_system() {
    # 优先检测Ubuntu
    if [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release 2>/dev/null; then
        echo "ubuntu"
        return
    fi

    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi

    echo "unknown"
}

# 自动安装依赖工具
install_missing_tools() {
    local missing_tools=("$@")
    local system_type=$(detect_system)

    echo -e "${YELLOW}检测到缺少工具: ${missing_tools[*]}${NC}"
    echo "正在自动安装..."

    case $system_type in
        "ubuntu")
            apt update -qq
            for tool in "${missing_tools[@]}"; do
                case $tool in
                    "nft") apt install -y nftables ;;
                    "tc") apt install -y iproute2 ;;
                    "ss") apt install -y iproute2 ;;
                    "jq") apt install -y jq ;;
                    "awk") apt install -y gawk ;;
                    "bc") apt install -y bc ;;
                    *) apt install -y "$tool" ;;
                esac
            done
            ;;
        "debian")
            apt-get update -qq
            for tool in "${missing_tools[@]}"; do
                case $tool in
                    "nft") apt-get install -y nftables ;;
                    "tc") apt-get install -y iproute2 ;;
                    "ss") apt-get install -y iproute2 ;;
                    "jq") apt-get install -y jq ;;
                    "awk") apt-get install -y gawk ;;
                    "bc") apt-get install -y bc ;;
                    *) apt-get install -y "$tool" ;;
                esac
            done
            ;;
        *)
            echo -e "${RED}不支持的系统类型: $system_type${NC}"
            echo "支持的系统: Ubuntu, Debian"
            echo "请手动安装: ${missing_tools[*]}"
            exit 1
            ;;
    esac

    echo -e "${GREEN}依赖工具安装完成${NC}"
}

# 检查依赖工具
check_dependencies() {
    local silent_mode=${1:-false}
    local missing_tools=()
    local required_tools=("nft" "tc" "ss" "jq" "awk" "bc" "unzip")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        install_missing_tools "${missing_tools[@]}"

        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                still_missing+=("$tool")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            echo -e "${RED}安装失败，仍缺少工具: ${still_missing[*]}${NC}"
            echo "请手动安装后重试"
            exit 1
        fi
    fi

    if [ "$silent_mode" != "true" ]; then
        echo -e "${GREEN}依赖检查通过${NC}"
    fi

    # 确保脚本有执行权限
    setup_script_permissions
    # 确保cron环境PATH正确
    setup_cron_environment
    # 设置端口自动重置任务
    local active_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${active_ports[@]}"; do
        setup_port_auto_reset_cron "$port" >/dev/null 2>&1 || true
    done
}

# 设置脚本权限
setup_script_permissions() {
    # 设置脚本执行权限
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi

    # 设置系统脚本权限
    if [ -f "/usr/local/bin/port-traffic-dog.sh" ]; then
        chmod +x "/usr/local/bin/port-traffic-dog.sh" 2>/dev/null || true
    fi
}

# 设置cron环境
setup_cron_environment() {
    # 检查cron PATH设置
    local current_cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$current_cron" | grep -q "^PATH=.*sbin"; then
        # 添加PATH设置
        local temp_cron=$(mktemp)
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > "$temp_cron"
        echo "$current_cron" | grep -v "^PATH=" >> "$temp_cron" || true
        crontab "$temp_cron" 2>/dev/null || true
        rm -f "$temp_cron"
    fi
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限运行${NC}"
        exit 1
    fi
}

# 初始化配置
init_config() {
    # 创建配置目录
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$SNAPSHOT_DIR" "$(dirname "$LOG_FILE")"

    # 下载通知模块（静默下载，不影响主流程）
    download_notification_modules >/dev/null 2>&1 || true

    # 创建配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "global": {
    "billing_mode": "single",
    "data_retention_days": 30,
    "collection_interval": 60,
    "interface": "auto"
  },
  "ports": {},
  "nftables": {
    "table_name": "port_traffic_monitor",
    "family": "inet"
  },
  "notifications": {
    "telegram": {
      "enabled": false,
      "bot_token": "",
      "chat_id": "",
      "server_name": "",
      "api_timeout": 10,
      "retry_count": 3,
      "snapshot_notifications": {
        "enabled": false,
        "format": "detailed",
        "last_sent": null
      },
      "status_notifications": {
        "enabled": false,
        "interval": "1h",
        "last_sent": null
      }
    },
    "email": {
      "enabled": false,
      "status": "coming_soon"
    },
    "wechat": {
      "enabled": false,
      "status": "coming_soon"
    }
  }
}
EOF
    fi

    # 初始化nftables表
    init_nftables

    # 设置快照定时任务
    setup_snapshot_cron
}

# 初始化nftables表
init_nftables() {
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    
    # 创建表和链
    nft add table $family $table_name 2>/dev/null || true
    nft add chain $family $table_name input { type filter hook input priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name output { type filter hook output priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name forward { type filter hook forward priority 0\; } 2>/dev/null || true
}


# 创建流量快照
create_traffic_snapshot() {
    local period=$1
    local active_ports=($(get_active_ports))

    if [ ${#active_ports[@]} -eq 0 ]; then
        return
    fi

    # 生成时间标识
    local time_key
    case $period in
        "daily")
            time_key=$(get_beijing_time +%Y-%m-%d)
            ;;
        "weekly")
            # 获取本周一日期，确保时间键一致
            local monday_date=$(get_beijing_time -d 'monday' +%Y-%m-%d)
            time_key=$(get_beijing_time -d "$monday_date" +%Y-W%V)
            ;;
        "monthly")
            time_key=$(get_beijing_time +%Y-%m)
            ;;
        *)
            echo "错误：无效的时间段 $period"
            return 1
            ;;
    esac

    # 创建端口快照
    for port in "${active_ports[@]}"; do
        # 获取流量数据
        local traffic_data=($(get_port_traffic "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}

        # 创建分离的快照文件
        local snapshot_file="$SNAPSHOT_DIR/port_${port}_${period}_${time_key}.json"
        echo "{\"input\": $input_bytes, \"output\": $output_bytes, \"timestamp\": \"$(get_beijing_time -Iseconds)\"}" > "$snapshot_file"
    done

    # 记录日志
    echo "$(get_beijing_time '+%Y-%m-%d %H:%M:%S') - 创建 $period 快照: $time_key" >> "$LOG_FILE"
}

# 获取时间段流量
get_period_traffic() {
    local port=$1
    local period=$2

    # 获取当前流量数据
    local current_traffic=($(get_port_traffic "$port"))
    local current_input=${current_traffic[0]}
    local current_output=${current_traffic[1]}

    # 生成时间标识
    local time_key
    case $period in
        "daily")
            time_key=$(get_beijing_time +%Y-%m-%d)
            ;;
        "weekly")
            # 获取本周一日期
            local monday_date=$(get_beijing_time -d 'monday' +%Y-%m-%d)
            time_key=$(get_beijing_time -d "$monday_date" +%Y-W%V)
            ;;
        "monthly")
            time_key=$(get_beijing_time +%Y-%m)
            ;;
        *)
            echo "0 0"
            return
            ;;
    esac

    # 查找对应的快照文件
    local snapshot_file="$SNAPSHOT_DIR/port_${port}_${period}_${time_key}.json"

    # 如果快照文件不存在，返回0流量（等待定时任务创建正式快照）
    if [ ! -f "$snapshot_file" ]; then
        echo "0 0"
        return
    fi

    # 从快照文件读取基准值
    local baseline_input=$(jq -r '.input // null' "$snapshot_file" 2>/dev/null || echo "null")
    local baseline_output=$(jq -r '.output // null' "$snapshot_file" 2>/dev/null || echo "null")

    # 如果没有找到对应的快照，返回当前累计流量作为时间段流量
    if [ "$baseline_input" = "null" ] || [ "$baseline_input" = "" ]; then
        echo "$current_input $current_output"
        return
    fi
    if [ "$baseline_output" = "null" ] || [ "$baseline_output" = "" ]; then
        echo "$current_input $current_output"
        return
    fi

    # 确保基准值是数字
    if ! [[ "$baseline_input" =~ ^[0-9]+$ ]]; then
        baseline_input=0
    fi
    if ! [[ "$baseline_output" =~ ^[0-9]+$ ]]; then
        baseline_output=0
    fi

    # 计算时间段流量（当前值 - 基准值）
    local period_input=$((current_input - baseline_input))
    local period_output=$((current_output - baseline_output))

    # 确保不为负数（防止计数器重置等异常情况）
    if [ $period_input -lt 0 ]; then
        period_input=0
    fi
    if [ $period_output -lt 0 ]; then
        period_output=0
    fi

    echo "$period_input $period_output"
}

# 获取时间段流量（使用缓存的当前流量数据）
get_period_traffic_cached() {
    local port=$1
    local period=$2
    local current_input=$3
    local current_output=$4

    # 生成时间标识
    local time_key
    case $period in
        "daily")
            time_key=$(get_beijing_time +%Y-%m-%d)
            ;;
        "weekly")
            # 获取本周一日期
            local monday_date=$(get_beijing_time -d 'monday' +%Y-%m-%d)
            time_key=$(get_beijing_time -d "$monday_date" +%Y-W%V)
            ;;
        "monthly")
            time_key=$(get_beijing_time +%Y-%m)
            ;;
        *)
            echo "0 0"
            return
            ;;
    esac

    # 查找对应的快照文件
    local snapshot_file="$SNAPSHOT_DIR/port_${port}_${period}_${time_key}.json"

    # 如果快照文件不存在，返回0流量（等待定时任务创建正式快照）
    if [ ! -f "$snapshot_file" ]; then
        echo "0 0"
        return
    fi

    # 从快照文件读取基准值
    local baseline_input=$(jq -r '.input // null' "$snapshot_file" 2>/dev/null || echo "null")
    local baseline_output=$(jq -r '.output // null' "$snapshot_file" 2>/dev/null || echo "null")

    # 如果没有找到对应的快照，返回当前累计流量作为时间段流量
    if [ "$baseline_input" = "null" ] || [ "$baseline_input" = "" ]; then
        echo "$current_input $current_output"
        return
    fi
    if [ "$baseline_output" = "null" ] || [ "$baseline_output" = "" ]; then
        echo "$current_input $current_output"
        return
    fi

    # 确保基准值是数字
    if ! [[ "$baseline_input" =~ ^[0-9]+$ ]]; then
        baseline_input=0
    fi
    if ! [[ "$baseline_output" =~ ^[0-9]+$ ]]; then
        baseline_output=0
    fi

    # 计算时间段流量（当前值 - 基准值）
    local period_input=$((current_input - baseline_input))
    local period_output=$((current_output - baseline_output))

    # 防止负数（可能由于计数器重置等原因）
    if [ $period_input -lt 0 ]; then
        period_input=$current_input
    fi
    if [ $period_output -lt 0 ]; then
        period_output=$current_output
    fi

    echo "$period_input $period_output"
}

# 设置流量快照定时任务
setup_snapshot_cron() {
    local script_path="$SCRIPT_PATH"

    # 检查cron服务
    if ! systemctl is-active --quiet cron 2>/dev/null && ! systemctl is-active --quiet crond 2>/dev/null; then
        echo -e "${YELLOW}警告：cron服务未运行，无法设置定时任务${NC}"
        echo "请手动启动cron服务：systemctl start cron"
        return 1
    fi

    # 创建临时文件
    local temp_cron=$(mktemp)

    # 获取现有任务
    crontab -l 2>/dev/null | grep -v "# 端口流量犬快照任务" | grep -v "port-traffic-dog.*--create-snapshot" | grep -v "每日1点清理过期快照" > "$temp_cron" || true

    # 添加定时任务
    cat >> "$temp_cron" << EOF
# 端口流量犬快照任务
0 0 * * * $script_path --create-snapshot daily >/dev/null 2>&1  # 每日0点创建日快照
0 0 * * 1 $script_path --create-snapshot weekly >/dev/null 2>&1 # 每周一0点创建周快照
0 0 1 * * $script_path --create-snapshot monthly >/dev/null 2>&1 # 每月1日0点创建月快照
0 1 * * * /bin/bash -c "find /etc/port-traffic-dog/data/snapshots -name 'port_*_daily_*.json' -type f -mtime +30 -delete 2>/dev/null; find /etc/port-traffic-dog/data/snapshots -name 'port_*_weekly_*.json' -type f -mtime +84 -delete 2>/dev/null; find /etc/port-traffic-dog/data/snapshots -name 'port_*_monthly_*.json' -type f -mtime +180 -delete 2>/dev/null" # 每日1点清理过期快照
EOF

    # 安装任务
    crontab "$temp_cron"
    rm -f "$temp_cron"

    echo -e "${GREEN}定时任务设置成功${NC}"
    echo "已设置以下定时任务："
    echo "  - 每日0点创建日快照"
    echo "  - 每周一0点创建周快照"
    echo "  - 每月1日0点创建月快照"
    echo "  - 每日1点清理过期快照"
}

# 移除流量快照定时任务
remove_snapshot_cron() {
    # 创建临时文件
    local temp_cron=$(mktemp)

    # 获取当前用户的cron任务
    crontab -l 2>/dev/null | grep -v "# 端口流量犬快照任务" | grep -v "port-traffic-dog.*--create-snapshot" | grep -v "每日1点清理过期快照" > "$temp_cron" || true

    # 安装清理后的cron任务
    crontab "$temp_cron"
    rm -f "$temp_cron"

    echo -e "${GREEN}定时任务已移除${NC}"
}



# 获取所有可用网络接口
get_network_interfaces() {
    local interfaces=()

    # 获取所有UP状态的接口，排除回环
    while IFS= read -r interface; do
        if [[ "$interface" != "lo" ]] && [[ "$interface" != "" ]]; then
            interfaces+=("$interface")
        fi
    done < <(ip link show | grep "state UP" | awk -F': ' '{print $2}' | cut -d'@' -f1)

    printf '%s\n' "${interfaces[@]}"
}

# 获取默认网络接口
get_default_interface() {
    local default_interface=$(ip route | grep default | awk '{print $5}' | head -n1)

    if [ -n "$default_interface" ]; then
        echo "$default_interface"
        return
    fi

    local interfaces=($(get_network_interfaces))
    if [ ${#interfaces[@]} -gt 0 ]; then
        echo "${interfaces[0]}"
    else
        echo "eth0"
    fi
}

# 格式化字节数
format_bytes() {
    local bytes=$1

    # 确保输入是数字，如果不是则默认为0
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi

    if [ $bytes -ge 1073741824 ]; then  # >= 1GB
        local gb=$(echo "scale=2; $bytes / 1073741824" | bc)
        echo "${gb}GB"
    elif [ $bytes -ge 1048576 ]; then  # >= 1MB
        local mb=$(echo "scale=2; $bytes / 1048576" | bc)
        echo "${mb}MB"
    elif [ $bytes -ge 1024 ]; then     # >= 1KB
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

# 获取GMT+8时间
get_beijing_time() {
    TZ='Asia/Shanghai' date "$@"
}

# 统一配置文件更新
update_config() {
    local jq_expression="$1"
    jq "$jq_expression" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# 统一端口列表显示
show_port_list() {
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        return 1
    fi

    echo "当前监控的端口:"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). 端口 $port $status_label"
    done
    return 0
}

# 统一多选择输入处理
parse_multi_choice_input() {
    local input="$1"
    local max_choice="$2"
    local -n result_array=$3

    IFS=',' read -ra CHOICES <<< "$input"
    result_array=()

    for choice in "${CHOICES[@]}"; do
        choice=$(echo "$choice" | tr -d ' ')
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            result_array+=("$choice")
        else
            echo -e "${RED}无效选择: $choice${NC}"
        fi
    done
}

# 统一逗号分隔输入解析
parse_comma_separated_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra result_array <<< "$input"

    # 去除每个元素的空格
    for i in "${!result_array[@]}"; do
        result_array[$i]=$(echo "${result_array[$i]}" | tr -d ' ')
    done
}

# 统一数组扩展逻辑（单值扩展到多值）
expand_single_value_to_array() {
    local -n source_array=$1
    local target_size=$2

    if [ ${#source_array[@]} -eq 1 ]; then
        local single_value="${source_array[0]}"
        source_array=()
        for ((i=0; i<target_size; i++)); do
            source_array+=("$single_value")
        done
    fi
}


# 获取GMT+8当前月份和年份
get_beijing_month_year() {
    local current_day=$(TZ='Asia/Shanghai' date +%d | sed 's/^0//')
    local current_month=$(TZ='Asia/Shanghai' date +%m | sed 's/^0//')
    local current_year=$(TZ='Asia/Shanghai' date +%Y)
    echo "$current_day $current_month $current_year"
}


# 获取端口流量数据
get_port_traffic() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    # 获取入站流量：目标端口为指定端口的所有流量（TCP+UDP）
    local input_bytes=$(nft list counter $family $table_name "port_${port}_in" 2>/dev/null | \
        grep -o 'bytes [0-9]*' | awk '{print $2}')

    # 获取出站流量：源端口为指定端口的所有流量（TCP+UDP）
    local output_bytes=$(nft list counter $family $table_name "port_${port}_out" 2>/dev/null | \
        grep -o 'bytes [0-9]*' | awk '{print $2}')

    input_bytes=${input_bytes:-0}
    output_bytes=${output_bytes:-0}

    echo "$input_bytes $output_bytes"
}

# 计算总流量（根据计费模式）
calculate_total_traffic() {
    local input_bytes=$1
    local output_bytes=$2
    local billing_mode=${3:-"single"}
    case $billing_mode in
        "double")
            echo $((input_bytes + output_bytes))
            ;;
        "single")
            echo $output_bytes
            ;;
        *)
            echo $output_bytes
            ;;
    esac
}

# 获取端口状态标签
get_port_status_label() {
    local port=$1

    # 从配置文件读取端口配置
    local port_config=$(jq -r ".ports.\"$port\"" "$CONFIG_FILE" 2>/dev/null)

    local remark=$(echo "$port_config" | jq -r '.remark // ""')
    local billing_mode=$(echo "$port_config" | jq -r '.billing_mode // "single"')
    local limit_enabled=$(echo "$port_config" | jq -r '.bandwidth_limit.enabled // false')
    local rate_limit=$(echo "$port_config" | jq -r '.bandwidth_limit.rate // "unlimited"')
    local quota_enabled=$(echo "$port_config" | jq -r '.quota.enabled // true')
    local monthly_limit=$(echo "$port_config" | jq -r '.quota.monthly_limit // "unlimited"')
    local reset_day=$(echo "$port_config" | jq -r '.quota.reset_day // 1')

    # 构建状态标签数组（并行显示，按顺序排列）
    local status_tags=()

    # 1. 备注标签
    if [ -n "$remark" ] && [ "$remark" != "null" ] && [ "$remark" != "" ]; then
        status_tags+=("[备注:$remark]")
    fi

    # 2. 配额状态标签
    if [ "$quota_enabled" = "true" ]; then
        if [ "$monthly_limit" != "unlimited" ]; then
            local current_usage=$(get_port_monthly_usage "$port")
            local limit_bytes=$(parse_size_to_bytes "$monthly_limit")
            local usage_percent=$((current_usage * 100 / limit_bytes))

            local time_info=($(get_beijing_month_year))
            local current_day=${time_info[0]}
            local current_month=${time_info[1]}
            local current_year=${time_info[2]}
            local next_month=$current_month
            local next_year=$current_year

            if [ $current_day -ge $reset_day ]; then
                next_month=$((current_month + 1))
                if [ $next_month -gt 12 ]; then
                    next_month=1
                    next_year=$((current_year + 1))
                fi
            fi

            local quota_display="$monthly_limit"
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向${quota_display}]")
            else
                status_tags+=("[单向${quota_display}]")
            fi
            status_tags+=("[${next_month}月${reset_day}日重置]")

            if [ $usage_percent -ge 100 ]; then
                status_tags+=("[已超限]")
            fi
        else
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向无限制]")
            else
                status_tags+=("[单向无限制]")
            fi
        fi
    fi

    # 3. 带宽限制标签
    if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
        local limit_text=$(echo "$rate_limit" | sed 's/bps$//' | sed 's/bit$//')
        status_tags+=("[限制带宽${limit_text}]")
    fi

    # 输出所有标签
    if [ ${#status_tags[@]} -gt 0 ]; then
        printf '%s' "${status_tags[@]}"
        echo
    else
        # 默认状态
        if [ "$billing_mode" = "double" ]; then
            echo "[双向无限制]"
        else
            echo "[单向无限制]"
        fi
    fi
}

# 获取端口月度使用量
get_port_monthly_usage() {
    local port=$1
    local traffic_data=($(get_port_traffic "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")

    calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode"
}

# 解析大小字符串为字节数
parse_size_to_bytes() {
    local size_str=$1
    local number=$(echo "$size_str" | grep -o '^[0-9]*')
    local unit=$(echo "$size_str" | grep -o '[A-Za-z]*$' | tr '[:lower:]' '[:upper:]')

    case $unit in
        "KB") echo $((number * 1024)) ;;
        "MB") echo $((number * 1048576)) ;;
        "GB") echo $((number * 1073741824)) ;;
        "TB") echo $((number * 1099511627776)) ;;
        *) echo "$number" ;;
    esac
}


# 获取守护端口列表
get_active_ports() {
    jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n
}

# 获取今日总流量
get_daily_total_traffic() {
    local total_bytes=0
    local ports=($(get_active_ports))
    
    for port in "${ports[@]}"; do
        local traffic_data=($(get_port_traffic "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
        
        local port_total=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        total_bytes=$(( total_bytes + port_total ))
    done
    
    format_bytes $total_bytes
}

# 格式化端口列表（通用函数）
format_port_list() {
    local format_type="$1"  # "display" 或 "message"
    local active_ports=($(get_active_ports))
    local result=""

    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_port_traffic "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local input_formatted=$(format_bytes $input_bytes)
        local output_formatted=$(format_bytes $output_bytes)
        local status_label=$(get_port_status_label "$port")

        if [ "$format_type" = "display" ]; then
            echo -e "端口:${GREEN}$port${NC} | 总流量:${GREEN}$total_formatted${NC} | 上行(入站): ${GREEN}$input_formatted${NC} | 下行(出站):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}"
        else
            result+="
端口:${port} | 总流量:${total_formatted} | 上行(入站): ${input_formatted} | 下行(出站):${output_formatted} | ${status_label}"
        fi
    done

    if [ "$format_type" = "message" ]; then
        echo "$result"
    fi
}

# 显示主界面
show_main_menu() {
    clear

    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    # 主标题
    echo -e "${BLUE}=== 端口流量犬 v$SCRIPT_VERSION ===${NC}"
    echo -e "${GREEN}作者主页:${NC}https://zywe.de"
    echo -e "${GREEN}项目开源:${NC}https://github.com/zywe03/realm-xwPF"
    echo -e "${GREEN}一只轻巧的‘守护犬’，时刻守护你的端口流量 | 快捷命令: dog${NC}"
    echo

    # 状态信息
    echo -e "${GREEN}状态: 监控中${NC} | ${BLUE}守护端口: ${port_count}个${NC} | ${YELLOW}今日总流量: $daily_total${NC}"
    echo "────────────────────────────────────────────────────────"

    # 端口列表
    if [ $port_count -gt 0 ]; then
        format_port_list "display"
    else
        echo -e "${YELLOW}暂无监控端口${NC}"
    fi

    echo "────────────────────────────────────────────────────────"

    # 菜单选项
    echo -e "${BLUE}1.${NC} 添加/删除端口监控     ${BLUE}2.${NC} 端口限制设置管理"
    echo -e "${BLUE}3.${NC} 流量统计查看          ${BLUE}4.${NC} 流量重置管理"
    echo -e "${BLUE}5.${NC} 一键导出/导入配置     ${BLUE}6.${NC} 安装依赖(更新)脚本"
    echo -e "${BLUE}7.${NC} 卸载脚本              ${BLUE}8.${NC} 通知管理"
    echo -e "${BLUE}0.${NC} 退出"
    echo
    read -p "请选择操作 [0-8]: " choice

    case $choice in
        1) manage_port_monitoring ;;
        2) manage_traffic_limits ;;
        3) view_traffic_statistics ;;
        4) manage_traffic_reset ;;
        5) manage_configuration ;;
        6) install_update_script ;;
        7) uninstall_script ;;
        8) manage_notifications ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请输入0-8${NC}"; sleep 1; show_main_menu ;;
    esac
}

# 端口监控管理
manage_port_monitoring() {
    echo -e "${BLUE}=== 端口监控管理 ===${NC}"
    echo "1. 添加端口监控"
    echo "2. 删除端口监控"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) add_port_monitoring ;;
        2) remove_port_monitoring ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_port_monitoring ;;
    esac
}

# 添加端口监控
add_port_monitoring() {
    echo -e "${BLUE}=== 添加端口监控 ===${NC}"
    echo

    # 显示当前端口使用情况
    echo -e "${GREEN}当前系统端口使用情况:${NC}"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"

    # 获取端口信息并处理
    declare -A program_ports
    while read line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local_addr=$(echo "$line" | awk '{print $5}')
            port=$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2)
            program=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")

            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                else
                    # 检查端口是否已存在（支持|分隔符）
                    if [[ ! "${program_ports[$program]}" =~ (^|.*\|)$port(\||$) ]]; then
                        program_ports[$program]="${program_ports[$program]}|$port"
                    fi
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

    # 按程序名排序并显示
    if [ ${#program_ports[@]} -gt 0 ]; then
        for program in $(printf '%s\n' "${!program_ports[@]}" | sort); do
            ports="${program_ports[$program]}"
            printf "%-10s | %-9s\n" "$program" "$ports"
        done
    else
        echo "无活跃端口"
    fi

    echo "────────────────────────────────────────────────────────"
    echo

    read -p "请输入要监控的端口号（多端口使用逗号,分隔）: " port_input

    # 处理多端口输入
    local PORTS=()
    parse_comma_separated_input "$port_input" PORTS
    local valid_ports=()

    for port in "${PORTS[@]}"; do

        # 验证端口号
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}错误：端口号 $port 无效，必须是1-65535之间的数字${NC}"
            continue
        fi

        # 检查端口是否已存在
        if jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}端口 $port 已在监控列表中，跳过${NC}"
            continue
        fi

        valid_ports+=("$port")
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可添加${NC}"
        sleep 2
        manage_port_monitoring
        return
    fi

    # 选择统计模式
    echo
    echo -e "${GREEN}说明:${NC}"
    echo "1. 双向流量统计："
    echo "   总流量 = 入站流量 + 出站流量"
    echo
    echo "2. 单向流量统计模式："
    echo "   总流量 = 只统计出站流量"
    echo
    echo "请选择统计模式:"
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    read -p "请选择(回车默认1) [1-2]: " billing_choice

    local billing_mode="double"
    case $billing_choice in
        1|"") billing_mode="double" ;;
        2) billing_mode="single" ;;
        *) billing_mode="double" ;;
    esac

    # 设置流量配额
    echo
    local port_list=$(IFS=','; echo "${valid_ports[*]}")
    echo "为端口 $port_list 设置流量配额（总量控制）:"
    echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
    echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "流量配额(回车默认0): " quota_input

    # 处理配额输入（空输入默认为0）
    if [ -z "$quota_input" ]; then
        quota_input="0"
    fi
    local QUOTAS=()
    parse_comma_separated_input "$quota_input" QUOTAS

    # 只输入一个值，应用到所有端口
    expand_single_value_to_array QUOTAS ${#valid_ports[@]}
    if [ ${#QUOTAS[@]} -ne ${#valid_ports[@]} ]; then
        echo -e "${RED}配额值数量与端口数量不匹配${NC}"
        sleep 2
        add_port_monitoring
        return
    fi

    # 设置备注
    echo
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"
    echo "请输入当前规则备注(可选，直接回车跳过):"
    echo "(多端口排序分别备注使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "备注: " remark_input

    # 处理备注输入
    local REMARKS=()
    if [ -n "$remark_input" ]; then
        parse_comma_separated_input "$remark_input" REMARKS

        # 如果只输入一个值，应用到所有端口
        expand_single_value_to_array REMARKS ${#valid_ports[@]}
        if [ ${#REMARKS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}备注数量与端口数量不匹配${NC}"
            sleep 2
            add_port_monitoring
            return
        fi
    fi

    # 批量添加端口配置
    local added_count=0
    for i in "${!valid_ports[@]}"; do
        local port="${valid_ports[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
        local remark=""
        if [ ${#REMARKS[@]} -gt $i ]; then
            remark=$(echo "${REMARKS[$i]}" | tr -d ' ')
        fi

        # 处理配额设置
        local quota_enabled="true"
        local monthly_limit="unlimited"
        local reset_day=1

        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            # 转换为大写进行验证
            local quota_upper=$(echo "$quota" | tr '[:lower:]' '[:upper:]')

            # 验证输入格式
            if [[ "$quota_upper" =~ ^[0-9]+[MGT]B?$ ]]; then
                monthly_limit="$quota"
            else
                echo -e "${YELLOW}端口 $port 配额格式错误，设置为无限制${NC}"
            fi
        fi

        local port_config="{
            \"name\": \"端口$port\",
            \"enabled\": true,
            \"billing_mode\": \"$billing_mode\",
            \"bandwidth_limit\": {
                \"enabled\": false,
                \"rate\": \"unlimited\"
            },
            \"quota\": {
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\",
                \"reset_day\": $reset_day
            },
            \"remark\": \"$remark\",
            \"created_at\": \"$(get_beijing_time -Iseconds)\"
        }"

        # 更新配置文件
        update_config ".ports.\"$port\" = $port_config"

        # 添加nftables规则
        add_nftables_rules "$port"

        # 设置了具体配额值，应用配额规则
        if [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$quota_upper"
        fi

        echo -e "${GREEN}端口 $port 监控添加成功${NC}"

        # 为新端口设置自动重置定时任务
        setup_port_auto_reset_cron "$port"

        added_count=$((added_count + 1))
    done

    echo
    echo -e "${GREEN}成功添加 $added_count 个端口监控${NC}"

    sleep 2
    manage_port_monitoring
}

# 删除端口监控
remove_port_monitoring() {
    echo -e "${BLUE}=== 删除端口监控 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_port_monitoring
        return
    fi
    echo

    read -p "请选择要删除的端口（多端口使用逗号,分隔）: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_delete=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_delete+=("$port")
    done

    if [ ${#ports_to_delete[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可删除${NC}"
        sleep 2
        remove_port_monitoring
        return
    fi

    # 显示要删除的端口
    echo
    echo "将删除以下端口的监控:"
    for port in "${ports_to_delete[@]}"; do
        echo "  端口 $port"
    done
    echo

    # 确认删除
    read -p "确认删除这些端口的监控? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        for port in "${ports_to_delete[@]}"; do
            # 1. 删除nftables规则和计数器
            remove_nftables_rules "$port"

            # 2. 删除nftables配额限制
            remove_nftables_quota "$port"

            # 3. 删除TC带宽限制
            remove_tc_limit "$port"

            # 4. 从配置文件删除
            update_config "del(.ports.\"$port\")"

            # 5. 删除对应的所有快照文件
            rm -f "$SNAPSHOT_DIR/port_${port}_daily_"*.json 2>/dev/null || true
            rm -f "$SNAPSHOT_DIR/port_${port}_weekly_"*.json 2>/dev/null || true
            rm -f "$SNAPSHOT_DIR/port_${port}_monthly_"*.json 2>/dev/null || true

            # 6. 清理重置历史记录中的该端口记录
            local history_file="$CONFIG_DIR/reset_history.log"
            if [ -f "$history_file" ]; then
                grep -v "|$port|" "$history_file" > "${history_file}.tmp" 2>/dev/null || true
                mv "${history_file}.tmp" "$history_file" 2>/dev/null || true
            fi

            # 7. 清理通知日志中的该端口记录
            local notification_log="$CONFIG_DIR/logs/notification.log"
            if [ -f "$notification_log" ]; then
                grep -v "端口 $port " "$notification_log" > "${notification_log}.tmp" 2>/dev/null || true
                mv "${notification_log}.tmp" "$notification_log" 2>/dev/null || true
            fi

            # 8. 删除该端口的自动重置定时任务
            remove_port_auto_reset_cron "$port"

            echo -e "${GREEN}端口 $port 监控及相关数据删除成功${NC}"
            deleted_count=$((deleted_count + 1))
        done

        echo
        echo -e "${GREEN}成功删除 $deleted_count 个端口监控${NC}"

        # 检查是否还有端口（已经在删除循环中处理了单个端口的任务删除）
        local remaining_ports=($(get_active_ports))
        if [ ${#remaining_ports[@]} -eq 0 ]; then
            echo -e "${YELLOW}所有端口已删除，自动重置功能已停用${NC}"
        fi
    else
        echo "取消删除"
    fi

    sleep 2
    manage_port_monitoring
}

# 添加nftables规则 - 通用端口流量统计
add_nftables_rules() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    # 添加命名计数器 - 简化为入站和出站两个计数器
    nft add counter $family $table_name "port_${port}_in" 2>/dev/null || true
    nft add counter $family $table_name "port_${port}_out" 2>/dev/null || true

    nft add rule $family $table_name input tcp dport $port counter name "port_${port}_in" accept
    nft add rule $family $table_name input udp dport $port counter name "port_${port}_in" accept
    nft add rule $family $table_name forward tcp dport $port counter name "port_${port}_in" accept
    nft add rule $family $table_name forward udp dport $port counter name "port_${port}_in" accept

    nft add rule $family $table_name output tcp sport $port counter name "port_${port}_out" accept
    nft add rule $family $table_name output udp sport $port counter name "port_${port}_out" accept
    nft add rule $family $table_name forward tcp sport $port counter name "port_${port}_out" accept
    nft add rule $family $table_name forward udp sport $port counter name "port_${port}_out" accept
}

# 删除nftables规则
remove_nftables_rules() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    # 先检查是否存在计数器规则
    if ! nft -a list table $family $table_name 2>/dev/null | grep -q "counter name \"port_${port}_"; then
        return 0
    fi

    nft -a list table $family $table_name 2>/dev/null | \
        grep -E "(tcp|udp) (dport|sport) $port.*counter name \"port_${port}_" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' | \
        while read handle; do
            nft delete rule $family $table_name handle $handle 2>/dev/null || true
        done

    # 重置计数器为0而不是删除，确保重新添加时从0开始
    nft reset counter $family $table_name "port_${port}_in" 2>/dev/null || true
    nft reset counter $family $table_name "port_${port}_out" 2>/dev/null || true

    # 然后删除计数器对象
    nft delete counter $family $table_name "port_${port}_in" 2>/dev/null || true
    nft delete counter $family $table_name "port_${port}_out" 2>/dev/null || true
}

# 设置端口带宽限制
set_port_bandwidth_limit() {
    echo -e "${BLUE}设置端口带宽限制${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read -p "请选择要限制的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_limit=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_limit+=("$port")
    done

    if [ ${#ports_to_limit[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置限制${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    # 显示要设置限制的端口
    echo
    local port_list=$(IFS=','; echo "${ports_to_limit[*]}")
    echo "为端口 $port_list 设置带宽限制（速率控制）:"
    echo "请输入限制值（0为无限制）（要带单位Mbps/Gbps）:"
    echo "(多端口排序分别限制使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "带宽限制: " limit_input

    # 处理限制值输入
    local LIMITS=()
    parse_comma_separated_input "$limit_input" LIMITS

    # 如果只输入一个值，应用到所有端口
    expand_single_value_to_array LIMITS ${#ports_to_limit[@]}
    if [ ${#LIMITS[@]} -ne ${#ports_to_limit[@]} ]; then
        echo -e "${RED}限制值数量与端口数量不匹配${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    # 批量设置限制
    local success_count=0
    for i in "${!ports_to_limit[@]}"; do
        local port="${ports_to_limit[$i]}"
        local limit=$(echo "${LIMITS[$i]}" | tr -d ' ')

        # 处理无限制情况
        if [ "$limit" = "0" ] || [ -z "$limit" ]; then
            remove_tc_limit "$port"
            update_config ".ports.\"$port\".bandwidth_limit.enabled = false |
                .ports.\"$port\".bandwidth_limit.rate = \"unlimited\""
            echo -e "${GREEN}端口 $port 带宽限制已移除${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        # 先移除旧的限制
        remove_tc_limit "$port"

        # 转换为小写进行验证和处理
        local limit_lower=$(echo "$limit" | tr '[:upper:]' '[:lower:]')

        # 验证输入格式
        if ! [[ "$limit_lower" =~ ^[0-9]+[mg]bps$ ]]; then
            echo -e "${RED}端口 $port 格式错误，请使用如：100Mbps, 1Gbps${NC}"
            continue
        fi

        # 转换为TC格式
        local tc_limit
        if [[ "$limit_lower" =~ ^[0-9]+mbps$ ]]; then
            tc_limit=$(echo "$limit_lower" | sed 's/mbps$/mbit/')
        elif [[ "$limit_lower" =~ ^[0-9]+gbps$ ]]; then
            tc_limit=$(echo "$limit_lower" | sed 's/gbps$/gbit/')
        fi

        # 应用TC限制
        apply_tc_limit "$port" "$tc_limit"

        # 更新配置文件
        update_config ".ports.\"$port\".bandwidth_limit.enabled = true |
            .ports.\"$port\".bandwidth_limit.rate = \"$limit\""

        echo -e "${GREEN}端口 $port 带宽限制设置成功: $limit${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的带宽限制${NC}"
    sleep 3
    manage_traffic_limits
}

# 设置端口流量配额限制
set_port_quota_limit() {
    echo -e "${BLUE}=== 设置端口流量配额 ===${NC}"
    echo

    local active_ports=($(get_active_ports))
    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read -p "请选择要设置配额的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_quota=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_quota+=("$port")
    done

    if [ ${#ports_to_quota[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置配额${NC}"
        sleep 2
        set_port_quota_limit
        return
    fi

    # 显示要设置配额的端口
    echo
    local port_list=$(IFS=','; echo "${ports_to_quota[*]}")
    echo "为端口 $port_list 设置流量配额（总量控制）:"
    echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
    echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "流量配额(回车默认0): " quota_input

    # 处理配额值输入（空输入默认为0）
    if [ -z "$quota_input" ]; then
        quota_input="0"
    fi
    local QUOTAS=()
    parse_comma_separated_input "$quota_input" QUOTAS

    # 如果只输入一个值，应用到所有端口
    expand_single_value_to_array QUOTAS ${#ports_to_quota[@]}
    if [ ${#QUOTAS[@]} -ne ${#ports_to_quota[@]} ]; then
        echo -e "${RED}配额值数量与端口数量不匹配${NC}"
        sleep 2
        set_port_quota_limit
        return
    fi

    # 批量设置配额
    local success_count=0
    for i in "${!ports_to_quota[@]}"; do
        local port="${ports_to_quota[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')

        # 处理无限制情况
        if [ "$quota" = "0" ] || [ -z "$quota" ]; then
            remove_nftables_quota "$port"
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"unlimited\""
            echo -e "${GREEN}端口 $port 流量配额设置为无限制${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        # 转换为大写进行验证和处理
        local quota_upper=$(echo "$quota" | tr '[:lower:]' '[:upper:]')

        # 验证输入格式
        if ! [[ "$quota_upper" =~ ^[0-9]+[MGT]B?$ ]]; then
            echo -e "${RED}端口 $port 格式错误，请使用如：100MB, 1GB, 2T${NC}"
            continue
        fi

        # 先删除旧的配额规则（如果存在）
        remove_nftables_quota "$port"

        # 应用新的nftables配额（使用标准化的大写格式）
        apply_nftables_quota "$port" "$quota_upper"

        # 更新配置文件（保存用户原始输入格式）
        update_config ".ports.\"$port\".quota.enabled = true |
            .ports.\"$port\".quota.monthly_limit = \"$quota\""

        echo -e "${GREEN}端口 $port 流量配额设置成功: $quota${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的流量配额${NC}"
    sleep 3
    manage_traffic_limits
}

# 端口限制设置管理
manage_traffic_limits() {
    echo -e "${BLUE}=== 端口限制设置管理 ===${NC}"
    echo "1. 设置端口带宽限制（速率控制）"
    echo "2. 设置端口流量配额（总量控制）"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) set_port_bandwidth_limit ;;
        2) set_port_quota_limit ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_traffic_limits ;;
    esac
}

# 应用nftables配额限制（基于统计模式）
apply_nftables_quota() {
    local port=$1
    local quota_limit=$2
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")

    # 转换配额为字节数
    local quota_bytes
    if [[ "$quota_limit" =~ ^[0-9]+MB?$ ]]; then
        local num=$(echo "$quota_limit" | sed 's/MB\?$//')
        quota_bytes=$((num * 1048576))
    elif [[ "$quota_limit" =~ ^[0-9]+GB?$ ]]; then
        local num=$(echo "$quota_limit" | sed 's/GB\?$//')
        quota_bytes=$((num * 1073741824))
    elif [[ "$quota_limit" =~ ^[0-9]+TB?$ ]]; then
        local num=$(echo "$quota_limit" | sed 's/TB\?$//')
        quota_bytes=$((num * 1099511627776))
    else
        quota_bytes="$quota_limit"
    fi

    # 创建配额对象
    local quota_name="port_${port}_quota"
    nft add quota $family $table_name $quota_name { over $quota_bytes bytes } 2>/dev/null || true

    # 根据统计模式设置配额规则
    if [ "$billing_mode" = "double" ]; then
        nft insert rule $family $table_name input tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name input udp dport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name forward tcp dport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name forward udp dport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
    else
        # 单向统计仅统计出站方向
        nft insert rule $family $table_name output tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name output udp sport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name forward tcp sport $port quota name "$quota_name" drop 2>/dev/null || true
        nft insert rule $family $table_name forward udp sport $port quota name "$quota_name" drop 2>/dev/null || true
    fi
}

# 删除nftables配额限制
remove_nftables_quota() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local quota_name="port_${port}_quota"

    # 先检查是否存在配额规则
    if ! nft -a list table $family $table_name 2>/dev/null | grep -q "quota name \"$quota_name\""; then
        return 0  # 没有配额规则，直接返回
    fi

    nft -a list table $family $table_name 2>/dev/null | \
        grep -E "(tcp|udp) (dport|sport) $port.*quota name \"$quota_name\"" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' | \
        while read handle; do
            nft delete rule $family $table_name handle $handle 2>/dev/null || true
        done

    # 删除配额对象
    nft delete quota $family $table_name $quota_name 2>/dev/null || true
}

# 应用TC带宽限制
apply_tc_limit() {
    local port=$1
    local total_limit=$2
    local interface=$(get_default_interface)

    tc qdisc add dev $interface root handle 1: htb default 30 2>/dev/null || true
    tc class add dev $interface parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null || true

    # 为端口创建专用类别
    local class_id="1:$(printf '%x' $((0x1000 + port)))"

    # 删除可能存在的旧类别
    tc class del dev $interface classid $class_id 2>/dev/null || true

    # 创建新的限制类别（允许偶尔突发）
    local base_rate
    if [[ "$total_limit" =~ gbit$ ]]; then
        base_rate=$(echo "$total_limit" | sed 's/gbit$//')
        base_rate=$((base_rate * 1000))  # 转换为Mbps
    else
        base_rate=$(echo "$total_limit" | sed 's/mbit$//')
    fi

    # 计算burst大小：burst = max((rate_bytes_per_sec / 100), 2*MTU)
    local rate_bytes_per_sec=$((base_rate * 1000000 / 8))  # Mbps转为bytes/sec
    local burst_by_formula=$((rate_bytes_per_sec / 20))   # 1/20秒的数据量 ≈ 50ms
    local min_burst=$((2 * 1500))                          # 2个MTU = 3000字节

    # 取两者最大值
    local burst_bytes
    if [ $burst_by_formula -gt $min_burst ]; then
        burst_bytes=$burst_by_formula
    else
        burst_bytes=$min_burst
    fi

    # 转换为tc可识别的格式
    local burst_size
    if [ $burst_bytes -lt 1024 ]; then
        burst_size="${burst_bytes}"
    elif [ $burst_bytes -lt 1048576 ]; then
        burst_size="$((burst_bytes / 1024))k"
    else
        burst_size="$((burst_bytes / 1048576))m"
    fi

    tc class add dev $interface parent 1:1 classid $class_id htb rate $total_limit ceil $total_limit burst $burst_size

    # 计算过滤器优先级（避免冲突）
    local filter_prio=$((port % 1000 + 1))

    # 应用过滤器（双向流量都使用同一个限制）
    # TCP协议过滤器
    tc filter add dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
        match ip protocol 6 0xff match ip sport $port 0xffff flowid $class_id 2>/dev/null || true
    tc filter add dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
        match ip protocol 6 0xff match ip dport $port 0xffff flowid $class_id 2>/dev/null || true

    # UDP协议过滤器
    tc filter add dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
        match ip protocol 17 0xff match ip sport $port 0xffff flowid $class_id 2>/dev/null || true
    tc filter add dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
        match ip protocol 17 0xff match ip dport $port 0xffff flowid $class_id 2>/dev/null || true
}

# 删除TC带宽限制
remove_tc_limit() {
    local port=$1
    local interface=$(get_default_interface)
    local class_id="1:$(printf '%x' $((0x1000 + port)))"

    # 先检查是否存在TC规则
    if ! tc class show dev $interface 2>/dev/null | grep -q "$class_id"; then
        return 0  # 没有TC规则，直接返回
    fi

    # 计算过滤器优先级
    local filter_prio=$((port % 1000 + 1))

    # 删除TCP过滤器
    tc filter del dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
        match ip protocol 6 0xff match ip sport $port 0xffff 2>/dev/null || true
    tc filter del dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
        match ip protocol 6 0xff match ip dport $port 0xffff 2>/dev/null || true

    # 删除UDP过滤器
    tc filter del dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
        match ip protocol 17 0xff match ip sport $port 0xffff 2>/dev/null || true
    tc filter del dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
        match ip protocol 17 0xff match ip dport $port 0xffff 2>/dev/null || true

    # 删除类别
    tc class del dev $interface classid $class_id 2>/dev/null || true
}

# 流量统计查看
view_traffic_statistics() {
    echo -e "${BLUE}流量统计查看${NC}"
    echo "快照文件路径: $SNAPSHOT_DIR"
    echo "1. 历史流量统计"
    echo "2. 端口流量排行"
    echo "0. 返回主菜单"
    echo
    read -p "请选择查看方式 [0-2]: " choice

    case $choice in
        1) view_historical_statistics ;;
        2) view_traffic_ranking ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; view_traffic_statistics ;;
    esac
}


# 历史流量统计
view_historical_statistics() {
    echo -e "${BLUE}历史流量统计${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        view_traffic_statistics
        return
    fi
    echo

    read -p "选择要查看的端口: [1-${#active_ports[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#active_ports[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        sleep 2
        view_historical_statistics
        return
    fi

    local port=${active_ports[$((choice-1))]}
    show_port_historical_details "$port"
}


# 显示端口历史流量详情
show_port_historical_details() {
    local port=$1
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")

    local status_label=$(get_port_status_label "$port")
    echo "端口 $port $status_label"
    echo

    # 获取本日流量情况(每日0点)
    local daily_traffic=($(get_period_traffic "$port" "daily"))
    local daily_input=${daily_traffic[0]:-0}
    local daily_output=${daily_traffic[1]:-0}
    local daily_total=$(calculate_total_traffic "$daily_input" "$daily_output" "$billing_mode")

    local daily_input_formatted=$(format_bytes $daily_input)
    local daily_output_formatted=$(format_bytes $daily_output)
    local daily_total_formatted=$(format_bytes $daily_total)

    echo "本日流量情况(昨日23:59起)"
    echo "🟢 上行(入站): $daily_input_formatted | 下行(出站): $daily_output_formatted | 总计流量: $daily_total_formatted"
    echo "────────────────────────────────────────────────────────"

    # 获取本周流量情况(周一0点)
    local weekly_traffic=($(get_period_traffic "$port" "weekly"))
    local weekly_input=${weekly_traffic[0]:-0}
    local weekly_output=${weekly_traffic[1]:-0}
    local weekly_total=$(calculate_total_traffic "$weekly_input" "$weekly_output" "$billing_mode")

    local weekly_input_formatted=$(format_bytes $weekly_input)
    local weekly_output_formatted=$(format_bytes $weekly_output)
    local weekly_total_formatted=$(format_bytes $weekly_total)

    echo "本周流量情况:(周一0点)"
    echo "🟢 上行(入站): $weekly_input_formatted | 下行(出站): $weekly_output_formatted | 总计流量: $weekly_total_formatted"
    echo "────────────────────────────────────────────────────────"

    # 获取本月流量情况(每月1日0点)
    local monthly_traffic=($(get_period_traffic "$port" "monthly"))
    local monthly_input=${monthly_traffic[0]:-0}
    local monthly_output=${monthly_traffic[1]:-0}
    local monthly_total=$(calculate_total_traffic "$monthly_input" "$monthly_output" "$billing_mode")

    local monthly_input_formatted=$(format_bytes $monthly_input)
    local monthly_output_formatted=$(format_bytes $monthly_output)
    local monthly_total_formatted=$(format_bytes $monthly_total)

    echo "本月流量情况:(每月1日0点)"
    echo "🟢 上行(入站): $monthly_input_formatted | 下行(出站): $monthly_output_formatted | 总计流量: $monthly_total_formatted"
    echo

    read -p "按回车键返回..."
    view_traffic_statistics
}

# 非交互式端口流量排行（供快照通知使用）
get_traffic_ranking_data() {
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        return
    fi

    # 创建临时文件存储排序数据
    local temp_file_double=$(mktemp)
    local temp_file_single=$(mktemp)

    # 收集双向统计模式的端口数据（使用月流量数据）
    for port in "${active_ports[@]}"; do
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
        local remark=$(jq -r ".ports.\"$port\".remark // \"\"" "$CONFIG_FILE")

        # 获取月流量数据
        local monthly_traffic=($(get_period_traffic "$port" "monthly"))
        local monthly_input=${monthly_traffic[0]:-0}
        local monthly_output=${monthly_traffic[1]:-0}

        # 确保是数字
        if ! [[ "$monthly_input" =~ ^[0-9]+$ ]]; then
            monthly_input=0
        fi
        if ! [[ "$monthly_output" =~ ^[0-9]+$ ]]; then
            monthly_output=0
        fi

        local monthly_total=$(calculate_total_traffic "$monthly_input" "$monthly_output" "$billing_mode")

        if [ "$billing_mode" = "double" ]; then
            echo "$monthly_total $port $remark" >> "$temp_file_double"
        else
            echo "$monthly_total $port $remark" >> "$temp_file_single"
        fi
    done

    # 显示双向统计模式排行（前5名）
    echo "双向统计模式:"
    local rank=1
    if [ -s "$temp_file_double" ]; then
        while IFS=' ' read -r total_bytes port remark; do
            local total_formatted=$(format_bytes $total_bytes)
            local remark_display=""
            if [ -n "$remark" ] && [ "$remark" != "null" ]; then
                remark_display=" [备注:$remark]"
            fi
            echo "$rank. 端口 $port$remark_display 总计流量: $total_formatted"
            rank=$((rank + 1))
        done < <(sort -nr "$temp_file_double" | head -5)
    fi
    # 补齐空位到5个
    while [ $rank -le 5 ]; do
        echo "$rank. "
        rank=$((rank + 1))
    done

    # 显示单向统计模式排行（前5名）
    echo "单向统计模式:"
    rank=1
    if [ -s "$temp_file_single" ]; then
        while IFS=' ' read -r total_bytes port remark; do
            local total_formatted=$(format_bytes $total_bytes)
            local remark_display=""
            if [ -n "$remark" ] && [ "$remark" != "null" ]; then
                remark_display=" [备注:$remark]"
            fi
            echo "$rank. 端口 $port$remark_display 总计流量: $total_formatted"
            rank=$((rank + 1))
        done < <(sort -nr "$temp_file_single" | head -5)
    fi
    # 补齐空位到5个
    while [ $rank -le 5 ]; do
        echo "$rank. "
        rank=$((rank + 1))
    done

    # 清理临时文件
    rm -f "$temp_file_double" "$temp_file_single"
}

# 端口流量排行
view_traffic_ranking() {
    echo -e "${BLUE}端口流量排行${NC}"
    echo

    local active_ports=($(get_active_ports))

    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        sleep 2
        view_traffic_statistics
        return
    fi

    # 调用非交互式函数获取排行数据
    get_traffic_ranking_data

    echo
    read -p "按回车键返回..."
    view_traffic_statistics
}

# 流量重置管理
manage_traffic_reset() {
    echo -e "${BLUE}流量重置管理${NC}"
    echo "1. 重置流量月重置日设置"
    echo "2. 立即重置"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) set_reset_day ;;
        2) immediate_reset ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_traffic_reset ;;
    esac
}

# 设置端口月重置日期
set_reset_day() {
    echo -e "${BLUE}=== 重置流量月重置日设置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read -p "请选择要设置重置日期的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_set=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_set+=("$port")
    done

    if [ ${#ports_to_set[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置${NC}"
        sleep 2
        set_reset_day
        return
    fi

    # 显示要设置的端口
    echo
    local port_list=$(IFS=','; echo "${ports_to_set[*]}")
    echo "为端口 $port_list 设置月重置日期:"
    echo "请输入月重置日（多端口使用逗号,分隔）:"
    echo "(只输入一个值，应用到所有端口):"
    read -p "月重置日 [1-31]: " reset_day_input

    # 处理重置日期输入
    local RESET_DAYS=()
    parse_comma_separated_input "$reset_day_input" RESET_DAYS

    # 如果只输入一个值，应用到所有端口
    expand_single_value_to_array RESET_DAYS ${#ports_to_set[@]}
    if [ ${#RESET_DAYS[@]} -ne ${#ports_to_set[@]} ]; then
        echo -e "${RED}重置日期数量与端口数量不匹配${NC}"
        sleep 2
        set_reset_day
        return
    fi

    # 批量设置重置日期
    local success_count=0
    for i in "${!ports_to_set[@]}"; do
        local port="${ports_to_set[$i]}"
        local reset_day=$(echo "${RESET_DAYS[$i]}" | tr -d ' ')

        # 验证重置日期
        if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || [ "$reset_day" -lt 1 ] || [ "$reset_day" -gt 31 ]; then
            echo -e "${RED}端口 $port 重置日期无效: $reset_day，必须是1-31之间的数字${NC}"
            continue
        fi

        # 更新配置文件
        update_config ".ports.\"$port\".quota.reset_day = $reset_day"

        # 重新设置该端口的自动重置定时任务
        setup_port_auto_reset_cron "$port"

        echo -e "${GREEN}端口 $port 月重置日设置成功: 每月${reset_day}日${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的月重置日期${NC}"

    sleep 2
    manage_traffic_reset
}

# 立即重置端口流量
immediate_reset() {
    echo -e "${BLUE}=== 立即重置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read -p "请选择要立即重置的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_reset=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_reset+=("$port")
    done

    if [ ${#ports_to_reset[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可重置${NC}"
        sleep 2
        immediate_reset
        return
    fi

    # 显示要重置的端口及其当前流量
    echo
    echo "将重置以下端口的流量统计:"
    local total_all_traffic=0
    for port in "${ports_to_reset[@]}"; do
        local traffic_data=($(get_port_traffic "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)

        echo "  端口 $port: $total_formatted"
        total_all_traffic=$((total_all_traffic + total_bytes))
    done

    echo
    echo "总计流量: $(format_bytes $total_all_traffic)"
    echo -e "${YELLOW}警告：重置后流量统计将清零，此操作不可撤销！${NC}"
    read -p "确认重置选定端口的流量统计? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local reset_count=0
        for port in "${ports_to_reset[@]}"; do
            # 获取当前流量用于记录
            local traffic_data=($(get_port_traffic "$port"))
            local input_bytes=${traffic_data[0]}
            local output_bytes=${traffic_data[1]}
            local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
            local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

            # 重置计数器
            reset_port_nftables_counters "$port"

            # 记录重置历史
            record_reset_history "$port" "$total_bytes"

            echo -e "${GREEN}端口 $port 流量统计重置成功${NC}"
            reset_count=$((reset_count + 1))
        done

        echo
        echo -e "${GREEN}成功重置 $reset_count 个端口的流量统计${NC}"
        echo "重置前总流量: $(format_bytes $total_all_traffic)"
    else
        echo "取消重置"
    fi

    sleep 3
    manage_traffic_reset
}

# 自动重置指定端口的流量
auto_reset_port() {
    local port="$1"

    # 获取当前流量用于记录
    local traffic_data=($(get_port_traffic "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
    local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

    # 重置计数器
    reset_port_nftables_counters "$port"

    # 记录重置历史
    record_reset_history "$port" "$total_bytes"

    # 记录日志
    log_notification "端口 $port 自动重置完成，重置前流量: $(format_bytes $total_bytes)"

    echo "端口 $port 自动重置完成"
}

# 重置端口nftables计数器
reset_port_nftables_counters() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    # 重置命名计数器
    nft reset counter $family $table_name "port_${port}_in" >/dev/null 2>&1 || true
    nft reset counter $family $table_name "port_${port}_out" >/dev/null 2>&1 || true
}

# 记录重置历史
record_reset_history() {
    local port=$1
    local traffic_bytes=$2
    local timestamp=$(get_beijing_time +%s)
    local history_file="$CONFIG_DIR/reset_history.log"

    mkdir -p "$(dirname "$history_file")"

    # 记录重置信息
    echo "$timestamp|$port|$traffic_bytes" >> "$history_file"

    # 保持历史记录不超过100条
    if [ $(wc -l < "$history_file" 2>/dev/null || echo 0) -gt 100 ]; then
        tail -n 100 "$history_file" > "${history_file}.tmp"
        mv "${history_file}.tmp" "$history_file"
    fi
}

# 配置管理
manage_configuration() {
    echo -e "${BLUE}=== 配置文件管理 ===${NC}"
    echo
    echo "请选择操作:"
    echo "1. 导出配置包"
    echo "2. 导入配置包"
    echo "0. 返回上级菜单"
    echo
    read -p "请输入选择 [0-2]: " choice

    case $choice in
        1) export_config ;;
        2) import_config ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_configuration ;;
    esac
}



# 导出配置包
export_config() {
    echo -e "${BLUE}=== 导出配置包 ===${NC}"
    echo

    # 检查配置目录是否存在
    if [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${RED}错误：配置目录不存在${NC}"
        sleep 2
        manage_configuration
        return
    fi

    # 生成时间戳文件名
    local timestamp=$(get_beijing_time +%Y%m%d-%H%M%S)
    local backup_name="port-traffic-dog-config-${timestamp}.tar.gz"
    local backup_path="/root/${backup_name}"

    echo "正在导出配置包..."
    echo "包含内容："
    echo "  - 主配置文件 (config.json)"
    echo "  - 端口监控数据"
    echo "  - 历史快照数据"
    echo "  - 通知配置"
    echo "  - 日志文件"
    echo

    # 创建临时目录用于打包
    local temp_dir=$(mktemp -d)
    local package_dir="$temp_dir/port-traffic-dog-config"

    # 复制配置目录到临时位置
    cp -r "$CONFIG_DIR" "$package_dir"

    # 生成配置包信息文件
    cat > "$package_dir/package_info.txt" << EOF
端口流量犬配置包信息
===================
导出时间: $(get_beijing_time '+%Y-%m-%d %H:%M:%S')
脚本版本: $SCRIPT_VERSION
配置目录: $CONFIG_DIR
导出主机: $(hostname)
包含端口: $(jq -r '.ports | keys | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "无")
EOF

    # 打包配置
    cd "$temp_dir"
    tar -czf "$backup_path" port-traffic-dog-config/ 2>/dev/null

    # 清理临时目录
    rm -rf "$temp_dir"

    # 检查导出结果
    if [ -f "$backup_path" ]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        echo -e "${GREEN}✅ 配置包导出成功${NC}"
        echo
        echo "📦 文件信息："
        echo "  文件名: $backup_name"
        echo "  路径: $backup_path"
        echo "  大小: $file_size"
    else
        echo -e "${RED}❌ 配置包导出失败${NC}"
    fi

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 导入配置包
import_config() {
    echo -e "${BLUE}=== 导入配置包 ===${NC}"
    echo

    echo "请输入配置包路径 (支持绝对路径或相对路径):"
    echo "例如: /root/port-traffic-dog-config-20241227-143022.tar.gz"
    echo
    read -p "配置包路径: " package_path

    # 检查输入是否为空
    if [ -z "$package_path" ]; then
        echo -e "${RED}错误：路径不能为空${NC}"
        sleep 2
        import_config
        return
    fi

    # 检查文件是否存在
    if [ ! -f "$package_path" ]; then
        echo -e "${RED}错误：配置包文件不存在${NC}"
        echo "路径: $package_path"
        sleep 2
        import_config
        return
    fi

    # 检查文件格式
    if [[ ! "$package_path" =~ \.tar\.gz$ ]]; then
        echo -e "${RED}错误：配置包必须是 .tar.gz 格式${NC}"
        sleep 2
        import_config
        return
    fi

    echo
    echo "正在验证配置包..."

    # 创建临时目录用于解压验证
    local temp_dir=$(mktemp -d)

    # 解压到临时目录进行验证
    cd "$temp_dir"
    if ! tar -tzf "$package_path" >/dev/null 2>&1; then
        echo -e "${RED}错误：配置包文件损坏或格式错误${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    # 解压配置包
    tar -xzf "$package_path" 2>/dev/null

    # 验证配置包结构
    local config_dir_name=$(ls | head -n1)
    if [ ! -d "$config_dir_name" ]; then
        echo -e "${RED}错误：配置包结构异常${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    local extracted_config="$temp_dir/$config_dir_name"

    # 检查必要文件
    if [ ! -f "$extracted_config/config.json" ]; then
        echo -e "${RED}错误：配置包中缺少 config.json 文件${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    # 显示配置包信息
    echo -e "${GREEN}✅ 配置包验证通过${NC}"
    echo

    if [ -f "$extracted_config/package_info.txt" ]; then
        echo "📋 配置包信息："
        cat "$extracted_config/package_info.txt"
        echo
    fi

    # 显示将要导入的端口
    local import_ports=$(jq -r '.ports | keys | join(", ")' "$extracted_config/config.json" 2>/dev/null || echo "无")
    echo "📊 包含端口: $import_ports"
    echo

    # 确认导入
    echo -e "${YELLOW}⚠️  警告：导入配置将会：${NC}"
    echo "  1. 停止当前所有端口监控"
    echo "  2. 替换为新的配置"
    echo "  3. 重新应用监控规则"
    echo
    read -p "确认导入配置包? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消导入"
        rm -rf "$temp_dir"
        sleep 1
        manage_configuration
        return
    fi

    echo
    echo "开始导入配置..."

    # 1. 停止当前监控
    echo "正在停止当前端口监控..."
    local current_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${current_ports[@]}"; do
        remove_nftables_rules "$port" 2>/dev/null || true
        remove_tc_limit "$port" 2>/dev/null || true
    done

    # 2. 替换配置
    echo "正在导入新配置..."
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$CONFIG_DIR")"
    cp -r "$extracted_config" "$CONFIG_DIR"

    # 3. 重新应用规则
    echo "正在重新应用监控规则..."

    # 重新初始化nftables
    init_nftables

    # 为每个端口重新应用规则
    local new_ports=($(get_active_ports))
    for port in "${new_ports[@]}"; do
        # 添加基础监控规则
        add_nftables_rules "$port"

        # 应用配额限制（如果有）
        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            local quota_upper=$(echo "$monthly_limit" | tr '[:lower:]' '[:upper:]')
            apply_nftables_quota "$port" "$quota_upper"
        fi

        # 应用带宽限制（如果有）
        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local limit_lower=$(echo "$rate_limit" | tr '[:upper:]' '[:lower:]')
            local tc_limit
            if [[ "$limit_lower" =~ ^[0-9]+mbps$ ]]; then
                tc_limit=$(echo "$limit_lower" | sed 's/mbps$/mbit/')
            elif [[ "$limit_lower" =~ ^[0-9]+gbps$ ]]; then
                tc_limit=$(echo "$limit_lower" | sed 's/gbps$/gbit/')
            fi
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit"
            fi
        fi
    done

    # 重新下载通知模块（确保版本匹配）
    echo "正在更新通知模块..."
    download_notification_modules >/dev/null 2>&1 || true

    # 清理临时目录
    rm -rf "$temp_dir"

    echo
    echo -e "${GREEN}✅ 配置导入完成${NC}"
    echo
    echo "📊 导入结果："
    echo "  导入端口数: ${#new_ports[@]} 个"
    if [ ${#new_ports[@]} -gt 0 ]; then
        echo "  端口列表: $(IFS=','; echo "${new_ports[*]}")"
    fi
    echo
    echo -e "${YELLOW}💡 提示：${NC}"
    echo "  - 所有端口监控规则已重新应用"
    echo "  - 通知配置已恢复"
    echo "  - 历史数据和快照已恢复"

    echo
    read -p "按回车键返回..."
    manage_configuration
}



# 统一下载函数
download_with_sources() {
    local url=$1
    local output_file=$2

    for source in "${DOWNLOAD_SOURCES[@]}"; do
        local full_url="${source}${url}"

        if [ -z "$source" ]; then
            echo -e "${YELLOW}尝试官方源下载...${NC}"
            full_url="$url"
        else
            echo -e "${YELLOW}尝试加速源: ${source}${NC}"
        fi

        if curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "$full_url" -o "$output_file" 2>/dev/null; then
            if [ -s "$output_file" ]; then
                echo -e "${GREEN}下载成功${NC}"
                return 0
            fi
        fi
        echo -e "${YELLOW}下载失败，尝试下一个源...${NC}"
    done

    return 1
}

# 下载通知模块
download_notification_modules() {
    local notifications_dir="$CONFIG_DIR/notifications"
    local temp_dir=$(mktemp -d)
    local repo_url="https://github.com/zywe03/realm-xwPF/archive/refs/heads/main.zip"

    # 下载解压复制清理（每次都覆盖更新）
    if download_with_sources "$repo_url" "$temp_dir/repo.zip" &&
       (cd "$temp_dir" && unzip -q repo.zip) &&
       rm -rf "$notifications_dir" &&
       cp -r "$temp_dir/realm-xwPF-main/notifications" "$notifications_dir" &&
       chmod +x "$notifications_dir"/*.sh; then
        rm -rf "$temp_dir"
        return 0
    else
        rm -rf "$temp_dir"
        return 1
    fi
}

# 安装(更新)脚本
install_update_script() {
    echo -e "${BLUE}安装依赖(更新)脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    # 1. 检查并安装依赖
    echo -e "${YELLOW}正在检查系统依赖...${NC}"
    check_dependencies true  # 使用静默模式

    # 2. 下载更新脚本
    echo -e "${YELLOW}正在下载最新版本...${NC}"

    local temp_file=$(mktemp)

    if download_with_sources "$SCRIPT_URL" "$temp_file"; then
        # 验证下载的文件
        if [ -s "$temp_file" ] && grep -q "端口流量犬" "$temp_file" 2>/dev/null; then
            # 安装新脚本
            mv "$temp_file" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"

            # 创建快捷命令
            create_shortcut_command

            # 重新下载通知模块（确保版本匹配）
            echo -e "${YELLOW}正在更新通知模块...${NC}"
            download_notification_modules >/dev/null 2>&1 || true

            echo -e "${GREEN}✅ 依赖检查完成${NC}"
            echo -e "${GREEN}✅ 脚本更新完成${NC}"
            echo -e "${GREEN}✅ 通知模块已更新${NC}"
        else
            echo -e "${RED}❌ 下载文件验证失败${NC}"
            rm -f "$temp_file"
        fi
    else
        echo -e "${RED}❌ 下载失败，请检查网络连接${NC}"
        rm -f "$temp_file"
    fi

    echo "────────────────────────────────────────────────────────"
    read -p "按回车键返回..."
    show_main_menu
}

# 创建快捷命令
create_shortcut_command() {
    if [ ! -f "/usr/local/bin/$SHORTCUT_COMMAND" ]; then
        cat > "/usr/local/bin/$SHORTCUT_COMMAND" << EOF
#!/bin/bash
exec bash "$SCRIPT_PATH" "\$@"
EOF
        chmod +x "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        echo -e "${GREEN}快捷命令 '$SHORTCUT_COMMAND' 创建成功${NC}"
    fi
}

# 卸载脚本
uninstall_script() {
    echo -e "${BLUE}卸载脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}将要删除以下内容:${NC}"
    echo "  - 脚本文件: $SCRIPT_PATH"
    echo "  - 快捷命令: /usr/local/bin/$SHORTCUT_COMMAND"
    echo "  - 配置目录: $CONFIG_DIR"
    echo "  - 所有nftables规则"
    echo "  - 所有TC限制规则"
    echo "  - 流量快照定时任务"
    echo
    echo -e "${RED}警告：此操作将完全删除端口流量犬及其所有数据！${NC}"
    read -p "确认卸载? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"

        # 删除所有端口的nftables规则
        local active_ports=($(get_active_ports 2>/dev/null || true))
        for port in "${active_ports[@]}"; do
            remove_nftables_rules "$port" 2>/dev/null || true
            remove_tc_limit "$port" 2>/dev/null || true
        done

        # 删除nftables表
        local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE" 2>/dev/null || echo "port_traffic_monitor")
        local family=$(jq -r '.nftables.family' "$CONFIG_FILE" 2>/dev/null || echo "inet")
        nft delete table $family $table_name >/dev/null 2>&1 || true

        # 删除定时任务
        remove_snapshot_cron 2>/dev/null || true
        remove_notification_cron 2>/dev/null || true

        # 删除配置目录
        rm -rf "$CONFIG_DIR" 2>/dev/null || true

        # 删除快捷命令
        rm -f "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true

        # 删除脚本文件
        rm -f "$SCRIPT_PATH" 2>/dev/null || true

        echo -e "${GREEN}卸载完成！${NC}"
        echo -e "${YELLOW}感谢使用端口流量犬！${NC}"
        exit 0
    else
        echo "取消卸载"
        sleep 1
        show_main_menu
    fi
}

# 通知管理
manage_notifications() {
    echo -e "${BLUE}=== 通知管理 ===${NC}"
    echo "1. Telegram机器人通知"
    echo "2. 邮箱通知 [敬请期待]"
    echo "3. 企业wx通知 [敬请期待]"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1) manage_telegram_notifications ;;
        2)
            echo -e "${YELLOW}预留的邮箱通知功能(画饼的)${NC}"
            sleep 2
            manage_notifications
            ;;
        3)
            echo -e "${YELLOW}预留的企业wx通知功能(画饼的)${NC}"
            sleep 2
            manage_notifications
            ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_notifications ;;
    esac
}

# Telegram 通知管理（调用外部模块）
manage_telegram_notifications() {
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"

    if [ -f "$telegram_script" ]; then
        source "$telegram_script"
        telegram_configure
        manage_notifications
    else
        echo -e "${RED}Telegram 通知模块不存在${NC}"
        echo "请检查文件: $telegram_script"
        sleep 2
        manage_notifications
    fi
}

# API 接口函数 - 供通知模块调用

# 获取所有端口数据（供通知模块调用）
get_all_ports_data() {
    local active_ports=($(get_active_ports))
    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_port_traffic "$port"))
        local status_label=$(get_port_status_label "$port")
        echo "$port|${traffic_data[0]}|${traffic_data[1]}|$status_label"
    done
}

# 获取系统状态信息（供通知模块调用）
get_system_status() {
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)
    echo "$port_count|$daily_total"
}

# 设置通知定时任务
setup_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    # 保留现有任务，移除旧的通知任务
    crontab -l 2>/dev/null | grep -v "# 端口流量犬快照通知" | grep -v "# 端口流量犬状态通知" | grep -v "port-traffic-dog.*--send-snapshot" | grep -v "port-traffic-dog.*--send-status" > "$temp_cron" || true

    # 读取配置
    local snapshot_enabled=$(jq -r '.notifications.telegram.snapshot_notifications.enabled' "$CONFIG_FILE")
    local status_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled' "$CONFIG_FILE")

    # 添加快照通知 - 固定每日23点55分发送（在新快照创建前获取完整数据）
    if [ "$snapshot_enabled" = "true" ]; then
        echo "55 23 * * * $script_path --send-snapshot >/dev/null 2>&1  # 端口流量犬快照通知" >> "$temp_cron"
    fi

    # 添加状态通知
    if [ "$status_enabled" = "true" ]; then
        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")
        case "$status_interval" in
            "1m")  echo "* * * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-status >/dev/null 2>&1  # 端口流量犬状态通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"

    echo -e "${GREEN}定时任务已更新${NC}"
}

# 移除通知定时任务
remove_notification_cron() {
    local temp_cron=$(mktemp)

    # 保留现有任务，移除通知任务（保留PATH设置）
    crontab -l 2>/dev/null | grep -v "# 端口流量犬快照通知" | grep -v "# 端口流量犬状态通知" | grep -v "port-traffic-dog.*--send-snapshot" | grep -v "port-traffic-dog.*--send-status" > "$temp_cron" || true

    crontab "$temp_cron"
    rm -f "$temp_cron"

    echo -e "${GREEN}通知定时任务已移除${NC}"
}

# 设置单个端口的自动重置定时任务
setup_port_auto_reset_cron() {
    local port="$1"
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    # 保留现有任务，移除该端口的旧任务
    crontab -l 2>/dev/null | grep -v "端口流量犬自动重置端口$port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    # 获取端口的重置配置
    local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
    if [ "$quota_enabled" = "true" ]; then
        local reset_day=$(jq -r ".ports.\"$port\".quota.reset_day // 1" "$CONFIG_FILE")
        # 为该端口设置独立的定时任务
        echo "0 0 $reset_day * * $script_path --reset-port $port >/dev/null 2>&1  # 端口流量犬自动重置端口$port" >> "$temp_cron"
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

# 移除单个端口的自动重置定时任务
remove_port_auto_reset_cron() {
    local port="$1"
    local temp_cron=$(mktemp)

    # 保留现有任务，移除该端口的任务
    crontab -l 2>/dev/null | grep -v "端口流量犬自动重置端口$port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

# 格式化快照消息
format_snapshot_message() {
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local server_name=$(jq -r '.notifications.telegram.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "$(hostname)")
    local notification_icon="🔔"

    local message="<b>${notification_icon} 端口流量犬 - 快照报告</b>
一只轻巧的'守护犬'，时刻守护你的端口流量
⏰ ${timestamp}

"

    # 获取所有活跃端口
    local active_ports=($(get_active_ports))

    # 预先获取所有端口的当前流量，避免重复调用
    declare -A current_traffic_cache
    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_port_traffic "$port"))
        current_traffic_cache["$port"]="${traffic_data[0]} ${traffic_data[1]}"
    done

    # 存储端口流量数据用于排行
    declare -A port_monthly_data

    # 为每个端口生成详细报告
    for port in "${active_ports[@]}"; do
        # 获取端口配置
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")

        # 获取完整的端口状态标签
        local status_label=$(get_port_status_label "$port")
        local port_title="端口 $port $status_label"

        # 从缓存获取当前流量
        local current_traffic=(${current_traffic_cache["$port"]})
        local current_input=${current_traffic[0]}
        local current_output=${current_traffic[1]}

        # 获取各时间段流量数据（传入当前流量避免重复获取）
        local daily_traffic=($(get_period_traffic_cached "$port" "daily" "$current_input" "$current_output"))
        local weekly_traffic=($(get_period_traffic_cached "$port" "weekly" "$current_input" "$current_output"))
        local monthly_traffic=($(get_period_traffic_cached "$port" "monthly" "$current_input" "$current_output"))

        local daily_input=${daily_traffic[0]:-0}
        local daily_output=${daily_traffic[1]:-0}
        local daily_total=$(calculate_total_traffic "$daily_input" "$daily_output" "$billing_mode")

        local weekly_input=${weekly_traffic[0]:-0}
        local weekly_output=${weekly_traffic[1]:-0}
        local weekly_total=$(calculate_total_traffic "$weekly_input" "$weekly_output" "$billing_mode")

        local monthly_input=${monthly_traffic[0]:-0}
        local monthly_output=${monthly_traffic[1]:-0}
        local monthly_total=$(calculate_total_traffic "$monthly_input" "$monthly_output" "$billing_mode")

        # 存储月流量数据用于排行
        port_monthly_data["$port"]="$monthly_total|$billing_mode"

        message+="$port_title
<pre>
本日流量情况(自昨日23:59起)
🟢 上行(入站): $(format_bytes $daily_input) | 下行(出站): $(format_bytes $daily_output) | 总计流量: $(format_bytes $daily_total)
本周流量情况(自上周日23:59起)
🟢 上行(入站): $(format_bytes $weekly_input) | 下行(出站): $(format_bytes $weekly_output) | 总计流量: $(format_bytes $weekly_total)
本月流量情况(自上月末23:59起)
🟢 上行(入站): $(format_bytes $monthly_input) | 下行(出站): $(format_bytes $monthly_output) | 总计流量: $(format_bytes $monthly_total)
</pre>

"
    done

    # 端口流量排行 - 使用非交互式函数
    message+="端口流量排行

<pre>
$(get_traffic_ranking_data)
</pre>
🔗 服务器: <i>${server_name}</i>"

    echo "$message"
}

# 格式化状态消息
format_status_message() {
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local server_name=$(jq -r '.notifications.telegram.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "$(hostname)")
    local notification_icon="🔔"
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="<b>${notification_icon} 端口流量犬 v1.0.0</b>
⏰ ${timestamp}
作者主页:<code>https://zywe.de</code>
项目开源:<code>https://github.com/zywe03/realm-xwPF</code>
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog

状态: 监控中 | 守护端口: ${port_count}个 | 今日总流量: ${daily_total}
────────────────────────────────────────
<pre>$(format_port_list "message")</pre>
────────────────────────────────────────
🔗 服务器: <i>${server_name}</i>"

    echo "$message"
}

# 发送Telegram消息
send_telegram_message() {
    local message="$1"

    # 直接从配置文件读取
    local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    local chat_id=$(jq -r '.notifications.telegram.chat_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")

    # 检查是否启用
    local enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")
    if [ "$enabled" != "true" ]; then
        log_notification "Telegram通知未启用"
        return 1
    fi

    # 检查必需变量
    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        log_notification "Telegram配置不完整"
        return 1
    fi

    # 基础URL编码
    local encoded_message=$(printf '%s' "$message" | sed 's/ /%20/g; s/\n/%0A/g')

    # 发送请求
    local response=$(curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${encoded_message}" \
        -d "parse_mode=HTML" \
        2>/dev/null)

    # 检查响应
    if echo "$response" | grep -q '"ok":true'; then
        log_notification "Telegram消息发送成功"
        return 0
    else
        log_notification "Telegram消息发送失败"
        return 1
    fi
}

# 记录通知日志
log_notification() {
    local message="$1"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local log_file="$CONFIG_DIR/logs/notification.log"

    mkdir -p "$(dirname "$log_file")"

    echo "[$timestamp] $message" >> "$log_file"

    # 日志轮转 (保持最近1000行)
    if [ -f "$log_file" ] && [ $(wc -l < "$log_file") -gt 1000 ]; then
        tail -n 500 "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"
    fi
}

# 主函数
main() {
    check_root
    check_dependencies
    init_config

    # 创建快捷命令
    create_shortcut_command

    # 如果有参数，处理命令行选项
    if [ $# -gt 0 ]; then
        case $1 in
            --check-deps)
                echo -e "${GREEN}依赖检查通过${NC}"
                exit 0
                ;;
            --version)
                echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
                echo -e "${GREEN}作者主页:${NC} https://zywe.de"
                echo -e "${GREEN}项目开源:${NC} https://github.com/zywe03/realm-xwPF"
                exit 0
                ;;
            --install)
                install_update_script
                exit 0
                ;;
            --uninstall)
                uninstall_script
                exit 0
                ;;
            --create-snapshot)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--create-snapshot 需要指定时间段参数${NC}"
                    echo "用法: $0 --create-snapshot [daily|weekly|monthly]"
                    exit 1
                fi
                create_traffic_snapshot "$2"
                exit 0
                ;;
            --send-snapshot)
                # 发送快照通知（调用外部模块）
                local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
                if [ -f "$telegram_script" ]; then
                    source "$telegram_script"
                    if telegram_send_snapshot; then
                        echo -e "${GREEN}快照通知发送成功${NC}"
                    else
                        echo -e "${RED}快照通知发送失败${NC}"
                    fi
                else
                    log_notification "Telegram通知模块不存在"
                    echo -e "${RED}Telegram通知模块不存在${NC}"
                fi
                exit 0
                ;;
            --send-status)
                # 发送状态通知（调用外部模块）
                local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
                if [ -f "$telegram_script" ]; then
                    source "$telegram_script"
                    if telegram_send_status; then
                        echo -e "${GREEN}状态通知发送成功${NC}"
                    else
                        echo -e "${RED}状态通知发送失败${NC}"
                    fi
                else
                    log_notification "Telegram通知模块不存在"
                    echo -e "${RED}Telegram通知模块不存在${NC}"
                fi
                exit 0
                ;;
            --reset-port)
                # 重置指定端口
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--reset-port 需要指定端口号${NC}"
                    exit 1
                fi
                auto_reset_port "$2"
                exit 0
                ;;
            *)
                echo -e "${YELLOW}用法: $0 [选项]${NC}"
                echo "选项:"
                echo "  --check-deps              检查依赖工具"
                echo "  --version                 显示版本信息"
                echo "  --install                 安装/更新脚本"
                echo "  --uninstall               卸载脚本"
                echo "  --create-snapshot PERIOD  创建流量快照 (daily|weekly|monthly)"
                echo "  --send-snapshot           发送Telegram快照通知"
                echo "  --send-status             发送Telegram状态通知"
                echo "  --reset-port PORT         重置指定端口流量"
                echo
                echo -e "${GREEN}快捷命令: $SHORTCUT_COMMAND${NC}"
                exit 1
                ;;
        esac
    fi

    # 显示主界面
    show_main_menu
}

# 脚本入口
main "$@"
