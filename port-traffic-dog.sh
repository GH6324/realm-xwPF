#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="1.3.3"
readonly SCRIPT_NAME="端口流量狗"
readonly SCRIPT_PATH="$(realpath "$0")"
readonly CONFIG_DIR="/etc/port-traffic-dog"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly LOG_FILE="$CONFIG_DIR/logs/traffic.log"
readonly TRAFFIC_DATA_FILE="$CONFIG_DIR/traffic_data.json"
# 整机流量伪端口：配置完全融入端口体系(配额/统计方式/重置走同一路径)，
# 唯一差异是计数源——/proc/net/dev 按网卡增量累加，无 nftables 规则
readonly VPS_PORT_ID="00"
readonly VPS_DATA_FILE="$CONFIG_DIR/vps_traffic.json"

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'
# 网络超时设置
readonly SHORT_CONNECT_TIMEOUT=5
readonly SHORT_MAX_TIMEOUT=7
readonly SCRIPT_URL="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh"
readonly SHORTCUT_COMMAND="dog"

detect_system() {
    # Ubuntu优先检测：避免Debian系统误判
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

install_missing_tools() {
    local missing_tools=("$@")
    local system_type=$(detect_system)
    local pkg_cmd
    case $system_type in
        "ubuntu") pkg_cmd="apt" ;;
        "debian") pkg_cmd="apt-get" ;;
        *)
            echo -e "${RED}不支持的系统类型: $system_type${NC}"
            echo "支持的系统: Ubuntu, Debian"
            echo "请手动安装: ${missing_tools[*]}"
            exit 1
            ;;
    esac

    echo -e "${YELLOW}检测到缺少工具: ${missing_tools[*]}${NC}"
    echo "正在自动安装..."

    $pkg_cmd update -qq
    for tool in "${missing_tools[@]}"; do
        case $tool in
            "nft") $pkg_cmd install -y nftables ;;
            "tc") $pkg_cmd install -y iproute2 ;;
            "ss") $pkg_cmd install -y iproute2 ;;
            "jq") $pkg_cmd install -y jq ;;
            "awk") $pkg_cmd install -y gawk ;;
            "bc") $pkg_cmd install -y bc ;;
            "cron")
                $pkg_cmd install -y cron
                systemctl enable cron 2>/dev/null || true
                systemctl start cron 2>/dev/null || true
                ;;
            *) $pkg_cmd install -y "$tool" ;;
        esac
    done

    echo -e "${GREEN}依赖工具安装完成${NC}"
}

check_dependencies() {
    local silent_mode=${1:-false}
    local missing_tools=()
    local required_tools=("nft" "tc" "ss" "jq" "awk" "bc" "unzip" "cron")

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

    setup_script_permissions
    setup_cron_environment
    # 重启后恢复定时任务
    local active_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${active_ports[@]}"; do
        setup_port_auto_reset_cron "$port" >/dev/null 2>&1 || true
    done
}

setup_script_permissions() {
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi

    if [ -f "/usr/local/bin/port-traffic-dog.sh" ]; then
        chmod +x "/usr/local/bin/port-traffic-dog.sh" 2>/dev/null || true
    fi
}

setup_cron_environment() {
    # cron环境PATH不完整，需要设置完整路径；@reboot 用于开机重建丢失的 nftables 监控规则
    local current_cron=$(crontab -l 2>/dev/null || true)
    local temp_cron=$(mktemp)
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > "$temp_cron"
    echo "$current_cron" | grep -v "^PATH=" | grep -v "# 端口流量狗开机自恢复" >> "$temp_cron" || true
    echo "@reboot $SCRIPT_PATH --restore-monitoring >/dev/null 2>&1  # 端口流量狗开机自恢复" >> "$temp_cron"
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限运行${NC}"
        exit 1
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR" "$(dirname "$LOG_FILE")"

    # 静默下载通知模块，避免影响主流程
    download_notification_modules >/dev/null 2>&1 || true

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "global": {
    "billing_mode": "double"
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
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    },
    "email": {
      "enabled": false,
      "status": "coming_soon"
    },
    "wecom": {
      "enabled": false,
      "webhook_url": "",
      "server_name": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    }
  }
}
EOF
    fi

    setup_exit_hooks
    # 端口组结构迁移：给存量 .ports 补 counter_key + rule_id（幂等，已迁移则跳过）
    migrate_ports_schema
    # 整机流量默认开启：幂等补建伪端口配置与采集 cron（全新安装即有，老版本升级自动迁移）
    ensure_vps_port_config
    # 与 cron 推送路径共用带锁的自愈入口，避免交互恢复和定时恢复并发把规则加双份
    ensure_monitoring_state
}

# 幂等创建整机流量伪端口条目与采集定时任务；已有配置不覆盖用户设置
ensure_vps_port_config() {
    if ! jq -e --arg vps "$VPS_PORT_ID" '.ports[$vps]' "$CONFIG_FILE" >/dev/null 2>&1; then
        update_config --arg vps "$VPS_PORT_ID" --arg now "$(get_beijing_time -Iseconds)" \
            '.ports[$vps] = {
                "name": "整机流量",
                "enabled": true,
                "billing_mode": "double",
                "bandwidth_limit": {"enabled": false, "rate": "unlimited"},
                "quota": {"enabled": true, "monthly_limit": "unlimited"},
                "remark": "",
                "created_at": $now
            }'
        log_notification "整机流量监控已启用"
    fi
    setup_vps_collect_cron
}

# 每分钟采集 cron：增量统计的窗口粒度，掉一条 cron 最多丢一分钟流量
setup_vps_collect_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗整机流量采集" > "$temp_cron" || true
    echo "* * * * * $SCRIPT_PATH --collect-vps-traffic >/dev/null 2>&1  # 端口流量狗整机流量采集" >> "$temp_cron"
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_vps_collect_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗整机流量采集" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

init_nftables() {
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    NFT_TABLE_CACHE=""
    # 推送/自愈路径每轮都进这里：表和三链都在位时直接返回，省掉 4 次注定失败的 nft add
    local existing
    existing=$(nft list table $family $table_name 2>/dev/null || true)
    if [ -n "$existing" ] \
        && grep -q "^[[:space:]]*chain input {" <<< "$existing" \
        && grep -q "^[[:space:]]*chain output {" <<< "$existing" \
        && grep -q "^[[:space:]]*chain forward {" <<< "$existing"; then
        NFT_TABLE_CACHE="$existing"
        return 0
    fi

    # 使用inet family支持IPv4/IPv6双栈
    nft add table $family $table_name 2>/dev/null || true
    nft add chain $family $table_name input { type filter hook input priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name output { type filter hook output priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name forward { type filter hook forward priority 0\; } 2>/dev/null || true
}


format_bytes() {
    local bytes=$1

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi

    if [ $bytes -ge 1073741824 ]; then
        local gb=$(echo "scale=2; $bytes / 1073741824" | bc)
        echo "${gb}GB"
    elif [ $bytes -ge 1048576 ]; then
        local mb=$(echo "scale=2; $bytes / 1048576" | bc)
        echo "${mb}MB"
    elif [ $bytes -ge 1024 ]; then
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

get_beijing_time() {
    TZ='Asia/Shanghai' date "$@"
}

update_config() {
    # 支持直接传 jq 表达式，或先传 jq 参数(--arg/--argjson...)再传表达式
    if [ "$1" = "--arg" ] || [ "$1" = "--argjson" ]; then
        local jq_args=("$@")
        local jq_expression="${jq_args[${#jq_args[@]}-1]}"
        unset "jq_args[$(( ${#jq_args[@]} - 1 ))]"
        jq "${jq_args[@]}" "$jq_expression" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    else
        jq "$1" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    fi
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# 端口展示名：伪端口 00 显示为整机流量，其余保持「端口 N」
get_port_display_name() {
    local port=$1
    if [ "$port" = "$VPS_PORT_ID" ]; then
        echo "整机流量"
    elif is_port_group "$port"; then
        echo "端口组 $port"
    else
        echo "端口 $port"
    fi
}

show_port_list() {
    # 设置类菜单（配额/限速/统计方式/重置）包含整机流量；删除菜单单独用过滤列表
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        return 1
    fi

    echo "当前监控的端口:"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). $(get_port_display_name "$port") $status_label"
    done
    echo "0. 返回上级菜单"
    return 0
}

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

# 读取用户选择：输入 0 跳转上级菜单，其余值去空格后写入指定变量
# 用法：read_user_choice "上级菜单函数名" "提示语" 结果变量名
# 返回 0=继续(值已写入), 1=已跳转上级菜单(调用方应 return)
read_user_choice() {
    local parent_menu="$1"
    local prompt="$2"
    local -n _ruc_choice=$3

    read -p "$prompt" _ruc_choice
    _ruc_choice=$(echo "$_ruc_choice" | tr -d ' ')
    if [ "$_ruc_choice" = "0" ]; then
        "$parent_menu"
        return 1
    fi
    return 0
}

parse_comma_separated_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra result_array <<< "$input"

    for i in "${!result_array[@]}"; do
        result_array[$i]=$(echo "${result_array[$i]}" | tr -d ' ')
    done
}

parse_port_range_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra PARTS <<< "$input"
    result_array=()

    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | tr -d ' ')

        if is_port_range "$part"; then
            # 端口段：100-200
            local start_port=$(echo "$part" | cut -d'-' -f1)
            local end_port=$(echo "$part" | cut -d'-' -f2)

            if [ "$start_port" -gt "$end_port" ]; then
                echo -e "${RED}错误：端口段 $part 起始端口大于结束端口${NC}"
                return 1
            fi

            if [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ] || [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
                echo -e "${RED}错误：端口段 $part 包含无效端口，必须在1-65535范围内${NC}"
                return 1
            fi

            result_array+=("$part")

        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -ge 1 ] && [ "$part" -le 65535 ]; then
                result_array+=("$part")
            else
                echo -e "${RED}错误：端口号 $part 无效，必须是1-65535之间的数字${NC}"
                return 1
            fi
        else
            echo -e "${RED}错误：无效的端口格式 $part${NC}"
            return 1
        fi
    done

    return 0
}

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


get_beijing_month_year() {
    local current_day=$(TZ='Asia/Shanghai' date +%d | sed 's/^0//')
    local current_month=$(TZ='Asia/Shanghai' date +%m | sed 's/^0//')
    local current_year=$(TZ='Asia/Shanghai' date +%Y)
    echo "$current_day $current_month $current_year"
}

# nft 全表快照缓存：一次 `nft list table` 喂给本轮所有读操作（计数器值/存在性/规则引用），
# 内核在此期间自行累加，快照内各读点数值一致反而是更好的一致性。
# 任何 nft 写操作后必须把 NFT_TABLE_CACHE 清空（写方负责），MISSING 是"表不存在"哨兵，
# 避免表不存在时每个端口重复 spawn。读函数运行在 $() 子壳里也没问题：各子壳各自惰性拉取
get_nft_table_dump() {
    if [ -z "${NFT_TABLE_CACHE:-}" ]; then
        local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
        local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
        NFT_TABLE_CACHE=$(nft list table $family $table_name 2>/dev/null || true)
        [ -z "$NFT_TABLE_CACHE" ] && NFT_TABLE_CACHE="MISSING"
    fi
    [ "$NFT_TABLE_CACHE" != "MISSING" ]
}

# 计数器对象是否已存在（基于表快照判断；表不在则视为不存在）
nft_counter_exists() {
    get_nft_table_dump || return 1
    grep -q "^[[:space:]]*counter $1 {" <<< "$NFT_TABLE_CACHE"
}

get_nftables_counter_data() {
    local port=$1
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    local input_bytes=0
    local output_bytes=0

    if [ "$port" = "$VPS_PORT_ID" ]; then
        # 整机伪端口：读 /proc/net/dev 增量累计的 monthly 原始值，按计费口径预乘，
        # 使下游 calculate_total_traffic 等端口逻辑零改动复用（双向=in 2x/out 2x，单向=out 1x）
        local vps_raw=($(get_vps_monthly_raw))
        local vps_rx=${vps_raw[0]:-0}
        local vps_tx=${vps_raw[1]:-0}
        if [ "$billing_mode" = "double" ]; then
            input_bytes=$((vps_rx * 2))
            output_bytes=$((vps_tx * 2))
        else
            input_bytes=0
            output_bytes=$vps_tx
        fi
        echo "$input_bytes $output_bytes"
        return 0
    fi

    # counter 名按 counter_key 派生，组内所有 selector 共享同一对 counter
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    # 一次 awk 从表快照解析两个计数器，兼容两种渲染：
    # nft≥1.0.x 单行 "packets N bytes M"（值在 $4），旧版分行 "bytes N bytes"（值在 $2）。
    # quota 块行首是 over/used，不会被误匹配。缺失计数器按 0，与旧逐个 nft list 语义一致
    if get_nft_table_dump; then
        local parsed
        parsed=$(printf '%s\n' "$NFT_TABLE_CACHE" | awk -v in_name="$in_name" -v out_name="$out_name" '
            $1 == "counter" { cur = $2; next }
            $1 == "quota" || $1 == "chain" || $1 == "table" || $1 == "set" || $1 == "map" { cur = ""; next }
            $1 == "}" { cur = ""; next }
            $1 == "packets" && $3 == "bytes" {
                if (cur == in_name) ib = $4
                else if (cur == out_name) ob = $4
                next
            }
            $1 == "bytes" && $3 == "bytes" {
                if (cur == in_name) ib = $2
                else if (cur == out_name) ob = $2
            }
            END {
                # 字符串透传，禁止数值化：print ib+0 会按 %.6g 输出科学计数法
                print (ib == "" ? 0 : ib), (ob == "" ? 0 : ob)
            }')
        read -r input_bytes output_bytes <<< "$parsed"
    fi

    # 单向口径与旧实现一致：不返回 in 计数器（单向模式下该计数器通常也不存在）
    [ "$billing_mode" != "double" ] && input_bytes=0
    echo "$input_bytes $output_bytes"
}



save_traffic_data() {
    local temp_file=$(mktemp)
    local active_ports=($(get_active_ports 2>/dev/null || true))

    # 整机流量走独立的 vps_traffic.json 生命周期（常驻，不随退出备份/恢复），
    # 这里跳过 00，避免往 nft 备份里写一条永远恢复不出计数器的假端口
    local ports_for_backup=()
    for port in "${active_ports[@]}"; do
        [ "$port" = "$VPS_PORT_ID" ] && continue
        ports_for_backup+=("$port")
    done

    if [ ${#ports_for_backup[@]} -eq 0 ]; then
        rm -f "$TRAFFIC_DATA_FILE"
        rm -f "$temp_file"
        return 0
    fi

    echo '{}' > "$temp_file"

    for port in "${ports_for_backup[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local current_input=${traffic_data[0]}
        local current_output=${traffic_data[1]}

        # 只备份有意义的数据
        if [ $current_input -gt 0 ] || [ $current_output -gt 0 ]; then
            jq ".\"$port\" = {\"input\": $current_input, \"output\": $current_output, \"backup_time\": \"$(get_beijing_time -Iseconds)\"}" \
                "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        fi
    done

    # 全零也照写空备份：重置后若保留旧备份，重启会把重置前的值恢复回来
    mv "$temp_file" "$TRAFFIC_DATA_FILE"
}

setup_exit_hooks() {
    # 进程退出时自动保存数据，避免重启丢失
    trap 'save_traffic_data_on_exit' EXIT
    trap 'save_traffic_data_on_exit; exit 1' INT TERM
}

save_traffic_data_on_exit() {
    save_traffic_data >/dev/null 2>&1
}

restore_monitoring_if_needed() {
    local active_ports=($(get_active_ports 2>/dev/null || true))

    # 只检查真实端口：00 的恢复检查判据永远为假，混进来会导致每次都触发全量规则重建
    local real_ports=()
    for port in "${active_ports[@]}"; do
        [ "$port" = "$VPS_PORT_ID" ] && continue
        real_ports+=("$port")
    done

    if [ ${#real_ports[@]} -eq 0 ]; then
        return 0
    fi

    # 检查计数器与规则是否都在：规则被单独清掉（计数器还在）时计数会静默停止。
    # 全部判据取自一次表快照（0 额外 spawn），表整体不在时视为全部丢失
    local need_restore=false
    if ! get_nft_table_dump; then
        need_restore=true
    else
        local port
        for port in "${real_ports[@]}"; do
            local out_name=$(get_counter_name "$(get_counter_key "$port")" out)

            if ! grep -q "^[[:space:]]*counter $out_name {" <<< "$NFT_TABLE_CACHE" \
                || ! grep -q "counter name \"$out_name\"" <<< "$NFT_TABLE_CACHE"; then
                need_restore=true
                break
            fi
        done
    fi

    if [ "$need_restore" = "true" ]; then
        restore_traffic_data_from_backup
        restore_all_monitoring_rules >/dev/null 2>&1 || true
    fi
}

restore_traffic_data_from_backup() {
    if [ ! -f "$TRAFFIC_DATA_FILE" ]; then
        return 0
    fi

    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local backup_ports=($(jq -r 'keys[]' "$TRAFFIC_DATA_FILE" 2>/dev/null || true))

    for port in "${backup_ports[@]}"; do
        # 配置里已删除的端口不恢复，避免留孤儿计数器；00 无 nft 计数器不参与
        [ "$port" = "$VPS_PORT_ID" ] && continue
        jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1 || continue

        local backup_input=$(jq -r ".\"$port\".input // 0" "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")
        local backup_output=$(jq -r ".\"$port\".output // 0" "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")

        if [ $backup_input -gt 0 ] || [ $backup_output -gt 0 ]; then
            restore_counter_value "$port" "$backup_input" "$backup_output"
        fi
    done

    # 恢复完成后删除备份文件
    rm -f "$TRAFFIC_DATA_FILE"
}

restore_counter_value() {
    local port=$1
    local target_input=$2
    local target_output=$3

    # 整机伪端口无计数器，数据常驻 vps_traffic.json 无需恢复
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    # 计数器还在就保留内核里的实时值（比备份新）；缺失才用备份值重建。
    # 语法用无花括号形式：nftables 0.9.3(Ubuntu 20.04) 不认带花括号的初值写法
    if [ "$billing_mode" = "double" ]; then
        if ! nft_counter_exists "$in_name" \
            && ! nft add counter $family $table_name "$in_name" packets 0 bytes $target_input 2>/dev/null; then
            log_notification "恢复计数器 $in_name 失败 (端口 $port)"
        fi
    fi
    if ! nft_counter_exists "$out_name" \
        && ! nft add counter $family $table_name "$out_name" packets 0 bytes $target_output 2>/dev/null; then
        log_notification "恢复计数器 $out_name 失败 (端口 $port)"
    fi
}

restore_all_monitoring_rules() {
    local active_ports=($(get_active_ports))

    for port in "${active_ports[@]}"; do
        # 整机流量无 nftables 规则/配额，只恢复限速与重置 cron
        if [ "$port" = "$VPS_PORT_ID" ]; then
            local vps_limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
            local vps_rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
            if [ "$vps_limit_enabled" = "true" ] && [ "$vps_rate_limit" != "unlimited" ]; then
                local vps_tc_limit=$(convert_bandwidth_to_tc "$vps_rate_limit")
                if [ -n "$vps_tc_limit" ]; then
                    apply_tc_limit "$port" "$vps_tc_limit" || true
                fi
            fi
            setup_port_auto_reset_cron "$port"
            continue
        fi

        add_nftables_rules "$port"

        # 恢复配额限制
        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$monthly_limit"
        fi

        # 恢复带宽限制
        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit" || true
            fi
        fi

        setup_port_auto_reset_cron "$port"
    done
}

calculate_total_traffic() {
    local input_bytes=$1
    local output_bytes=$2
    local billing_mode=${3:-"double"}
    case $billing_mode in
        "double")
            # 双向统计：input + output（计数器已在规则层面×2）
            echo $((input_bytes + output_bytes))
            ;;
        "single"|*)
            # 单向统计：仅 output
            echo $output_bytes
            ;;
    esac
}


get_port_status_label() {
    local port=$1
    local port_config=$(jq -r ".ports.\"$port\"" "$CONFIG_FILE" 2>/dev/null)

    # 一次 @tsv 取齐全部字段（null 端口行 jq 会输出全默认值行），替代逐字段 8 次 jq。
    # tab 是 IFS 空白：read 会合并连续 tab、吞掉空字段——remark 是唯一可为空的字段，
    # 空时放 0x01 占位、读回后还原。reset_day 缺失/null 统一为 "null"，与原逐字段语义一致
    local fields
    fields=$(printf '%s' "$port_config" | jq -r '[
        "S",
        (.remark // "" | if . == "" then "\u0001" else . end),
        .billing_mode // "double",
        (.bandwidth_limit.enabled // false),
        .bandwidth_limit.rate // "unlimited",
        (.quota.enabled // true),
        .quota.monthly_limit // "unlimited",
        (.quota.reset_day // "null")
    ] | @tsv' 2>/dev/null) || fields=""

    local remark billing_mode limit_enabled rate_limit quota_enabled monthly_limit reset_day_raw
    if [ -n "$fields" ]; then
        IFS=$'\t' read -r _sentinel remark billing_mode limit_enabled rate_limit quota_enabled monthly_limit reset_day_raw <<< "$fields"
        [ "$remark" = $'\x01' ] && remark=""
    else
        remark=""; billing_mode="double"; limit_enabled="false"
        rate_limit="unlimited"; quota_enabled="true"; monthly_limit="unlimited"; reset_day_raw="null"
    fi
    local reset_day="null"
    
    # 有流量限额时，获取重置日期（null表示用户取消了自动重置）
    if [ "$monthly_limit" != "unlimited" ] && [ "$reset_day_raw" != "null" ]; then
        reset_day="${reset_day_raw:-1}"  # 未配置时默认为1
    fi

    local status_tags=()

    if [ -n "$remark" ] && [ "$remark" != "null" ] && [ "$remark" != "" ]; then
        status_tags+=("[备注:$remark]")
    fi

    if [ "$quota_enabled" = "true" ]; then
        if [ "$monthly_limit" != "unlimited" ]; then
            local current_usage=$(get_port_monthly_usage "$port")
            local limit_bytes=$(parse_size_to_bytes "$monthly_limit")

            local quota_display="$monthly_limit"
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向${quota_display}]")
            else
                status_tags+=("[单向${quota_display}]")
            fi

            # 只有配置了reset_day时才显示重置日期信息
            if [ "$reset_day" != "null" ]; then
                local time_info=($(get_beijing_month_year))
                local current_day=${time_info[0]}
                local current_month=${time_info[1]}
                local next_month=$current_month

                if [ $current_day -ge $reset_day ]; then
                    next_month=$((current_month + 1))
                    if [ $next_month -gt 12 ]; then
                        next_month=1
                    fi
                fi

                status_tags+=("[${next_month}月${reset_day}日重置]")
            fi

            if [ -n "$limit_bytes" ] && [ "$limit_bytes" -gt 0 ] && [ "$current_usage" -ge "$limit_bytes" ]; then
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

    if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
        status_tags+=("[限制带宽${rate_limit}]")
    fi

    if [ ${#status_tags[@]} -gt 0 ]; then
        printf '%s' "${status_tags[@]}"
        echo
    fi
}

get_port_monthly_usage() {
    local port=$1
    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode"
}

validate_bandwidth() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+kbps$ ]] || [[ "$lower_input" =~ ^[0-9]+mbps$ ]] || [[ "$lower_input" =~ ^[0-9]+gbps$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_quota() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+(mb|gb|tb|m|g|t)$ ]]; then
        return 0
    else
        return 1
    fi
}

parse_size_to_bytes() {
    local size_str=$1
    local number=$(echo "$size_str" | grep -o '^[0-9]\+' || true)
    local unit=$(echo "$size_str" | grep -o '[A-Za-z]\+$' | tr '[:lower:]' '[:upper:]' || true)

    [ -z "$number" ] && echo "0" && return 0

    case $unit in
        "MB"|"M") echo $((number * 1048576)) ;;
        "GB"|"G") echo $((number * 1073741824)) ;;
        "TB"|"T") echo $((number * 1099511627776)) ;;
        *) echo "0" ;;
    esac
}


get_active_ports() {
    jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n
}

# 排除整机伪端口后的真实端口列表：header 计数、端口总流量、删除菜单都用它
get_monitored_ports() {
    jq -r --arg vps "$VPS_PORT_ID" '.ports | keys[] | select(. != $vps)' "$CONFIG_FILE" 2>/dev/null | sort -n
}

# 整机流量监控的网卡集合：与限速同一排除列表，再排除 ifb——
# ifb 是入向限速的镜像设备，计数器与物理网卡重复，计入会把入向流量算成两倍
# 物理网卡计数天然已含容器/隧道流量（最终都从物理口出去），逐网卡独立计数，不做聚合求和
list_vps_interfaces() {
    list_shaping_interfaces | grep -v "^ifb" || true
}

# timeout 传数字则限时拿锁（秒），超时返回 1；不传则阻塞等待（重置路径必须拿到锁）
vps_lock() {
    local timeout="${1:-}"
    mkdir -p "$CONFIG_DIR"
    exec 8>"$CONFIG_DIR/.vps.lock"
    if [ -n "$timeout" ]; then
        flock -w "$timeout" 8
    else
        flock 8
    fi
}

vps_unlock() {
    flock -u 8 2>/dev/null || true
    # 裸 exec 只带重定向时，所有重定向会永久作用于当前 shell：
    # 这里若写 exec 8>&- 2>/dev/null，fd2 将被永久重定向到 /dev/null，
    # 之后所有 read -p 提示（走 stderr）全部消失
    exec 8>&- || true
}

vps_read_data() {
    cat "$VPS_DATA_FILE" 2>/dev/null || echo '{}'
}

# 原子写回整机流量数据（mktemp + mv，与 save_traffic_data 同模式）
vps_write_data() {
    local data="$1"
    local temp_file=$(mktemp)
    printf '%s' "$data" > "$temp_file"
    mv "$temp_file" "$VPS_DATA_FILE"
}

# 单网卡采集一次原始计数；网卡消失返回空
vps_read_iface_raw() {
    local iface=$1
    awk -v dev="$iface:" '$1 == dev {print $2, $10}' /proc/net/dev 2>/dev/null
}

# 采集引擎：读全部监控网卡 → 按网卡算 delta → 累加进 monthly。
# lifetime_raw 永不清零（delta 基准），monthly 随重置日清零，二者严格分离。
# 校验优先级：文件不存在(首次,只落基准) > boot_id 变化(重启,current即delta) > 计数回退(NIC重建) > 正常增量
collect_vps_traffic() {
    # cron 每分钟跑一次，全新机器 jq 可能尚未安装：静默跳过，等交互初始化补装
    command -v jq >/dev/null 2>&1 || return 0

    local ifaces=($(list_vps_interfaces 2>/dev/null || true))
    if [ ${#ifaces[@]} -eq 0 ]; then
        return 0
    fi

    local current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
    local now=$(get_beijing_time +%s)

    # 限时 2 秒拿锁：撞上 cron/推送持锁时不阻塞交互，放弃本轮（cron 下轮补采）
    vps_lock 2 || return 0

    local data=$(vps_read_data)
    local last_boot_id=$(printf '%s' "$data" | jq -r '.lifetime_raw.boot_id // ""' 2>/dev/null || echo "")
    local file_exists=false
    [ -f "$VPS_DATA_FILE" ] && file_exists=true

    local new_data="$data"
    local iface raw_line current_rx current_tx last_rx last_tx delta_rx delta_tx

    for iface in "${ifaces[@]}"; do
        raw_line=$(vps_read_iface_raw "$iface")
        # 网卡此刻消失（热插拔中）：跳过，不动它的基准与月度数据
        [ -z "$raw_line" ] && continue

        current_rx=$(echo "$raw_line" | awk '{print $1}')
        current_tx=$(echo "$raw_line" | awk '{print $2}')
        [[ "$current_rx" =~ ^[0-9]+$ ]] || continue
        [[ "$current_tx" =~ ^[0-9]+$ ]] || continue

        last_rx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        last_tx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)

        if [ "$file_exists" = "false" ]; then
            # 首次采集：只落基准，历史流量不计入（从启用当刻起算）
            delta_rx=0
            delta_tx=0
        elif [ "$last_boot_id" != "$current_boot_id" ]; then
            # 文件在但内核变了 = 宿主机重启：开机以来的计数全部计入本月
            delta_rx=$current_rx
            delta_tx=$current_tx
        elif [ "$current_rx" -lt "$last_rx" ] || [ "$current_tx" -lt "$last_tx" ]; then
            # 未重启但计数回退：网卡被重建/重置（云厂商NIC重建等），按当前值校准并留痕
            log_notification "整机流量：网卡 $iface 计数器未重启发生回退（疑似NIC重建），已按当前值校准"
            delta_rx=$current_rx
            delta_tx=$current_tx
        else
            delta_rx=$((current_rx - last_rx))
            delta_tx=$((current_tx - last_tx))
        fi

        new_data=$(printf '%s' "$new_data" | jq -c --arg i "$iface" \
            --argjson lrx "$current_rx" --argjson ltx "$current_tx" \
            --argjson drx "$delta_rx" --argjson dtx "$delta_tx" '
            .lifetime_raw.ifaces[$i] = {"rx_bytes": $lrx, "tx_bytes": $ltx} |
            .monthly.ifaces[$i] = ((.monthly.ifaces[$i] // {"rx_bytes": 0, "tx_bytes": 0}) |
                .rx_bytes += $drx | .tx_bytes += $dtx)' 2>/dev/null) || new_data="$data"
    done

    new_data=$(printf '%s' "$new_data" | jq -c --arg boot "$current_boot_id" --argjson now "$now" '
        .lifetime_raw.boot_id = $boot |
        .lifetime_raw.updated_at = $now |
        .monthly.reset_at = (.monthly.reset_at // $now)' 2>/dev/null) || new_data=""

    # jq 全程成功才落盘：失败宁可不写也不写坏数据（读端走原子mv不会读到半截）
    if [ -n "$new_data" ]; then
        vps_write_data "$new_data"
    else
        log_notification "整机流量：增量计算失败，本轮数据未落盘"
    fi

    vps_unlock
}

# 整机月度合计（原始 rx/tx，未乘计费倍率）：返回 "rx tx"
get_vps_monthly_raw() {
    local data=$(vps_read_data)
    local total_rx=$(printf '%s' "$data" | jq -r '[.monthly.ifaces[]?.rx_bytes] | add // 0' 2>/dev/null || echo 0)
    local total_tx=$(printf '%s' "$data" | jq -r '[.monthly.ifaces[]?.tx_bytes] | add // 0' 2>/dev/null || echo 0)
    [[ "$total_rx" =~ ^[0-9]+$ ]] || total_rx=0
    [[ "$total_tx" =~ ^[0-9]+$ ]] || total_tx=0
    echo "$total_rx $total_tx"
}

# 整机在用网卡名列表（展示用）
get_vps_interface_names() {
    local data=$(vps_read_data)
    printf '%s' "$data" | jq -r '.monthly.ifaces // {} | keys[]' 2>/dev/null || true
}

is_port_range() {
    local port=$1
    [[ "$port" =~ ^[0-9]+-[0-9]+$ ]]
}

# 端口组 key 含逗号；单端口与端口段不含。三类监控单元统一走 rule_id 派生，不再用此分支区分命名
is_port_group() {
    [[ "$1" == *,* ]]
}

# 单端口段「100-200」拆出起止端口；非法格式返回 1
split_port_range() {
    local range=$1 start end
    IFS='-' read -r start end <<< "$range"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 1
    echo "$start $end"
}

# 校验单个端口/端口段字符串：1-65535，段起始≤结束。合法返回 0 并回显，非法返回 1
validate_port_spec() {
    local spec=$1
    if is_port_range "$spec"; then
        local se
        se=$(split_port_range "$spec") || { echo -e "${RED}错误：无效端口段 $spec${NC}" >&2; return 1; }
        local start=${se% *}
        local end=${se#* }
        if [ "$start" -gt "$end" ]; then
            echo -e "${RED}错误：端口段 $spec 起始大于结束${NC}" >&2; return 1
        fi
        if [ "$start" -lt 1 ] || [ "$end" -gt 65535 ]; then
            echo -e "${RED}错误：端口段 $spec 越界，需在1-65535${NC}" >&2; return 1
        fi
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        if [ "$spec" -lt 1 ] || [ "$spec" -gt 65535 ]; then
            echo -e "${RED}错误：端口号 $spec 无效，需1-65535${NC}" >&2; return 1
        fi
    else
        echo -e "${RED}错误：无效端口格式 $spec${NC}" >&2; return 1
    fi
    return 0
}

# 端口区间两两相交检测：把各单元成员展开为 (start,end) 后两两比较，重叠即报错返回 1。
# 同时服务两处：单次输入的内部校验（含组内成员重叠，443,443-500 会被拦下），
# 以及「新监控项 vs 已监控项」的跨配置校验（防止同一端口被两套规则重复统计）
check_units_overlap() {
    local intervals=() uk s e
    for uk in "$@"; do
        while read -r s e; do
            [ -n "$s" ] && intervals+=("$s $e")
        done < <(expand_unit_intervals "$uk")
    done

    local i j sa ea sb eb
    for ((i=0; i<${#intervals[@]}; i++)); do
        sa=${intervals[$i]% *}
        ea=${intervals[$i]#* }
        for ((j=i+1; j<${#intervals[@]}; j++)); do
            sb=${intervals[$j]% *}
            eb=${intervals[$j]#* }
            # 区间相交：sa<=eb && sb<=ea
            if [ "$sa" -le "$eb" ] && [ "$sb" -le "$ea" ]; then
                echo -e "${RED}错误：端口区间 $sa-$ea 与 $sb-$eb 重叠${NC}" >&2
                return 1
            fi
        done
    done
    return 0
}

# 规范化一个监控单元为 key：成员校验、去前导零、去重排序后用逗号拼接
# 单成员直接返回规范 spec（单端口/端口段常规书写不变，老 key 零变化）
normalize_unit_key() {
    local input=$1
    # 去空格
    input=$(printf '%s' "$input" | tr -d ' ')

    local members=()
    IFS=',' read -ra members <<< "$input"
    # 空成员即报错（如 443,,80 的中间空项），不静默容忍
    local -A seen=()
    local clean=()
    local m
    for m in "${members[@]}"; do
        [ -z "$m" ] && { echo -e "${RED}错误：空端口项${NC}" >&2; return 1; }
        validate_port_spec "$m" || return 1
        # 去前导零（0443→443）：同一端口的不同写法必须归并为同一 key，
        # 否则「0443」与「443」会被当成两个监控项，同一端口统计/限速两份
        if is_port_range "$m"; then
            local se start end
            se=$(split_port_range "$m")
            start=$((10#${se% *}))
            end=$((10#${se#* }))
            m="$start-$end"
        else
            m=$((10#$m))
        fi
        if [ -z "${seen[$m]:-}" ]; then
            seen[$m]=1
            clean+=("$m")
        fi
    done
    if [ ${#clean[@]} -eq 0 ]; then
        echo -e "${RED}错误：空单元${NC}" >&2; return 1
    fi
    if [ ${#clean[@]} -eq 1 ]; then
        echo "${clean[0]}"
        return 0
    fi
    # 多成员：排序去重后拼接
    local sorted
    sorted=$(printf '%s\n' "${clean[@]}" | awk -F'-' '
        { if (NF==2) k=$1; else k=$0; print k"\t"$0 }
    ' | sort -n -k1,1 | cut -f2- | paste -sd,)
    echo "$sorted"
}

# 把单元 key 展开为 (start end) 区间数组，供重叠检测与规则展开
# 单端口「443」→(443 443)；端口段「100-200」→(100 200)；组「443,80-90」→(443 443)(80 90)
expand_unit_intervals() {
    local key=$1
    local members=()
    IFS=',' read -ra members <<< "$key"
    local m se start end
    for m in "${members[@]}"; do
        [ -z "$m" ] && continue
        if is_port_range "$m"; then
            se=$(split_port_range "$m") || continue
            echo "${se% *} ${se#* }"
        else
            echo "$m $m"
        fi
    done
}

# 解析整行输入为监控单元 key 数组
# 语法：; 拆单元，, 拆组成员，- 表端口段
# 校验：空项、非法端口、跨单元区间重叠（含组内成员重叠）一律报错返回 1
parse_monitor_units() {
    local input=$1
    local -n _pmu_units=$2

    _pmu_units=()
    # 先按 ; 拆单元。用 mapfile -d 保留尾分隔符产生的空字段，
    # read -ra 会吞掉尾部空字段，导致 443; 被当成合法单单元
    local raw_units=()
    mapfile -d ';' -t raw_units <<< "$input"
    # here-string 给末尾元素带换行，mapfile 会一并收进数组，逐元素去掉
    local i
    for ((i=0; i<${#raw_units[@]}; i++)); do
        raw_units[$i]="${raw_units[$i]%$'\n'}"
    done

    local unit_keys=()
    local ru
    for ru in "${raw_units[@]}"; do
        # 空单元（如 443; 的尾分号或 ; 开头）报错，不静默容忍
        if [ -z "$(printf '%s' "$ru" | tr -d ' ')" ]; then
            echo -e "${RED}错误：空监控项${NC}" >&2; return 1
        fi
        local key
        key=$(normalize_unit_key "$ru") || return 1
        unit_keys+=("$key")
    done

    if [ ${#unit_keys[@]} -eq 0 ]; then
        echo -e "${RED}错误：没有有效的监控项${NC}" >&2; return 1
    fi

    # 跨单元 key 重复直接报错（同一规范 key 出现两次即重复端口）
    local -A uk_seen=()
    local k
    for k in "${unit_keys[@]}"; do
        if [ -n "${uk_seen[$k]:-}" ]; then
            echo -e "${RED}错误：监控项 $k 重复${NC}" >&2; return 1
        fi
        uk_seen[$k]=1
    done

    # 区间重叠检测（含组内成员重叠，443,443-500 会被同一机制拦下）
    check_units_overlap "${unit_keys[@]}" || return 1

    _pmu_units=("${unit_keys[@]}")
    return 0
}

# 从单元 key 派生 selectors 数组（成员原样，单端口/端口段/组统一）
# 整机伪端口 00 返回空数组（计数源不同，不参与 nft/tc）
port_selectors() {
    local key=$1
    [ "$key" = "$VPS_PORT_ID" ] && return 0
    local members=()
    IFS=',' read -ra members <<< "$key"
    local m
    for m in "${members[@]}"; do
        [ -n "$m" ] && echo "$m"
    done
}

# key 的稳定哈希：字符 ASCII 加权和，落进 [1, 0x1FFF]
# 组 rule_id 只用此区间，与端口段偏移区间 [0x2000, 0xFFFF] 永不重叠（端口段 class 不撞组）；
# 与单端口端口号 [1, 65535] 理论可重叠，assign 时按存量 rule_id 去重，不会撞已配置单元
hash_port_key() {
    local key=$1 salt=${2:-0}
    local h=$salt i ch
    local chars
    chars=$(printf '%s' "$key")
    for ((i=0; i<${#chars}; i++)); do
        ch=$(printf '%d' "'${chars:$i:1}")
        h=$(( (h*31 + ch) % 0x2000 ))
    done
    # 保证落在 1-0x1FFF，避开 0
    echo $(( h == 0 ? 1 : h ))
}

# 为端口组分配全局唯一 rule_id（数值，用于 tc class）：
# 哈希后扫描现有所有 .ports 的 rule_id，冲突则 salt 递增重哈希至唯一。
# 单端口/端口段不走此函数（确定性派生），故组的哈希只与存量组的哈希去重
assign_group_rule_id() {
    local key=$1
    local salt=0 id
    local existing
    existing=$(jq -r '[.ports[].rule_id] | map(. // empty)' "$CONFIG_FILE" 2>/dev/null || echo '[]')
    while :; do
        id=$(hash_port_key "$key" "$salt")
        # id 不在已用集合里则采用：index 返回 null 即未占用
        if printf '%s' "$existing" | jq -e --argjson id "$id" 'index($id) == null' >/dev/null 2>&1; then
            echo "$id"
            return 0
        fi
        salt=$((salt + 1))
        # 极端兜底：8192(0x2000) 次后仍冲突（几乎不可能，组数量个位数且空间有8192槽），取+1偏移。
        # 注意必须写十进制：bash 的 [ ] 不认十六进制字面量，写 0x2000 会恒为假变成死循环
        if [ $salt -ge 8192 ]; then
            id=$(hash_port_key "$key" 1)
            echo "$id"
            return 0
        fi
    done
}

# counter_key 派生（counter/quota 名后缀，字符串）：
# 单端口 = 端口号；端口段 = key 里 - 换 _ ；组 = g<哈希>。
# 单端口/端口段的 counter_key 与存量 counter 名完全一致——存量零迁移、计数器值不丢
derive_counter_key() {
    local key=$1
    if is_port_group "$key"; then
        echo "g$(hash_port_key "$key")"
    elif is_port_range "$key"; then
        printf '%s' "$key" | tr '-' '_'
    else
        echo "$key"
    fi
}

# rule_id 派生（tc class 数值，直接作为 classid minor 的 hex）：
# 单端口 = 端口号；端口段 = 0x2000 + mark%0xE000（与存量 generate_tc_class_id 完全一致）；
# 组 = 哈希（避开存量，assign 时去重）。单端口/端口段存量 class 零迁移
derive_rule_id() {
    local key=$1
    if is_port_group "$key"; then
        assign_group_rule_id "$key"
    elif is_port_range "$key"; then
        local mark=$(generate_port_range_mark "$key")
        echo $(( 0x2000 + mark % 0xE000 ))
    else
        echo "$key"
    fi
}

# 统一派生：counter/quota 名用 counter_key，class id 用 rule_id
get_counter_name() {  # $1=counter_key $2=in|out
    echo "port_$1_$2"
}
get_quota_name() {    # $1=counter_key
    echo "port_${1}_quota"
}
get_tc_class_id() {   # $1=rule_id（数值）
    echo "1:$(printf '%x' "$1")"
}

# 取某监控单元的 counter_key（配置已迁移后直接读；缺失则实时派生）
get_counter_key() {
    local key=$1
    local ck
    ck=$(jq -r --arg k "$key" '.ports[$k].counter_key // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$ck" ] || [ "$ck" = "null" ]; then
        ck=$(derive_counter_key "$key")
    fi
    echo "$ck"
}

# 取某监控单元的 rule_id（配置已迁移后直接读；缺失则实时派生）
get_rule_id() {
    local key=$1
    local rid
    rid=$(jq -r --arg k "$key" '.ports[$k].rule_id // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$rid" ] || [ "$rid" = "null" ]; then
        rid=$(derive_rule_id "$key")
    fi
    echo "$rid"
}

# 一次性配置迁移：给存量 .ports 补 counter_key + rule_id
# 单端口/端口段的 counter_key/rule_id 与存量派生完全一致——迁移后 counter 名与 class id
# 都不变，存量 nft/tc 规则无需重建，计数器累计值不丢。组才走哈希派生。
migrate_ports_schema() {
    [ -f "$CONFIG_FILE" ] || return 0
    # 任一条目缺 counter_key 即视为需要迁移（幂等：已迁移则跳过）
    local need
    need=$(jq -r '[.ports | to_entries[] | select((.value.counter_key // null) == null)] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [ "$need" -eq 0 ] && return 0

    # mapfile -t 只去 \n：config 文件若带 CRLF（跨平台编辑常见），key 尾的 \r 会破坏
    # 字符串比较与 jq --arg 传参，统一 tr -d '\r' 清洗
    local keys=()
    mapfile -t keys < <(jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | tr -d '\r' || true)

    local k
    for k in "${keys[@]}"; do
        k=${k%$'\r'}
        local ck rid
        ck=$(derive_counter_key "$k")
        rid=$(derive_rule_id "$k")
        update_config --arg k "$k" --arg ck "$ck" --argjson rid "$rid" \
            '.ports[$k].counter_key = $ck | .ports[$k].rule_id = $rid'
        # 写一条后 existing 集合已变，下一条组派生自然读到新值
    done
    log_notification "配置已迁移到监控单元结构（counter_key + rule_id）"
}

generate_port_range_mark() {
    local port_range=$1
    local start_port=$(echo "$port_range" | cut -d'-' -f1)
    local end_port=$(echo "$port_range" | cut -d'-' -f2)
    # 确定性算法：避免不同端口段产生相同标记
    echo $(( (start_port * 1000 + end_port) % 65536 ))
}

# burst速率突发计算：突发窗口取10ms——过大的burst会以网卡线速瞬间打出，
# 把排队压力转移给下游设备；低速档用4*MTU保底，高速档用64KB封顶
calculate_tc_burst() {
    local base_rate_kbps=$1
    local rate_bytes_per_sec=$((base_rate_kbps * 1000 / 8))
    local burst_10ms=$((rate_bytes_per_sec / 100))        # 10ms缓冲
    local min_burst=$((4 * 1500))                          # 4个以太网MTU保底(约6KB)
    local max_burst=$((64 * 1024))                         # 64KB最大突发上限

    local burst_calc=$burst_10ms
    if [ $burst_calc -lt $min_burst ]; then
        burst_calc=$min_burst
    elif [ $burst_calc -gt $max_burst ]; then
        burst_calc=$max_burst
    fi
    echo $burst_calc
}

# 协议开销补偿：tc 按含帧头/包头的线速计数，用户测速只算有效载荷，
# 不补偿时实测会比配置档位低约10%
calculate_effective_rate_kbps() {
    local target_rate_kbps=$1
    echo $(( target_rate_kbps * 110 / 100 ))
}

format_tc_burst() {
    local burst_bytes=$1
    if [ $burst_bytes -lt 1024 ]; then
        echo "${burst_bytes}"
    elif [ $burst_bytes -lt 1048576 ]; then
        echo "$((burst_bytes / 1024))k"
    else
        echo "$((burst_bytes / 1048576))m"
    fi
}

parse_tc_rate_to_kbps() {
    local total_limit=$1
    if [[ "$total_limit" =~ gbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/gbit$//')
        echo $((rate * 1000000))
    elif [[ "$total_limit" =~ mbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/mbit$//')
        echo $((rate * 1000))
    else
        echo $(echo "$total_limit" | sed 's/kbit$//')
    fi
}

# 将用户输入的带宽值(Kbps/Mbps/Gbps)转换为TC格式(kbit/mbit/gbit)
convert_bandwidth_to_tc() {
    local rate="$1"
    local lower=$(echo "$rate" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" =~ kbps$ ]]; then
        echo "${lower/%kbps/kbit}"
    elif [[ "$lower" =~ mbps$ ]]; then
        echo "${lower/%mbps/mbit}"
    elif [[ "$lower" =~ gbps$ ]]; then
        echo "${lower/%gbps/gbit}"
    fi
}

# tc classid 统一入口：按监控单元 rule_id 派生，单端口/端口段/组同构
# 单端口/端口段 rule_id 与存量派生一致，存量 class 零迁移；组用哈希 rule_id
generate_tc_class_id() {
    local port=$1
    local rule_id=$(get_rule_id "$port")
    get_tc_class_id "$rule_id"
}

get_daily_total_traffic() {
    local total_bytes=0
    local ports=($(get_monitored_ports))
    for port in "${ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local port_total=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        total_bytes=$(( total_bytes + port_total ))
    done
    format_bytes $total_bytes
}

# 整机流量独立展示行（逐网卡一行，多网卡时 tag 相同——配额/统计方式是整机统一配置）。
# 字段/分隔符/颜色与端口行逐项对齐，三格式同源生成
format_vps_traffic_line() {
    local format_type="$1"
    local ifaces=($(get_vps_interface_names))
    if [ ${#ifaces[@]} -eq 0 ]; then
        return 0
    fi

    local billing_mode=$(jq -r ".ports.\"$VPS_PORT_ID\".billing_mode // \"double\"" "$CONFIG_FILE")
    local status_label=$(get_port_status_label "$VPS_PORT_ID")
    local data=$(vps_read_data)
    local result=""

    for iface in "${ifaces[@]}"; do
        local m_rx=$(printf '%s' "$data" | jq -r --arg i "$iface" '.monthly.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        local m_tx=$(printf '%s' "$data" | jq -r --arg i "$iface" '.monthly.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$m_rx" =~ ^[0-9]+$ ]] || m_rx=0
        [[ "$m_tx" =~ ^[0-9]+$ ]] || m_tx=0

        # 与端口行同口径：按整机计费模式预乘后展示
        local input_bytes=0
        local output_bytes=0
        if [ "$billing_mode" = "double" ]; then
            input_bytes=$((m_rx * 2))
            output_bytes=$((m_tx * 2))
        else
            output_bytes=$m_tx
        fi
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local input_formatted=$(format_bytes $input_bytes)
        local output_formatted=$(format_bytes $output_bytes)

        if [ "$format_type" = "display" ]; then
            result+="整机总流量:${GREEN}${iface}${NC} | 总流量:${GREEN}$total_formatted${NC} | 上行(入站): ${GREEN}$input_formatted${NC} | 下行(出站):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}
"
        elif [ "$format_type" = "markdown" ]; then
            result+="**整机总流量**:**${iface}** | **总流量**:**${total_formatted}** | **上行**:**${input_formatted}** | **下行**:**${output_formatted}** | ${status_label}
"
        else
            result+="整机总流量:${iface} | 总流量:${total_formatted} | 上行(入站): ${input_formatted} | 下行(出站):${output_formatted} | ${status_label}
"
        fi
    done

    printf '%s' "$result"
}

format_port_list() {
    local format_type="$1"
    local active_ports=($(get_monitored_ports))
    local result=""

    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local output_formatted=$(format_bytes $output_bytes)
        local status_label=$(get_port_status_label "$port")

        local input_formatted=$(format_bytes $input_bytes)


        if [ "$format_type" = "display" ]; then
            echo -e "${GREEN}$(get_port_display_name "$port")${NC} | 总流量:${GREEN}$total_formatted${NC} | 上行(入站): ${GREEN}$input_formatted${NC} | 下行(出站):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}"
        elif [ "$format_type" = "markdown" ]; then
            result+="> **$(get_port_display_name "$port")** | 总流量:**${total_formatted}** | 上行:**${input_formatted}** | 下行:**${output_formatted}** | ${status_label}
"
        else
            result+="
$(get_port_display_name "$port") | 总流量:${total_formatted} | 上行(入站): ${input_formatted} | 下行(出站):${output_formatted} | ${status_label}"
        fi
    done

    if [ "$format_type" = "message" ] || [ "$format_type" = "markdown" ]; then
        echo "$result"
    fi
}

# 显示主界面
show_main_menu() {
    clear

    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)
    # 整机行先采集一次，显示的才是最新值
    collect_vps_traffic

    echo -e "${BLUE}=== 端口流量狗 v$SCRIPT_VERSION ===${NC}"
    echo -e "${GREEN}介绍主页:${NC}https://zywe.de | ${GREEN}项目开源:${NC}https://github.com/zywe03/realm-xwPF"
    echo -e "${GREEN}一只轻巧的‘守护犬’，时刻守护你的端口流量 | 快捷命令: dog${NC}"
    echo

    # 整机行含颜色码，必须经 echo -e 解释；多网卡逐行同显
    local vps_lines=$(format_vps_traffic_line "display")
    [ -n "$vps_lines" ] && echo -e "$vps_lines"
    echo -e "${GREEN}状态: 监控中${NC} | ${BLUE}监控项: ${port_count}个${NC} | ${YELLOW}端口总流量: $daily_total${NC}"
    echo "────────────────────────────────────────────────────────"

    if [ $port_count -gt 0 ]; then
        format_port_list "display"
    else
        echo -e "${YELLOW}暂无监控端口${NC}"
    fi

    echo "────────────────────────────────────────────────────────"

    echo -e "${BLUE}1.${NC} 添加/删除端口监控     ${BLUE}2.${NC} 端口限制设置管理"
    echo -e "${BLUE}3.${NC} 流量重置管理          ${BLUE}4.${NC} 一键导出/导入配置"
    echo -e "${BLUE}5.${NC} 安装依赖(更新)脚本    ${BLUE}6.${NC} 卸载脚本"
    echo -e "${BLUE}7.${NC} 通知管理"
    echo -e "${BLUE}0.${NC} 退出"
    echo
    read -p "请选择操作 [0-7]: " choice

    case $choice in
        1) manage_port_monitoring ;;
        2) manage_traffic_limits ;;
        3) manage_traffic_reset ;;
        4) manage_configuration ;;
        5) install_update_script ;;
        6) uninstall_script ;;
        7) manage_notifications ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请输入0-7${NC}"; sleep 1; show_main_menu ;;
    esac
}

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

add_port_monitoring() {
    echo -e "${BLUE}=== 添加端口监控 ===${NC}"
    echo

    echo -e "${GREEN}当前系统端口使用情况:${NC}"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"

    # 解析ss输出，聚合同程序的端口。=() 初始化不能省：bash 5.0/5.1 下 set -u
    # 对只 declare 未赋值的关联数组取 ${#...[@]} 会报 unbound variable，匹配不到程序时整个添加流程崩溃
    declare -A program_ports=()
    while read line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local_addr=$(echo "$line" | awk '{print $5}')
            port=$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2 || true)
            program=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")

            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                else
                    # 避免重复端口
                    if [[ ! "${program_ports[$program]}" =~ (^|.*\|)$port(\||$) ]]; then
                        program_ports[$program]="${program_ports[$program]}|$port"
                    fi
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

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

    read_user_choice manage_port_monitoring "请输入要监控的端口（;分隔独立监控项，,分隔同组共享端口，-表端口段，如 443,80;22222） [0返回]: " port_input || return

    # 统一解析：; 拆监控单元，, 拆同组成员，- 表端口段；具体错误（重叠/越界/空项）由解析器直接打印
    local PORTS=()
    if ! parse_monitor_units "$port_input" PORTS; then
        sleep 2
        manage_port_monitoring
        return
    fi
    local valid_ports=()

    for port in "${PORTS[@]}"; do
        if jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}监控项 $port 已在监控列表中，跳过${NC}"
            continue
        fi

        valid_ports+=("$port")
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的监控项可添加${NC}"
        sleep 2
        manage_port_monitoring
        return
    fi

    # 跨监控项重叠：新单元不得与任何已监控单元的端口区间重叠，否则同一端口被统计/限速两份
    local existing_keys=($(get_monitored_ports))
    if ! check_units_overlap "${valid_ports[@]}" "${existing_keys[@]}"; then
        sleep 2
        manage_port_monitoring
        return
    fi

    echo
    echo -e "${GREEN}说明:${NC}"
    echo "1. 双向流量统计"
    echo "   总流量 = in*2 + out*2"
    echo
    echo "2. 单向流量统计"
    echo "   仅统计出站流量，总流量 = out"
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

    echo
    local port_list=$(IFS=','; echo "${valid_ports[*]}")
    while true; do
        echo "为端口 $port_list 设置流量配额（总量控制）:"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额值"
            continue
        fi

        expand_single_value_to_array QUOTAS ${#valid_ports[@]}
        if [ ${#QUOTAS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    echo
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"
    echo "请输入当前规则备注(可选，直接回车跳过):"
    echo "(多端口排序分别备注使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "备注: " remark_input

    local REMARKS=()
    if [ -n "$remark_input" ]; then
        parse_comma_separated_input "$remark_input" REMARKS

        expand_single_value_to_array REMARKS ${#valid_ports[@]}
        if [ ${#REMARKS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}备注数量与端口数量不匹配${NC}"
            sleep 2
            add_port_monitoring
            return
        fi
    fi

    local added_count=0
    for i in "${!valid_ports[@]}"; do
        local port="${valid_ports[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
        local remark=""
        if [ ${#REMARKS[@]} -gt $i ]; then
            remark=$(echo "${REMARKS[$i]}" | tr -d ' ')
        fi

        local quota_enabled="true"
        local monthly_limit="unlimited"

        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            monthly_limit="$quota"
        fi

        # 只有设置了流量限额时才添加reset_day字段（默认为1）
        local quota_config
        if [ "$monthly_limit" != "unlimited" ]; then
            quota_config="{
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\",
                \"reset_day\": 1
            }"
        else
            quota_config="{
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\"
            }"
        fi

        local display_name=$(get_port_display_name "$port")

        # 派生 counter_key/rule_id 并写入（与迁移同构，存量单端口/端口段零迁移）
        local ck rid
        ck=$(derive_counter_key "$port")
        rid=$(derive_rule_id "$port")

        local port_config="{
            \"name\": \"$display_name\",
            \"enabled\": true,
            \"billing_mode\": \"$billing_mode\",
            \"bandwidth_limit\": {
                \"enabled\": false,
                \"rate\": \"unlimited\"
            },
            \"quota\": $quota_config,
            \"remark\": \"$remark\",
            \"counter_key\": \"$ck\",
            \"rule_id\": $rid,
            \"created_at\": \"$(get_beijing_time -Iseconds)\"
        }"

        update_config ".ports.\"$port\" = $port_config"
        add_nftables_rules "$port"

        if [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$quota"
        fi

        echo -e "${GREEN}$display_name 监控添加成功${NC}"
        setup_port_auto_reset_cron "$port"
        added_count=$((added_count + 1))
    done

    echo
    echo -e "${GREEN}成功添加 $added_count 个监控项${NC}"

    sleep 2
    manage_port_monitoring
}

remove_port_monitoring() {
    echo -e "${BLUE}=== 删除端口监控 ===${NC}"
    echo

    # 整机流量为默认内置监控，不允许从删除菜单移除：列表与序号都用排除后的端口
    local active_ports=($(get_monitored_ports))

    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无可删除的监控端口"
        sleep 2
        manage_port_monitoring
        return
    fi

    echo "当前监控的端口:"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). $(get_port_display_name "$port") $status_label"
    done
    echo "0. 返回上级菜单"
    echo

    read_user_choice manage_port_monitoring "请选择要删除的端口（多端口使用逗号,分隔） [0返回]: " choice_input || return

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

    echo
    echo "将删除以下端口的监控:"
    for port in "${ports_to_delete[@]}"; do
        echo "  端口 $port"
    done
    echo

    read -p "确认删除这些端口的监控? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        for port in "${ports_to_delete[@]}"; do
            remove_nftables_rules "$port"
            remove_nftables_quota "$port"
            remove_tc_limit "$port"
            update_config "del(.ports.\"$port\")"

            # 清理历史记录
            local history_file="$CONFIG_DIR/reset_history.log"
            if [ -f "$history_file" ]; then
                grep -v "|$port|" "$history_file" > "${history_file}.tmp" 2>/dev/null || true
                mv "${history_file}.tmp" "$history_file" 2>/dev/null || true
            fi

            local notification_log="$CONFIG_DIR/logs/notification.log"
            if [ -f "$notification_log" ]; then
                grep -v "端口 $port " "$notification_log" > "${notification_log}.tmp" 2>/dev/null || true
                mv "${notification_log}.tmp" "$notification_log" 2>/dev/null || true
            fi

            remove_port_auto_reset_cron "$port"

            echo -e "${GREEN}端口 $port 监控及相关数据删除成功${NC}"
            deleted_count=$((deleted_count + 1))
        done

        echo
        echo -e "${GREEN}成功删除 $deleted_count 个端口监控${NC}"

        # 清理连接跟踪：按监控项的 selectors 展开，确保现有连接不受限制
        echo "正在清理网络状态..."
        for port in "${ports_to_delete[@]}"; do
            echo "清理 $(get_port_display_name "$port") 连接状态..."
            local sel
            while read -r sel; do
                [ -z "$sel" ] && continue
                if is_port_range "$sel"; then
                    local start_port=$(echo "$sel" | cut -d'-' -f1)
                    local end_port=$(echo "$sel" | cut -d'-' -f2)
                    for ((p=start_port; p<=end_port; p++)); do
                        conntrack -D -p tcp --dport $p 2>/dev/null || true
                        conntrack -D -p udp --dport $p 2>/dev/null || true
                    done
                else
                    conntrack -D -p tcp --dport $sel 2>/dev/null || true
                    conntrack -D -p udp --dport $sel 2>/dev/null || true
                fi
            done < <(port_selectors "$port")
        done

        echo -e "${GREEN}网络状态已清理，现有连接的限制应该已解除${NC}"
        echo -e "${YELLOW}提示：新建连接将不受任何限制${NC}"

        local remaining_ports=($(get_monitored_ports))
        if [ ${#remaining_ports[@]} -eq 0 ]; then
            echo -e "${YELLOW}所有端口已删除（整机流量监控保持开启），自动重置功能已停用${NC}"
        fi
    else
        echo "取消删除"
    fi

    sleep 2
    manage_port_monitoring
}

add_nftables_rules() {
    local port=$1

    # 整机伪端口无 nftables 规则（计数源是 /proc/net/dev）
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    # 幂等：重加规则前先清掉该端口的旧规则，避免恢复流程把规则翻倍
    remove_port_rules_by_pattern "$port"

    # 组内所有 selector 共享同一对 in/out counter（端口组核心：整组合并统计）
    if [ "$billing_mode" = "double" ]; then
        nft_counter_exists "$in_name" || \
            nft add counter $family $table_name "$in_name" 2>/dev/null || true
    fi
    nft_counter_exists "$out_name" || \
        nft add counter $family $table_name "$out_name" 2>/dev/null || true

    # 对每个 selector 展开规则，全部绑定到同一对共享 counter
    # 单端口/端口段 nft 均接受 tcp dport 443 或 tcp dport 100-200 区间写法
    # 端口段额外打 meta mark，供 tc fw 分类器把同段流量归入组共享 class
    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        local mark_clause=""
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            mark_clause=" meta mark set $mark_id"
        fi

        if [ "$billing_mode" = "double" ]; then
            # in × 2：input/forward 各绑两条（tcp+udp），实现双向口径下 in 翻倍
            nft add rule $family $table_name input tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name input udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name input tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name input udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            # out × 2
            nft add rule $family $table_name output tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
        else
            # 单向：仅 out × 1
            nft add rule $family $table_name output tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

# 按句柄删除匹配端口的监控/配额规则（不动计数器对象），供重加规则前清理旧规则用
# 重构后规则里不再含端口字面量，只含 counter name = port_<counter_key>_(in|out)，按 counter_key 匹配
remove_port_rules_by_pattern() {
    local port=$1

    # 整机伪端口无 nftables 规则
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local search_pattern="port_${counter_key}_"

    # 使用handle删除法：句柄互不影响，一次全表列出所有匹配句柄再逐个删。
    # 原实现每删一条就重新 dump 全表，双向模式 16 条规则/端口就是 16+ 次全表 dump
    local deleted_count=0
    local handles=()
    mapfile -t handles < <(nft -a list table $family $table_name 2>/dev/null | \
        grep -E "counter name \"$search_pattern" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' || true)

    local handle
    for handle in "${handles[@]}"; do
        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done
}

remove_nftables_rules() {
    local port=$1

    # 整机伪端口无 nftables 规则与计数器
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    remove_port_rules_by_pattern "$port"

    # 删除计数器
    nft delete counter $family $table_name "$in_name" 2>/dev/null || true
    nft delete counter $family $table_name "$out_name" 2>/dev/null || true
}

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

    read_user_choice manage_traffic_limits "请选择要限制的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

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

    echo
    local display_list
    for port in "${ports_to_limit[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done
    echo "为 $display_list 设置带宽限制（速率控制）:"
    echo "请输入限制值（0为无限制）（要带单位Kbps/Mbps/Gbps）:"
    echo "(多端口排序分别限制使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "带宽限制: " limit_input

    local LIMITS=()
    parse_comma_separated_input "$limit_input" LIMITS

    expand_single_value_to_array LIMITS ${#ports_to_limit[@]}
    if [ ${#LIMITS[@]} -ne ${#ports_to_limit[@]} ]; then
        echo -e "${RED}限制值数量与端口数量不匹配${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    local success_count=0
    for i in "${!ports_to_limit[@]}"; do
        local port="${ports_to_limit[$i]}"
        local limit=$(echo "${LIMITS[$i]}" | tr -d ' ')

        if [ "$limit" = "0" ] || [ -z "$limit" ]; then
            remove_tc_limit "$port"
            update_config ".ports.\"$port\".bandwidth_limit.enabled = false |
                .ports.\"$port\".bandwidth_limit.rate = \"unlimited\""
            echo -e "${GREEN}$(get_port_display_name "$port") 带宽限制已移除${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        remove_tc_limit "$port"

        if ! validate_bandwidth "$limit"; then
            echo -e "${RED}$(get_port_display_name "$port") 格式错误，请使用如：500Kbps, 100Mbps, 1Gbps${NC}"
            continue
        fi

        # 转换为TC格式
        local tc_limit=$(convert_bandwidth_to_tc "$limit")

        if apply_tc_limit "$port" "$tc_limit"; then
            update_config ".ports.\"$port\".bandwidth_limit.enabled = true |
                .ports.\"$port\".bandwidth_limit.rate = \"$limit\""

            echo -e "${GREEN}$(get_port_display_name "$port") 带宽限制设置成功: $limit${NC}"
        else
            echo -e "${RED}端口 $port 限速规则应用失败，请检查 tc/nftables 环境${NC}"
            continue
        fi
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的带宽限制${NC}"
    sleep 3
    manage_traffic_limits
}

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

    read_user_choice manage_traffic_limits "请选择要设置配额的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

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

    echo
    local display_list
    for port in "${ports_to_quota[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done
    while true; do
        echo "为 $display_list 设置流量配额（总量控制）:"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额值"
            continue
        fi

        expand_single_value_to_array QUOTAS ${#ports_to_quota[@]}
        if [ ${#QUOTAS[@]} -ne ${#ports_to_quota[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    local success_count=0
    for i in "${!ports_to_quota[@]}"; do
        local port="${ports_to_quota[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')

        if [ "$quota" = "0" ] || [ -z "$quota" ]; then
            remove_nftables_quota "$port"
            # 设为无限额时删除reset_day字段并清除定时任务
            jq ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"unlimited\" |
                del(.ports.\"$port\".quota.reset_day)" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 流量配额设置为无限制${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        remove_nftables_quota "$port"
        apply_nftables_quota "$port" "$quota"

        # 获取当前配额限制状态
        local current_monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        
        # 从无限额改为有限额时默认添加reset_day=1
        if [ "$current_monthly_limit" = "unlimited" ]; then
            # 原来是无限额，现在设置为有限额，添加默认reset_day=1
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"$quota\" |
                .ports.\"$port\".quota.reset_day = 1"
        else
            # 原来就是有限额，只修改配额值，保持reset_day不变
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"$quota\""
        fi
        
        setup_port_auto_reset_cron "$port"
        echo -e "${GREEN}$(get_port_display_name "$port") 流量配额设置成功: $quota${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的流量配额${NC}"
    sleep 3
    manage_traffic_limits
}

manage_traffic_limits() {
    echo -e "${BLUE}=== 端口限制设置管理 ===${NC}"
    echo "1. 设置端口带宽限制（速率控制）"
    echo "2. 设置端口流量配额（总量控制）"
    echo "3. 修改端口统计方式（双向/单向）"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1) set_port_bandwidth_limit ;;
        2) set_port_quota_limit ;;
        3) change_port_billing_mode ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_traffic_limits ;;
    esac
}

# 修改端口计费模式（流量数据不丢失）
change_port_billing_mode() {
    echo -e "${BLUE}=== 修改端口统计方式 ===${NC}"
    
    local active_ports=$(jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n)
    if [ -z "$active_ports" ]; then
        echo -e "${RED}没有正在监控的端口${NC}"
        sleep 2
        manage_traffic_limits
        return
    fi
    
    echo -e "${YELLOW}当前监控的端口列表：${NC}"
    local port_list=()
    local idx=1
    for port in $active_ports; do
        local current_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local mode_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
        echo -e "  $idx. $(get_port_display_name "$port") - 当前模式: ${BLUE}${mode_display}${NC}"
        port_list+=("$port")
        ((idx++))
    done
    echo "  0. 返回上级菜单"
    echo
    
    read -p "请选择要修改的端口 [0-$((idx-1))]: " port_choice
    
    if [ "$port_choice" = "0" ]; then
        manage_traffic_limits
        return
    fi
    
    if ! [[ "$port_choice" =~ ^[0-9]+$ ]] || [ "$port_choice" -lt 1 ] || [ "$port_choice" -gt ${#port_list[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        sleep 1
        change_port_billing_mode
        return
    fi
    
    local target_port="${port_list[$((port_choice-1))]}"
    local current_mode=$(jq -r ".ports.\"$target_port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local current_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
    local target_label=$(get_port_display_name "$target_port")

    echo
    echo -e "$target_label 当前统计方式: ${BLUE}$current_display${NC}"
    echo
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    echo "0. 取消"
    echo
    read -p "请选择统计模式 [0-2]: " mode_choice
    
    local new_mode=""
    case $mode_choice in
        1) new_mode="double" ;;
        2) new_mode="single" ;;
        0|"") change_port_billing_mode; return ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; change_port_billing_mode; return ;;
    esac
    
    local new_display=$([ "$new_mode" = "double" ] && echo "双向" || echo "单向")
    
    echo
    echo -e "${YELLOW}正在应用 $new_display 模式...${NC}"
    
    # 读取当前流量
    local traffic_data=($(get_nftables_counter_data "$target_port"))
    local saved_input=${traffic_data[0]:-0}
    local saved_output=${traffic_data[1]:-0}
    echo -e "  读取流量: 上行=$(format_bytes $saved_input), 下行=$(format_bytes $saved_output)"
    
    # 删除旧规则
    remove_nftables_rules "$target_port"
    
    # 更新配置
    local tmp_file=$(mktemp)
    jq ".ports.\"$target_port\".billing_mode = \"$new_mode\"" "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
    
    # 创建带初始值的计数器（复用灾备恢复函数）
    restore_counter_value "$target_port" "$saved_input" "$saved_output"
    
    # 添加规则（计数器已存在，会被复用）
    add_nftables_rules "$target_port"
    
    # 重新应用配额（apply_nftables_quota 会先删除旧配额对象再创建新的）
    local quota_enabled=$(jq -r ".ports.\"$target_port\".quota.enabled // false" "$CONFIG_FILE")
    local quota_limit=$(jq -r ".ports.\"$target_port\".quota.monthly_limit // \"\"" "$CONFIG_FILE")
    if [ "$quota_enabled" = "true" ] && [ -n "$quota_limit" ] && [ "$quota_limit" != "null" ] && [ "$quota_limit" != "unlimited" ]; then
        apply_nftables_quota "$target_port" "$quota_limit"
    fi
    
    echo -e "${GREEN}✓ ${target_label}已应用 $new_display 模式，流量数据已保留${NC}"
    sleep 2
    
    change_port_billing_mode
}

apply_nftables_quota() {
    local port=$1
    local quota_limit=$2

    # 整机配额只做监控告警（tag+推送预警），不做内核阻断：整机 drop 一旦误判会连 SSH 一起断
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local quota_name=$(get_quota_name "$counter_key")

    local quota_bytes=$(parse_size_to_bytes "$quota_limit")

    # 使用当前流量作为配额初始值，避免重置后立即触发限制
    local current_traffic=($(get_nftables_counter_data "$port"))
    local current_input=${current_traffic[0]}
    local current_output=${current_traffic[1]}
    local current_total=$(calculate_total_traffic "$current_input" "$current_output" "$billing_mode")

    # 组内所有 selector 共享同一个 quota 对象（整组配额统一扣减）
    # 确保幂等：先删除现有配额对象（如果存在）
    nft delete quota $family $table_name $quota_name 2>/dev/null || true
    nft add quota $family $table_name $quota_name { over $quota_bytes bytes used $current_total bytes } 2>/dev/null || true

    # 对每个 selector 展开配额阻断规则，全部引用同一 quota 对象
    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if [ "$billing_mode" = "double" ]; then
            # input×2 + output×2，与计数器绑定次数一致
            nft insert rule $family $table_name input tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            # output×2
            nft insert rule $family $table_name output tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
        else
            # 单向：仅 output×1
            nft insert rule $family $table_name output tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

# 删除nftables配额限制 - 使用handle删除法
remove_nftables_quota() {
    local port=$1

    # 整机伪端口无配额对象
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local quota_name=$(get_quota_name "$counter_key")

    # 一次列出所有配额规则句柄再逐个删（句柄互不影响），不再每删一条 dump 一次全表
    local deleted_count=0
    local handles=()
    mapfile -t handles < <(nft -a list table $family $table_name 2>/dev/null | \
        grep "quota name \"$quota_name\"" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' || true)

    local handle
    for handle in "${handles[@]}"; do
        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done

    nft delete quota $family $table_name "$quota_name" 2>/dev/null || true
}

# 需要挂限速的真实网卡：排除回环/ifb 自身/容器与虚拟网桥/隧道。
# 出向和入向都必须覆盖全部真实网卡——回复包从连接进入的网卡发出，
# 只挂默认路由网卡时，多网卡 VPS 的另一个网卡会完全绕过限速
list_shaping_interfaces() {
    ls /sys/class/net | grep -v -E "^(lo|ifb|docker0|br-.*|veth.*|virbr.*|wg.*|tun.*|tap.*)$"
}

# 整机限速启用时父类 1:1 的速率上限（配置里存的是用户输入格式，需走同一条换算链）；
# 端口类都是 1:1 子类，实际速率 = min(端口限速, 整机限速)。未启用返回空
get_vps_tc_ceiling() {
    local enabled=$(jq -r ".ports.\"$VPS_PORT_ID\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
    local rate=$(jq -r ".ports.\"$VPS_PORT_ID\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
    if [ "$enabled" = "true" ] && [ "$rate" != "unlimited" ]; then
        local tc_rate=$(convert_bandwidth_to_tc "$rate")
        if [ -n "$tc_rate" ]; then
            echo "$(calculate_effective_rate_kbps $(parse_tc_rate_to_kbps "$tc_rate"))kbit"
        fi
    fi
}

# HTB default 类 minor 0x30 与端口 48 的限速类天然同号（单端口类 minor=端口号的十六进制）。
# 端口 48 在限时时让出 1:30：整机路径不创建/改写它，避免覆盖或清除端口 48 自身的限速；
# 缺省类缺失时内核对未分类流量直通，出向仍有父类 1:1 收口
vps_default_class_in_use() {
    local enabled=$(jq -r '.ports."48".bandwidth_limit.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false)
    local rate=$(jq -r '.ports."48".bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE" 2>/dev/null || echo unlimited)
    [ "$enabled" = "true" ] && [ "$rate" != "unlimited" ]
}

# 整机限速（伪端口 00）：不建端口类，直接压父类 1:1 速率 + default 30 兜底类，
# 端口类都是 1:1 子类，实际速率 = min(端口限速, 整机限速)，二者天然组合
apply_vps_tc_limit() {
    local total_limit=$1

    local raw_rate_kbps=$(parse_tc_rate_to_kbps "$total_limit")
    local effective_rate_kbps=$(calculate_effective_rate_kbps "$raw_rate_kbps")
    local effective_limit="${effective_rate_kbps}kbit"

    local dev
    local ok_count=0
    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "qdisc htb 1:"; then
            tc qdisc replace dev $dev root handle 1: htb default 30 2>/dev/null || true
        fi
        if tc class replace dev $dev parent 1: classid 1:1 htb rate $effective_limit ceil $effective_limit 2>/dev/null; then
            ok_count=$((ok_count + 1))
        else
            log_notification "整机限速：压父类失败 (网卡 $dev)"
        fi
        # default 类兜底未分类流量（无端口限速时端口流量也走这里）
        if ! vps_default_class_in_use; then
            if ! tc class show dev $dev 2>/dev/null | grep -q "class htb 1:30"; then
                tc class add dev $dev parent 1:1 classid 1:30 htb rate $effective_limit ceil $effective_limit 2>/dev/null || true
            else
                tc class change dev $dev parent 1:1 classid 1:30 htb rate $effective_limit ceil $effective_limit 2>/dev/null || true
            fi
        fi
    done
    [ $ok_count -eq 0 ] && return 1

    # 入向：tc 只能整形出向，ifb 链路不存在时先建（与 apply_ingress_shaping 同法），
    # 否则纯整机限速（无端口限速）场景下入向完全不受控
    if ! ip link show ifb0 >/dev/null 2>&1; then
        modprobe ifb numifbs=1 2>/dev/null || true
        ip link add ifb0 type ifb 2>/dev/null || true
        ip link set ifb0 up 2>/dev/null || true
    fi
    # ifb 是 NOARP 虚拟设备，up 后 operstate 仍是 UNKNOWN，判据用 UP flag
    if ! ip link show ifb0 2>/dev/null | grep -q "<.*UP.*>"; then
        log_notification "ifb0 创建失败，整机入向限速未生效"
        return 0
    fi

    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "^qdisc ingress"; then
            tc qdisc add dev $dev handle ffff: ingress 2>/dev/null || true
        fi
        # 全量重定向只装一次：重复装会按相同 match 叠加多条等价规则
        if ! tc filter show dev $dev parent ffff: 2>/dev/null | grep -q "mirred.*ifb0"; then
            tc filter add dev $dev parent ffff: protocol ip u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
            tc filter add dev $dev parent ffff: protocol ipv6 u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
        fi
    done

    if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb 1:"; then
        tc qdisc add dev ifb0 root handle 1: htb default 1 2>/dev/null || true
    fi
    # 入向整机上限压在 ifb0 的 1:1：端口类是它的子类，min 组合语义与出向一致
    tc class replace dev ifb0 parent 1: classid 1:1 htb rate $effective_limit ceil $effective_limit 2>/dev/null || true
    return 0
}

# 整机限速解除：父类还原为 100gbit 直通（1:30 一并还原）；
# 已无端口限速类时连同整形链路一起拆除——ifb 入向镜像是逐包转发，留着常驻耗 CPU
remove_vps_tc_limit() {
    local dev
    local default_busy=false
    vps_default_class_in_use && default_busy=true

    for dev in $(list_shaping_interfaces); do
        tc class replace dev $dev parent 1: classid 1:1 htb rate 100gbit 2>/dev/null || true
        if [ "$default_busy" = "false" ]; then
            tc class change dev $dev parent 1:1 classid 1:30 htb rate 100gbit ceil 100gbit 2>/dev/null || true
        fi
    done
    if ip link show ifb0 >/dev/null 2>&1; then
        tc class replace dev ifb0 parent 1: classid 1:1 htb rate 100gbit 2>/dev/null || true
    fi

    if [ "$default_busy" = "false" ]; then
        # 剩余子类里排除整机 default 类(1:30)，仅剩它说明没有端口限速在用
        local port_classes=0
        for dev in $(list_shaping_interfaces); do
            port_classes=$((port_classes + $(tc class show dev $dev 2>/dev/null | grep "parent 1:1" | grep -vc "class htb 1:30 " || true)))
        done
        local ifb_classes=0
        if ip link show ifb0 >/dev/null 2>&1; then
            ifb_classes=$(tc class show dev ifb0 2>/dev/null | grep -c "parent 1:1" || true)
        fi
        if [ "$port_classes" -eq 0 ] && [ "$ifb_classes" -eq 0 ]; then
            for dev in $(list_shaping_interfaces); do
                tc qdisc del dev $dev root 2>/dev/null || true
                tc qdisc del dev $dev ingress 2>/dev/null || true
            done
            if ip link show ifb0 >/dev/null 2>&1; then
                tc qdisc del dev ifb0 root 2>/dev/null || true
                ip link set ifb0 down 2>/dev/null || true
                ip link del ifb0 2>/dev/null || true
            fi
        fi
    fi
    return 0
}

apply_tc_limit() {
    local port=$1
    local total_limit=$2

    # 整机限速走父类收口路径
    if [ "$port" = "$VPS_PORT_ID" ]; then
        apply_vps_tc_limit "$total_limit"
        return $?
    fi


    # 出向整形挂到所有真实网卡(幂等)；已有根qdisc(如systemd默认fq_codel)时
    # add 会静默失败导致限速全灭，而已是自己的htb时 replace 不支持change，先探测再创建
    # 根类默认 100gbit 直通避免父类成为多端口总速率瓶颈；整机限速启用时改为整机速率收口，
    # 否则应用端口限速会把整机上限抹掉（开机恢复按 00→端口 顺序也会走到这里）
    local root_rate="100gbit"
    local vps_ceiling=$(get_vps_tc_ceiling)
    [ -n "$vps_ceiling" ] && root_rate="$vps_ceiling"

    local dev
    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "qdisc htb 1:"; then
            tc qdisc replace dev $dev root handle 1: htb default 30 2>/dev/null || true
        fi
        tc class replace dev $dev parent 1: classid 1:1 htb rate $root_rate 2>/dev/null || true
    done

    local class_id=$(generate_tc_class_id "$port")
    # 改档位时 filter/leaf 引用着旧 class 直接删会失败，先拆后建
    remove_egress_filters "$port"

    # 计算补偿后的有效限速与 burst，出向/入向共用同一套换算
    local raw_rate_kbps=$(parse_tc_rate_to_kbps "$total_limit")
    local effective_rate_kbps=$(calculate_effective_rate_kbps "$raw_rate_kbps")
    local effective_limit="${effective_rate_kbps}kbit"
    local burst_bytes=$(calculate_tc_burst "$effective_rate_kbps")
    local burst_size=$(format_tc_burst "$burst_bytes")

    local ok_count=0
    for dev in $(list_shaping_interfaces); do
        tc qdisc del dev $dev parent $class_id 2>/dev/null || true
        tc class del dev $dev classid $class_id 2>/dev/null || true
        if tc class add dev $dev parent 1:1 classid $class_id htb rate $effective_limit ceil $effective_limit burst $burst_size 2>/dev/null; then
            attach_leaf_qdisc $dev "$class_id" "$effective_rate_kbps"
            add_egress_filters "$dev" "$port" "$class_id"
            ok_count=$((ok_count + 1))
        else
            log_notification "创建限速类 $class_id 失败 (端口 $port, 网卡 $dev)"
        fi
    done
    [ $ok_count -eq 0 ] && return 1

    # 出向(下载)+入向(上传)双向限速：入向经 ifb0 虚拟设备借用出向整形能力
    apply_ingress_shaping "$port" "$total_limit"
    return 0
}

# 在指定网卡上挂某端口的出向分类器：单端口用 u32 精确匹配，端口段用 fw 标记；v4/v6 都要覆盖
add_egress_filters() {
    local dev=$1
    local port=$2
    local class_id=$3

    # 对每个 selector 展开分类器，全部 flowid 指向同一组 class_id（整组共享限速上限）
    # 单端口用 u32 直配 sport/dport；端口段用 fw mark（nft 规则已打 meta mark）
    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            tc filter add dev $dev protocol ip parent 1:0 prio 1 handle $mark_id fw flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio 2 handle $mark_id fw flowid $class_id 2>/dev/null || true
        else
            local filter_prio=$((sel % 1000 + 1))
            tc filter add dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            # IPv6：只抓 protocol ip 时 v6 流量完全绕过限速
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

# 删除该端口在各网卡上的出向分类器（与 add_egress_filters 的 v4+v6 全量对称）
remove_egress_filters() {
    local port=$1
    local dev

    for dev in $(list_shaping_interfaces); do
        local sel
        while read -r sel; do
            [ -z "$sel" ] && continue
            if is_port_range "$sel"; then
                local mark_id=$(generate_port_range_mark "$sel")
                local mark_hex=$(printf '0x%x' "$mark_id")
                tc filter del dev $dev protocol ip parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio 2 handle $mark_hex fw 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio 2 handle $mark_id fw 2>/dev/null || true
            else
                local filter_prio=$((sel % 1000 + 1))
                tc filter del dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                    match ip protocol 6 0xff match ip sport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                    match ip protocol 6 0xff match ip dport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                    match ip protocol 17 0xff match ip sport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                    match ip protocol 17 0xff match ip dport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                    match u8 6 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                    match u8 6 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                    match u8 17 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                    match u8 17 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
            fi
        done < <(port_selectors "$port")
    done
}

# 探测内核是否支持 CAKE：sch_cake 可能是模块也可能是内建，两次探测都失败才认定不支持
check_cake_support() {
    if modprobe sch_cake 2>/dev/null; then
        return 0
    fi
    # 某些内核cake已内建无需modprobe
    if tc qdisc add dev lo root cake 2>/dev/null; then
        tc qdisc del dev lo root 2>/dev/null || true
        return 0
    fi
    return 1
}

attach_leaf_qdisc() {
    local dev=$1
    local class_id=$2
    local rate_kbps=$3

    # 优先 CAKE：ethernet 开销补偿 + ack-filter(非对称链路下精简纯ACK)；失败回退 fq_codel
    if check_cake_support && tc qdisc replace dev "$dev" parent "$class_id" cake bandwidth "${rate_kbps}kbit" ethernet ack-filter 2>/dev/null; then
        return 0
    fi

    # 回退方案：fq_codel(target 5ms/interval 100ms)，RFC 8290 行业标准
    tc qdisc replace dev "$dev" parent "$class_id" fq_codel 2>/dev/null || true
}

# 入向限速：tc 只能整形出向流量，把入向包经 ifb0 重定向后按出向整形。
# 排队缓冲而非丢包，对端 TCP 收到的是平滑降速信号而不是连续丢包
apply_ingress_shaping() {
    local port=$1
    local total_limit=$2

    # ifb0 共享单设备：所有端口的入向限速都挂在这上面，首个端口启用时创建
    if ! ip link show ifb0 >/dev/null 2>&1; then
        modprobe ifb numifbs=1 2>/dev/null || true
        ip link add ifb0 type ifb 2>/dev/null || true
        ip link set ifb0 up 2>/dev/null || true
    fi
    # ifb 是 NOARP 虚拟设备，up 后 operstate 仍是 UNKNOWN，判据用 UP flag
    if ! ip link show ifb0 2>/dev/null | grep -q "<.*UP.*>"; then
        log_notification "ifb0 创建失败，端口 $port 入向限速未生效"
        return 1
    fi

    # ingress 根qdisc：把入向包捕获送进 ifb0。必须在所有非lo网卡上安装——
    # 只挂默认路由网卡时，多网卡VPS上从其他网卡进来的流量会完全绕过限速
    # 注意 "qdisc show dev X ingress" 在无 ingress 时也会打印 root qdisc，判据必须查全量输出里的 ingress 行
    local dev
    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "^qdisc ingress"; then
            tc qdisc add dev $dev handle ffff: ingress 2>/dev/null || true
        fi
        # 全量重定向只装一次：重复装会按相同 match 叠加多条等价规则
        if ! tc filter show dev $dev parent ffff: 2>/dev/null | grep -q "mirred.*ifb0"; then
            tc filter add dev $dev parent ffff: protocol ip u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
            # IPv6 同样重定向：vpn 常走 v6，只抓 ip 会漏限
            tc filter add dev $dev parent ffff: protocol ipv6 u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
        fi
    done

    # ifb0 上建与出向对称的 HTB 树，default 指向 100gbit 兜底类（未限速端口直通）；
    # 整机限速启用时父类保持整机速率，同出向的覆盖保护
    if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb 1:"; then
        tc qdisc add dev ifb0 root handle 1: htb default 1 2>/dev/null || true
    fi
    local ifb_root_rate="100gbit"
    local vps_ceiling=$(get_vps_tc_ceiling)
    [ -n "$vps_ceiling" ] && ifb_root_rate="$vps_ceiling"
    tc class replace dev ifb0 parent 1: classid 1:1 htb rate $ifb_root_rate 2>/dev/null || true

    local class_id=$(generate_tc_class_id "$port")
    # 拆除顺序必须 filter → leaf → class：任何一环引用着 class 都会 "HTB class in use"
    remove_ingress_filters "$port"
    tc qdisc del dev ifb0 parent $class_id 2>/dev/null || true
    tc class del dev ifb0 classid $class_id 2>/dev/null || true
    # 与出向同规格的有效限速与 burst
    local raw_rate_kbps=$(parse_tc_rate_to_kbps "$total_limit")
    local effective_rate_kbps=$(calculate_effective_rate_kbps "$raw_rate_kbps")
    local effective_limit="${effective_rate_kbps}kbit"
    local burst_bytes=$(calculate_tc_burst "$effective_rate_kbps")
    local burst_size=$(format_tc_burst "$burst_bytes")
    if ! tc class add dev ifb0 parent 1:1 classid $class_id htb rate $effective_limit ceil $effective_limit burst $burst_size 2>/dev/null; then
        log_notification "创建入向限速类 $class_id 失败 (端口 $port)"
        return 1
    fi
    attach_leaf_qdisc ifb0 "$class_id" "$effective_rate_kbps"

    # 入向方向相反：dport 是用户流量，sport 是中转场景本地回源端口
    # 按 selectors 展开，全部 flowid 指向同一组 class_id（整组共享入向上限）
    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            tc filter add dev ifb0 protocol ip parent 1:0 prio 1 handle $mark_id fw flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio 2 handle $mark_id fw flowid $class_id 2>/dev/null || true
        else
            local filter_prio=$((sel % 1000 + 1))
            tc filter add dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            # IPv6 已随 redirect 进入 ifb0，端口匹配也要有 v6 变体，否则回落 default 类不限速
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
    return 0
}

# 删除该端口挂在 ifb0 上的 u32/fw 分类器
remove_ingress_filters() {
    local port=$1

    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            local mark_hex=$(printf '0x%x' "$mark_id")
            tc filter del dev ifb0 protocol ip parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio 2 handle $mark_hex fw 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio 2 handle $mark_id fw 2>/dev/null || true
        else
            local filter_prio=$((sel % 1000 + 1))
            tc filter del dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip dport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip sport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip dport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip sport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

# 拆除入向限速链路：filter → leaf → class；所有端口都拆完后连同 ifb0 和 ingress 一起清理
remove_ingress_shaping() {
    local port=$1

    if ! ip link show ifb0 >/dev/null 2>&1; then
        return 0
    fi

    local class_id=$(generate_tc_class_id "$port")
    remove_ingress_filters "$port"
    tc qdisc del dev ifb0 parent $class_id 2>/dev/null || true
    tc class del dev ifb0 classid $class_id 2>/dev/null || true

    # 整机入向限速仍启用时保留 ifb0/ingress 链路，只拆端口自己的类
    if [ -n "$(get_vps_tc_ceiling)" ]; then
        return 0
    fi

    # ifb0 上已无限速类：整条链路拆除（所有装过 ingress 的网卡一起清）
    if [ "$(tc class show dev ifb0 2>/dev/null | grep -c "parent 1:1" || true)" -eq 0 ]; then
        local dev
        for dev in $(list_shaping_interfaces); do
            tc qdisc del dev $dev ingress 2>/dev/null || true
        done
        tc qdisc del dev ifb0 root 2>/dev/null || true
        ip link set ifb0 down 2>/dev/null || true
        ip link del ifb0 2>/dev/null || true
    fi
}

# 删除TC带宽限制
remove_tc_limit() {
    local port=$1

    # 整机限速解除走父类还原路径
    if [ "$port" = "$VPS_PORT_ID" ]; then
        remove_vps_tc_limit
        return 0
    fi

    local class_id=$(generate_tc_class_id "$port")

    remove_egress_filters "$port"
    local dev remaining=0
    for dev in $(list_shaping_interfaces); do
        tc qdisc del dev $dev parent $class_id 2>/dev/null || true
        tc class del dev $dev classid $class_id 2>/dev/null || true
    done

    remove_ingress_shaping "$port"

    # 所有网卡都没有剩余限速类时，把各网卡的 htb 根一并还原，避免残留
    for dev in $(list_shaping_interfaces); do
        remaining=$((remaining + $(tc class show dev $dev 2>/dev/null | grep -c "parent 1:1" || true)))
    done
    if [ "$remaining" -eq 0 ]; then
        for dev in $(list_shaping_interfaces); do
            tc qdisc del dev $dev root 2>/dev/null || true
        done
    fi
}

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

    read_user_choice manage_traffic_reset "请选择要设置重置日期的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

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

    echo
    local display_list
    for port in "${ports_to_set[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done
    echo "为 $display_list 设置月重置日期:"
    echo "请输入月重置日（多端口使用逗号,分隔）(0代表不重置):"
    echo "(只输入一个值，应用到所有端口):"
    read -p "月重置日 [0-31]: " reset_day_input

    local RESET_DAYS=()
    parse_comma_separated_input "$reset_day_input" RESET_DAYS

    expand_single_value_to_array RESET_DAYS ${#ports_to_set[@]}
    if [ ${#RESET_DAYS[@]} -ne ${#ports_to_set[@]} ]; then
        echo -e "${RED}重置日期数量与端口数量不匹配${NC}"
        sleep 2
        set_reset_day
        return
    fi

    local success_count=0
    for i in "${!ports_to_set[@]}"; do
        local port="${ports_to_set[$i]}"
        local reset_day=$(echo "${RESET_DAYS[$i]}" | tr -d ' ')

        if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || [ "$reset_day" -lt 0 ] || [ "$reset_day" -gt 31 ]; then
            echo -e "${RED}$(get_port_display_name "$port") 重置日期无效: $reset_day，必须是0-31之间的数字${NC}"
            continue
        fi

        if [ "$reset_day" = "0" ]; then
            # 删除reset_day字段并移除定时任务
            jq "del(.ports.\"$port\".quota.reset_day)" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 已取消自动重置${NC}"
        else
            # 无流量配额的端口不需要自动重置
            local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
            if [ "$monthly_limit" = "unlimited" ]; then
                echo -e "${YELLOW}$(get_port_display_name "$port") 未设置流量配额，请先通过「端口限制设置管理→设置端口流量配额」设置配额后再设置重置日${NC}"
                continue
            fi
            update_config ".ports.\"$port\".quota.reset_day = $reset_day"
            setup_port_auto_reset_cron "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 月重置日设置成功: 每月${reset_day}日${NC}"
        fi
        
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的月重置日期${NC}"

    sleep 2
    manage_traffic_reset
}

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

    read_user_choice manage_traffic_reset "请选择要立即重置的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

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
        # 重置整机前先采集一次，入账与历史记录才是最新值
        [ "$port" = "$VPS_PORT_ID" ] && collect_vps_traffic

        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)

        echo "  $(get_port_display_name "$port"): $total_formatted"
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
            [ "$port" = "$VPS_PORT_ID" ] && collect_vps_traffic
            local traffic_data=($(get_nftables_counter_data "$port"))
            local input_bytes=${traffic_data[0]}
            local output_bytes=${traffic_data[1]}
            local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
            local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

            reset_port_nftables_counters "$port"
            record_reset_history "$port" "$total_bytes"

            echo -e "${GREEN}$(get_port_display_name "$port") 流量统计重置成功${NC}"
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

    # 整机重置前采集一次：月度入账到重置刻为止
    [ "$port" = "$VPS_PORT_ID" ] && collect_vps_traffic

    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

    reset_port_nftables_counters "$port"
    record_reset_history "$port" "$total_bytes"

    local port_label=$(get_port_display_name "$port")

    log_notification "$port_label 自动重置完成，重置前流量: $(format_bytes $total_bytes)"

    echo "$port_label 自动重置完成"
}

# 重置端口nftables计数器和配额
reset_port_nftables_counters() {
    local port=$1

    if [ "$port" = "$VPS_PORT_ID" ]; then
        # 整机重置：仅清 monthly，lifetime_raw 基准保持不动（否则下次 delta 计算会重复累计）
        vps_lock
        local data=$(vps_read_data)
        local new_data=$(printf '%s' "$data" | jq -c --arg now "$(get_beijing_time +%s)" \
            '.monthly = {ifaces: {}, reset_at: ($now | tonumber)}' 2>/dev/null) || new_data="$data"
        vps_write_data "$new_data"
        vps_unlock
        return 0
    fi

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)
    local quota_name=$(get_quota_name "$counter_key")

    # 组内所有 selector 共享同一对 counter 与同一 quota：一次重置即清空整组
    nft reset counter $family $table_name "$in_name" >/dev/null 2>&1 || true
    nft reset counter $family $table_name "$out_name" >/dev/null 2>&1 || true
    nft reset quota $family $table_name "$quota_name" >/dev/null 2>&1 || true
}

record_reset_history() {
    local port=$1
    local traffic_bytes=$2
    local timestamp=$(get_beijing_time +%s)
    local history_file="$CONFIG_DIR/reset_history.log"

    mkdir -p "$(dirname "$history_file")"

    echo "$timestamp|$port|$traffic_bytes" >> "$history_file"

    # 限制历史记录条数，避免文件过大
    if [ $(wc -l < "$history_file" 2>/dev/null || echo 0) -gt 100 ]; then
        tail -n 100 "$history_file" > "${history_file}.tmp"
        mv "${history_file}.tmp" "$history_file"
    fi
}

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
    echo "  - 整机流量数据"
    echo "  - 通知配置"
    echo "  - 日志文件"
    echo

    # 创建临时目录用于打包
    local temp_dir=$(mktemp -d)
    local package_dir="$temp_dir/port-traffic-dog-config"

    # 打包前先采集一次，整机流量数据随包导出（必须在 cp 之前，包里才是最新值）
    collect_vps_traffic

    # 复制配置目录到临时位置
    cp -r "$CONFIG_DIR" "$package_dir"

    # 生成端口流量狗配置包信息文件
    cat > "$package_dir/package_info.txt" << EOF
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

    if [ -f "$backup_path" ]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        echo -e "${GREEN}配置包导出成功${NC}"
        echo
        echo "文件信息："
        echo "  文件名: $backup_name"
        echo "  路径: $backup_path"
        echo "  大小: $file_size"
    else
        echo -e "${RED}配置包导出失败${NC}"
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

    # 显示端口流量狗配置包信息
    echo -e "${GREEN}配置包验证通过${NC}"
    echo

    if [ -f "$extracted_config/package_info.txt" ]; then
        echo -e "${GREEN}端口流量狗配置包信息：${NC}"
        cat "$extracted_config/package_info.txt"
        echo
    fi

    # 显示将要导入的端口
    local import_ports=$(jq -r '.ports | keys | join(", ")' "$extracted_config/config.json" 2>/dev/null || echo "无")
    echo "包含端口: $import_ports"
    echo

    # 确认导入
    echo -e "${YELLOW}警告：导入配置将会：${NC}"
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

    # 旧版本导出的包里没有整机流量条目：幂等补建 + 重建采集 cron
    ensure_vps_port_config

    # 为每个端口重新应用规则
    local new_ports=($(get_active_ports))
    for port in "${new_ports[@]}"; do
        # 添加基础监控规则
        add_nftables_rules "$port"

        # 应用配额限制（如果有）
        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$monthly_limit"
        fi

        # 应用带宽限制（如果有）
        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit" || true
            fi
        fi
    done

    echo "正在更新通知模块..."
    download_notification_modules >/dev/null 2>&1 || true

    rm -rf "$temp_dir"

    echo
    echo -e "${GREEN}配置导入完成${NC}"
    echo
    echo "导入结果："
    echo "  导入端口数: ${#new_ports[@]} 个"
    if [ ${#new_ports[@]} -gt 0 ]; then
        echo "  端口列表: $(IFS=','; echo "${new_ports[*]}")"
    fi
    echo
    echo -e "${YELLOW}提示：${NC}"
    echo "  - 所有端口监控规则已重新应用"
    echo "  - 通知配置已恢复"
    echo "  - 历史数据已恢复"

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 统一下载函数
download_with_sources() {
    local url=$1
    local output_file=$2

    if curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "$url" -o "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            echo -e "${GREEN}下载成功${NC}"
            return 0
        fi
    fi

    echo -e "${RED}下载失败${NC}"
    return 1
}

# 下载通知模块
download_notification_modules() {
    local notifications_dir="$CONFIG_DIR/notifications"
    local temp_dir=$(mktemp -d)
    local repo_url="https://github.com/zywe03/realm-xwPF/archive/refs/heads/main.zip"

    # 下载解压复制清理：每次都覆盖更新确保版本一致
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

    echo -e "${YELLOW}正在检查系统依赖...${NC}"
    check_dependencies true

    # 与主脚本(pf)相同的更新模式：先比对远端版本，有新版才询问下载
    echo -e "${YELLOW}正在检查脚本更新...${NC}"
    local remote_ver=$(curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT \
        "$SCRIPT_URL" 2>/dev/null | \
        grep -E '^readonly SCRIPT_VERSION=' | head -1 | cut -d'"' -f2)

    if [ -z "$remote_ver" ]; then
        echo -e "${RED}无法获取远端版本，请检查网络连接${NC}"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        echo -e "${GREEN}✓ 脚本已是最新版本 ($SCRIPT_VERSION)${NC}"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    echo -e "${YELLOW}发现脚本新版本: ${SCRIPT_VERSION} → ${remote_ver}${NC}"
    read -p "是否更新脚本？(y/n) [默认: y]: " update_choice
    update_choice="${update_choice:-y}"
    if ! [[ "$update_choice" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}使用现有版本${NC}"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    local temp_file=$(mktemp)
    if ! download_with_sources "$SCRIPT_URL" "$temp_file"; then
        echo -e "${RED} 下载失败，请检查网络连接${NC}"
        rm -f "$temp_file"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    if [ ! -s "$temp_file" ] || ! grep -q "端口流量狗" "$temp_file" 2>/dev/null; then
        echo -e "${RED} 下载文件验证失败${NC}"
        rm -f "$temp_file"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    mv "$temp_file" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    create_shortcut_command

    echo -e "${YELLOW}正在更新通知模块...${NC}"
    download_notification_modules >/dev/null 2>&1 || true

    echo -e "${GREEN}脚本已更新到 ${remote_ver}${NC}"
    echo -e "${GREEN}通知模块已更新${NC}"
    echo -e "${YELLOW}正在重启脚本使新版本生效...${NC}"
    sleep 1
    exec bash "$SCRIPT_PATH"
}

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
    echo "  - 整机流量监控及数据"
    echo "  - 通知定时任务"
    echo
    echo -e "${RED}警告：此操作将完全删除端口流量狗及其所有数据！${NC}"
    read -p "确认卸载? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"

        local active_ports=($(get_active_ports 2>/dev/null || true))
        for port in "${active_ports[@]}"; do
            remove_nftables_rules "$port" 2>/dev/null || true
            remove_tc_limit "$port" 2>/dev/null || true
        done

        local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE" 2>/dev/null || echo "port_traffic_monitor")
        local family=$(jq -r '.nftables.family' "$CONFIG_FILE" 2>/dev/null || echo "inet")
        nft delete table $family $table_name >/dev/null 2>&1 || true

        remove_telegram_notification_cron 2>/dev/null || true
        remove_wecom_notification_cron 2>/dev/null || true
        remove_restore_cron 2>/dev/null || true
        remove_vps_collect_cron 2>/dev/null || true

        rm -rf "$CONFIG_DIR" 2>/dev/null || true
        rm -f "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        rm -f "$SCRIPT_PATH" 2>/dev/null || true

        echo -e "${GREEN}卸载完成！${NC}"
        echo -e "${YELLOW}感谢使用端口流量狗！${NC}"
        exit 0
    else
        echo "取消卸载"
        sleep 1
        show_main_menu
    fi
}

manage_notifications() {
    echo -e "${BLUE}=== 通知管理 ===${NC}"
    echo "1. Telegram机器人通知"
    echo "2. 邮箱通知 [敬请期待]"
    echo "3. 企业wx 机器人通知"
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
        3) manage_wecom_notifications ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_notifications ;;
    esac
}

manage_telegram_notifications() {
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"

    if [ -f "$telegram_script" ]; then
        # 导出通知管理函数供模块使用
        export_notification_functions
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

manage_wecom_notifications() {
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"

    if [ -f "$wecom_script" ]; then
        # 导出通知管理函数供模块使用
        export_notification_functions
        source "$wecom_script"
        wecom_configure
        manage_notifications
    else
        echo -e "${RED}企业wx 通知模块不存在${NC}"
        echo "请检查文件: $wecom_script"
        sleep 2
        manage_notifications
    fi
}

setup_telegram_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true

    # 检查telegram通知是否启用
    local telegram_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$telegram_enabled" = "true" ]; then
        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")
        case "$status_interval" in
            "1m")  echo "* * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

setup_wecom_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true

    # 检查企业wx 通知是否启用
    local wecom_enabled=$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$wecom_enabled" = "true" ]; then
        local wecom_interval=$(jq -r '.notifications.wecom.status_notifications.interval' "$CONFIG_FILE")
        case "$wecom_interval" in
            "1m")  echo "* * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

# 通用间隔选择函数
select_notification_interval() {
    # 显示选择菜单到stderr，避免被变量捕获
    echo "请选择状态通知发送间隔:" >&2
    echo "1. 1分钟   2. 15分钟  3. 30分钟  4. 1小时" >&2
    echo "5. 2小时   6. 6小时   7. 12小时  8. 24小时" >&2
    read -p "请选择(回车默认1小时) [1-8]: " interval_choice >&2

    # 默认1小时
    local interval="1h"
    case $interval_choice in
        1) interval="1m" ;;
        2) interval="15m" ;;
        3) interval="30m" ;;
        4|"") interval="1h" ;;
        5) interval="2h" ;;
        6) interval="6h" ;;
        7) interval="12h" ;;
        8) interval="24h" ;;
        *) interval="1h" ;;
    esac

    echo "$interval"
}

remove_telegram_notification_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_wecom_notification_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_restore_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗开机自恢复" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

export_notification_functions() {
    export -f setup_telegram_notification_cron
    export -f setup_wecom_notification_cron
    export -f select_notification_interval
}

setup_port_auto_reset_cron() {
    local port="$1"
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    # 保留现有任务，移除该端口的旧任务
    crontab -l 2>/dev/null | grep -v "端口流量狗自动重置端口$port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
    local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
    local reset_day_raw=$(jq -r ".ports.\"$port\".quota.reset_day" "$CONFIG_FILE")
    
    # 只有quota启用、monthly_limit不是unlimited、且reset_day存在时才添加cron任务
    if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ] && [ "$reset_day_raw" != "null" ]; then
        local reset_day="${reset_day_raw:-1}"
        echo "5 0 $reset_day * * $script_path --reset-port $port >/dev/null 2>&1  # 端口流量狗自动重置端口$port" >> "$temp_cron"
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_port_auto_reset_cron() {
    local port="$1"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "端口流量狗自动重置端口$port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

# 格式化状态消息（HTML格式）
format_status_message() {
    local server_name="${1:-$(hostname)}"  # 接受服务器名称参数
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="<b>${notification_icon} 端口流量狗 v${SCRIPT_VERSION}</b> | ⏰ ${timestamp}
介绍主页:<code>https://zywe.de</code> | 项目开源:<code>https://github.com/zywe03/realm-xwPF</code>
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog
---
$(format_vps_traffic_line "plain")
状态: 监控中 | 监控项: ${port_count}个 | 端口总流量: ${daily_total}
────────────────────────────────────────
<pre>$(format_port_list "message")</pre>
────────────────────────────────────────
🔗 服务器: <i>${server_name}</i>"

    echo "$message"
}

# 格式化状态消息（纯文本text格式）
format_text_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="${notification_icon} 端口流量狗 v${SCRIPT_VERSION} | ⏰ ${timestamp}
介绍主页: https://zywe.de | 项目开源: https://github.com/zywe03/realm-xwPF
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog
---
$(format_vps_traffic_line "plain")
状态: 监控中 | 监控项: ${port_count}个 | 端口总流量: ${daily_total}
────────────────────────────────────────
$(format_port_list "message")
────────────────────────────────────────
🔗 服务器: ${server_name}"

    echo "$message"
}

# 格式化状态消息（Markdown格式）
format_markdown_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="**${notification_icon} 端口流量狗 v${SCRIPT_VERSION}** | ⏰ ${timestamp}
介绍主页: \`https://zywe.de\` | 项目开源: \`https://github.com/zywe03/realm-xwPF\`
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog
---
$(format_vps_traffic_line "markdown")
**状态**: 监控中 | **监控项**: ${port_count}个 | **端口总流量**: ${daily_total}
────────────────────────────────────────
$(format_port_list "markdown")
────────────────────────────────────────
🔗 **服务器**: ${server_name}"

    echo "$message"
}

# 记录通知日志
log_notification() {
    local message="$1"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local log_file="$CONFIG_DIR/logs/notification.log"

    mkdir -p "$(dirname "$log_file")"

    echo "[$timestamp] $message" >> "$log_file"

    # 日志轮转：防止日志文件过大
    if [ -f "$log_file" ] && [ $(wc -l < "$log_file") -gt 1000 ]; then
        tail -n 500 "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"
    fi
}

# 通用状态通知发送函数
send_status_notification() {
    local success_count=0
    local total_count=0

    # 发送Telegram通知
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
    if [ -f "$telegram_script" ]; then
        source "$telegram_script"
        total_count=$((total_count + 1))
        if telegram_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    # 发送企业wx 通知
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
    if [ -f "$wecom_script" ]; then
        source "$wecom_script"
        total_count=$((total_count + 1))
        if wecom_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    if [ $total_count -eq 0 ]; then
        log_notification "通知模块不存在"
        echo -e "${RED}通知模块不存在${NC}"
        return 1
    elif [ $success_count -gt 0 ]; then
        echo -e "${GREEN}状态通知发送成功 ($success_count/$total_count)${NC}"
        return 0
    else
        echo -e "${RED}状态通知发送失败${NC}"
        return 1
    fi
}

# cron/开机路径的状态自愈：表被重启或外部工具清掉后静默重建，避免推送全 0
ensure_monitoring_state() {
    # 推送、重置、交互会话可能同时触发恢复，并发重加规则会翻倍，用文件锁串行化
    mkdir -p "$CONFIG_DIR"
    exec 9>"$CONFIG_DIR/.restore.lock"
    flock 9
    init_nftables
    restore_monitoring_if_needed
    flock -u 9 2>/dev/null || true
    exec 9>&-
}

main() {
    check_root

    # cron 快速路径：跳过重型初始化（依赖检查、通知模块下载等），
    # 但取数前先自愈监控状态并落盘备份，推送/重置读到的才是真实值
    if [ $# -gt 0 ]; then
        case $1 in
            --collect-vps-traffic)
                # 整机流量采集快速路径：只做增量计算，不碰 nftables/通知模块
                collect_vps_traffic
                exit 0
                ;;
            --restore-monitoring)
                ensure_monitoring_state
                collect_vps_traffic
                exit 0
                ;;
            --reset-port)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--reset-port 需要指定端口号${NC}"
                    exit 1
                fi
                ensure_monitoring_state
                collect_vps_traffic
                auto_reset_port "$2"
                save_traffic_data
                exit 0
                ;;
            --send-telegram-status)
                local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
                ensure_monitoring_state
                collect_vps_traffic
                save_traffic_data
                if [ -f "$telegram_script" ]; then
                    source "$telegram_script"
                    telegram_send_status_notification
                fi
                exit 0
                ;;
            --send-wecom-status)
                local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
                ensure_monitoring_state
                collect_vps_traffic
                save_traffic_data
                if [ -f "$wecom_script" ]; then
                    source "$wecom_script"
                    wecom_send_status_notification
                fi
                exit 0
                ;;
            --send-status)
                ensure_monitoring_state
                collect_vps_traffic
                save_traffic_data
                send_status_notification
                exit 0
                ;;
        esac
    fi

    # 完整启动流程（交互式菜单和其余命令需要）
    check_dependencies
    init_config
    create_shortcut_command

    if [ $# -gt 0 ]; then
        case $1 in
            --check-deps)
                echo -e "${GREEN}依赖检查通过${NC}"
                exit 0
                ;;
            --version)
                echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
                echo -e "${GREEN}介绍主页:${NC} https://zywe.de"
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
            *)
                echo -e "${YELLOW}用法: $0 [选项]${NC}"
                echo "选项:"
                echo "  --check-deps              检查依赖工具"
                echo "  --version                 显示版本信息"
                echo "  --install                 安装/更新脚本"
                echo "  --uninstall               卸载脚本"
                echo "  --send-status             发送所有启用的状态通知"
                echo "  --send-telegram-status    发送Telegram状态通知"
                echo "  --send-wecom-status       发送企业wx 状态通知"
                echo "  --reset-port PORT         重置指定监控项流量（支持端口/端口段/端口组）"
                echo "  --collect-vps-traffic     采集整机流量(整机流量监控用)"
                echo "  --restore-monitoring      重建丢失的监控规则(开机自恢复用)"
                echo
                echo -e "${GREEN}快捷命令: $SHORTCUT_COMMAND${NC}"
                exit 1
                ;;
        esac
    fi

    show_main_menu
}

main "$@"
