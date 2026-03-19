import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/app_theme.dart';
import 'control_page.dart';

/// 蓝牙扫描页面 - 首页
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with TickerProviderStateMixin {
  final List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanStateSubscription;
  String? _connectingDeviceId;

  // 动画控制器
  late AnimationController _pulseController;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    _scanStateSubscription = FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) {
        setState(() => _isScanning = scanning);
      }
    });

    // 自动开始扫描
    _requestPermissionsAndScan();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _fadeController.dispose();
    _scanSubscription?.cancel();
    _scanStateSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  /// 请求权限后开始扫描
  Future<void> _requestPermissionsAndScan() async {
    // 请求蓝牙和定位权限
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    final allGranted = statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );

    if (allGranted) {
      _startScan();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('需要蓝牙和定位权限才能扫描设备'),
            backgroundColor: AppTheme.errorColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  /// 开始蓝牙扫描
  void _startScan() {
    setState(() {
      _scanResults.clear();
    });

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      if (mounted) {
        setState(() {
          for (final r in results) {
            // 过滤没有名称的设备
            if (r.device.advName.isEmpty && r.device.platformName.isEmpty) {
              continue;
            }
            // 去重
            final index = _scanResults.indexWhere(
              (e) => e.device.remoteId == r.device.remoteId,
            );
            if (index >= 0) {
              _scanResults[index] = r;
            } else {
              _scanResults.add(r);
            }
          }
          // 按信号强度排序
          _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
        });
      }
    });

    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      androidUsesFineLocation: true,
    );
  }

  /// 连接设备
  Future<void> _connectToDevice(ScanResult result) async {
    if (_connectingDeviceId != null) return;

    setState(() {
      _connectingDeviceId = result.device.remoteId.str;
    });

    // 停止扫描
    await FlutterBluePlus.stopScan();

    try {
      // 连接设备
      await result.device.connect(timeout: const Duration(seconds: 15));

      if (mounted) {
        // 导航到控制页面，传递设备以及蓝牙广播数据
        Navigator.of(context).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) {
              return ControlPage(device: result.device, advertisementData: result.advertisementData);
            },
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(1.0, 0.0),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                )),
                child: child,
              );
            },
            transitionDuration: const Duration(milliseconds: 400),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('连接失败: $e'),
            backgroundColor: AppTheme.errorColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceId = null;
        });
      }
    }
  }

  /// 获取信号强度指示器颜色
  Color _getRssiColor(int rssi) {
    if (rssi >= -50) return AppTheme.successColor;
    if (rssi >= -70) return AppTheme.accentColor;
    if (rssi >= -85) return AppTheme.warningColor;
    return AppTheme.errorColor;
  }

  /// 获取信号强度指示器图标
  IconData _getRssiIcon(int rssi) {
    if (rssi >= -50) return Icons.signal_cellular_4_bar;
    if (rssi >= -70) return Icons.signal_cellular_alt;
    if (rssi >= -85) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.darkGradient),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              children: [
                _buildHeader(),
                _buildScanIndicator(),
                Expanded(child: _buildDeviceList()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部标题栏
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          // 标题
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShaderMask(
                  shaderCallback: (bounds) =>
                      AppTheme.primaryGradient.createShader(bounds),
                  child: const Text(
                    '蓝牙扫描',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isScanning ? '正在扫描附近设备...' : '点击设备名称进行连接',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          // 扫描按钮
          _buildScanButton(),
        ],
      ),
    );
  }

  /// 扫描按钮
  Widget _buildScanButton() {
    return GestureDetector(
      onTap: _isScanning ? FlutterBluePlus.stopScan : _startScan,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: _isScanning
              ? const LinearGradient(
                  colors: [Color(0xFFFF5252), Color(0xFFFF1744)],
                )
              : AppTheme.primaryGradient,
          boxShadow: [
            BoxShadow(
              color: (_isScanning ? AppTheme.errorColor : AppTheme.primaryColor)
                  .withOpacity(0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          _isScanning ? Icons.stop_rounded : Icons.bluetooth_searching_rounded,
          color: Colors.white,
          size: 28,
        ),
      ),
    );
  }

  /// 扫描状态指示器
  Widget _buildScanIndicator() {
    if (!_isScanning) return const SizedBox(height: 16);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            height: 3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: AppTheme.surfaceDark,
            ),
            child: FractionallySizedBox(
              alignment: Alignment(
                _pulseController.value * 2 - 1,
                0,
              ),
              widthFactor: 0.3,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: AppTheme.primaryGradient,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 设备列表
  Widget _buildDeviceList() {
    if (_scanResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Opacity(
                  opacity: 0.3 +
                      0.4 *
                          (1 +
                              math.sin(
                                  _pulseController.value * math.pi * 2)) /
                          2,
                  child: Icon(
                    Icons.bluetooth_searching_rounded,
                    size: 80,
                    color: AppTheme.primaryColor.withOpacity(0.6),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text(
              _isScanning ? '正在搜索蓝牙设备...' : '未发现蓝牙设备',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 16,
              ),
            ),
            if (!_isScanning) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _startScan,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新扫描'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.accentColor,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _scanResults.length,
      itemBuilder: (context, index) {
        return _buildDeviceCard(_scanResults[index], index);
      },
    );
  }

  /// 设备卡片
  Widget _buildDeviceCard(ScanResult result, int index) {
    final device = result.device;
    final name = device.advName.isNotEmpty
        ? device.advName
        : device.platformName.isNotEmpty
            ? device.platformName
            : '未知设备';
    final isConnecting = _connectingDeviceId == device.remoteId.str;
    final rssiColor = _getRssiColor(result.rssi);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 400 + index * 80),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: GestureDetector(
        onTap: isConnecting ? null : () => _connectToDevice(result),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isConnecting
                  ? AppTheme.primaryColor.withOpacity(0.5)
                  : Colors.white.withOpacity(0.06),
              width: 1,
            ),
            boxShadow: [
              if (isConnecting)
                BoxShadow(
                  color: AppTheme.primaryColor.withOpacity(0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          child: Row(
            children: [
              // 蓝牙图标
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.primaryColor.withOpacity(0.2),
                      AppTheme.accentColor.withOpacity(0.1),
                    ],
                  ),
                ),
                child: const Icon(
                  Icons.bluetooth_rounded,
                  color: AppTheme.primaryColor,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              // 设备名称和ID
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      device.remoteId.str,
                      style: const TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 信号强度 & 连接状态
              if (isConnecting)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                  ),
                )
              else
                Column(
                  children: [
                    Icon(
                      _getRssiIcon(result.rssi),
                      color: rssiColor,
                      size: 20,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${result.rssi} dBm',
                      style: TextStyle(
                        color: rssiColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
