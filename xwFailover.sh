#!/bin/bash

# 故障转移管理脚本

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

# 全局变量
RULES_DIR="/etc/realm/rules"
HEALTH_STATUS_FILE="/etc/realm/health/health_status.conf"
HEALTH_DIR="/etc/realm/health"
LOCK_FILE="/var/lock/realm-health-check.lock"

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行。${NC}"
        exit 1
    fi
}

# 连通性检查
check_connectivity() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"

    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
    else
        return 1
    fi
    return $?
}

# 读取规则文件
read_rule_file() {
    local rule_file="$1"
    if [ -f "$rule_file" ]; then
        source "$rule_file"
        return 0
    fi
    return 1
}

# 健康检查专用的读取规则文件函数
read_rule_file_for_health_check() {
    local rule_file="$1"
    if [ ! -f "$rule_file" ]; then
        return 1
    fi

    # 清空所有变量
    unset RULE_ID RULE_NAME RULE_ROLE LISTEN_PORT LISTEN_IP THROUGH_IP REMOTE_HOST REMOTE_PORT
    unset FORWARD_TARGET SECURITY_LEVEL
    unset TLS_SERVER_NAME TLS_CERT_PATH TLS_KEY_PATH WS_PATH WS_HOST
    unset ENABLED BALANCE_MODE FAILOVER_ENABLED HEALTH_CHECK_INTERVAL
    unset FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT
    unset TARGET_STATES WEIGHTS CREATED_TIME

    source "$rule_file"
    return 0
}

# 查找文件路径
find_file_path() {
    local filename="$1"
    local cache_file="/tmp/realm_path_cache"
    local cache_timeout=3600

    # 第一阶段：常见位置直接检查
    local common_paths=(
        "/etc/realm/health/$filename"
        "/etc/realm/$filename"
        "/var/lib/realm/$filename"
        "/opt/realm/$filename"
        "/usr/local/realm/$filename"
        "/tmp/$filename"
    )

    for path in "${common_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    # 第二阶段：缓存检查
    if [ -f "$cache_file" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
        if [ "$cache_age" -lt "$cache_timeout" ]; then
            local cached_path=$(grep "^$filename:" "$cache_file" 2>/dev/null | cut -d: -f2-)
            if [ -n "$cached_path" ] && [ -f "$cached_path" ]; then
                echo "$cached_path"
                return 0
            fi
        fi
    fi

    # 第三阶段：全局搜索
    local found_path=$(find /etc /var /opt /usr/local -name "$filename" -type f 2>/dev/null | head -1)
    if [ -n "$found_path" ]; then
        echo "$filename:$found_path" >> "$cache_file"
        echo "$found_path"
        return 0
    fi

    return 1
}

# 故障转移切换功能（按端口分组管理）
toggle_failover_mode() {
    while true; do
        clear
        echo -e "${YELLOW}=== 开启/关闭故障转移 ===${NC}"
        echo ""

        # 按端口分组收集启用负载均衡的中转服务器规则
        unset port_groups port_configs port_failover_status
        declare -A port_groups
        declare -A port_configs
        declare -A port_failover_status

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$ENABLED" = "true" ] && [ "$BALANCE_MODE" != "off" ]; then
                    local port_key="$LISTEN_PORT"
                    # 存储端口配置（使用第一个规则的配置作为基准）
                    if [ -z "${port_configs[$port_key]}" ]; then
                        port_configs[$port_key]="$RULE_NAME"
                        port_failover_status[$port_key]="${FAILOVER_ENABLED:-false}"
                    fi

                    # 正确处理REMOTE_HOST中可能包含多个地址的情况
                    if [[ "$REMOTE_HOST" == *","* ]]; then
                        # 多个地址的情况
                        IFS=',' read -ra addresses <<< "$REMOTE_HOST"
                        for addr in "${addresses[@]}"; do
                            addr=$(echo "$addr" | xargs)  # 去除空格
                            local target="${addr}:${REMOTE_PORT}"
                            if [ -z "${port_groups[$port_key]}" ]; then
                                port_groups[$port_key]="$target"
                            else
                                port_groups[$port_key]="${port_groups[$port_key]},$target"
                            fi
                        done
                    else
                        # 单个地址的情况
                        local target="${REMOTE_HOST}:${REMOTE_PORT}"
                        if [ -z "${port_groups[$port_key]}" ]; then
                            port_groups[$port_key]="$target"
                        else
                            port_groups[$port_key]="${port_groups[$port_key]},$target"
                        fi
                    fi
                fi
            fi
        done

        # 显示可用的规则组
        local has_balance_rules=false
        local rule_ports=()
        local rule_names=()
        local rule_number=1

        if [ ${#port_groups[@]} -gt 0 ]; then
            for port_key in $(printf '%s\n' "${!port_groups[@]}" | sort -n); do
                IFS=',' read -ra targets <<< "${port_groups[$port_key]}"
                local target_count=${#targets[@]}

                # 只显示有多个目标服务器的规则组（故障转移的前提条件）
                if [ $target_count -gt 1 ]; then
                    if [ "$has_balance_rules" = false ]; then
                        has_balance_rules=true
                        echo -e "${BLUE}可配置故障转移的规则组:${NC}"
                        echo ""
                    fi

                    rule_ports+=("$port_key")
                    rule_names+=("${port_configs[$port_key]}")

                    # 获取故障转移状态
                    local failover_status="${port_failover_status[$port_key]}"
                    local status_text="关闭"
                    local status_color="${RED}"

                    if [ "$failover_status" = "true" ]; then
                        status_text="开启"
                        status_color="${GREEN}"
                    fi

                    echo -e "${GREEN}$rule_number.${NC} ${port_configs[$port_key]} (端口: $port_key) - $target_count个目标服务器 - 故障转移: ${status_color}$status_text${NC}"
                fi
            done
        fi

        if [ "$has_balance_rules" = false ]; then
            echo -e "${YELLOW}暂无启用负载均衡的规则组${NC}"
            echo -e "${BLUE}提示: 只有开启负载均衡才能使用故障转移功能${NC}"
            echo ""
            echo -e "${BLUE}故障转移的前提条件：${NC}"
            echo -e "${BLUE}  1. 规则类型为中转服务器${NC}"
            echo -e "${BLUE}  2. 已启用负载均衡模式（轮询或IP哈希）${NC}"
            echo -e "${BLUE}  3. 有多个目标服务器${NC}"
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo -e "${WHITE}注意: 故障转移功能会自动检测节点健康状态并动态调整负载均衡${NC}"
        echo ""
        read -p "请输入规则编号 [1-${#rule_ports[@]}] (或按回车返回): " choice

        if [ -z "$choice" ]; then
            return
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#rule_ports[@]} ]; then
            echo -e "${RED}无效的选择，请输入 1-${#rule_ports[@]} 之间的数字${NC}"
            read -p "按回车键继续..."
            continue
        fi

        local selected_index=$((choice - 1))
        local selected_port="${rule_ports[$selected_index]}"
        local rule_name="${rule_names[$selected_index]}"

        # 切换故障转移状态
        local current_status="${port_failover_status[$selected_port]}"
        local new_status="true"
        local action_text="开启"
        local color="${GREEN}"

        if [ "$current_status" = "true" ]; then
            new_status="false"
            action_text="关闭"
            color="${RED}"
        fi

        # 直接切换状态，无需确认
        echo -e "${BLUE}正在${action_text}故障转移功能...${NC}"

        # 更新所有相关规则文件
        local updated_count=0
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$selected_port" ]; then
                    # 更新故障转移状态
                    if grep -q "^FAILOVER_ENABLED=" "$rule_file"; then
                        sed -i "s/^FAILOVER_ENABLED=.*/FAILOVER_ENABLED=\"$new_status\"/" "$rule_file"
                    else
                        echo "FAILOVER_ENABLED=\"$new_status\"" >> "$rule_file"
                    fi
                    updated_count=$((updated_count + 1))
                fi
            fi
        done

        echo -e "${color}✓ 已更新 $updated_count 个规则文件的故障转移状态${NC}"

        if [ "$new_status" = "true" ]; then
            echo -e "${BLUE}故障转移参数:${NC}"
            echo -e "  检查间隔: ${GREEN}4秒${NC}"
            echo -e "  失败阈值: ${GREEN}连续2次${NC}"
            echo -e "  成功阈值: ${GREEN}连续2次${NC}"
            echo -e "  连接超时: ${GREEN}3秒${NC}"
        fi

        # 重启服务以应用更改
        echo -e "${YELLOW}正在重启服务以应用故障转移设置...${NC}"
        restart_realm_service

        # 管理健康检查服务
        if [ "$new_status" = "true" ]; then
            echo -e "${BLUE}正在启动健康检查服务...${NC}"
            start_health_check_service
        else
            # 检查是否还有其他规则启用了故障转移
            local has_other_failover=false
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$FAILOVER_ENABLED" = "true" ]; then
                        has_other_failover=true
                        break
                    fi
                fi
            done

            if [ "$has_other_failover" = false ]; then
                echo -e "${BLUE}正在停止健康检查服务...${NC}"
                stop_health_check_service
            fi
        fi

        echo -e "${GREEN}✓ 故障转移设置已生效${NC}"
        echo ""
        read -p "按回车键继续..."
        # 重新显示菜单以显示更新的状态
    done
}

# 健康检查服务管理
start_health_check_service() {
    local health_dir="/etc/realm/health"
    local health_script="/etc/realm/health/health_check.sh"
    local health_timer="/etc/systemd/system/realm-health-check.timer"
    local health_service="/etc/systemd/system/realm-health-check.service"

    # 创建健康检查目录
    mkdir -p "$health_dir"

    # 创建健康检查脚本
    cat > "$health_script" << 'EOF'
#!/bin/bash

# 健康检查脚本
HEALTH_DIR="/etc/realm/health"
RULES_DIR="/etc/realm/rules"
LOCK_FILE="/var/lock/realm-health-check.lock"

# 查找健康状态文件
HEALTH_STATUS_FILE=""
for path in "/etc/realm/health/health_status.conf" "/etc/realm/health_status.conf" "/var/lib/realm/health_status.conf"; do
    if [ -f "$path" ]; then
        HEALTH_STATUS_FILE="$path"
        break
    fi
done

# 如果找不到，使用默认路径
if [ -z "$HEALTH_STATUS_FILE" ]; then
    HEALTH_STATUS_FILE="$HEALTH_DIR/health_status.conf"
fi

# 获取文件锁
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查已在运行中，跳过本次检查"
    exit 0
fi

# 健康检查函数（统一使用check_connectivity）
check_connectivity() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"

    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
    else
        return 1
    fi
    return $?
}

# 健康检查脚本专用的读取规则文件函数
read_rule_file_for_health_check() {
    local rule_file="$1"
    if [ ! -f "$rule_file" ]; then
        return 1
    fi

    # 清空所有变量
    unset RULE_ID RULE_NAME RULE_ROLE LISTEN_PORT LISTEN_IP THROUGH_IP REMOTE_HOST REMOTE_PORT
    unset FORWARD_TARGET SECURITY_LEVEL
    unset TLS_SERVER_NAME TLS_CERT_PATH TLS_KEY_PATH WS_PATH WS_HOST
    unset ENABLED BALANCE_MODE FAILOVER_ENABLED HEALTH_CHECK_INTERVAL
    unset FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT
    unset TARGET_STATES WEIGHTS CREATED_TIME

    source "$rule_file"
    return 0
}


# 初始化健康状态文件
if [ ! -f "$HEALTH_STATUS_FILE" ]; then
    echo "# Realm健康状态文件" > "$HEALTH_STATUS_FILE"
    echo "# 格式: RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME" >> "$HEALTH_STATUS_FILE"
fi

# 检查所有启用故障转移的规则
config_changed=false
current_time=$(date +%s)

for rule_file in "${RULES_DIR}"/rule-*.conf; do
    if [ ! -f "$rule_file" ]; then
        continue
    fi

    if ! read_rule_file_for_health_check "$rule_file"; then
        continue
    fi

    # 只检查启用故障转移的中转规则
    if [ "$RULE_ROLE" != "1" ] || [ "$ENABLED" != "true" ] || [ "$FAILOVER_ENABLED" != "true" ]; then
        continue
    fi

    # 处理REMOTE_HOST中的多个地址
    IFS=',' read -ra targets <<< "$REMOTE_HOST"
    for target in "${targets[@]}"; do
        target=$(echo "$target" | xargs)  # 去除空格
        target_key="${RULE_ID}|${target}"

        # 获取当前状态
        status_line=$(grep "^${target_key}|" "$HEALTH_STATUS_FILE" 2>/dev/null)
        if [ -n "$status_line" ]; then
            IFS='|' read -r _ _ status fail_count success_count last_check failure_start_time <<< "$status_line"
            # 兼容旧格式（没有failure_start_time字段）
            if [ -z "$failure_start_time" ]; then
                failure_start_time="$last_check"
            fi
        else
            status="healthy"
            fail_count=0
            success_count=2
            last_check=0
            failure_start_time=0
        fi

        # 执行健康检查
        if check_connectivity "$target" "$REMOTE_PORT" "${CONNECTION_TIMEOUT:-3}"; then
            # 检查成功
            success_count=$((success_count + 1))
            fail_count=0

            # 如果之前是故障状态，检查是否可以恢复
            if [ "$status" = "failed" ] && [ "$success_count" -ge "${SUCCESS_THRESHOLD:-2}" ]; then
                # 检查冷却期（基于故障开始时间）
                cooldown_period=$((120))  # 120秒冷却期
                if [ $((current_time - failure_start_time)) -ge "$cooldown_period" ]; then
                    status="healthy"
                    config_changed=true
                    failure_start_time=0  # 重置故障开始时间
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [RECOVERY] 目标 $target:$REMOTE_PORT 已恢复健康"
                fi
            fi
        else
            # 检查失败
            fail_count=$((fail_count + 1))
            success_count=0

            # 如果连续失败达到阈值，标记为故障
            if [ "$status" = "healthy" ] && [ "$fail_count" -ge "${FAILURE_THRESHOLD:-2}" ]; then
                status="failed"
                config_changed=true
                failure_start_time="$current_time"  # 记录故障开始时间
                echo "$(date '+%Y-%m-%d %H:%M:%S') [FAILURE] 目标 $target:$REMOTE_PORT 检测失败，标记为故障"
            fi
        fi

        # 更新状态文件（包含故障开始时间）
        grep -v "^${target_key}|" "$HEALTH_STATUS_FILE" > "$HEALTH_STATUS_FILE.tmp" 2>/dev/null || true
        echo "${target_key}|${status}|${fail_count}|${success_count}|${current_time}|${failure_start_time}" >> "$HEALTH_STATUS_FILE.tmp"
        mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE"
    done
done

# 如果配置有变化，调用xwPF.sh重启接口
if [ "$config_changed" = true ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 检测到节点状态变化，正在更新配置..."

    # 调用xwPF.sh的重启接口
    if command -v pf >/dev/null 2>&1; then
        pf --restart-service >/dev/null 2>&1
    elif [ -f "/usr/local/bin/xwPF.sh" ]; then
        bash "/usr/local/bin/xwPF.sh" --restart-service >/dev/null 2>&1
    elif [ -f "/root/xwPF.sh" ]; then
        bash "/root/xwPF.sh" --restart-service >/dev/null 2>&1
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] 未找到主脚本，无法更新配置"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 配置更新完成"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查完成"
EOF

    chmod +x "$health_script"

    # 创建systemd服务文件
    cat > "$health_service" << EOF
[Unit]
Description=Realm Health Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=$health_script
User=root
WorkingDirectory=/etc/realm
StandardOutput=journal
StandardError=journal
SyslogIdentifier=realm-health

[Install]
WantedBy=multi-user.target
EOF

    # 创建systemd定时器
    cat > "$health_timer" << EOF
[Unit]
Description=Realm Health Check Timer
Requires=realm-health-check.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=7sec
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 启用并启动定时器
    systemctl daemon-reload
    systemctl enable realm-health-check.timer >/dev/null 2>&1
    systemctl start realm-health-check.timer >/dev/null 2>&1

    echo -e "${GREEN}✓ 健康检查服务已启动${NC}"
}

# 停止健康检查服务
stop_health_check_service() {
    # 停止并禁用健康检查服务
    systemctl stop realm-health-check.timer >/dev/null 2>&1
    systemctl disable realm-health-check.timer >/dev/null 2>&1
    systemctl stop realm-health-check.service >/dev/null 2>&1
    systemctl disable realm-health-check.service >/dev/null 2>&1

    # 删除服务文件
    rm -f "/etc/systemd/system/realm-health-check.timer"
    rm -f "/etc/systemd/system/realm-health-check.service"
    rm -f "/etc/realm/health/health_check.sh"

    systemctl daemon-reload

    echo -e "${GREEN}✓ 健康检查服务已停止${NC}"
}

# 查看健康状态
show_health_status() {
    echo -e "${YELLOW}=== 健康状态查看 ===${NC}"
    echo ""

    # 动态查找健康状态文件
    local health_status_file=$(find_file_path "health_status.conf")

    if [ ! -f "$health_status_file" ]; then
        echo -e "${YELLOW}健康状态文件不存在${NC}"
        return
    fi

    echo -e "${BLUE}健康状态文件: ${health_status_file}${NC}"
    echo ""

    # 读取并显示健康状态
    local has_data=false
    while read -r line; do
        # 跳过注释行和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        has_data=true
        IFS='|' read -r rule_target _ status fail_count success_count last_check failure_start_time <<< "$line"

        local rule_id=$(echo "$rule_target" | cut -d'|' -f1)
        local target=$(echo "$rule_target" | cut -d'|' -f2)

        # 格式化时间
        local last_check_time="未知"
        if [ "$last_check" != "0" ] && [ -n "$last_check" ]; then
            last_check_time=$(date -d "@$last_check" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
        fi

        # 状态颜色
        local status_color="${GREEN}"
        local status_text="健康"
        if [ "$status" = "failed" ]; then
            status_color="${RED}"
            status_text="故障"
        fi

        echo -e "${BLUE}规则ID: ${rule_id}${NC}"
        echo -e "  目标: ${target}"
        echo -e "  状态: ${status_color}${status_text}${NC}"
        echo -e "  失败次数: ${fail_count}"
        echo -e "  成功次数: ${success_count}"
        echo -e "  最后检查: ${last_check_time}"
        echo ""
    done < "$health_status_file"

    if [ "$has_data" = false ]; then
        echo -e "${YELLOW}暂无健康状态数据${NC}"
    fi
}



# 显示使用帮助
show_help() {
    echo -e "${GREEN}xwFailover.sh - Realm故障转移管理脚本${NC}"
    echo ""
    echo "用法:"
    echo "  $0 toggle [port]          # 切换故障转移状态"
    echo "  $0 status                 # 查看健康状态"
    echo "  $0 start                  # 启动健康检查服务"
    echo "  $0 stop                   # 停止健康检查服务"
    echo "  $0 restart-realm          # 重启realm服务"
    echo "  $0 help                   # 显示帮助信息"
}

# 重启realm服务（调用xwPF.sh的重启接口）
restart_realm_service() {
    echo -e "${BLUE}调用主脚本的重启接口...${NC}"

    # 尝试调用常见的xwPF.sh命令
    if command -v pf >/dev/null 2>&1; then
        pf --restart-service
        return $?
    elif [ -f "/usr/local/bin/xwPF.sh" ]; then
        bash "/usr/local/bin/xwPF.sh" --restart-service
        return $?
    elif [ -f "/root/xwPF.sh" ]; then
        bash "/root/xwPF.sh" --restart-service
        return $?
    else
        echo -e "${RED}✗ 未找到主脚本，无法重启服务${NC}"
        echo -e "${YELLOW}请确保xwPF.sh已正确安装${NC}"
        return 1
    fi
}

# 主函数
main() {
    check_root

    case "${1:-toggle}" in
        "toggle")
            toggle_failover_mode
            ;;
        "status")
            show_health_status
            ;;
        "start")
            start_health_check_service
            ;;
        "stop")
            stop_health_check_service
            ;;
        "restart-realm")
            restart_realm_service
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"