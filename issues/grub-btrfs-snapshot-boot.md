# فشل الإقلاع بعد تحديث النواة: النظام "منزلق" إلى لقطة timeshift بدل subvolume @ الحقيقي

**البيئة:** Manjaro Linux, نواة `linux618` (6.18.x), btrfs, GRUB, `timeshift-btrfs`, `grub-btrfs`, EFI.

## الأعراض

بعد تحديث النظام (`pacman -Syu`) وإعادة التشغيل، ظهرت رسالة عند الإقلاع:

```
error: fs/btrfs.c:find_path:1890:file `/@/boot/vmlinuz-6.18-x86_64' not found.
error: loader/i386/linux.c:grub_cmd_initrd:1082:you need to load the kernel first.
Press any key to continue...
```

الدخول للنظام كان ممكناً فقط عبر خيار **fallback** في قائمة GRUB. الإدخال العادي "Manjaro Linux" كان يفشل بنفس الخطأ بشكل متكرر، حتى بعد عدة محاولات لإعادة بناء `initramfs` و`grub.cfg`.

## التشخيص

### الخطوة 1: التحقق من وجود ملفات النواة
```bash
ls /boot/
sudo mkinitcpio -P
```
النتيجة: تم بناء الصور بنجاح ظاهرياً بدون أخطاء حقيقية.

### الخطوة 2: إعادة توليد grub.cfg
```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```
النتيجة: نجح ووجد النواة (`Found linux image: /boot/vmlinuz-6.18-x86_64`) — لكن المشكلة استمرت بعد إعادة التشغيل. هذا كان أول مؤشر على أن العطل ليس في *وجود* الملفات في الجلسة الحالية، بل في *مكان* الجلسة الحالية نفسها.

### الخطوة 3: فحص عدد ملفات grub.cfg (استبعاد تعدد النسخ)
```bash
sudo find / -xdev -iname "grub.cfg" 2>/dev/null
```
النتيجة: ملف واحد فعلي في `/boot/grub/grub.cfg` (وملف آخر غير مستخدَم لـ grub-customizer). استبعدنا احتمال أن EFI يقرأ نسخة قديمة.

### الخطوة 4: فحص محتوى الإدخال الرئيسي فعلياً (وليس submenu اللقطات)
```bash
sudo grep -A15 "^menuentry 'Manjaro Linux'" /boot/grub/grub.cfg
```
النتيجة — **هنا ظهر السبب**:
```
linux   /timeshift-btrfs/snapshots/2026-07-31_04-00-17/@/boot/vmlinuz-6.18-x86_64 \
        root=UUID=... rw rootflags=subvol=timeshift-btrfs/snapshots/2026-07-31_04-00-17/@ ...
```
الإدخال **الرئيسي** (غير submenu اللقطات المخصص أصلاً لذلك) كان يشير إلى لقطة قديمة بتاريخ سابق للتحديث. تلك اللقطة لا تحتوي على النواة الجديدة، ومن هنا الخطأ.

### الخطوة 5: لماذا يحدث هذا؟ فحص الجذر المُركَّب فعلياً
```bash
findmnt /
cat /etc/fstab | grep subvol
```
النتيجة الحاسمة:
```
TARGET SOURCE
/      /dev/sda6[/timeshift-btrfs/snapshots/2026-07-31_04-00-17/@]
```
بينما `/etc/fstab` ينص بوضوح على أن الجذر يجب أن يكون `subvol=/@`. **النظام كان يعمل فعلياً من داخل لقطة قديمة، وليس من subvolume `@` الحقيقي** — رغم أن fstab صحيح! هذا يعني أن أداة توليد `grub.cfg` (`grub-mkconfig`) اكتشفت الجذر *الحالي المُركَّب فعلياً* (اللقطة) بدل الاعتماد فقط على fstab، فأعادت كتابة الإدخال الرئيسي ليشير لنفس اللقطة الخاطئة في كل مرة — حلقة تكرّر نفسها مهما أعدت تشغيل `grub-mkconfig`.

**السبب الجذري الاحتمالي:** استعادة سابقة عبر timeshift، أو اختيار غير مقصود لإدخال لقطة من قائمة `grub-btrfs` submenu في إقلاع سابق، أدّى إلى أن الجلسة الحالية أصبحت "عالقة" على تلك اللقطة كجذر فعلي، رغم أن جميع ملفات الإعداد (fstab) تشير للمكان الصحيح.

### الخطوة 6: تأكيد أن @ الحقيقي "متجمّد" عند حالة قديمة
عبر `arch-chroot` إلى `subvol=@` الحقيقي:
```bash
sudo mount -o subvol=@ /dev/sda6 /mnt/realroot
sudo mount -o subvol=@home /dev/sda6 /mnt/realroot/home
sudo mount -o subvol=@cache /dev/sda6 /mnt/realroot/var/cache
sudo mount -o subvol=@log /dev/sda6 /mnt/realroot/var/log
sudo mount /dev/sda1 /mnt/realroot/boot/efi
sudo arch-chroot /mnt/realroot
mkinitcpio -P
```
النتيجة:
```
==> ERROR: No presets found in /etc/mkinitcpio.d
```
تأكيد قاطع: subvolume `@` الحقيقي **لا يحتوي أصلاً** على ملف preset النواة الجديدة (`linux618.preset` كان موجوداً فقط بامتداد `.pacsave` غير فعّال)، ولا على صورة النواة الجديدة في `/boot`. كل التحديثات الأخيرة (بما فيها تثبيت النواة 6.18) كانت تُكتب فعلياً داخل اللقطة المنفصلة، بينما `@` الحقيقي بقي عند حالته الأقدم.

## السبب الجذري (ملخّص)

الجلسة كانت تعمل من جذر مركّب فعلياً من داخل لقطة `timeshift-btrfs/snapshots/.../@` بدل `subvolume @` الأصلي، رغم أن `/etc/fstab` كان يشير للمكان الصحيح. نتيجة ذلك:
1. كل تحديثات pacman (بما فيها النواة) كُتبت داخل اللقطة، لا داخل `@`.
2. `grub-mkconfig` يكتشف الجذر الفعلي المُركَّب حالياً، فأعاد توليد الإدخال الرئيسي ليشير لمسار اللقطة — تكرار العطل مهما حاولت.
3. `@` الحقيقي بقي بلا نواة جديدة، فحتى لو أصلحت grub.cfg يدوياً ليشير لـ `@`، الملف غير موجود هناك أصلاً.

## الحل

عبر `arch-chroot` إلى `@` الحقيقي، أُعيد تثبيت حزمة النواة بالقوة لضمان كتابة كل ملفاتها (بما فيها الـ preset) في المكان الصحيح:

```bash
sudo mount -o subvol=@ /dev/sda6 /mnt/realroot
sudo mount -o subvol=@home /dev/sda6 /mnt/realroot/home
sudo mount -o subvol=@cache /dev/sda6 /mnt/realroot/var/cache
sudo mount -o subvol=@log /dev/sda6 /mnt/realroot/var/log
sudo mount /dev/sda1 /mnt/realroot/boot/efi
sudo arch-chroot /mnt/realroot

# داخل الـ chroot:
pacman -S linux618 --overwrite '*'   # عدّل اسم الحزمة حسب نواتك
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg
exit

sudo umount -R /mnt/realroot
sudo reboot
```

بعد إعادة التشغيل، تحقق من الإقلاع الصحيح:
```bash
findmnt /
# يجب أن يظهر: /dev/sda6[/@]  وليس مساراً يحوي timeshift-btrfs/snapshots
```

## الوقاية

استخدم السكربت [`scripts/boot-sanity-check.sh`](../scripts/boot-sanity-check.sh) — يكتشف هذه الحالة بالضبط:
- هل الجذر الحالي يعمل من داخل لقطة بدل `@`؟
- هل الإدخال الرئيسي في grub.cfg يشير للقطة بدل المسار الطبيعي؟
- هل ملف النواة المذكور موجود فعلياً؟

ركّبه كـ pacman hook (انظر [`hooks/95-boot-sanity-check.hook`](../hooks/95-boot-sanity-check.hook)) ليعمل تلقائياً بعد كل تحديث نواة/grub/mkinitcpio.

**نصيحة إضافية:** بعد أي استعادة عبر timeshift، تحقق فوراً من `findmnt /` للتأكد أنك عدت فعلياً لـ `@` وليس لجلسة عالقة على اللقطة المستعادة.

## بعد الإصلاح: تحقق من التغييرات المفقودة

بما أن العمل تم لفترة داخل اللقطة المنفصلة، راجع أي مشاريع أو ملفات عدّلتها خلال تلك الفترة — قد لا تكون منعكسة في `@` الحقيقي:
```bash
cd ~/your-project && git log --oneline -10 && git status
```

## تحديث: تكرار المشكلة بعد تحديث لاحق + الحل النهائي الدائم

رغم تطبيق الحل أعلاه وتثبيت `scripts/boot-sanity-check.sh` كـ pacman hook، **تكررت نفس المشكلة بالضبط** بعد تحديث نواة لاحق (`linux618` من 6.18.39 إلى 6.18.44)، بنفس الأعراض تماماً (`findmnt /` يُظهر الجذر مركّباً من داخل لقطة timeshift جديدة).

### التحقيقات التي استبعدت أسباباً أخرى محتملة

عند التكرار، جرّبنا نظريتين إضافيتين قبل الوصول للحل النهائي:

**نظرية 1: `saved_entry` في GRUB يشير للقطة (مستبعدة)**
```bash
grep -E "GRUB_SAVEDEFAULT|GRUB_DEFAULT" /etc/default/grub
sudo grub-editenv /boot/grub/grubenv list
```
النتيجة: `GRUB_SAVEDEFAULT=false` ولا يوجد `saved_entry` مسجّل أصلاً في `grubenv`. استبعاد كامل لهذا الاحتمال.

**نظرية 2: btrfs default subvolume تغيّر عن `@` (مستبعدة)**
```bash
sudo btrfs subvolume get-default /
```
النتيجة: `291` (أي `@`) كان بالفعل هو default الصحيح على مستوى btrfs نفسه. استبعاد كامل أيضاً.

### التفسير الأرجح للسبب الجذري

بما أن كلا الاحتمالين أعلاه سليمان، يبقى التفسير الأرجح أن **`grub-mkconfig` لا يعتمد على `/etc/fstab` لتحديد `rootflags=subvol=...`، بل يقرأ subvolume الجلسة الحية وقت تشغيله فعلياً** (عبر آلية `grub-probe`/mountinfo). إذا تزامن تشغيل `grub-mkconfig` (كجزء من pacman hook بعد تحديث النواة) مع أي لحظة كانت فيها الجلسة الحية مرتبطة بلقطة (مثلاً مباشرة بعد أن يأخذ `timeshift-autosnap` لقطة جديدة "قبل الترقية")، فإن `grub.cfg` الناتج يُكتب فيه `rootflags=subvol=timeshift-btrfs/snapshots/.../@` بدل `subvol=@` — رغم أن كل الإعدادات الأخرى (fstab، btrfs default) سليمة تماماً طوال الوقت.

لم نتمكن من تثبيت التوقيت الدقيق لهذا التزامن عبر `journalctl`، لكن الحل التالي **يجعل تحديد السبب الدقيق غير ضروري عملياً**.

### الحل النهائي الدائم (يمنع التكرار بغض النظر عن السبب الدقيق)

أضف `rootflags=subvol=@` صراحة داخل `GRUB_CMDLINE_LINUX_DEFAULT` في `/etc/default/grub`:

```bash
sudo nano /etc/default/grub
```
```
GRUB_CMDLINE_LINUX_DEFAULT='quiet splash udev.log_priority=3 rootflags=subvol=@'
```

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

**لماذا هذا يحل المشكلة نهائياً:** في سطر `linux` النهائي داخل `menuentry`، يُدرَج `rootflags=subvol=X` المُكتَشَف تلقائياً أولاً، ثم يُلحَق محتوى `GRUB_CMDLINE_LINUX_DEFAULT` (بما فيه `rootflags=subvol=@` اليدوي) في آخر السطر. في معالجة خيارات mount عند تكرار نفس المفتاح (`subvol=`)، **القيمة الأخيرة في السلسلة هي التي تُطبَّق فعلياً** بغض النظر عن القيمة المكتشفة تلقائياً قبلها. هذا يجعل الإقلاع يشير دائماً لـ `@` الحقيقي، حتى لو أخطأت `grub-mkconfig` مستقبلاً في اكتشاف subvolume الحي وقت التشغيل.

**تحقق بعد إعادة التشغيل:**
```bash
findmnt /
# يجب أن يظهر: /dev/sda6[/@]  دائماً، بغض النظر عن أي تحديث لاحق
```

هذا الإصلاح تم التحقق منه عملياً بعد إعادة التشغيل التالية للتطبيق: `findmnt /` أظهر `/dev/sda6[/@]` مباشرة.
