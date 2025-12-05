#!/bin/sh
#
# zfs_snap_manager.sh
# bsddialog 版 ZFS 快照管理工具
#

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
if [ "$SCRIPT_PATH" = "$0" ]; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi

# ---------------------------
# Terminal / size helpers
# ---------------------------
get_term_size() {
    TERM_LINES="$(tput lines 2>/dev/null || echo 24)"
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    TERM_LINES="$(printf '%d' "$TERM_LINES" 2>/dev/null || echo 24)"
    TERM_COLS="$(printf '%d' "$TERM_COLS" 2>/dev/null || echo 80)"
}

calc_dims() {
    desired_h="$1"
    desired_w="$2"
    content="$3"

    get_term_size

    if [ -n "$content" ]; then
        content_lines=$(printf '%s\n' "$content" | wc -l 2>/dev/null || echo 0)
        maxlen=$(printf '%s\n' "$content" | awk '{ if (length>l) l=length } END { print l+0 }' 2>/dev/null || echo 0)
    else
        content_lines=0
        maxlen=0
    fi

    maxw=$(( TERM_COLS - 4 ))
    maxh=$(( TERM_LINES - 4 ))

    w=$desired_w
    if [ "$maxlen" -gt "$w" ]; then
        w=$(( maxlen + 6 ))
    fi
    if [ "$w" -gt "$maxw" ]; then w=$maxw; fi
    if [ "$w" -lt 40 ]; then w=40; fi

    h=$desired_h
    if [ "$content_lines" -gt 0 ]; then
        desired_from_content=$(( content_lines + 6 ))
        if [ "$desired_from_content" -gt "$h" ]; then
            h=$desired_from_content
        fi
    fi
    if [ "$h" -gt "$maxh" ]; then h=$maxh; fi
    if [ "$h" -lt 8 ]; then h=8; fi

    printf '%d %d' "$h" "$w"
}

# ---------------------------
# Helpers for bsddialog/text
# ---------------------------
HAS_BSDDIALOG=0
if command -v bsddialog >/dev/null 2>&1; then
    HAS_BSDDIALOG=1
fi

bsd_inputbox() {
    prompt="$1"
    desired_h="${2:-8}"
    desired_w="${3:-60}"
    dims="$(calc_dims "$desired_h" "$desired_w" "$prompt")"
    h="$(echo "$dims" | awk '{print $1}')"
    w="$(echo "$dims" | awk '{print $2}')"

    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        bsddialog --title "ZFS 快照管理" --inputbox "$prompt" "$h" "$w" 3>&1 1>&2 2>&3
    else
        printf '%s\n' "$prompt"
        read -r result
        printf '%s\n' "$result"
    fi
}

bsd_passwordbox() {
    prompt="$1"
    desired_h="${2:-8}"
    desired_w="${3:-60}"
    dims="$(calc_dims "$desired_h" "$desired_w" "$prompt")"
    h="$(echo "$dims" | awk '{print $1}')"
    w="$(echo "$dims" | awk '{print $2}')"

    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        bsddialog --title "ZFS 快照管理" --passwordbox "$prompt" "$h" "$w" 3>&1 1>&2 2>&3
    else
        printf '%s\n' "$prompt"
        stty -echo 2>/dev/null || true
        read -r result
        stty echo 2>/dev/null || true
        printf '%s\n' "$result"
    fi
}

bsd_yesno() {
    prompt="$1"
    desired_h="${2:-8}"
    desired_w="${3:-60}"
    dims="$(calc_dims "$desired_h" "$desired_w" "$prompt")"
    h="$(echo "$dims" | awk '{print $1}')"
    w="$(echo "$dims" | awk '{print $2}')"

    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        bsddialog --title "ZFS 快照管理" --yesno "$prompt" "$h" "$w"
        return $?
    else
        printf '%s [y/N]: ' "$prompt"
        read -r resp
        case "$resp" in
            y|Y) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

bsd_msgbox() {
    prompt="$1"
    desired_h="${2:-8}"
    desired_w="${3:-60}"
    dims="$(calc_dims "$desired_h" "$desired_w" "$prompt")"
    h="$(echo "$dims" | awk '{print $1}')"
    w="$(echo "$dims" | awk '{print $2}')"

    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        bsddialog --title "ZFS 快照管理" --msgbox "$prompt" "$h" "$w"
    else
        printf '%s\n' "$prompt"
        printf "按回车继续..."
        read -r _
    fi
}

bsd_textbox() {
    title="$1"
    content="$2"
    desired_h="${3:-15}"
    desired_w="${4:-80}"
    dims="$(calc_dims "$desired_h" "$desired_w" "$content")"
    h="$(echo "$dims" | awk '{print $1}')"
    w="$(echo "$dims" | awk '{print $2}')"

    TMPFILE="$(mktemp 2>/dev/null || mktemp -t zfs_snap_manager 2>/dev/null || echo "/tmp/zfs_snap_manager.$$")"
    printf '%s\n' "$content" > "$TMPFILE"

    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        bsddialog --title "ZFS 快照管理 - $title" --textbox "$TMPFILE" "$h" "$w"
    else
        printf '=== %s ===\n' "$title"
        cat "$TMPFILE"
        printf "\n按回车继续..."
        read -r _
    fi

    rm -f "$TMPFILE" 2>/dev/null || true
}

bsd_menu() {
    prompt="$1"
    shift
    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        bsddialog --title "ZFS 快照管理" --menu "$prompt" 0 0 0 "$@" 3>&1 1>&2 2>&3
    else
        echo "$prompt"
        i=1
        args="$@"
        set -- $args
        while [ $# -gt 0 ]; do
            tag="$1"; shift
            desc="$1"; shift
            printf "  %s) %s\n" "$tag" "$desc"
            i=$((i+1))
        done
        printf "输入选择: "
        read -r sel
        printf "%s\n" "$sel"
    fi
}

# ---------------------------
# Privilege escalation
# ---------------------------
check_root_and_escalate() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        PASS="$(bsd_passwordbox "当前未以 root 运行。\n请输入 sudo 密码以提权并继续（留空或取消将退出）:" 10 70)"
        if [ -z "$PASS" ]; then
            echo "未输入密码，退出。"
            exit 1
        fi
        printf "%s\n" "$PASS" | sudo -S sh "$SCRIPT_PATH" "$@"
        exit $?
    fi

    if command -v doas >/dev/null 2>&1; then
        bsd_yesno "检测到 doas。是否使用 doas 以 root 运行脚本？\n（注意：doas 可能会在终端直接请求密码；若在 GUI 环境请在终端运行脚本。）" 10 70
        if [ $? -eq 0 ]; then
            exec doas sh "$SCRIPT_PATH" "$@"
            exit $?
        else
            bsd_msgbox "请以 root 或通过 doas/sudo 运行此脚本。脚本退出。" 8 60
            exit 1
        fi
    fi

    bsd_yesno "系统未检测到 sudo 或 doas。是否使用 su 切换到 root？\n（选择是后将进入 root shell，完成认证后请在 root shell 中重新运行本脚本）" 12 80
    if [ $? -eq 0 ]; then
        exec su -
        echo "无法执行 su，退出。"
        exit 1
    else
        bsd_msgbox "请以 root 或通过 sudo/doas 运行此脚本后再试。脚本退出。" 10 60
        exit 1
    fi
}

# ---------------------------
# ZFS helpers
# ---------------------------
zfs_exists() {
    command -v zfs >/dev/null 2>&1
}

check_snapshots_exist() {
    if ! zfs_exists; then
        return 2
    fi
    if zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | grep -q .; then
        return 0
    else
        return 1
    fi
}

show_no_snapshots_then_wait() {
    bsd_msgbox "当前不存在任何 ZFS 快照。\n请先使用“创建快照”功能创建快照，然后再重试。" 10 70
}

read_lines_to_array() {
    idx=0
    while IFS= read -r line; do
        arr[$idx]="$line"
        idx=$((idx+1))
    done <<EOF
$1
EOF
}

dataset_of_snapshot() {
    printf '%s' "$1" | awk -F'@' '{print $1}'
}

tag_of_snapshot() {
    printf '%s' "$1" | awk -F'@' '{print $2}'
}

# ---------------------------
# Deletion implementations
# ---------------------------
do_recursive_destroy_optimized() {
    snapshots="$1"
    success=0
    fail=0
    tuples=""
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        ds=$(dataset_of_snapshot "$s")
        depth=$(printf '%s' "$ds" | awk -F'/' '{print NF-1}')
        tuples="${tuples}${depth}|${ds}|${s}
"
    done <<EOF
$snapshots
EOF

    sorted=$(printf '%s' "$tuples" | awk -F'|' '{print $1 "|" $2 "|" $3}' | sort -n -t'|' -k1,1 || true)

    destroyed_list=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        depth=$(printf '%s' "$line" | cut -d'|' -f1)
        ds=$(printf '%s' "$line" | cut -d'|' -f2)
        snap=$(printf '%s' "$line" | cut -d'|' -f3-)
        skip=0
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            case "$ds" in
                "$d"|"${d}"/*)
                    skip=1
                    break
                    ;;
            esac
        done <<EOF
$destroyed_list
EOF
        if [ $skip -eq 1 ]; then
            printf "跳过已由上级递归删除覆盖的快照: %s\n" "$snap"
            continue
        fi

        printf "正在递归删除: %s\n" "$snap"
        if zfs destroy -r "$snap"; then
            printf "  成功\n"
            success=$((success+1))
            destroyed_list="${destroyed_list}${ds}
"
        else
            printf "  失败\n"
            fail=$((fail+1))
        fi
    done <<EOF
$sorted
EOF

    printf "\n递归删除完成，成功: %d，失败: %d\n" "$success" "$fail"
}

do_nonrecursive_destroy() {
    snapshots="$1"
    success=0
    fail=0
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        printf "正在删除: %s\n" "$s"
        if zfs destroy "$s"; then
            printf "  成功\n"
            success=$((success+1))
        else
            printf "  失败\n"
            fail=$((fail+1))
        fi
    done <<EOF
$snapshots
EOF
    printf "\n删除完成，成功: %d，失败: %d\n" "$success" "$fail"
}

do_recursive_destroy_manual() {
    snapshots="$1"
    success=0
    fail=0
    tuples=""
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        ds=$(dataset_of_snapshot "$s")
        depth=$(printf '%s' "$ds" | awk -F'/' '{print NF-1}')
        tuples="${tuples}${depth}|${ds}|${s}
"
    done <<EOF
$snapshots
EOF

    sorted=$(printf '%s' "$tuples" | sort -t'|' -k1,1nr || true)

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        snap=$(printf '%s' "$line" | cut -d'|' -f3-)
        printf "正在删除: %s\n" "$snap"
        if zfs destroy "$snap"; then
            printf "  成功\n"
            success=$((success+1))
        else
            printf "  失败\n"
            fail=$((fail+1))
        fi
    done <<EOF
$sorted
EOF

    printf "\n按树状顺序逐个删除完成，成功: %d，失败: %d\n" "$success" "$fail"
}

# ---------------------------
# Main menu and actions (bsddialog-driven)
# ---------------------------
main_menu_bsddialog() {
    while true; do
        if [ "$HAS_BSDDIALOG" -eq 1 ]; then
            choice=$(bsddialog --title "FreeBSD 中文社区 ZFS 快照管理" --menu "请选择要执行的操作：" 15 60 6 \
                1 "创建快照" \
                2 "还原快照" \
                3 "删除快照" \
                4 "查看快照" \
                5 "退出程序" 3>&1 1>&2 2>&3)
        else
            echo "===== FreeBSD 中文社区 ZFS 快照管理 ====="
            echo "1) 创建快照"
            echo "2) 还原快照"
            echo "3) 删除快照"
            echo "4) 查看快照"
            echo "5) 退出程序"
            printf "输入选择: "
            read -r choice
        fi

        case "$choice" in
            1) create_snapshot_flow ;;
            2) restore_snapshot_flow ;;
            3) delete_snapshot_flow ;;
            4) view_snapshots_flow ;;
            5)
                bsd_yesno "确定要退出程序吗？" 8 50 && exit 0 || true
                ;;
            *)
                bsd_msgbox "选择无效，请重新选择。" 8 50
                ;;
        esac
    done
}

# ---------------------------
# Create snapshot flow
# ---------------------------
create_snapshot_flow() {
    if ! zfs_exists; then
        bsd_msgbox "错误：未检测到 zfs 命令，请检查系统是否安装并可用。" 10 70
        return 1
    fi

    datasets="$(zfs list -o name,used,avail,refer,mountpoint 2>/dev/null | sed -n '1,20p' || true)"
    if [ -z "$datasets" ]; then
        bsd_msgbox "无法获取 ZFS 存储池/数据集列表（或者无数据集）" 10 70
        return 1
    fi

    bsd_textbox "可用的存储池/数据集（前 20 行）" "$datasets" 18 90

    pool_name="$(bsd_inputbox "要为哪个 存储池 / 数据集 创建快照？请输入名称：" 8 70)"
    [ -z "$pool_name" ] && return 0

    if ! zfs list "$pool_name" >/dev/null 2>&1; then
        bsd_msgbox "错误：存储池/数据集 '$pool_name' 未找到，请确认名称是否正确。" 10 70
        return 1
    fi

    snapshot_tag="$(bsd_inputbox "请输入快照标签（例如：daily-2025-12-05；留空则使用默认：test）：" 8 70)"
    if [ -z "$snapshot_tag" ]; then
        snapshot_tag="test"
    fi

    bsd_yesno "是否对 $pool_name 使用递归创建（-r）？\n提示：若选择的是顶级 pool，通常需要 -r 才能包含子数据集。" 10 80
    use_recursive=$?

    snapname="${pool_name}@${snapshot_tag}"
    if [ $use_recursive -eq 0 ]; then
        bsd_msgbox "将以递归方式创建快照： $snapname（可能包含子数据集）" 8 70
        if zfs snapshot -r "$snapname"; then
            bsd_msgbox "递归快照创建成功： $snapname" 8 60
        else
            bsd_msgbox "递归快照创建失败，请检查权限或错误信息。" 8 60
        fi
    else
        bsd_msgbox "将以非递归方式创建快照： $snapname（仅当前数据集）" 8 70
        if zfs snapshot "$snapname"; then
            bsd_msgbox "快照创建成功： $snapname" 8 60
        else
            bsd_msgbox "快照创建失败，请检查权限或错误信息。" 8 60
        fi
    fi
}

# ---------------------------
# Restore flow (by tag)
# ---------------------------
restore_snapshot_flow() {
    check_snapshots_exist
    rc=$?
    if [ $rc -eq 2 ]; then
        bsd_msgbox "错误：zfs 命令未找到或执行出错。" 10 70
        return 1
    elif [ $rc -eq 1 ]; then
        show_no_snapshots_then_wait
        return 1
    fi

    tags="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | awk -F'@' '{print $2}' | sort -u || true)"
    if [ -z "$tags" ]; then
        bsd_msgbox "未能获取可用快照标签。" 8 60
        return 1
    fi

    bsd_textbox "可用的快照标签（去重）" "$tags" 12 70
    tag_choice="$(bsd_inputbox "请输入要还原的快照标签（例如：daily-2025-12-05）：" 8 70)"
    [ -z "$tag_choice" ] && return 0

    snapshots="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | grep "@${tag_choice}$" | grep -v "^$" || true)"
    if [ -z "$snapshots" ]; then
        bsd_msgbox "未找到任何标签为 @${tag_choice} 的快照。" 10 70
        return 1
    fi

    bsd_textbox "将要还原的快照清单" "$snapshots" 18 90
    bsd_yesno "是否对这些快照使用递归还原（-r）？\n提示：递归还原会同时还原子数据集，可能影响子数据集的数据。" 10 80
    use_recursive=$?

    success=0
    fail=0
    while IFS= read -r snap; do
        [ -z "$snap" ] && continue
        if [ $use_recursive -eq 0 ]; then
            printf "正在递归还原: %s\n" "$snap"
            if zfs rollback -r "$snap"; then
                success=$((success+1))
            else
                fail=$((fail+1))
            fi
        else
            printf "正在非递归还原: %s\n" "$snap"
            if zfs rollback "$snap"; then
                success=$((success+1))
            else
                fail=$((fail+1))
            fi
        fi
    done <<EOF
$snapshots
EOF

    bsd_msgbox "还原完成。\n成功: $success，失败: $fail" 10 70
}

# ---------------------------
# Delete flow (增强)
# ---------------------------
delete_snapshot_flow() {
    check_snapshots_exist
    rc=$?
    if [ $rc -eq 2 ]; then
        bsd_msgbox "错误：zfs 命令未找到或执行出错。" 10 70
        return 1
    elif [ $rc -eq 1 ]; then
        show_no_snapshots_then_wait
        return 1
    fi

    pool_mode=0

    if [ "$HAS_BSDDIALOG" -eq 1 ]; then
        delmode=$(bsddialog --title "删除快照" --menu "请选择删除方式（按数字选择）：" 15 60 6 \
            1 "按标签删除（删除所有匹配标签的快照）" \
            2 "按存储池/数据集删除（删除该数据集的所有快照，逐个删除而非递归）" \
            3 "按完整快照名称删除" \
            4 "查看快照统计信息" 3>&1 1>&2 2>&3)
    else
        echo "删除方式："
        echo "1) 按标签删除（删除所有匹配标签的快照）"
        echo "2) 按存储池/数据集删除（删除该数据集的所有快照，逐个删除而非递归）"
        echo "3) 按完整快照名称删除"
        echo "4) 查看快照统计信息"
        printf "选择: "
        read -r delmode
    fi

    case "$delmode" in
        1)
            tags="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | awk -F'@' '{print $2}' | sort -u || true)"
            if [ -z "$tags" ]; then
                bsd_msgbox "未能获取可用快照标签。" 8 60
                return 1
            fi
            bsd_textbox "可用的快照标签" "$tags" 12 70
            tag_choice="$(bsd_inputbox "请输入要删除的快照标签（将删除所有匹配的快照）：" 8 70)"
            [ -z "$tag_choice" ] && return 0
            snapshots="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | grep "@${tag_choice}$" | grep -v "^$" || true)"
            if [ -z "$snapshots" ]; then
                bsd_msgbox "未找到标签为 @${tag_choice} 的快照。" 10 70
                return 1
            fi
            ;;

        2)
            pools="$(zfs list -o name 2>/dev/null | sed -n '2,$p' || true)"
            if [ -z "$pools" ]; then
                bsd_msgbox "未能获取可用存储池/数据集。" 8 60
                return 1
            fi
            bsd_textbox "可用存储池/数据集" "$pools" 18 80
            pool_choice="$(bsd_inputbox "请输入要删除快照的存储池/数据集（例如：tank 或 tank/dataset）：\n注意：将逐个删除匹配范围内的快照（不会自动使用 zfs -r）：" 10 90)"
            [ -z "$pool_choice" ] && return 0

            # 使用字符串前缀检测，避免将 tank 与 tank2 混淆：
            # top-level snapshots: index(line, pool_choice "@") == 1
            # child snapshots: index(line, pool_choice "/") == 1
            ALL_SNAP_LIST="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' || true)"

            top_snaps="$(printf '%s\n' "$ALL_SNAP_LIST" | awk -v p="$pool_choice" 'index($0,p"@")==1 { print }')"
            child_snaps="$(printf '%s\n' "$ALL_SNAP_LIST" | awk -v p="$pool_choice" 'index($0,p"/")==1 { print }')"
            # combined
            combined_snaps="$(printf '%s\n' "$top_snaps"$'\n'"$child_snaps" | awk 'NF' || true)"

            if [ -z "$combined_snaps" ]; then
                bsd_msgbox "存储池/数据集 '$pool_choice' 及其子数据集没有快照。" 10 70
                return 1
            fi

            pool_mode=1

            # If user input contains '/', it's a specific child dataset - show clearer prompt
            if printf '%s' "$pool_choice" | grep -q '/'; then
                extra_note="（您输入的是子数据集，系统将匹配 dataset 前缀为 '$pool_choice' 的所有快照，包括子数据集）"
            else
                extra_note=""
            fi

            # prepare menu choices (show counts)
            cnt_top="$(printf '%s\n' "$top_snaps" | awk 'NF' | wc -l | tr -d ' ')"
            cnt_child="$(printf '%s\n' "$child_snaps" | awk 'NF' | wc -l | tr -d ' ')"
            cnt_total="$(printf '%s\n' "$combined_snaps" | awk 'NF' | wc -l | tr -d ' ')"

            opt1_desc="仅顶级（仅 ${pool_choice}@* ，共 ${cnt_top} 个）"
            opt2_desc="仅子数据集（${pool_choice}/...@* ，共 ${cnt_child} 个）"
            opt3_desc="顶级 + 子数据集（共 ${cnt_total} 个）"

            if [ "$HAS_BSDDIALOG" -eq 1 ]; then
                range_choice=$(bsddialog --title "选择删除范围" --menu "请选择要删除的范围：\n$extra_note" 14 90 3 \
                    1 "$opt1_desc" \
                    2 "$opt2_desc" \
                    3 "$opt3_desc" 3>&1 1>&2 2>&3)
            else
                echo "请选择要删除的范围： $extra_note"
                echo "1) $opt1_desc"
                echo "2) $opt2_desc"
                echo "3) $opt3_desc"
                printf "选择: "
                read -r range_choice
            fi

            case "$range_choice" in
                1)
                    snapshots="$top_snaps"
                    ;;
                2)
                    snapshots="$child_snaps"
                    ;;
                3)
                    snapshots="$combined_snaps"
                    ;;
                *)
                    bsd_msgbox "无效选择，操作取消。" 8 60
                    return 0
                    ;;
            esac

            # ensure not empty (e.g., user chose only top but top count is 0)
            if [ -z "$snapshots" ]; then
                bsd_msgbox "所选范围内没有快照可删除。操作取消。" 10 70
                return 0
            fi

            # Before delete: write snapshot list to temp file and create undo script draft
            TMP_DELETED_LIST="$(mktemp /tmp/zfs_deleted_list.XXXXXX 2>/dev/null || mktemp -t zfs_deleted_list.XXXXXX 2>/dev/null || echo /tmp/zfs_deleted_list.$$)"
            TMP_UNDO_SCRIPT="$(mktemp /tmp/zfs_undo_script.XXXXXX 2>/dev/null || mktemp -t zfs_undo_script.XXXXXX 2>/dev/null || echo /tmp/zfs_undo_script.$$)"
            printf '%s\n' "$snapshots" > "$TMP_DELETED_LIST"

            cat > "$TMP_UNDO_SCRIPT" <<'EOF'
#!/bin/sh
# 撤销脚本草稿（仅供审计与手动恢复指引）
# 说明：
#  - 此脚本不会自动恢复被删除的快照（因为恢复需要你自己的备份/发送流）。
#  - 如果你之前对这些快照做了 zfs send 的备份，可手动使用 zfs receive 恢复。
#  - 本脚本将列出被删除的快照，并为每个快照给出建议恢复命令模板（需根据你的备份实际情况修改）。
#
DELETED_LIST="@DELETED_LIST@"

echo "被删除的快照已保存到：$DELETED_LIST"
echo "列出快照："
cat "$DELETED_LIST"
echo
echo "恢复指引（示例，请根据你的实际备份情况调整并执行）："
echo "例如：如果你有 <snapshot>.zstream 文件或 zfs send 的输出，使用:"
echo "  zfs receive -F <pool>/<dataset>"
echo
echo "若你使用 zfs send 将快照发送到远程或文件，请参考以下模板（请勿直接运行，先确认你的备份位置）:"
echo
while IFS= read -r s; do
    [ -z "$s" ] && continue
    ds=$(printf '%s' "$s" | awk -F'@' '{print $1}')
    tag=$(printf '%s' "$s" | awk -F'@' '{print $2}')
    echo "----"
    echo "# 快照: $s"
    echo "# 恢复示例（假设已有 send 的流）："
    echo "# zfs receive -F ${ds}"
    echo "# 或者（如果你有 send 的文件）："
    echo "# cat ${ds}@${tag}.zstream | zfs receive -F ${ds}"
done < "$DELETED_LIST"
echo
echo "注意：请在恢复前确保目标数据集存在且接收命令与你的备份数据来源匹配。"
EOF
            # replace placeholder with actual path
            sed "s|@DELETED_LIST@|$TMP_DELETED_LIST|g" "$TMP_UNDO_SCRIPT" 2>/dev/null || true
            chmod +x "$TMP_UNDO_SCRIPT" 2>/dev/null || true

            bsd_textbox "将要删除的快照（已写入临时文件）" "$snapshots" 18 90
            bsd_msgbox "已将将要删除的快照清单写入：\n$TMP_DELETED_LIST\n\n已生成撤销脚本草稿（请手动审计并根据实际备份修改）：\n$TMP_UNDO_SCRIPT" 16 90

            # ask deletion mode for pool-based operation
            bsd_yesno "您选择按 存储池/数据集 删除（已选择范围）。是否要以“递归（手动逐个）”方式删除（即先删除子再删除父，不使用 zfs -r）？\n说明：递归方式会优先删除子数据集的快照以避免 zfs destroy -r 冲突。" 14 90
            if [ $? -eq 0 ]; then
                bsd_yesno "确定要对上述清单执行 递归（手动逐个）删除 吗？此操作不可逆。" 10 70
                if [ $? -ne 0 ]; then
                    bsd_msgbox "操作已取消。" 8 50
                    return 0
                fi
                do_recursive_destroy_manual "$snapshots"
                bsd_msgbox "按存储池递归（逐个）删除操作已完成（请查看上方输出）" 8 70
                return 0
            else
                bsd_yesno "将以非递归方式逐个删除上述快照（不使用 -r）。确定要继续吗？" 12 90
                if [ $? -ne 0 ]; then
                    bsd_msgbox "操作已取消。" 8 50
                    return 0
                fi
                do_nonrecursive_destroy "$snapshots"
                bsd_msgbox "按存储池逐个删除操作已完成（请查看上方输出）" 8 70
                return 0
            fi
            ;;

        3)
            full_name="$(bsd_inputbox "请输入完整快照名称（例如：zroot@test）： " 8 70)"
            [ -z "$full_name" ] && return 0
            if ! zfs list -t snapshot "$full_name" >/dev/null 2>&1; then
                bsd_msgbox "快照 '$full_name' 不存在。" 10 70
                return 1
            fi
            snapshots="$full_name"
            ;;

        4)
            show_snapshot_stats_text
            return 0
            ;;

        *)
            bsd_msgbox "无效选择，请重试。" 8 50
            return 1
            ;;
    esac

    # For modes other than pool-mode (tag/full name), show and ask recursive vs non-recursive as before
    if [ "$pool_mode" -ne 1 ]; then
        bsd_textbox "将要删除以下快照" "$snapshots" 18 90

        bsd_yesno "是否使用递归删除（-r）？\n说明：选择是将以递归方式删除并对候选快照做递归删除优化；若顶级已删除则会跳过其子快照。" 12 80
        use_recursive=$?

        if [ $use_recursive -eq 0 ]; then
            bsd_yesno "确定要递归删除以上所有快照吗？此操作不可逆。" 10 70
            if [ $? -ne 0 ]; then
                bsd_msgbox "操作已取消。" 8 50
                return 0
            fi

            # Create temp list & undo draft for auditing
            TMP_DELETED_LIST="$(mktemp /tmp/zfs_deleted_list.XXXXXX 2>/dev/null || mktemp -t zfs_deleted_list.XXXXXX 2>/dev/null || echo /tmp/zfs_deleted_list.$$)"
            TMP_UNDO_SCRIPT="$(mktemp /tmp/zfs_undo_script.XXXXXX 2>/dev/null || mktemp -t zfs_undo_script.XXXXXX 2>/dev/null || echo /tmp/zfs_undo_script.$$)"
            printf '%s\n' "$snapshots" > "$TMP_DELETED_LIST"
            cat > "$TMP_UNDO_SCRIPT" <<'EOF'
#!/bin/sh
# 撤销脚本草稿（请参考并根据你的备份修改）
DELETED_LIST="@DELETED_LIST@"
echo "被删除快照列表在：$DELETED_LIST"
cat "$DELETED_LIST"
EOF
            sed "s|@DELETED_LIST@|$TMP_DELETED_LIST|g" "$TMP_UNDO_SCRIPT" 2>/dev/null || true
            chmod +x "$TMP_UNDO_SCRIPT" 2>/dev/null || true
            bsd_msgbox "已写入将要删除的清单到：\n$TMP_DELETED_LIST\n并创建撤销脚本草稿：\n$TMP_UNDO_SCRIPT" 12 80

            do_recursive_destroy_optimized "$snapshots"
            bsd_msgbox "递归删除操作已完成（请查看上方输出）" 8 70
        else
            bsd_yesno "确定要逐个删除以上所有快照吗？（非递归）" 8 70
            if [ $? -ne 0 ]; then
                bsd_msgbox "操作已取消。" 8 50
                return 0
            fi

            TMP_DELETED_LIST="$(mktemp /tmp/zfs_deleted_list.XXXXXX 2>/dev/null || mktemp -t zfs_deleted_list.XXXXXX 2>/dev/null || echo /tmp/zfs_deleted_list.$$)"
            TMP_UNDO_SCRIPT="$(mktemp /tmp/zfs_undo_script.XXXXXX 2>/dev/null || mktemp -t zfs_undo_script.XXXXXX 2>/dev/null || echo /tmp/zfs_undo_script.$$)"
            printf '%s\n' "$snapshots" > "$TMP_DELETED_LIST"
            cat > "$TMP_UNDO_SCRIPT" <<'EOF'
#!/bin/sh
# 撤销脚本草稿（请参考并根据你的备份修改）
DELETED_LIST="@DELETED_LIST@"
echo "被删除快照列表在：$DELETED_LIST"
cat "$DELETED_LIST"
EOF
            sed "s|@DELETED_LIST@|$TMP_DELETED_LIST|g" "$TMP_UNDO_SCRIPT" 2>/dev/null || true
            chmod +x "$TMP_UNDO_SCRIPT" 2>/dev/null || true
            bsd_msgbox "已写入将要删除的清单到：\n$TMP_DELETED_LIST\n并创建撤销脚本草稿：\n$TMP_UNDO_SCRIPT" 12 80

            do_nonrecursive_destroy "$snapshots"
            bsd_msgbox "删除操作已完成（请查看上方输出）" 8 70
        fi
    fi
}

# ---------------------------
# View snapshots
# ---------------------------
view_snapshots_flow() {
    check_snapshots_exist
    rc=$?
    if [ $rc -eq 2 ]; then
        bsd_msgbox "错误：zfs 命令未找到或执行出错。" 10 70
        return 1
    elif [ $rc -eq 1 ]; then
        show_no_snapshots_then_wait
        return 1
    fi

    list="$(zfs list -t snapshot -o name,used,refer,creation 2>/dev/null | sed -n '2,$p' || true)"
    if [ -z "$list" ]; then
        bsd_msgbox "当前没有快照。" 8 50
        return 0
    fi
    bsd_textbox "所有快照" "$list" 20 100
    show_snapshot_stats_text
}

show_snapshot_stats_text() {
    total_snapshots="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | wc -l || true)"
    pools_stats="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | awk -F'/' '{print $1}' | awk -F'@' '{print $1}' | sort | uniq -c || true)"
    tag_stats="$(zfs list -t snapshot -o name 2>/dev/null | sed -n '2,$p' | awk -F'@' '{print $2}' | sort | uniq -c || true)"
    bsd_msgbox "统计信息：\n快照总数: $total_snapshots\n\n按存储池统计:\n$(printf '%s\n' "$pools_stats")\n\n按标签统计:\n$(printf '%s\n' "$tag_stats")" 20 100
}

# ---------------------------
# Start
# ---------------------------
check_root_and_escalate "$@"

main_menu_bsddialog

exit 0
