#!/usr/bin/env bash
#
# boot-sanity-check.sh
# يكتشف حالتين شائعتين تسببان فشل الإقلاع بعد تحديث Manjaro على btrfs:
#   1) النظام الحالي يعمل فعلياً من داخل لقطة timeshift بدل subvolume @ الحقيقي.
#   2) grub.cfg (الإدخال الرئيسي غير submenu اللقطات) يشير لمسار /boot داخل لقطة قديمة.
#
# الاستخدام:
#   sudo ./boot-sanity-check.sh          # فحص فقط
#   sudo ./boot-sanity-check.sh --fix    # فحص + إصلاح تلقائي إن كان آمناً
#
set -euo pipefail

FIX_MODE=false
if [[ "${1:-}" == "--fix" ]]; then
    FIX_MODE=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[تحذير]${NC} $1"; }
log_err()  { echo -e "${RED}[خطأ]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_err "شغّل السكربت عبر sudo."
    exit 1
fi

PROBLEM_FOUND=false

# ---------------------------------------------------------------------------
# 1) هل الجذر الحالي مركّب من داخل لقطة timeshift بدل @ الحقيقي؟
# ---------------------------------------------------------------------------
ROOT_SOURCE=$(findmnt -no SOURCE /)
echo "مصدر الجذر الحالي: $ROOT_SOURCE"

if [[ "$ROOT_SOURCE" == *"timeshift-btrfs/snapshots"* ]]; then
    PROBLEM_FOUND=true
    log_err "النظام يعمل حالياً من داخل لقطة timeshift وليس من subvolume @ الحقيقي!"
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
else
    log_ok "الجذر يعمل من subvolume حقيقي (ليس لقطة)."
fi

# ---------------------------------------------------------------------------
# 2) هل الإدخال الرئيسي في grub.cfg يشير لمسار لقطة بدل @ ؟
#    (نتجاهل عمداً submenu اللقطات الذي يُفترض أن يشير إليها)
# ---------------------------------------------------------------------------
GRUB_CFG="/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
    MAIN_ENTRY_LINE=$(awk '/^menuentry .Manjaro Linux./{flag=1} flag && /linux[[:space:]]+\//{print; exit}' "$GRUB_CFG" || true)
    if [[ -n "$MAIN_ENTRY_LINE" ]]; then
        if [[ "$MAIN_ENTRY_LINE" == *"timeshift-btrfs/snapshots"* ]]; then
            PROBLEM_FOUND=true
            log_err "الإدخال الرئيسي في grub.cfg يشير خطأً إلى لقطة قديمة:"
            echo "  $MAIN_ENTRY_LINE"
        else
            log_ok "الإدخال الرئيسي في grub.cfg يشير لمسار طبيعي (ليس لقطة)."
        fi
    else
        log_warn "تعذر العثور على سطر 'linux' داخل menuentry الرئيسي لتحليله."
    fi
else
    log_warn "لم يُعثر على $GRUB_CFG (هل أنت داخل chroot أو نظام مختلف؟)"
fi

# ---------------------------------------------------------------------------
# 3) هل النواة المُشار إليها في grub.cfg موجودة فعلياً في /boot الحالي؟
# ---------------------------------------------------------------------------
if [[ -n "${MAIN_ENTRY_LINE:-}" ]]; then
    KERNEL_PATH=$(echo "$MAIN_ENTRY_LINE" | awk '{print $2}')
    # نحذف بادئة اللقطة إن وجدت لمعرفة الاسم الفعلي للملف المطلوب
    KERNEL_BASENAME=$(basename "$KERNEL_PATH")
    if [[ -f "/boot/$KERNEL_BASENAME" ]]; then
        log_ok "ملف النواة $KERNEL_BASENAME موجود في /boot الحالي."
    else
        PROBLEM_FOUND=true
        log_err "ملف النواة $KERNEL_BASENAME غير موجود في /boot الحالي!"
    fi
fi

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
