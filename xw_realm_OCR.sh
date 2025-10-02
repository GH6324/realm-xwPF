#!/bin/bash

# xw_realm_OCR.sh - Realm配置文件识别脚本
# 识别用户的realm配置文件，识别endpoints字段，导入脚本管理

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

get_gmt8_time() {
    TZ='GMT-8' date "$@"
}

# 规则ID生成器（临时使用，最终由主脚本重排序）
# 生成唯一ID
generate_rule_id() {
    # 基于已生成的文件数量生成临时ID
    local existing_count=$(ls -1 "$OUTPUT_DIR"/rule-*.conf 2>/dev/null | wc -l)
    echo $((existing_count + 1))
}

# 配置路径定义（与主脚本保持一致）
CONFIG_DIR="/etc/realm"
RULES_DIR="${CONFIG_DIR}/rules"

# 默认SNI域名（与主脚本保持一致）
DEFAULT_SNI_DOMAIN="www.tesla.com"

# 检查参数
if [ -n "$1" ]; then
    RULES_DIR="$1"
fi

echo -e "${YELLOW}=== 识别realm配置文件并导入 ===${NC}"
echo ""

# 确保工作目录存在
if ! pwd >/dev/null 2>&1; then
    cd /tmp
fi

# 输入配置文件路径
read -p "请输入配置文件的完整路径：" CONFIG_FILE
echo ""

if [ -z "$CONFIG_FILE" ]; then
    echo -e "${BLUE}已取消操作${NC}"
    exit 1
fi

# 检查文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误: 文件不存在${NC}"
    exit 1
fi

# 检查文件格式
file_ext=$(echo "$CONFIG_FILE" | awk -F. '{print tolower($NF)}')
if [ "$file_ext" != "json" ] && [ "$file_ext" != "toml" ]; then
    echo -e "${RED}错误: 仅支持 .json 和 .toml 格式的配置文件${NC}"
    exit 1
fi

# 创建临时目录用于处理
OUTPUT_DIR="/tmp/realm_import_$$"
mkdir -p "$OUTPUT_DIR"

echo -e "${YELLOW}正在识别配置文件...${NC}"

# 检查文件格式
file_ext=$(echo "$CONFIG_FILE" | awk -F. '{print tolower($NF)}')

# 获取安全级别显示文本（与主脚本完全一致）
get_security_display() {
    local security_level="$1"
    local ws_path="$2"
    local tls_server_name="$3"  # 在ws模式下作为host，在tls模式下作为SNI

    case "$security_level" in
        "standard")
            echo "默认传输"
            ;;
        "ws")
            echo "ws (host: $tls_server_name) (路径: $ws_path)"
            ;;
        "tls_self")
            local display_sni="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
            echo "TLS自签证书 (SNI: $display_sni)"
            ;;
        "tls_ca")
            echo "TLS CA证书 (域名: $tls_server_name)"
            ;;
        "ws_tls_self")
            local display_sni="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            echo "wss 自签证书 (host: $tls_server_name) (路径: $ws_path) (SNI: $display_sni)"
            ;;
        "ws_tls_ca")
            local display_sni="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            echo "wss CA证书 (host: $tls_server_name) (路径: $ws_path) (SNI: $display_sni)"
            ;;
        "ws_"*)
            echo "$security_level (路径: $ws_path)"
            ;;
        *)
            echo "$security_level"
            ;;
    esac
}

# 解析transport配置
parse_transport_config() {
    local transport="$1"
    local role="$2"  # 1=中转服务器, 2=落地服务器

    # 初始化返回值
    local security_level="standard"
    local tls_server_name=""
    local ws_path=""
    local ws_host=""

    if [ -n "$transport" ]; then
        # 检查是否包含WebSocket
        local has_ws=false
        if echo "$transport" | grep -q "ws;"; then
            has_ws=true

            ws_host=$(echo "$transport" | grep -oP 'host=\K[^;]+' || echo "")
            ws_path=$(echo "$transport" | grep -oP 'path=\K[^;]+' || echo "")
        fi

        # 检查是否包含TLS
        local has_tls=false
        if echo "$transport" | grep -q "tls"; then
            has_tls=true

            if [ "$role" = "1" ]; then
                # 中转服务器：从sni参数提取
                tls_server_name=$(echo "$transport" | grep -oP 'sni=\K[^;]+' || echo "")
            else
                # 落地服务器：从servername参数提取
                tls_server_name=$(echo "$transport" | grep -oP 'servername=\K[^;]+' || echo "")
            fi
        fi

        # 根据组合确定security_level
        if [ "$has_ws" = true ] && [ "$has_tls" = true ]; then
            # 检查是否为自签证书
            if echo "$transport" | grep -q "insecure"; then
                # 中转服务器：有insecure关键字 → 自签证书
                security_level="ws_tls_self"
            elif echo "$transport" | grep -q "servername="; then
                # 落地服务器：有servername参数 → 自签证书
                security_level="ws_tls_self"
            elif echo "$transport" | grep -q "cert=.*key="; then
                # 落地服务器：有cert和key参数 → CA证书
                security_level="ws_tls_ca"
            elif [ "$role" = "1" ]; then
                # 中转服务器：没有insecure → CA证书
                security_level="ws_tls_ca"
            else
                # 落地服务器：默认自签证书
                security_level="ws_tls_self"
            fi
        elif [ "$has_ws" = true ]; then
            security_level="ws"
        elif [ "$has_tls" = true ]; then
            # 检查是否为自签证书
            if echo "$transport" | grep -q "insecure"; then
                # 中转服务器：有insecure关键字 → 自签证书
                security_level="tls_self"
            elif echo "$transport" | grep -q "servername="; then
                # 落地服务器：有servername参数 → 自签证书
                security_level="tls_self"
            elif echo "$transport" | grep -q "cert=.*key="; then
                # 落地服务器：有cert和key参数 → CA证书
                security_level="tls_ca"
            elif [ "$role" = "1" ]; then
                # 中转服务器：没有insecure → CA证书
                security_level="tls_ca"
            else
                # 落地服务器：默认自签证书
                security_level="tls_self"
            fi
        fi
    fi

    echo "$security_level|$tls_server_name|$ws_path|$ws_host"
}

# 处理JSON格式
process_json() {
    local json_file="$1"

    # 检查是否有endpoints字段
    if ! jq -e '.endpoints' "$json_file" >/dev/null 2>&1; then
        echo "错误: 配置文件中未找到endpoints字段"
        return 1
    fi

    # 获取endpoints数组长度
    local endpoint_count=$(jq '.endpoints | length' "$json_file")
    if [ "$endpoint_count" -eq 0 ]; then
        echo "错误: endpoints数组为空"
        return 1
    fi

    echo "发现 $endpoint_count 个endpoint配置"

    # 处理每个endpoint
    for i in $(seq 0 $((endpoint_count - 1))); do
        local endpoint=$(jq ".endpoints[$i]" "$json_file")

        # 重置变量（避免污染）
        local listen="" remote="" extra_remotes="" balance="" listen_transport="" remote_transport=""
        local rule_role="" rule_name="" listen_ip="" listen_port="" remote_host="" remote_port=""
        local transport_to_parse="" security_level="" tls_server_name="" ws_path="" ws_host=""

        # 提取基本信息
        listen=$(echo "$endpoint" | jq -r '.listen // empty')
        remote=$(echo "$endpoint" | jq -r '.remote // empty')
        extra_remotes=$(echo "$endpoint" | jq -r '.extra_remotes[]? // empty' | tr '\n' ',' | sed 's/,$//')
        balance=$(echo "$endpoint" | jq -r '.balance // empty')
        listen_transport=$(echo "$endpoint" | jq -r '.listen_transport // empty')
        remote_transport=$(echo "$endpoint" | jq -r '.remote_transport // empty')

        if [ -z "$listen" ] || [ -z "$remote" ]; then
            echo "警告: endpoint $i 缺少必要字段，跳过"
            continue
        fi

        # 解析listen地址和端口
        local listen_ip="${listen%:*}"
        local listen_port="${listen##*:}"

        # 解析remote地址和端口
        local remote_host="${remote%:*}"
        local remote_port="${remote##*:}"

        # 判断规则角色
        local rule_role="1"  # 默认中转服务器
        local rule_name="中转"

        if [ -n "$listen_transport" ]; then
            # 有listen_transport字段，判断为落地服务器
            rule_role="2"
            rule_name="落地"
            # 落地服务器监听IP强制改为::（双栈监听）
            listen_ip="::"
        fi
        # 中转服务器保持原始监听IP

        # 解析transport配置
        local transport_to_parse=""
        if [ "$rule_role" = "1" ]; then
            transport_to_parse="$remote_transport"
        else
            transport_to_parse="$listen_transport"
        fi

        # 解析transport参数
        local transport_result=$(parse_transport_config "$transport_to_parse" "$rule_role")
        local security_level tls_server_name ws_path ws_host
        IFS='|' read -r security_level tls_server_name ws_path ws_host <<< "$transport_result"

        # 收集所有目标地址（主地址 + 额外地址）
        local all_targets=("$remote")
        if [ -n "$extra_remotes" ]; then
            IFS=',' read -ra extra_array <<< "$extra_remotes"
            for extra_addr in "${extra_array[@]}"; do
                extra_addr=$(echo "$extra_addr" | xargs)  # 去除空格
                all_targets+=("$extra_addr")
            done
        fi

        # 处理负载均衡配置
        local balance_mode="off"
        local weights=""
        if [ -n "$balance" ]; then
            if echo "$balance" | grep -q "roundrobin"; then
                balance_mode="roundrobin"
                # 提取权重 (格式: "roundrobin: 4, 2, 1")
                weights=$(echo "$balance" | sed 's/.*roundrobin:\s*//' | tr -d ' ')
            elif echo "$balance" | grep -q "iphash"; then
                balance_mode="iphash"
                # 提取权重 (格式: "iphash: 2, 1")
                weights=$(echo "$balance" | sed 's/.*iphash:\s*//' | tr -d ' ')
            fi
        fi

        # 为每个目标创建独立的规则文件（与主脚本兼容）
        local target_index=0
        for target in "${all_targets[@]}"; do
            local rule_id=$(generate_rule_id)
            local rule_file="$OUTPUT_DIR/rule-$rule_id.conf"

            # 解析目标地址和端口
            local target_host="${target%:*}"
            local target_port="${target##*:}"

            # 设置负载均衡参数（多目标时才设置）
            local rule_balance_mode="off"
            local rule_target_states=""
            local rule_weights=""

            if [ ${#all_targets[@]} -gt 1 ]; then
                # 多目标时设置负载均衡配置
                rule_balance_mode="$balance_mode"
                # 设置TARGET_STATES为所有目标的逗号分隔列表
                rule_target_states=$(IFS=','; echo "${all_targets[*]}")
                # 设置权重
                if [ -n "$weights" ]; then
                    rule_weights="$weights"
                else
                    # 默认权重：所有目标权重为1
                    local default_weights=()
                    for ((j=0; j<${#all_targets[@]}; j++)); do
                        default_weights+=("1")
                    done
                    rule_weights=$(IFS=','; echo "${default_weights[*]}")
                fi
            fi

            cat > "$rule_file" << RULE_EOF
RULE_ID=$rule_id
RULE_NAME="$rule_name"
RULE_ROLE="$rule_role"
SECURITY_LEVEL="$security_level"
LISTEN_PORT="$listen_port"
LISTEN_IP="$listen_ip"
ENABLED="true"
CREATED_TIME="$(get_gmt8_time '+%Y-%m-%d %H:%M:%S')"
RULE_NOTE=""

# 负载均衡配置
BALANCE_MODE="$rule_balance_mode"
TARGET_STATES="$rule_target_states"
WEIGHTS="$rule_weights"

# 故障转移配置
FAILOVER_ENABLED="false"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"

# MPTCP配置
MPTCP_MODE="off"

# Proxy配置
PROXY_MODE="off"
RULE_EOF

            if [ "$rule_role" = "1" ]; then
                # 中转服务器字段（使用主脚本的标准格式）
                cat >> "$rule_file" << RULE_EOF

# 中转服务器配置
THROUGH_IP="::"
REMOTE_HOST="$target_host"
REMOTE_PORT="$target_port"
TLS_SERVER_NAME="$tls_server_name"
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH="$ws_path"
WS_HOST="$ws_host"
RULE_EOF
            else
                # 落地服务器字段（使用主脚本的标准格式）
                cat >> "$rule_file" << RULE_EOF

# 落地服务器配置
FORWARD_TARGET="$target"
TLS_SERVER_NAME="$tls_server_name"
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH="$ws_path"
WS_HOST="$ws_host"
RULE_EOF
            fi

            # 构建显示信息
            local targets_display="$target_host:$target_port"
            if [ ${#all_targets[@]} -gt 1 ]; then
                targets_display="$targets_display (${target_index}/${#all_targets[@]})"
            fi

            echo "✓ 生成规则文件: rule-$rule_id.conf ($rule_name → $targets_display)"
            target_index=$((target_index + 1))
        done
    done

    return 0
}

# 处理TOML格式
process_toml() {
    local toml_file="$1"

    # 检查是否有toml转json的工具
    if command -v toml2json >/dev/null 2>&1; then
        local temp_json="/tmp/realm_toml_$$.json"
        toml2json "$toml_file" > "$temp_json"
        process_json "$temp_json"
        local result=$?
        rm -f "$temp_json"
        return $result
    elif command -v python3 >/dev/null 2>&1; then
        # 尝试使用python转换
        local temp_json="/tmp/realm_toml_$$.json"
        python3 -c "
import toml, json, sys
try:
    with open('$toml_file', 'r') as f:
        data = toml.load(f)
    with open('$temp_json', 'w') as f:
        json.dump(data, f)
except Exception as e:
    print(f'TOML转换失败: {e}')
    sys.exit(1)
" 2>/dev/null
        if [ $? -eq 0 ]; then
            process_json "$temp_json"
            local result=$?
            rm -f "$temp_json"
            return $result
        fi
    fi

    echo "错误: 暂不支持TOML格式，请转换为JSON格式后重试"
    return 1
}

# 主处理逻辑
case "$file_ext" in
    "json")
        if process_json "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 配置文件识别成功${NC}"
        else
            echo -e "${RED}✗ 配置文件识别失败${NC}"
            rm -rf "$OUTPUT_DIR"
            exit 1
        fi
        ;;
    "toml")
        if process_toml "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 配置文件识别成功${NC}"
        else
            echo -e "${RED}✗ 配置文件识别失败${NC}"
            rm -rf "$OUTPUT_DIR"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}错误: 不支持的文件格式${NC}"
        rm -rf "$OUTPUT_DIR"
        exit 1
        ;;
esac

echo ""

# 检查识别结果
rule_count=$(ls -1 "$OUTPUT_DIR"/rule-*.conf 2>/dev/null | wc -l)
if [ "$rule_count" -eq 0 ]; then
    echo -e "${RED}错误: 未识别到有效的realm配置${NC}"
    rm -rf "$OUTPUT_DIR"
    exit 1
fi

echo -e "${BLUE}识别到 $rule_count 个转发规则:${NC}"
for rule_file in "$OUTPUT_DIR"/rule-*.conf; do
    if [ -f "$rule_file" ]; then
        source "$rule_file"

        # 设置全局变量TLS_SERVER_NAME（ws_tls模式需要）
        TLS_SERVER_NAME="$TLS_SERVER_NAME"

        # 使用主脚本的get_security_display函数显示传输模式
        third_param=""
        case "$SECURITY_LEVEL" in
            "ws"|"ws_tls_self"|"ws_tls_ca")
                third_param="$WS_HOST"
                ;;
            *)
                third_param="$TLS_SERVER_NAME"
                ;;
        esac
        transport_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$third_param")

        # 构建负载均衡显示
        balance_display=""
        if [ "$BALANCE_MODE" != "off" ] && [ -n "$TARGET_STATES" ]; then
            target_count=$(echo "$TARGET_STATES" | tr ',' ' ' | wc -w)
            case "$BALANCE_MODE" in
                "roundrobin") balance_display=" [轮询负载均衡:${target_count}个目标" ;;
                "iphash") balance_display=" [IP哈希负载均衡:${target_count}个目标" ;;
                *) balance_display=" [${BALANCE_MODE}负载均衡:${target_count}个目标" ;;
            esac
            if [ -n "$WEIGHTS" ]; then
                balance_display="${balance_display},权重:$WEIGHTS"
            fi
            balance_display="${balance_display}]"
        fi

        if [ "$RULE_ROLE" = "1" ]; then
            # 中转服务器
            echo -e "  • ${GREEN}$RULE_NAME${NC}: $LISTEN_PORT → $REMOTE_HOST:$REMOTE_PORT"
            echo -e "    传输模式: ${YELLOW}$transport_display${NC}$balance_display"
        else
            # 落地服务器
            echo -e "  • ${GREEN}$RULE_NAME${NC}: $LISTEN_PORT → $FORWARD_TARGET"
            echo -e "    传输模式: ${YELLOW}$transport_display${NC}$balance_display"
        fi
    fi
done
echo ""

echo -e "${RED}警告: 导入操作将清空现有规则并导入新配置！${NC}"
echo -e "${YELLOW}这是初始化导入，会删除所有现有的转发规则${NC}"
echo ""
read -p "确认清空现有规则并导入新配置？(y/n): " confirm
if ! echo "$confirm" | grep -qE "^[Yy]$"; then
    echo -e "${BLUE}已取消导入操作${NC}"
    rm -rf "$OUTPUT_DIR"
    exit 1
fi

echo ""
echo -e "${YELLOW}正在清空现有规则...${NC}"

if [ -d "$RULES_DIR" ]; then
    rm -rf "$RULES_DIR"/*
    echo -e "${GREEN}✓${NC} 已清空现有规则"
fi

mkdir -p "$RULES_DIR"

echo -e "${YELLOW}正在导入新配置...${NC}"

imported_count=0
for rule_file in "$OUTPUT_DIR"/rule-*.conf; do
    if [ -f "$rule_file" ]; then
        rule_name=$(basename "$rule_file")
        cp "$rule_file" "$RULES_DIR/"
        imported_count=$((imported_count + 1))
        echo -e "${GREEN}✓${NC} 导入规则文件: $rule_name"
    fi
done

rm -rf "$OUTPUT_DIR"

if [ $imported_count -gt 0 ]; then
    echo -e "${GREEN}✓ realm配置导入成功，共导入 $imported_count 个规则${NC}"
    echo ""
    echo -e "${YELLOW}正在重启服务并优化规则排序...${NC}"

    # 直接调用主脚本的重启接口（包含自动排序功能）
    pf --restart-service

    echo -e "${GREEN}✓ 配置导入和优化完成${NC}"
    exit 0
else
    echo -e "${RED}✗ 配置导入失败${NC}"
    exit 1
fi