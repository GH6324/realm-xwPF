#!/bin/bash

# xw_realm_OCR.sh - Realm配置文件识别脚本
# 识别用户的realm配置文件，识别endpoints字段，导入脚本管理

# 颜色定义（与主脚本保持一致）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

# 获取GMT+8时间（复制自主脚本）
get_gmt8_time() {
    TZ='GMT-8' date "$@"
}

# 生成新的规则ID(主脚本)
generate_rule_id() {
    local max_id=0
    # 检查现有规则目录
    if [ -d "$RULES_DIR" ]; then
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                local id=$(basename "$rule_file" | sed 's/rule-\([0-9]*\)\.conf/\1/')
                if [ "$id" -gt "$max_id" ]; then
                    max_id=$id
                fi
            fi
        done
    fi
    # 检查临时输出目录（避免导入时ID重复）
    if [ -d "$OUTPUT_DIR" ]; then
        for rule_file in "${OUTPUT_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                local id=$(basename "$rule_file" | sed 's/rule-\([0-9]*\)\.conf/\1/')
                if [ "$id" -gt "$max_id" ]; then
                    max_id=$id
                fi
            fi
        done
    fi
    echo $((max_id + 1))
}

# 配置路径定义（与主脚本保持一致）
CONFIG_DIR="/etc/realm"
RULES_DIR="${CONFIG_DIR}/rules"

# 检查参数
if [ -n "$1" ]; then
    RULES_DIR="$1"
fi

echo -e "${YELLOW}=== 识别realm配置文件并导入 ===${NC}"
echo ""

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

        # 提取基本信息
        local listen=$(echo "$endpoint" | jq -r '.listen // empty')
        local remote=$(echo "$endpoint" | jq -r '.remote // empty')
        local extra_remotes=$(echo "$endpoint" | jq -r '.extra_remotes[]? // empty' | tr '\n' ',' | sed 's/,$//')
        local balance=$(echo "$endpoint" | jq -r '.balance // empty')
        local listen_transport=$(echo "$endpoint" | jq -r '.listen_transport // empty')
        local remote_transport=$(echo "$endpoint" | jq -r '.remote_transport // empty')

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

        # 为多目标配置设置负载均衡参数
        local rule_balance_mode="off"
        local rule_target_states=""
        local rule_weights=""

        if [ ${#all_targets[@]} -gt 1 ]; then
            # 多目标时使用负载均衡配置
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

        # 为每个目标创建独立的规则文件
        local target_index=0
        for target in "${all_targets[@]}"; do
            # 使用主脚本的标准规则ID生成函数
            local rule_id=$(generate_rule_id)

            # 解析目标地址和端口
            local target_host="${target%:*}"
            local target_port="${target##*:}"

            # 创建规则文件（使用主脚本的标准格式）
            local rule_file="$OUTPUT_DIR/rule-$rule_id.conf"

            cat > "$rule_file" << RULE_EOF
RULE_ID=$rule_id
RULE_NAME="$rule_name"
RULE_ROLE="$rule_role"
SECURITY_LEVEL="standard"
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
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_EOF
            else
                # 落地服务器字段（使用主脚本的标准格式）
                cat >> "$rule_file" << RULE_EOF

# 落地服务器配置
FORWARD_TARGET="$target"
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_EOF
            fi

            echo "✓ 生成规则文件: rule-$rule_id.conf ($rule_name → $target_host:$target_port)"
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
        if [ "$RULE_ROLE" = "1" ]; then
            # 中转服务器
            echo -e "  • ${GREEN}$RULE_NAME${NC}: $LISTEN_PORT → $REMOTE_HOST:$REMOTE_PORT"
        else
            # 落地服务器
            echo -e "  • ${GREEN}$RULE_NAME${NC}: $LISTEN_PORT → $FORWARD_TARGET"
        fi
    fi
done
echo ""

# 确认导入
echo -e "${RED}警告: 导入操作将清空现有规则并导入新配置！${NC}"
echo -e "${YELLOW}这是初始化导入，会删除所有现有的转发规则${NC}"
echo ""
read -p "确认清空现有规则并导入新配置？(y/n): " confirm
if ! echo "$confirm" | grep -qE "^[Yy]$"; then
    echo -e "${BLUE}已取消导入操作${NC}"
    rm -rf "$OUTPUT_DIR"
    exit 1
fi

# 执行初始化导入
echo ""
echo -e "${YELLOW}正在清空现有规则...${NC}"

# 清空现有规则目录
if [ -d "$RULES_DIR" ]; then
    rm -rf "$RULES_DIR"/*
    echo -e "${GREEN}✓${NC} 已清空现有规则"
fi

# 重新创建规则目录
mkdir -p "$RULES_DIR"

echo -e "${YELLOW}正在导入新配置...${NC}"

# 导入规则文件
imported_count=0
for rule_file in "$OUTPUT_DIR"/rule-*.conf; do
    if [ -f "$rule_file" ]; then
        rule_name=$(basename "$rule_file")
        cp "$rule_file" "$RULES_DIR/"
        imported_count=$((imported_count + 1))
        echo -e "${GREEN}✓${NC} 导入规则文件: $rule_name"
    fi
done

# 清理临时目录
rm -rf "$OUTPUT_DIR"

if [ $imported_count -gt 0 ]; then
    echo -e "${GREEN}✓ realm配置导入成功，共导入 $imported_count 个规则${NC}"
    exit 0
else
    echo -e "${RED}✗ 配置导入失败${NC}"
    exit 1
fi