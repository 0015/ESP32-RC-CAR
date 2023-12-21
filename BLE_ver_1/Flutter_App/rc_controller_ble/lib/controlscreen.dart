import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:go_router/go_router.dart';
import 'package:kdgaugeview/kdgaugeview.dart';
import 'package:lottie/lottie.dart';
import 'package:rc_controller_ble/utils/utils.dart';

import '../utils/extra.dart';
import 'constants.dart';

class ControlScreen extends StatefulWidget {
  final BluetoothDevice device;

  const ControlScreen({Key? key, required this.device}) : super(key: key);

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  int? _rssi;

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  bool _isDiscoveringServices = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;

  late StreamSubscription<BluetoothConnectionState>
      _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;
  late StreamSubscription<bool> _isDisconnectingSubscription;

  List<int> _value = [];
  late StreamSubscription<List<int>> _lastValueSubscription;

  BluetoothCharacteristic? _characteristicTX;

  bool _isSendingDC = false;
  bool _isSendingSERVO = false;
  double _rowWidth = 0;
  int _preDC = 0;
  int _preServo = 0;

  final speedNotifier = ValueNotifier<double>(10);
  final key = GlobalKey<KdGaugeViewState>();

  bool _anim = false;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription =
        widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
        _services = []; // must rediscover services
      }
      if (state == BluetoothConnectionState.connected && _rssi == null) {
        _rssi = await widget.device.readRssi();
      }

      if (state == BluetoothConnectionState.disconnected) {
        backToHome(true);
      }
    });

    _isConnectingSubscription = widget.device.isConnecting.listen((value) {
      _isConnecting = value;
      setState(() {});
    });

    _isDisconnectingSubscription =
        widget.device.isDisconnecting.listen((value) {
      _isDisconnecting = value;
      setState(() {});
    });

    onDiscoverServices();
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();

    _isConnectingSubscription.cancel();
    _isDisconnectingSubscription.cancel();
    _lastValueSubscription.cancel();
    super.dispose();
  }

  bool get isConnected {
    return _connectionState == BluetoothConnectionState.connected;
  }

  Future onConnect() async {
    try {
      await widget.device.connectAndUpdateStream();
    } catch (e) {
      if (e is FlutterBluePlusException &&
          e.code == FbpErrorCode.connectionCanceled.index) {
      } else {
        print("Connect Error:${e.toString()}");
      }
    }
  }

  Future onCancel() async {
    try {
      await widget.device.disconnectAndUpdateStream(queue: false);
    } catch (e) {
      print("Cancel Error:${e.toString()}");
    }
  }

  Future onDisconnect() async {
    try {
      await widget.device.disconnectAndUpdateStream();
    } catch (e) {
      print("Disconnect Error:${e.toString()}");
    }
  }

  Future onDiscoverServices() async {
    _isDiscoveringServices = true;
    try {
      _services = await widget.device.discoverServices();
      final targetServiceUUID =
          _services.singleWhere((item) => item.serviceUuid.str == SERVICE_UUID);

      final targetCharacterUUID = targetServiceUUID.characteristics.singleWhere(
          (item) => item.characteristicUuid.str == CHARACTERISTIC_UUID_RX);

      await targetCharacterUUID.setNotifyValue(true);

      _lastValueSubscription =
          targetCharacterUUID.lastValueStream.listen((value) {
        _value = value;
        setState(() {});
      });

      _characteristicTX = targetServiceUUID.characteristics.singleWhere(
          (item) => item.characteristicUuid.str == CHARACTERISTIC_UUID_TX);
    } catch (e) {
      print("Discover Services Error:${e.toString()}");
    }
    _isDiscoveringServices = false;
  }

  void backToHome(bool needToReConnect) {
    onDisconnect();
    context.pop(needToReConnect);
  }

  void writeBLE(int cmd, int data) async {
    if (!isConnected) {
      backToHome(true);
      return;
    }

    if (cmd == CMD_DC && _isSendingDC) {
      _isSendingDC = false;
      await _characteristicTX?.write([cmd, data], timeout: 1);
      _isSendingDC = true;
    } else if (cmd == CMD_SERVO && _isSendingSERVO) {
      _isSendingSERVO = false;
      await _characteristicTX?.write([cmd, data], timeout: 1);
      _isSendingSERVO = true;
    }

    if (cmd == CMD_DC) {
      _preDC = data;
    } else if (cmd == CMD_SERVO) {
      _preServo = data;
    }
  }

  void prepareSendingData(int cmd, double data) {
    int remappingInt = 0;

    if (cmd == CMD_DC) {
      double remapping = data.remap(-1.00, 1.00, 255, 0);
      remappingInt = remapping.toInt();
      updateSpeedometer(remappingInt);

      if ((remappingInt - _preDC).abs() < DATA_GAP) {
        return;
      }
    } else if (cmd == CMD_SERVO) {
      double remapping = data.remap(-1.00, 1.00, 0, 255);
      remappingInt = remapping.toInt();
      if ((remappingInt - _preServo).abs() < DATA_GAP) {
        return;
      }
    }
    setState(() {});
    writeBLE(cmd, remappingInt);
  }

  void updateSpeedometer(int rawValue) {
    int base = rawValue - 127;

    if (base <= 0) {
      base = 0;
      _anim = false;
    } else {
      _anim = true;
    }

    key.currentState!.updateSpeed(base.toDouble());
    speedNotifier.value = base.toDouble();
  }

  @override
  void didChangeDependencies() {
    _rowWidth = MediaQuery.of(context).size.width / 2;
    super.didChangeDependencies();
  }

  void _getOutOfApp() {
    onDisconnect();

    Future.delayed(const Duration(milliseconds: 500), () {
      if (Platform.isIOS) {
        try {
          exit(0);
        } catch (e) {
          SystemNavigator.pop();
        }
      } else {
        try {
          SystemNavigator.pop();
        } catch (e) {
          exit(0);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {},
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: Lottie.asset('assets/lottiefiles/1701371264021.json',
                    animate: _anim),
              ),
              Center(
                child: Container(
                  width: 360,
                  height: 360,
                  padding: const EdgeInsets.all(10),
                  child: ValueListenableBuilder<double>(
                      valueListenable: speedNotifier,
                      builder: (context, value, child) {
                        return KdGaugeView(
                          unitOfMeasurement: "MPH",
                          speedTextStyle: TextStyle(
                            fontSize: 100,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w900,
                            foreground: Paint()
                              ..style = PaintingStyle.stroke
                              ..strokeWidth = 6
                              ..color = Colors.greenAccent,
                          ),
                          key: key,
                          minSpeed: 0,
                          maxSpeed: 125,
                          speed: 0,
                          animate: true,
                          alertSpeedArray: const [40, 80, 100],
                          alertColorArray: const [
                            Colors.orange,
                            Colors.indigo,
                            Colors.red
                          ],
                          duration: const Duration(seconds: 6),
                        );
                      }),
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Container(
                      width: _rowWidth,
                      height: double.infinity,
                      alignment: Alignment.bottomCenter,
                      child: JoystickArea(
                        mode: JoystickMode.vertical,
                        initialJoystickAlignment: const Alignment(0, 0.8),
                        listener: (details) {
                          prepareSendingData(CMD_DC, details.y);
                        },
                        onStickDragStart: () {
                          _isSendingDC = true;
                        },
                        onStickDragEnd: () {
                          _isSendingDC = false;
                        },
                      ),
                    ),
                    Container(
                      width: _rowWidth,
                      height: double.infinity,
                      alignment: Alignment.bottomCenter,
                      child: JoystickArea(
                        mode: JoystickMode.horizontal,
                        initialJoystickAlignment: const Alignment(0, 0.8),
                        listener: (details) {
                          prepareSendingData(CMD_SERVO, details.x);
                        },
                        onStickDragStart: () {
                          _isSendingSERVO = true;
                        },
                        onStickDragEnd: () {
                          _isSendingSERVO = false;
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0.0,
                right: 0.0,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: CloseButton(
                    color: Colors.red,
                    onPressed: () => showDialog<String>(
                      context: context,
                      builder: (BuildContext context) => AlertDialog(
                        title: const Text('Do you want to close App?'),
                        content: const Text(
                            '(Automatically disconnected when the app ends.)'),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.pop(context, 'Cancel'),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => _getOutOfApp(),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
