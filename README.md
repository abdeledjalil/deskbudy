# DeskBuddy

تطبيق هاتف Flutter للتحكم بجهاز DeskBuddy عبر Bluetooth Low Energy (BLE).

## المزايا

- البحث عن جهاز `DeskBuddy_BLE` والاتصال به.
- مزامنة وقت ESP32 من الهاتف.
- إرسال ما يصل إلى خمسة مواعيد للأدوية مع أسمائها.
- حفظ المواعيد محليًا على الهاتف.
- استقبال إشعارات `ALERT` من ESP32.
- دعم الكتابة حسب خصائص BLE وحجم MTU.

## المتطلبات

- Flutter 3.x
- Dart SDK `^3.3.0`
- هاتف Android أو iPhone يدعم Bluetooth Low Energy.
- جهاز ESP32 يعمل بخدمة BLE ذات UUIDs الموجودة في `lib/main.dart`.

## التشغيل على الهاتف

```bash
flutter pub get
flutter devices
flutter run -d <device-id>
```

على Android يجب السماح للتطبيق بصلاحيات Bluetooth عند أول تشغيل. يجب أن يكون جهاز ESP32 مشغّلًا ويعلن باسم `DeskBuddy_BLE`.

## إنشاء APK

```bash
flutter build apk --release
```

سيظهر الملف في:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## رفع المشروع إلى GitHub

بعد إنشاء مستودع فارغ على GitHub:

```bash
git init
git add .
git commit -m "Prepare DeskBuddy mobile app"
git branch -M main
git remote add origin https://github.com/<username>/<repository>.git
git push -u origin main
```

لا ترفع مجلد `build/` أو ملفات الأسرار؛ هذه الملفات مستبعدة في `.gitignore`.
