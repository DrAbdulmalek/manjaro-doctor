#!/usr/bin/env bash
#
# boot-sanity-check.sh
# يكتشف حالتين شائعتين تسببان فشل الإقلاع بعد تحديث Manjaro على btrfs:
#   1) النظام الحالي يعمل فعلياً من داخل لقطة timeshift بدل subvolume @ الحقيقي.
#   2) grub.cfg (الإدخال الرئيسي غير submenu اللقطات) يشير لمسار /boot داخل لقطة قديمة.
#   3) الحل الوقائي الدائم (rootflags=subvol=@) غير مُفعّل.
#
# الاستخدام:
#   sudo ./boot-sanity-check.sh          # فحص فقط (نصي)
#   sudo ./boot-sanity-check.sh --json   # فحص فقط (JSON — للاستهلاك من واجهات GUI)
#   sudo ./boot-sanity-check.sh --fix    # فحص + إصلاح تلقائي إن كان آمناً
#
set -euo pipefail

FIX_MODE=false
JSON_MODE=false
for arg in "${@:-}"; do
    case "$arg" in
        --fix)  FIX_MODE=true ;;
        --json) JSON_MODE=true ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok()   { [[ "$JSON_MODE" == "false" ]] && echo -e "${GREEN}[OK]${NC} $1" || true; }
log_warn() { [[ "$JSON_MODE" == "false" ]] && echo -e "${YELLOW}[تحذير]${NC} $1" || true; }
log_err()  { [[ "$JSON_MODE" == "false" ]] && echo -e "${RED}[خطأ]${NC} $1" || true; }

if [[ $EUID -ne 0 ]]; then
    if [[ "$JSON_MODE" == "true" ]]; then
        echo '{"error": "شغّل السكربت عبر sudo."}'
        exit 1
    fi
    log_err "شغّل السكربت عبر sudo."
    exit 1
fi

# ── متغيرات JSON (تُجمع دائماً، تُخرج فقط مع --json) ────────────────────
J_RUNNING_FROM_SNAPSHOT=false
J_GRUB_POINTS_TO_SNAPSHOT=false
J_KERNEL_MISSING=false
J_PREVENTIVE_FIX_ENABLED=false
J_CAN_AUTO_FIX=true
J_ROOT_SOURCE=""
J_GRUB_LINE=""
J_KERNEL_NAME=""
J_PROBLEMS="[]"   # JSON array of problem objects
J_FIX_COMMANDS="[]"  # JSON array of fix command strings

# دالة مساعدة لإضافة مشكلة لـ J_PROBLEMS (JSON)
add_problem() {
    local id="$1" severity="$2" message="$3" detail="${4:-}"
    # نبنى كائن JSON يدوياً (لتجنب الاعتماد على jq)
    local entry="{\"id\":\"$id\",\"severity\":\"$severity\",\"message\":\"$message\""
    if [[ -n "$detail" ]]; then
        entry="$entry,\"detail\":\"$detail\""
    fi
    entry="$entry}"
    # أضف للمصفوفة
    if [[ "$J_PROBLEMS" == "[]" ]]; then
        J_PROBLEMS="[$entry]"
    else
        J_PROBLEMS="${J_PROBLEMS%]},$entry]"
    fi
}

# دالة مساعدة لإضافة أمر إصلاح لـ J_FIX_COMMANDS
add_fix_command() {
    local cmd="$1"
    if [[ "$J_FIX_COMMANDS" == "[]" ]]; then
        J_FIX_COMMANDS="[\"$cmd\"]"
    else
        J_FIX_COMMANDS="${J_FIX_COMMANDS%]},\"$cmd\"]"
    fi
}

PROBLEM_FOUND=false

# ---------------------------------------------------------------------------
# 1) هل الجذر الحالي مركّب من داخل لقطة timeshift بدل @ الحقيقي؟
# ---------------------------------------------------------------------------
ROOT_SOURCE=$(findmnt -no SOURCE /)
J_ROOT_SOURCE="$ROOT_SOURCE"
[[ "$JSON_MODE" == "false" ]] && echo "مصدر الجذر الحالي: $ROOT_SOURCE"

if [[ "$ROOT_SOURCE" == *"timeshift-btrfs/snapshots"* ]]; then
    PROBLEM_FOUND=true
    J_RUNNING_FROM_SNAPSHOT=true
    J_CAN_AUTO_FIX=false
    add_problem "booted_from_snapshot" "critical" \
        "النظام يعمل حالياً من داخل لقطة timeshift وليس من subvolume @ الحقيقي!" \
        "أي تحديثات تُكتب داخل اللقطة وليس في @ الحقيقي. يجب الإصلاح عبر chroot."
    log_err "النظام يعمل حالياً من داخل لقطة timeshift وليس من subvolume @ الحقيقي!"
    [[ "$JSON_MODE" == "false" ]] && {
        echo "  هذا يعني أن أي تحديثات (بما فيها تثبيت نواة جديدة) تُكتب داخل اللقطة"
        echo "  وليس في @ الحقيقي، وهذا هو السبب الجذري لتكرر خطأ 'kernel not found'."
        echo
        echo "  لا يمكن إصلاح هذا تلقائياً من الجلسة الحالية لأنك تعمل من داخل المشكلة نفسها."
        echo "  الحل: أعد التشغيل وادخل قائمة GRUB، اختر الإدخال العادي 'Manjaro Linux'"
        echo "  (وليس أي إدخال ضمن 'Advanced options' أو submenu اللقطات)."
        echo "  إن استمر الدخول للقطة رغم ذلك، استخدم chroot لتثبيت النواة يدوياً في @:"
        echo
        echo "    sudo mount -o subvol=@ /dev/sda6 /mnt/realroot"
        echo "    sudo mount -o subvol=@home /dev/sda6 /mnt/realroot/home"
        echo "    sudo mount -o subvol=@cache /dev/sda6 /mnt/realroot/var/cache"
        echo "    sudo mount -o subvol=@log /dev/sda6 /mnt/realroot/var/log"
        echo "    sudo mount /dev/sda1 /mnt/realroot/boot/efi"
        echo "    sudo arch-chroot /mnt/realroot"
        echo "    pacman -S linux618 --overwrite '*'   # عدّل اسم الحزمة حسب نواتك"
        echo "    mkinitcpio -P && grub-mkconfig -o /boot/grub/grub.cfg && exit"
        echo "    sudo umount -R /mnt/realroot && sudo reboot"
        echo
    }
else
    log_ok "الجذر يعمل من subvolume حقيقي (ليس لقطة)."
fi

# ---------------------------------------------------------------------------
# 2) هل الإدخال الرئيسي في grub.cfg يشير لمسار لقطة بدل @ ؟
#    (نتجاهل عمداً submenu اللقطات الذي يُفترض أن يشير إليها)
# ---------------------------------------------------------------------------
GRUB_CFG="/boot/grub/grub.cfg"
MAIN_ENTRY_LINE=""
if [[ -f "$GRUB_CFG" ]]; then
    MAIN_ENTRY_LINE=$(awk '/^menuentry .Manjaro Linux./{flag=1} flag && /linux[[:space:]]+\//{print; exit}' "$GRUB_CFG" || true)
    J_GRUB_LINE="$MAIN_ENTRY_LINE"
    if [[ -n "$MAIN_ENTRY_LINE" ]]; then
        if [[ "$MAIN_ENTRY_LINE" == *"timeshift-btrfs/snapshots"* ]]; then
            PROBLEM_FOUND=true
            J_GRUB_POINTS_TO_SNAPSHOT=true
            add_problem "grub_snapshot" "critical" \
                "الإدخال الرئيسي في grub.cfg يشير خطأً إلى لقطة قديمة" \
                "السطر: ${MAIN_ENTRY_LINE:0:120}"
            log_err "الإدخال الرئيسي في grub.cfg يشير خطأً إلى لقطة قديمة:"
            [[ "$JSON_MODE" == "false" ]] && echo "  $MAIN_ENTRY_LINE"
        else
            log_ok "الإدخال الرئيسي في grub.cfg يشير لمسار طبيعي (ليس لقطة)."
        end
    else
        log_warn "تعذر العثور على سطر 'linux' داخل menuentry الرئيسي لتحليله."
    fi
else
    log_warn "لم يُعثر على $GRUB_CFG (هل أنت داخل chroot أو نظام مختلف؟)"
fi

# ---------------------------------------------------------------------------
# 2.5) هل الحل الوقائي الدائم مُفعّل في /etc/default/grub؟
#      (rootflags=subvol=@ في GRUB_CMDLINE_LINUX_DEFAULT يمنع الانزلاق
#       حتى لو أخطأت grub-mkconfig مستقبلاً في اكتشاف subvolume الحي وقت التشغيل)
# ---------------------------------------------------------------------------
GRUB_DEFAULT_FILE="/etc/default/grub"
if [[ -f "$GRUB_DEFAULT_FILE" ]]; then
    if grep -q "GRUB_CMDLINE_LINUX_DEFAULT=.*rootflags=subvol=@" "$GRUB_DEFAULT_FILE"; then
        J_PREVENTIVE_FIX_ENABLED=true
        log_ok "الحل الوقائي الدائم (rootflags=subvol=@) مُفعّل في $GRUB_DEFAULT_FILE."
    else
        PROBLEM_FOUND=true
        add_problem "rootflags_missing" "warning" \
            "الحل الوقائي الدائم غير مُفعّل بعد" \
            "أضف rootflags=subvol=@ إلى GRUB_CMDLINE_LINUX_DEFAULT في /etc/default/grub"
        add_fix_command "grub-mkconfig -o /boot/grub/grub.cfg"
        log_warn "الحل الوقائي الدائم غير مُفعّل بعد. أضف rootflags=subvol=@ إلى"
        [[ "$JSON_MODE" == "false" ]] && {
            echo "  GRUB_CMDLINE_LINUX_DEFAULT في $GRUB_DEFAULT_FILE ثم شغّل grub-mkconfig."
            echo "  هذا يمنع تكرار مشكلة 'kernel not found' حتى لو انزلق اكتشاف"
            echo "  subvolume الحي في grub-mkconfig مستقبلاً."
        }
    fi
fi

# ---------------------------------------------------------------------------
# 3) هل النواة المُشار إليها في grub.cfg موجودة فعلياً في /boot الحالي؟
# ---------------------------------------------------------------------------
if [[ -n "${MAIN_ENTRY_LINE:-}" ]]; then
    KERNEL_PATH=$(echo "$MAIN_ENTRY_LINE" | awk '{print $2}')
    KERNEL_BASENAME=$(basename "$KERNEL_PATH")
    J_KERNEL_NAME="$KERNEL_BASENAME"
    if [[ -f "/boot/$KERNEL_BASENAME" ]]; then
        log_ok "ملف النواة $KERNEL_BASENAME موجود في /boot الحالي."
    else
        PROBLEM_FOUND=true
        J_KERNEL_MISSING=true
        add_problem "kernel_missing" "critical" \
            "ملف النواة $KERNEL_BASENAME غير موجود في /boot الحالي!" \
            "النواة المُشار إليها في grub.cfg غير موجودة — سيفشل الإقلاع."
        log_err "ملف النواة $KERNEL_BASENAME غير موجود في /boot الحالي!"
    fi
fi

# ---------------------------------------------------------------------------
# إخراج JSON إن طُلب
# ---------------------------------------------------------------------------
if [[ "$JSON_MODE" == "true" ]]; then
    cat <<EOF
{
  "running_from_snapshot": $J_RUNNING_FROM_SNAPSHOT,
  "grub_points_to_snapshot": $J_GRUB_POINTS_TO_SNAPSHOT,
  "kernel_missing": $J_KERNEL_MISSING,
  "preventive_fix_enabled": $J_PREVENTIVE_FIX_ENABLED,
  "can_auto_fix": $J_CAN_AUTO_FIX,
  "root_source": "$J_ROOT_SOURCE",
  "kernel_name": "$J_KERNEL_NAME",
  "problems": $J_PROBLEMS,
  "fix_commands": $J_FIX_COMMANDS
}
EOF
    if [[ "$PROBLEM_FOUND" == "false" ]]; then
        exit 0
    fi
    if [[ "$J_RUNNING_FROM_SNAPSHOT" == "true" ]]; then
        exit 1
    fi
    exit 2
fi

# ---------------------------------------------------------------------------
# النمط النصي (الأصلي)
# ---------------------------------------------------------------------------
echo
if [[ "$PROBLEM_FOUND" == false ]]; then
    log_ok "لا توجد مشاكل. النظام سليم."
    exit 0
fi

# ---------------------------------------------------------------------------
# الإصلاح التلقائي (فقط إذا كنا على @ حقيقي وليس داخل لقطة)
# ---------------------------------------------------------------------------
if [[ "$ROOT_SOURCE" == *"timeshift-btrfs/snapshots"* ]]; then
    log_warn "تخطي الإصلاح التلقائي: يجب إصلاح هذا عبر chroot كما هو موضح أعلاه أولاً."
    exit 1
fi

if [[ "$FIX_MODE" == true ]]; then
    echo "جارٍ محاولة الإصلاح التلقائي (mkinitcpio + grub-mkconfig)..."
    mkinitcpio -P
    grub-mkconfig -o /boot/grub/grub.cfg
    log_ok "تم الإصلاح. أعد التشغيل واختبر."
else
    log_warn "شغّل السكربت بخيار --fix لتنفيذ الإصلاح التلقائي (mkinitcpio -P && grub-mkconfig)."
    exit 2
fi
