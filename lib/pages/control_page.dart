import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:eqi_ble_sdk/eqi_ble_sdk.dart';
import '../theme/app_theme.dart';

class ControlPage extends StatefulWidget {
  final BluetoothDevice device;
  final AdvertisementData advertisementData;

  const ControlPage({super.key, required this.device, required this.advertisementData});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> with TickerProviderStateMixin {
  late BleProtocol _protocol;
  bool _isInitialized = false;
  bool _isRunning = false;
  String _machineStatus = '初始化中...';
  SupportedRanges? _ranges;
  double _currentSpeed = 0.0;
  double _currentIncline = 0.0;
  
  // 运动数据
  int _distance = 0;
  double _calories = 0.0;
  Duration _duration = Duration.zero;

  StreamSubscription? _statusSubscription;
  StreamSubscription? _workoutSubscription;
  StreamSubscription? _connectionSubscription;

  // 动画控制
  late AnimationController _startBtnController;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _startBtnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _initProtocol();
    
    // 监听连接状态
    _connectionSubscription = widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('设备已断开连接')),
          );
          Navigator.of(context).pop();
        }
      }
    });
  }

  Future<void> _initProtocol() async {
    try {
      final bleDevice = FbpBleDevice(widget.device);
      
      // 读取广告数据。flutter_blue_plus 扫描结果的 manufacturerData 是个 Map<int, List<int>>，
      // EQI 设备的 CompanyIdentifier 是 0x07D5 (2005)
      Uint8List? manufacturerData;
      if (widget.advertisementData.manufacturerData.containsKey(0x07D5)) {
        manufacturerData = Uint8List.fromList(widget.advertisementData.manufacturerData[0x07D5]!);
      } else if (widget.advertisementData.manufacturerData.isNotEmpty) {
        manufacturerData = Uint8List.fromList(widget.advertisementData.manufacturerData.values.first);
      }

      AdvertisingData parsedAd;
      if (manufacturerData != null && manufacturerData.isNotEmpty) {
        // 如果能拿到完整的厂商数据，走深度解析
        parsedAd = AdvertisingData.fromManufacturerData(manufacturerData);
      } else {
        // 退化方案：从名字判定
        parsedAd = AdvertisingData(deviceName: widget.device.platformName);
      }

      // 使用动态连接服务发现识别协议，代替启发式的名字推断分析。如果在服务没能返回对应的协议则利用名字快速推断补偿
      final dynamicProtocol = await ProtocolRegistry.resolveProtocolAsync(bleDevice);
      
      _protocol = dynamicProtocol ?? ProtocolRegistry.getProtocolForDevice(parsedAd) ?? FtmsProtocol();
      
      await _protocol.initialize(bleDevice);

      // 请求控制权限
      final response = await _protocol.sendCommand(ControlCommand.requestControl());
      if (response.isSuccess) {
        // 读取支持范围
        final ranges = await _protocol.readSupportedRanges();
        setState(() {
          _ranges = ranges;
          _isInitialized = true;
          _machineStatus = '准备就绪';
          
          // 如果读取到最小速度，初始化当前速度
          if (ranges.speedRange != null && (_currentSpeed == 0 || _currentSpeed < ranges.speedRange!.minimum)) {
             _currentSpeed = ranges.speedRange!.minimum;
          }
        });
      } else {
        setState(() {
          _machineStatus = '无法获取控制权 (${response.resultCode.name})';
        });
      }

      // 订阅数据
      _statusSubscription = _protocol.machineStatusStream.listen((status) {
        if (mounted) {
          setState(() {
            // 这里可以根据状态码更新 UI
            _machineStatus = '状态: ${status.statusCode.name}';
          });
        }
      });

      _workoutSubscription = _protocol.workoutDataStream.listen((data) {
        if (mounted) {
          setState(() {
            _currentSpeed = data.instantaneousSpeed ?? _currentSpeed;
            _currentIncline = data.inclination ?? _currentIncline;
            _distance = data.totalDistance ?? _distance;
            _calories = data.totalEnergy ?? _calories;
            _duration = data.elapsedTime != null 
                ? Duration(seconds: data.elapsedTime!) 
                : _duration;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _machineStatus = '初始化失败: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _workoutSubscription?.cancel();
    _connectionSubscription?.cancel();
    _protocol.dispose();
    _startBtnController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// 切换开始/停止状态
  Future<void> _toggleStartStop() async {
    if (!_isInitialized) return;

    if (_isRunning) {
      final res = await _protocol.sendCommand(ControlCommand.stop());
      if (res.isSuccess) {
        setState(() {
          _isRunning = false;
          _pulseController.stop();
        });
        _startBtnController.reverse();
      }
    } else {
      final res = await _protocol.sendCommand(ControlCommand.startOrResume());
      if (res.isSuccess) {
        setState(() {
          _isRunning = true;
          _pulseController.repeat(reverse: true);
        });
        _startBtnController.forward();
      }
    }
  }

  /// 调整速度
  Future<void> _adjustSpeed(double delta) async {
    if (!_isRunning) return;
    
    double newSpeed = _currentSpeed + delta;
    
    double minSpeed = _ranges?.speedRange?.minimum ?? 0.6;
    double maxSpeed = _ranges?.speedRange?.maximum ?? 20.0;

    if (newSpeed < minSpeed) newSpeed = minSpeed;
    if (newSpeed > maxSpeed) newSpeed = maxSpeed;

    final res = await _protocol.sendCommand(ControlCommand.setTargetSpeed(newSpeed));
    if (res.isSuccess) {
      setState(() {
        _currentSpeed = newSpeed;
      });
    }
  }

  /// 调整坡度
  Future<void> _adjustIncline(double delta) async {
    if (!_isRunning) return;
    
    double newIncline = _currentIncline + delta;
    
    double minIncline = _ranges?.inclinationRange?.minimum ?? 0.0;
    double maxIncline = _ranges?.inclinationRange?.maximum ?? 15.0;

    if (newIncline < minIncline) newIncline = minIncline;
    if (newIncline > maxIncline) newIncline = maxIncline;

    final res = await _protocol.sendCommand(ControlCommand.setTargetInclination(newIncline));
    if (res.isSuccess) {
      setState(() {
        _currentIncline = newIncline;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.darkGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              const Spacer(flex: 1),
              _buildStatusDisplay(),
              const Spacer(flex: 2),
              _buildControlPanel(),
              const Spacer(flex: 2),
              _buildStatsRow(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.05),
              padding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.device.platformName.isNotEmpty 
                      ? widget.device.platformName 
                      : '已连接设备',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  _machineStatus,
                  style: TextStyle(
                    fontSize: 12,
                    color: _isInitialized ? AppTheme.successColor : AppTheme.textHint,
                  ),
                ),
              ],
            ),
          ),
          _buildConnectionIndicator(),
        ],
      ),
    );
  }

  Widget _buildConnectionIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.successColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.successColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppTheme.successColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '已连接',
            style: TextStyle(color: AppTheme.successColor, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDisplay() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 速度显示
          Expanded(
            child: Column(
              children: [
                Text(
                  '当前速度',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                ShaderMask(
                  shaderCallback: (bounds) => AppTheme.primaryGradient.createShader(bounds),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _currentSpeed.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'km/h',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          Container(
            width: 1,
            height: 40,
            color: Colors.white.withOpacity(0.1),
          ),

          // 坡度显示
          Expanded(
            child: Column(
              children: [
                Text(
                  '当前坡度',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [AppTheme.accentColor, AppTheme.infoColor],
                  ).createShader(bounds),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _currentIncline.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '%',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 减速按钮
          _buildCircleButton(
            icon: Icons.remove_rounded,
            color: Colors.white.withOpacity(0.1),
            onPressed: () => _adjustSpeed(-0.3),
            label: '减速',
          ),
          
          // 中间控制部分：坡度加 + 开始按钮 + 坡度减
          Column(
            children: [
              _buildCircleButton(
                icon: Icons.keyboard_arrow_up_rounded,
                color: Colors.white.withOpacity(0.05),
                onPressed: () => _adjustIncline(1.0),
                label: '升坡',
              ),
              const SizedBox(height: 20),
              _buildStartButton(),
              const SizedBox(height: 20),
              _buildCircleButton(
                icon: Icons.keyboard_arrow_down_rounded,
                color: Colors.white.withOpacity(0.05),
                onPressed: () => _adjustIncline(-1.0),
                label: '降坡',
              ),
            ],
          ),

          // 加速按钮
          _buildCircleButton(
            icon: Icons.add_rounded,
            color: Colors.white.withOpacity(0.1),
            onPressed: () => _adjustSpeed(0.3),
            label: '加速',
          ),
        ],
      ),
    );
  }



  Widget _buildStartButton() {
    return GestureDetector(
      onTap: _toggleStartStop,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final pulse = _isRunning ? _pulseController.value : 0.0;
          return Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (_isRunning ? AppTheme.errorColor : AppTheme.primaryColor).withOpacity(0.3),
                  blurRadius: 20 + (20 * pulse),
                  spreadRadius: 5 + (10 * pulse),
                ),
              ],
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: _isRunning 
                    ? [const Color(0xFFFF5252), const Color(0xFFFF1744)]
                    : [AppTheme.primaryColor, AppTheme.accentColor],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 60,
                  ),
                  Text(
                    _isRunning ? 'STOP' : 'START',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required String label,
  }) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(40),
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildStateItem(String value, String label, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 12),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsRow() {
    final minutes = _duration.inMinutes;
    final seconds = _duration.inSeconds % 60;
    final durationStr = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          _buildStateItem(durationStr, '时长', Icons.timer_outlined, AppTheme.accentColor),
          _buildStateItem((_distance / 1000).toStringAsFixed(1), '里程 (km)', Icons.map_outlined, AppTheme.successColor),
          _buildStateItem(_calories.toStringAsFixed(3), '消耗 (kcal)', Icons.local_fire_department_outlined, AppTheme.warningColor),
        ],
      ),
    );
  }
}
