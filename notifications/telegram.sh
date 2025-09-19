#!/bin/bash

# Telegram 通知模块 - UI 界面部分
# 核心的消息格式化和发送逻辑在主脚本中

# 检查 Telegram 是否启用
telegram_is_enabled() {
    local enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")
    [ "$enabled" = "true" ]
}

# Telegram 状态通知（调用主脚本函数）
telegram_send_status() {
    local message=$(format_status_message)
    if send_telegram_message "$message"; then
        log_notification "Telegram状态通知发送成功"
        return 0
    else
        log_notification "Telegram状态通知发送失败"
        return 1
    fi
}

# Telegram 测试功能
telegram_test() {
    echo -e "${BLUE}=== 发送测试消息 ===${NC}"
    echo

    if ! telegram_is_enabled; then
        echo -e "${RED}请先配置Telegram Bot信息${NC}"
        sleep 2
        return 1
    fi

    echo "正在发送测试消息..."

    # 发送状态通知
    if telegram_send_status; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

# Telegram 配置管理界面
telegram_configure() {
    while true; do
        local telegram_enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")

        # 状态显示
        local config_status="❌未配置"
        if [ "$telegram_enabled" = "true" ]; then
            config_status="✅已配置"
        fi

        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

        echo -e "${BLUE}=== Telegram通知配置 ===${NC}"
        local interval_display="未设置"
        if [ -n "$status_interval" ] && [ "$status_interval" != "null" ]; then
            interval_display="每${status_interval}"
        fi
        echo -e "当前状态: ${config_status} | 状态通知: ${interval_display}"
        echo
        echo "1. 配置Bot信息 (Token + Chat ID + 服务器名称)"
        echo "2. 通知设置管理"
        echo "3. 发送测试消息"
        echo "4. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-4]: " choice

        case $choice in
            1) telegram_configure_bot ;;
            2) telegram_manage_settings ;;
            3) telegram_test ;;
            4) telegram_view_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_bot() {
    echo -e "${BLUE}=== 配置Telegram Bot信息 ===${NC}"
    echo
    echo -e "${GREEN}配置步骤说明:${NC}"
    echo "1. 与 @BotFather 对话创建机器人"
    echo "2. 获取 Bot Token (格式: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo "3. 获取 Chat ID (个人聊天或群组ID)"
    echo "4. 设置服务器名称用于标识"
    echo

    # 显示当前配置
    local current_token=$(jq -r '.notifications.telegram.bot_token' "$CONFIG_FILE")
    local current_chat_id=$(jq -r '.notifications.telegram.chat_id' "$CONFIG_FILE")
    local current_server_name=$(jq -r '.notifications.telegram.server_name' "$CONFIG_FILE")

    if [ "$current_token" != "" ] && [ "$current_token" != "null" ]; then
        local masked_token="${current_token:0:10}...${current_token: -10}"
        echo -e "${GREEN}当前Token: $masked_token${NC}"
    fi
    if [ "$current_chat_id" != "" ] && [ "$current_chat_id" != "null" ]; then
        echo -e "${GREEN}当前Chat ID: $current_chat_id${NC}"
    fi
    if [ "$current_server_name" != "" ] && [ "$current_server_name" != "null" ]; then
        echo -e "${GREEN}当前服务器名: $current_server_name${NC}"
    fi
    echo

    read -p "请输入Bot Token: " bot_token
    if [ -z "$bot_token" ]; then
        echo -e "${RED}Token不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Token格式错误，请检查${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    read -p "请输入Chat ID: " chat_id
    if [ -z "$chat_id" ]; then
        echo -e "${RED}Chat ID不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}Chat ID格式错误，必须是数字${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    local default_server_name=$(hostname)
    read -p "请输入服务器名称 (回车默认: $default_server_name): " server_name
    if [ -z "$server_name" ]; then
        server_name="$default_server_name"
    fi

    # 保存配置
    update_config ".notifications.telegram.bot_token = \"$bot_token\" |
        .notifications.telegram.chat_id = \"$chat_id\" |
        .notifications.telegram.server_name = \"$server_name\" |
        .notifications.telegram.enabled = true |
        .notifications.telegram.status_notifications.enabled = true"

    echo -e "${GREEN}基本配置保存成功！${NC}"
    echo

    # 设置状态通知间隔
    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    echo "请选择状态通知发送间隔:"
    echo "1. 1分钟   2. 15分钟  3. 30分钟  4. 1小时"
    echo "5. 2小时   6. 6小时   7. 12小时  8. 24小时"
    read -p "请选择(回车默认1小时) [1-8]: " interval_choice

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

    # 设置间隔
    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    # 设置定时任务
    setup_notification_cron

    echo
    echo "正在发送测试通知..."

    # 发送测试通知
    if telegram_send_status; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

# 通知设置管理
telegram_manage_settings() {
    while true; do
        echo -e "${BLUE}=== 通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-1]: " choice

        case $choice in
            1) telegram_configure_interval ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}


# 配置状态通知间隔
telegram_configure_interval() {
    local current_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval_display="未设置"
    if [ -n "$current_interval" ] && [ "$current_interval" != "null" ]; then
        interval_display="$current_interval"
    fi
    echo -e "当前间隔: $interval_display"
    echo
    echo "请选择状态通知发送间隔:"
    echo "1. 1分钟   2. 15分钟  3. 30分钟  4. 1小时"
    echo "5. 2小时   6. 6小时   7. 12小时  8. 24小时"
    read -p "请选择(回车默认1小时) [1-8]: " interval_choice

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

    # 验证并设置间隔
    if [[ "$interval" =~ ^(1m|15m|30m|1h|2h|6h|12h|24h)$ ]]; then
        update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
        echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

        setup_notification_cron
    else
        echo -e "${RED}无效的间隔格式，请重新输入${NC}"
        sleep 2
        telegram_configure_interval
        return
    fi

    sleep 2
}

telegram_view_logs() {
    echo -e "${BLUE}=== 通知日志 ===${NC}"
    echo

    local log_file="$CONFIG_DIR/logs/notification.log"
    if [ ! -f "$log_file" ]; then
        echo -e "${YELLOW}暂无通知日志${NC}"
        sleep 2
        return
    fi

    echo "最近20条通知日志:"
    echo "────────────────────────────────────────────────────────"
    tail -n 20 "$log_file"
    echo "────────────────────────────────────────────────────────"
    echo
    read -p "按回车键返回..."
}
