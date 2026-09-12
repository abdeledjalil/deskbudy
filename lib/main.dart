import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DeskBuddyApp());
}

class DeskBuddyApp extends StatelessWidget {
  const DeskBuddyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Desk Buddy BLE Control',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ControlScreen(),
    );
  }
}

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? targetCharacteristic;
  bool isConnected = false;
  bool _isScanning = false;
  String _statusMessage = 'جاهز للبحث عن الجهاز';
  String _deviceName = 'DeskBuddy_BLE';
  bool _isLoadingPills = true;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;

  // قوائم لتخزين أوقات وأسماء الأدوية
  final List<TimeOfDay> _pillTimes = [];
  final List<String> _pillNames = [];

  // UUIDs المطابقة لكود الـ ESP32-C3
  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String characteristicUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  @override
  void initState() {
    super.initState();
    _loadPillsLocally();
    _requestNotificationPermission();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state != BluetoothAdapterState.off || !mounted) return;

      setState(() {
        isConnected = false;
        targetCharacteristic = null;
        _statusMessage = 'تم فصل البلوتوث من الهاتف';
      });
    });
  }

  Future<void> _requestNotificationPermission() async {
    await Permission.notification.request();
  }

  @override
  void dispose() {
    _adapterStateSubscription?.cancel();
    _notificationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadPillsLocally() async {
    final preferences = await SharedPreferences.getInstance();
    final savedTimes = preferences.getStringList('pill_times') ?? <String>[];
    final savedNames = preferences.getStringList('pill_names') ?? <String>[];
    final itemCount = savedTimes.length < savedNames.length
        ? savedTimes.length
        : savedNames.length;

    for (var i = 0; i < itemCount && i < 5; i++) {
      final minutes = int.tryParse(savedTimes[i]);
      if (minutes == null || minutes < 0 || minutes >= 24 * 60) continue;

      _pillTimes.add(
        TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      );
      _pillNames.add(savedNames[i]);
    }

    if (!mounted) return;
    setState(() => _isLoadingPills = false);
  }

  Future<void> _savePillsLocally() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      'pill_times',
      _pillTimes
          .map((time) => (time.hour * 60 + time.minute).toString())
          .toList(),
    );
    await preferences.setStringList(
        'pill_names', List<String>.from(_pillNames));
  }

  Future<void> _scanAndConnect() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _statusMessage = 'جاري طلب صلاحيات البلوتوث والموقع...';
    });

    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        if (!mounted) return;
        setState(() => _statusMessage = 'هاتفك لا يدعم تقنية البلوتوث!');
        return;
      }

      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }

      if (!mounted) return;
      setState(() => _statusMessage = 'جاري البحث عن DeskBuddy_BLE...');

      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      final result = await FlutterBluePlus.scanResults
          .expand((results) => results)
          .firstWhere(
            (result) =>
                result.device.platformName == 'DeskBuddy_BLE' ||
                result.advertisementData.advName == 'DeskBuddy_BLE',
          )
          .timeout(const Duration(seconds: 6));

      await FlutterBluePlus.stopScan();
      if (!mounted) return;

      setState(() {
        _statusMessage = 'تم العثور على الجهاز، جاري الاتصال...';
        _deviceName = result.device.platformName.isNotEmpty
            ? result.device.platformName
            : 'DeskBuddy_BLE';
      });

      targetDevice = result.device;
      await targetDevice!.connect();

      try {
        await targetDevice!.requestMtu(247);
      } catch (_) {
        // بعض المنصات لا تسمح بطلب MTU، لذلك نستخدم القيمة المتفاوض عليها.
      }

      if (!mounted) return;
      setState(() {
        isConnected = true;
        _statusMessage = 'متصل بنجاح بالجهاز ✅';
        _deviceName = targetDevice?.platformName ?? 'DeskBuddy_BLE';
      });

      await _discoverServices();
      if (targetCharacteristic == null) {
        throw StateError('لم يتم العثور على خاصية التحكم في الجهاز');
      }

      await _listenForDeviceAlerts();

      await _syncTime();
      await _sendAllPillReminders();
    } catch (e) {
      if (!mounted) return;
      final message = e is TimeoutException
          ? 'لم يتم العثور على DeskBuddy_BLE'
          : 'خطأ في البحث: $e';
      setState(() => _statusMessage = message);
    } finally {
      await FlutterBluePlus.stopScan();
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _discoverServices() async {
    if (targetDevice == null) return;

    try {
      final services = await targetDevice!.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() ==
            serviceUuid.toLowerCase()) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() ==
                characteristicUuid.toLowerCase()) {
              targetCharacteristic = characteristic;
            }
          }
        }
      }
      if (targetCharacteristic == null && mounted) {
        setState(() => _statusMessage = 'خدمة التحكم غير موجودة في الجهاز');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _statusMessage = 'فشل في اكتشاف خدمات البلوتوث');
      }
    }
  }

  Future<void> _listenForDeviceAlerts() async {
    final characteristic = targetCharacteristic;
    if (characteristic == null || !characteristic.properties.notify) return;

    await _notificationSubscription?.cancel();
    await characteristic.setNotifyValue(true);
    _notificationSubscription = characteristic.onValueReceived.listen((value) {
      final message = utf8.decode(value, allowMalformed: true);
      if (!mounted || !message.startsWith('ALERT:')) return;

      final pillName = message.substring('ALERT:'.length).trim();
      setState(() {
        _statusMessage =
            pillName.isEmpty ? 'حان موعد الدواء' : 'حان موعد الدواء: $pillName';
      });
    });
  }

  Future<void> _sendMode(int modeVal) async {
    if (!isConnected || targetCharacteristic == null) {
      setState(() => _statusMessage = 'غير متصل بالجهاز بالبلوتوث!');
      return;
    }

    try {
      final command = modeVal.toString();
      await _writeBleData(command.codeUnits);
      setState(() => _statusMessage = 'تم إرسال الوضع بنجاح! ($modeVal)');
    } catch (e) {
      setState(() => _statusMessage = 'فشل إرسال الأمر: $e');
    }
  }

  Future<void> _syncTime() async {
    if (!isConnected || targetCharacteristic == null) {
      setState(() => _statusMessage = 'غير متصل بالجهاز بالبلوتوث!');
      return;
    }

    final now = DateTime.now();
    try {
      final timeCommand =
          'T${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      await _writeBleData(timeCommand.codeUnits);
      setState(
        () => _statusMessage =
            'تم مزامنة الوقت (${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}) ⏰',
      );
    } catch (e) {
      setState(() => _statusMessage = 'خطأ في مزامنة الوقت: $e');
    }
  }

  Future<void> _addPillTime(BuildContext context) async {
    final localContext = context;
    if (!localContext.mounted) return;

    final nameController = TextEditingController();

    final pickedTime = await showTimePicker(
      context: localContext,
      initialTime: TimeOfDay.now(),
    );

    if (!localContext.mounted) return;

    if (pickedTime != null) {
      final dialogResult = await showDialog<bool>(
        context: localContext,
        builder: (dialogContext) => AlertDialog(
          title: const Text('أدخل اسم الدواء'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(hintText: 'مثال: Panadol'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('إضافة'),
            ),
          ],
        ),
      );

      if (!localContext.mounted) return;
      if (dialogResult != true) return;

      if (_pillTimes.length >= 5) {
        setState(() => _statusMessage = 'الحد الأقصى هو 5 منبهات');
        return;
      }

      setState(() {
        _pillTimes.add(pickedTime);
        _pillNames.add(
          nameController.text.trim().isEmpty
              ? 'Medicine'
              : nameController.text.trim(),
        );
      });
      await _savePillsLocally();
      await _sendAllPillReminders();
    }
  }

  Future<void> _sendAllPillReminders() async {
    if (!isConnected || targetCharacteristic == null) {
      setState(() => _statusMessage = 'غير متصل بالجهاز بالبلوتوث!');
      return;
    }
    final reminderCount = _pillTimes.length < 5 ? _pillTimes.length : 5;
    var command = 'P';
    for (var i = 0; i < reminderCount; i++) {
      final h = _pillTimes[i].hour.toString().padLeft(2, '0');
      final m = _pillTimes[i].minute.toString().padLeft(2, '0');
      command += '$h:$m-${_pillNames[i]}';
      if (i < reminderCount - 1) {
        command += ',';
      }
    }

    try {
      await _writeBleData(command.codeUnits);
      setState(
        () => _statusMessage = reminderCount == 0
            ? 'تم مسح منبهات الأدوية من الجهاز'
            : 'تم إرسال $reminderCount تنبيهات مع الأسماء بنجاح 💊',
      );
    } catch (e) {
      setState(() => _statusMessage = 'فشل إرسال الأوقات: $e');
    }
  }

  Future<void> _writeBleData(List<int> data) async {
    final characteristic = targetCharacteristic;
    if (characteristic == null) return;

    final withoutResponse = characteristic.properties.writeWithoutResponse;
    final payloadSize = (targetDevice?.mtuNow ?? 23) - 3;

    if (!withoutResponse) {
      await characteristic.write(
        data,
        allowLongWrite: data.length > payloadSize,
      );
      return;
    }

    final chunkSize = payloadSize > 0 ? payloadSize : 20;
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final end =
          (offset + chunkSize < data.length) ? offset + chunkSize : data.length;
      await characteristic.write(
        data.sublist(offset, end),
        withoutResponse: true,
      );
    }
  }

  Future<void> _removePillAt(int index) async {
    setState(() {
      _pillTimes.removeAt(index);
      _pillNames.removeAt(index);
    });
    await _savePillsLocally();
    await _sendAllPillReminders();
  }

  @override
  Widget build(BuildContext context) {
    final connectionColor = isConnected ? Colors.green : Colors.orange;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(
        title: const Text('تحكم عبر البلوتوث Desk Buddy 🤖'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [],
      ),
      body: Padding(
        padding: const EdgeInsets.all(18.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: connectionColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              isConnected
                                  ? Icons.bluetooth_connected
                                  : Icons.bluetooth_searching,
                              color: connectionColor,
                              size: 30,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isConnected ? 'متصل' : 'غير متصل',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _deviceName,
                                  style: TextStyle(
                                    color: Colors.grey[700],
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _statusMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.indigo,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? Colors.grey : Colors.indigo,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: isConnected ? null : _scanAndConnect,
                icon: Icon(
                  isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  size: 28,
                ),
                label: Text(
                  isConnected
                      ? 'متصل بـ DeskBuddy_BLE'
                      : 'بحث والاتصال بالبلوتوث 🔍',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'إدارة الأدوية 💊',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber[800],
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isLoadingPills ? null : () => _addPillTime(context),
                icon: const Icon(Icons.add_alarm, size: 24),
                label: const Text(
                  'إضافة موعد واسم دواء جديد',
                  style: TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                height: 140,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: _pillTimes.isEmpty
                    ? const Center(
                        child: Text(
                          'لم تقم بإضافة أي أوقات بعد',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _pillTimes.length,
                        itemBuilder: (context, index) {
                          return ListTile(
                            leading: const Icon(
                              Icons.access_time,
                              color: Colors.teal,
                            ),
                            title: Text(
                              '${_pillNames[index]} : ${_pillTimes[index].format(context)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _removePillAt(index),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _sendAllPillReminders,
                icon: const Icon(Icons.send, size: 24),
                label: const Text(
                  'إرسال الأوقات والأسماء للجهاز ⏰',
                  style: TextStyle(fontSize: 16),
                ),
              ),
              const Divider(height: 32),
              const Text(
                'أوضاع الوجه:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _sendMode(0),
                icon: const Icon(Icons.sentiment_satisfied, size: 28),
                label: const Text(
                  'وضع عادي 😊',
                  style: TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _sendMode(1),
                icon: const Icon(Icons.bedtime, size: 28),
                label: const Text(
                  'وضع نائم 😴',
                  style: TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.pink,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _sendMode(2),
                icon: const Icon(Icons.flash_on, size: 28),
                label: const Text(
                  'وضع تركيز ⚡',
                  style: TextStyle(fontSize: 18),
                ),
              ),
              const Divider(height: 32),
              const Text(
                'ضبط الوقت:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _syncTime,
                icon: const Icon(Icons.access_time, size: 28),
                label: const Text(
                  'مزامنة الوقت من الهاتف ⏰',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
