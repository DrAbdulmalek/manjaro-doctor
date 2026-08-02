# Manjaro Doctor 🩺

مرجع عملي مفتوح المصدر لمشاكل Manjaro Linux الحقيقية وحلولها — كل مشكلة موثّقة هنا حدثت فعلياً، مع التشخيص الكامل خطوة بخطوة والحل والسكربتات الجاهزة للوقاية من تكرارها.

الهدف: توفير مرجع عربي (وقابل للترجمة) دقيق ومُختبَر، بدلاً من الحلول العامة المنسوخة التي لا تراعي خصوصية كل حالة (خصوصاً أنظمة btrfs + timeshift + grub-btrfs المعقدة).

## لماذا هذا المشروع؟

أغلب المحتوى العربي عن مشاكل Linux إما مترجم آلياً أو سطحي. هنا كل مشكلة:
- حدثت فعلياً على نظام حقيقي (Manjaro KDE, btrfs, dual/multi-boot).
- تحتوي على **التشخيص الكامل**، وليس فقط "الحل"، لأن فهم السبب يمنع التكرار.
- مرفقة بسكربت وقائي جاهز عند الإمكان.

## هيكل المشروع

```
manjaro-doctor/
├── issues/          # كل مشكلة موثّقة كملف Markdown منفصل
├── scripts/         # سكربتات التشخيص والإصلاح التلقائي
├── hooks/           # pacman hooks جاهزة للتثبيت
└── CONTRIBUTING.md  # كيفية إضافة مشكلة جديدة
```

## المشاكل الموثّقة حتى الآن

| المشكلة | الملف | السكربت |
|---|---|---|
| فشل الإقلاع بعد تحديث النواة: `file not found` + إقلاع من لقطة timeshift بدل subvolume الحقيقي | [issues/grub-btrfs-snapshot-boot.md](issues/grub-btrfs-snapshot-boot.md) | [scripts/boot-sanity-check.sh](scripts/boot-sanity-check.sh) |

## الاستخدام السريع

```bash
git clone https://github.com/DrAbdulmalek/manjaro-doctor.git
cd manjaro-doctor
sudo cp scripts/boot-sanity-check.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/boot-sanity-check.sh
sudo cp hooks/95-boot-sanity-check.hook /etc/pacman.d/hooks/
```

الآن سيُفحص نظامك تلقائياً بعد كل تحديث نواة أو grub أو mkinitcpio.

## المساهمة

راجع [CONTRIBUTING.md](CONTRIBUTING.md) لإضافة مشكلة واجهتها وحللتها. كل إضافة تفيد شخصاً آخر يواجه نفس الموقف مستقبلاً.

## الترخيص

MIT — استخدم وشارك بحرية.
