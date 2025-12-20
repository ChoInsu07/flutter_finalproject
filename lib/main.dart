import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart';

// FlutterFire CLI 사용 중이면 켜세요.
// import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    // options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomeShell(),
    );
  }
}


class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class DistanceAIResult {
  final String stage;
  final int closenessScore;
  final String message;

  DistanceAIResult({
    required this.stage,
    required this.closenessScore,
    required this.message,
  });
}


class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  // ===============================
  // 0) UI Constants
  // ===============================
  static const Color primaryBlue = Color(0xFF2979FF);
  static const Color inactiveIcon = Color(0xFF8E8E93);
  static const Color barColor = Color(0xFFF4F6F8);
  static const Color textColor = Color(0xFF1C1C1E);

  // ===============================
  // Tabs / Controllers
  // ===============================
  int _tabIndex = 0; // 0: Map, 1: Share(실행), 2: Profile
  late final AnimationController _spinController;
  final Completer<GoogleMapController> _mapController = Completer();
  bool _centeredOnce = false;

  // ===============================
  // Firebase / Session State
  // ===============================
  static const String shareHost = "https://finalproject-82e34.web.app/";
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _locSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;

  String? _sessionId;
  LatLng? _aLatLng;
  LatLng? _bLatLng;
  double? _distanceMeters;

  // ===============================
  // Map Overlays
  // ===============================
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  String _regionLabel = "";

  // ===============================
  // Profile State
  // ===============================
  String _profileName = "";
  File? _profileImageFile;
  BitmapDescriptor? _aProfileMarkerIcon; // 원형 프로필
  BitmapDescriptor? _bHeartMarkerIcon; // 상대 하트

  final TextEditingController _nameController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  // ===============================
  // Lifecycle
  // ===============================
  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _loadBHeartIcon();
  }

  @override
  void dispose() {
    _spinController.dispose();
    _locSub?.cancel();
    _sessionSub?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  // ===============================
  // Load B Heart Marker Icon
  // ===============================
  Future<void> _loadBHeartIcon() async {
    try {
      //  원하는 하트 마커 실제 픽셀 크기
      const int sizePx = 48; // ← 여기만 조절하면 됨 (추천: 40~48)

      final byteData = await rootBundle.load('assets/B_heart.png');

      final codec = await ui.instantiateImageCodec(
        byteData.buffer.asUint8List(),
        targetWidth: sizePx,
        targetHeight: sizePx,
      );

      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);

      if (!mounted) return;

      setState(() {
        _bHeartMarkerIcon =
            BitmapDescriptor.bytes(data!.buffer.asUint8List());
      });

      _rebuildMarkersAndPolylines();
    } catch (e) {
      // asset 오류 시 기본 마커 fallback
      debugPrint("B heart marker load error: $e");
    }
  }


  // ===============================
  // Location Helpers
  // ===============================
  Future<Position?> _getPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  Future<void> _updateRegion(double lat, double lon) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lon);
      if (placemarks.isEmpty) return;

      final admin = (placemarks.first.administrativeArea ?? "").trim();
      if (!mounted) return;

      setState(() {
        _regionLabel = admin.isNotEmpty ? admin : "현재 위치";
      });
    } catch (_) {}
  }

  Future<void> centerOnce() async {
    if (_centeredOnce || !_mapController.isCompleted) return;

    final pos = await _getPosition();
    if (pos == null) return;

    final controller = await _mapController.future;
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(pos.latitude, pos.longitude),
        16,
      ),
    );

    await _updateRegion(pos.latitude, pos.longitude);
    _centeredOnce = true;
  }

  // ===============================
  // Share Flow (A: session 생성 + 링크 공유)
  // ===============================
  Future<void> startShareFlow() async {
    setState(() => _tabIndex = 0);

    final pos = await _getPosition();
    if (pos == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("위치 권한/서비스를 확인해 주세요.")),
      );
      return;
    }

    final sid = const Uuid().v4();
    _sessionId = sid;

    _aLatLng = LatLng(pos.latitude, pos.longitude);
    _bLatLng = null;
    _distanceMeters = null;

    // sessions/{sid} 생성
    await _db.collection("sessions").doc(sid).set(
      {
        "createdAt": FieldValue.serverTimestamp(),
        "updatedAt": FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    // locations/A 저장
    await _db.collection("sessions").doc(sid).collection("locations").doc("A").set(
      {
        "role": "A",
        "lat": _aLatLng!.latitude,
        "lon": _aLatLng!.longitude,
        "updatedAt": FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    // 지도 이동 및 라벨 업데이트
    if (_mapController.isCompleted) {
      final controller = await _mapController.future;
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(_aLatLng!, 16),
      );
    }
    await _updateRegion(_aLatLng!.latitude, _aLatLng!.longitude);

    // Firestore 구독
    _listenLocations(sid);
    _listenSessionDoc(sid);

    // 공유 링크
    final link = "$shareHost?sessionId=$sid";

    if (!mounted) return;
    final ro = context.findRenderObject();
    final box = ro is RenderBox ? ro : null;

    await Share.share(
      link,
      subject: "위치 공유 링크",
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );

    if (!mounted) return;
    setState(() {});
  }

  // ===============================
  // Firestore Listeners
  // ===============================
  void _listenLocations(String sid) {
    _locSub?.cancel();

    _locSub = _db
        .collection("sessions")
        .doc(sid)
        .collection("locations")
        .withConverter<Map<String, dynamic>>(
          fromFirestore: (snap, _) => snap.data() ?? <String, dynamic>{},
          toFirestore: (data, _) => data,
        )
        .snapshots()
        .listen((snap) async {
      LatLng? a;
      LatLng? latestB;
      Timestamp? latestBTs;

      for (final d in snap.docs) {
        final data = d.data();
        final role = (data["role"] ?? "").toString();

        final lat = (data["lat"] as num?)?.toDouble();
        final lon = (data["lon"] as num?)?.toDouble();
        if (lat == null || lon == null) continue;

        if (role == "A") {
          a = LatLng(lat, lon);
          continue;
        }

        if (role == "B") {
          final ts = data["updatedAt"];
          final t = ts is Timestamp ? ts : null;

          if (latestB == null) {
            latestB = LatLng(lat, lon);
            latestBTs = t;
          } else if (t != null) {
            if (latestBTs == null) {
              latestB = LatLng(lat, lon);
              latestBTs = t;
            } else if (t.compareTo(latestBTs) > 0) {
              latestB = LatLng(lat, lon);
              latestBTs = t;
            }
          }
        }
      }

      _aLatLng = a ?? _aLatLng;
      _bLatLng = latestB ?? _bLatLng;

      _rebuildMarkersAndPolylines();

      // 둘 다 있으면 둘을 화면에 보이게 bounds 조정
      if (_aLatLng != null && _bLatLng != null && _mapController.isCompleted) {
        final controller = await _mapController.future;
        final bounds = _boundsFrom(_aLatLng!, _bLatLng!);
        await controller.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 80),
        );
      }
    });
  }

  void _listenSessionDoc(String sid) {
    _sessionSub?.cancel();

    _sessionSub = _db.collection("sessions").doc(sid).snapshots().listen((docSnap) {
      if (!docSnap.exists) return;
      final data = docSnap.data();
      if (data == null) return;

      final dm = data["distanceMeters"];
      final dist = dm is num ? dm.toDouble() : null;

      setState(() => _distanceMeters = dist);
    });
  }

  // ===============================
  // Map Overlays Builder (Markers/Polylines)
  // ===============================
  void _rebuildMarkersAndPolylines() {
    final m = <Marker>{};
    final p = <Polyline>{};

    if (_aLatLng != null) {
      m.add(
        Marker(
          markerId: const MarkerId("A"),
          position: _aLatLng!,
          icon: _aProfileMarkerIcon ?? BitmapDescriptor.defaultMarker,
          infoWindow: InfoWindow(
            title: _profileName.isNotEmpty ? _profileName : "A (나)",
          ),
        ),
      );
    }

    if (_bLatLng != null) {
      m.add(
        Marker(
          markerId: const MarkerId("B"),
          position: _bLatLng!,
          icon: _bHeartMarkerIcon ?? BitmapDescriptor.defaultMarker,
          infoWindow: const InfoWindow(title: "B (상대)"),
        ),
      );
    }

    if (_aLatLng != null && _bLatLng != null) {
      p.add(
        Polyline(
          polylineId: const PolylineId("A_to_B"),
          points: [_aLatLng!, _bLatLng!],
          width: 6,
          color: primaryBlue,
        ),
      );
    }

    setState(() {
      _markers
        ..clear()
        ..addAll(m);
      _polylines
        ..clear()
        ..addAll(p);
    });
  }

  LatLngBounds _boundsFrom(LatLng p1, LatLng p2) {
    final sw = LatLng(
      math.min(p1.latitude, p2.latitude),
      math.min(p1.longitude, p2.longitude),
    );
    final ne = LatLng(
      math.max(p1.latitude, p2.latitude),
      math.max(p1.longitude, p2.longitude),
    );
    return LatLngBounds(southwest: sw, northeast: ne);
  }

  // ===============================
  // 10.5) AI Distance Analyzer 
  // ===============================
  DistanceAIResult analyzeDistance(double distance) {
    if (distance < 50) {
      return DistanceAIResult(
        stage: "즉시 만남 가능",
        closenessScore: 95,
        message: "지금 바로 만날 수 있는 거리입니다 💕",
      );
    } else if (distance < 500) {
      return DistanceAIResult(
        stage: "가까운 인연",
        closenessScore: 75,
        message: "조금만 이동하면 만날 수 있어요!!",
      );
    } else if (distance < 5000) {
      return DistanceAIResult(
        stage: "중간 거리",
        closenessScore: 45,
        message: "계획을 잡아야 만날 수 있어요.",
      );
    } else {
      return DistanceAIResult(
        stage: "장거리",
        closenessScore: 20,
        message: "마음의 거리는 가까울지도 몰라요 🌍",
      );
    }
  }

  // ===============================
  // Profile Page Actions
  // ===============================
  Future<void> openProfileTab() async {
    _nameController.text = _profileName;
    setState(() => _tabIndex = 2);
  }

  Future<void> pickProfileImage() async {
    final XFile? x = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1200,
    );
    if (x == null) return;

    final file = File(x.path);

    //  원형 + 비율 유지 + crop + 흰 테두리
    final icon = await _circularMarkerFromFile(
      file,
      size: 70,
      borderWidth: 5,
    );

    if (!mounted) return;
    setState(() {
      _profileImageFile = file;
      _aProfileMarkerIcon = icon;
    });

    _rebuildMarkersAndPolylines();
  }

  void saveProfile() {
    final name = _nameController.text.trim();
    setState(() {
      _profileName = name;
      _tabIndex = 0;
    });
    _rebuildMarkersAndPolylines();
  }

  void cancelProfile() {
    setState(() => _tabIndex = 0);
  }

  // ===============================
  // Circular Marker Builder (A profile)
  // ===============================
  Future<BitmapDescriptor> _circularMarkerFromFile(
    File file, {
    int size = 160,
    int borderWidth = 10,
  }) async {
    final bytes = await file.readAsBytes();

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final ui.Image src = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final double s = size.toDouble();

    final paint = Paint()..isAntiAlias = true;
    final center = Offset(s / 2, s / 2);
    final outerR = s / 2;

    // 1) 흰색 테두리 원
    paint.color = Colors.white;
    canvas.drawCircle(center, outerR, paint);

    // 2) 내부 원으로 clip
    final innerR = outerR - borderWidth;
    final clipPath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: innerR));
    canvas.save();
    canvas.clipPath(clipPath);

    // 3) cover crop 계산 (정사각에 맞춰 자르기)
    final srcW = src.width.toDouble();
    final srcH = src.height.toDouble();
    const dstAR = 1.0;
    final srcAR = srcW / srcH;

    late Rect srcRect;
    if (srcAR > dstAR) {
      final newW = srcH * dstAR;
      final left = (srcW - newW) / 2;
      srcRect = Rect.fromLTWH(left, 0, newW, srcH);
    } else {
      final newH = srcW / dstAR;
      final top = (srcH - newH) / 2;
      srcRect = Rect.fromLTWH(0, top, srcW, newH);
    }

    final dstSize = innerR * 2;
    final dstRect = Rect.fromLTWH(
      (s - dstSize) / 2,
      (s - dstSize) / 2,
      dstSize,
      dstSize,
    );

    canvas.drawImageRect(src, srcRect, dstRect, Paint()..isAntiAlias = true);
    canvas.restore();

    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final pngBytes = data!.buffer.asUint8List();

    return BitmapDescriptor.bytes(pngBytes);
  }

  // ===============================
  // AppBar (공통)
  // ===============================
  PreferredSizeWidget _appBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(72),
      child: AppBar(
        backgroundColor: barColor,
        surfaceTintColor: barColor,
        elevation: 0,
        centerTitle: true,
        title: Image.asset('assets/YOU.png', height: 150, fit: BoxFit.contain),
        actions: [
          if (_profileName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Center(
                child: Text(
                  _profileName,
                  style: const TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          if (_profileImageFile != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: CircleAvatar(
                radius: 14,
                backgroundImage: FileImage(_profileImageFile!),
                backgroundColor: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  // ===============================
  // Bottom Bar Buttons (공통)
  // ===============================
  Widget _roundButton({
    required IconData icon,
    required int index,
    required VoidCallback onTap,
    double size = 56,
  }) {
    final bool active = _tabIndex == index;
    return Material(
      color: active ? primaryBlue : inactiveIcon,
      shape: const CircleBorder(),
      elevation: active ? 8 : 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          setState(() => _tabIndex = index);
          onTap();
        },
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: Icon(icon, color: Colors.white, size: 26)),
        ),
      ),
    );
  }

  Widget _sphereShareButton() {
    const double size = 78;
    final bool active = _tabIndex == 1;

    final Color baseColor = active ? primaryBlue : inactiveIcon;
    final Color darkColor =
        active ? const Color(0xFF1E5BFF) : const Color(0xFF6E6E73);

    return GestureDetector(
      onTap: startShareFlow,
      child: AnimatedBuilder(
        animation: _spinController,
        builder: (_, __) {
          final angle = _spinController.value * 2 * math.pi;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.002)
              ..rotateY(angle),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.35, -0.35),
                  radius: 0.95,
                  colors: [
                    baseColor.withValues(alpha: 0.95),
                    baseColor,
                    darkColor,
                  ],
                  stops: const [0.15, 0.65, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: active ? 0.28 : 0.18),
                    blurRadius: active ? 20 : 12,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(Icons.share_location, color: Colors.white, size: 34),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      bottom: 28,
      left: 24,
      right: 24,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _roundButton(icon: Icons.map, index: 0, onTap: () {}),
          _sphereShareButton(),
          _roundButton(icon: Icons.person, index: 2, onTap: openProfileTab),
        ],
      ),
    );
  }

  // ===============================
  // Build (키보드 올라오면 하단바 숨김)
  // ===============================
  @override
  Widget build(BuildContext context) {
    final bool keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final bool hideBottomBar = (_tabIndex == 2) && keyboardOpen;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: _appBar(),
      body: Stack(
        children: [
          IndexedStack(
            index: _tabIndex == 2 ? 1 : 0,
            children: [
              MapPage(
                onMapCreated: (controller) async {
                  if (!_mapController.isCompleted) _mapController.complete(controller);
                  await centerOnce();
                },
                regionLabel: _regionLabel,
                sessionId: _sessionId,
                distanceMeters: _distanceMeters,
                bLatLng: _bLatLng,

                aiResult: (_distanceMeters == null)
                    ? null
                    : analyzeDistance(_distanceMeters!), 

                markers: _markers,
                polylines: _polylines,
                barColor: barColor,
                textColor: textColor,
              ),
              ProfilePage(
                nameController: _nameController,
                profileImageFile: _profileImageFile,
                onPickImage: pickProfileImage,
                onSave: saveProfile,
                onCancel: cancelProfile,
                primaryBlue: primaryBlue,
                textColor: textColor,
              ),
            ],
          ),

          if (!hideBottomBar) _bottomBar(),
        ],
      ),
    );
  }
}

// ===============================
// MapPage
// ===============================
class MapPage extends StatelessWidget {
  const MapPage({
    super.key,
    required this.onMapCreated,
    required this.regionLabel,
    required this.sessionId,
    required this.distanceMeters,
    required this.aiResult,
    required this.bLatLng,
    required this.markers,
    required this.polylines,
    required this.barColor,
    required this.textColor,
  

  });

  final void Function(GoogleMapController) onMapCreated;
  final String regionLabel;
  final String? sessionId;
  final double? distanceMeters;
  final DistanceAIResult? aiResult;
  final LatLng? bLatLng;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Color barColor;
  final Color textColor;

  static const CameraPosition fallback = CameraPosition(
    target: LatLng(37.5665, 126.9780),
    zoom: 14,
  );

  Widget _regionChip() {
    if (regionLabel.isEmpty) return const SizedBox.shrink();
    return Positioned(
      top: 12,
      left: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: barColor,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3)),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.place, size: 16, color: textColor),
            const SizedBox(width: 6),
            Text(
              regionLabel,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _distanceCard() {
    if (sessionId == null) return const SizedBox.shrink();

    String title = "세션 생성됨";
    String sub = "상대(B) 위치 대기 중…";

    if (bLatLng != null && distanceMeters == null) {
      title = "거리 계산 중…";
      sub = "잠시만 기다려 주세요.";
    }
    if (distanceMeters != null) {
      final m = distanceMeters!;
      title = "거리";
      sub = m >= 1000 ? "${(m / 1000).toStringAsFixed(2)} km" : "${m.toStringAsFixed(1)} m";
    }

    return Positioned(
      top: 12,
      right: 12,
      child: Container(
        width: 190,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: barColor,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(height: 6),
            Text(sub, style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 12)),
            const SizedBox(height: 8),
            Text(
              "sessionId:\n$sessionId",
              style: TextStyle(color: textColor, fontSize: 10, height: 1.2),
            ),
          ],
        ),
      ),
    );
  }
    Widget _aiCard() {
    if (aiResult == null || distanceMeters == null) {
      return const SizedBox.shrink();
    }

    // ===============================
    // ★ 도보 ETA 계산 (외부 API 없음)
    // ===============================
    const double walkSpeedKmh = 4.5; // 도보 평균 속도
    final double distanceKm = distanceMeters! / 1000;
    final int walkMinutes = ((distanceKm / walkSpeedKmh) * 60).ceil();

    final String etaText = walkMinutes <= 1
        ? "도보 1분 이내"
        : walkMinutes < 60
            ? "도보 약 $walkMinutes분"
            : "도보 약 ${walkMinutes ~/ 60}시간 ${walkMinutes % 60}분";

    return Positioned(
      bottom: 110,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: barColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 10,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===============================
            // AI 거리 단계
            // ===============================
            Text(
              aiResult!.stage,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),

            // ===============================
            // AI 메시지
            // ===============================
            Text(
              aiResult!.message,
              style: TextStyle(
                fontSize: 13,
                color: textColor,
              ),
            ),

            const SizedBox(height: 10),

            // ===============================
            // ★ 도보 ETA 출력
            // ===============================
            Text(
              "예상 이동 시간 · $etaText",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: textColor.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: fallback,
          onMapCreated: onMapCreated,
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          markers: markers,
          polylines: polylines,
        ),
        _regionChip(),
        _distanceCard(),
        _aiCard(),
      ],
    );
  }
}

// ===============================
//  ProfilePage (키보드 올라오면 스크롤, overflow 방지)
// ===============================
class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.nameController,
    required this.profileImageFile,
    required this.onPickImage,
    required this.onSave,
    required this.onCancel, // (호출 안 함. 시그니처 유지용)
    required this.primaryBlue,
    required this.textColor,
  });

  final TextEditingController nameController;
  final File? profileImageFile;

  final VoidCallback onPickImage;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  final Color primaryBlue;
  final Color textColor;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  // ===============================
  // Focus 관리
  // ===============================
  late final FocusNode _nameFocus;

  @override
  void initState() {
    super.initState();
    _nameFocus = FocusNode();
    _nameFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool editingName = _nameFocus.hasFocus;

    // ===============================
    // 키보드/아이콘바와 겹침 방지 padding
    // ===============================
    final double viewInset = MediaQuery.of(context).viewInsets.bottom;
    final double bottomSafePadding = editingName
        ? (viewInset > 0 ? viewInset + 20 : 20)
        : 140; // 하단 아이콘바 공간

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Container(
        color: Colors.white,
        padding: EdgeInsets.fromLTRB(20, 18, 20, bottomSafePadding),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ===============================
                        // Title
                        // ===============================
                        Text(
                          "프로필",
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: widget.textColor,
                          ),
                        ),
                        const SizedBox(height: 18),

                        // ===============================
                        // Image Picker Row
                        // ===============================
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 36,
                              backgroundColor: const Color(0xFFEDEFF2),
                              backgroundImage: widget.profileImageFile != null
                                  ? FileImage(widget.profileImageFile!)
                                  : null,
                              child: widget.profileImageFile == null
                                  ? const Icon(
                                      Icons.person,
                                      size: 34,
                                      color: Color(0xFF7A7A80),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 14),
                            ElevatedButton.icon(
                              onPressed: widget.onPickImage,
                              icon: const Icon(Icons.photo_library),
                              label: const Text("이미지 선택"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: widget.primaryBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 18),

                        // ===============================
                        // Name Field
                        // ===============================
                        Text(
                          "이름",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: widget.textColor,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: widget.nameController,
                          focusNode: _nameFocus,
                          textInputAction: TextInputAction.done,
                          onEditingComplete: () => FocusScope.of(context).unfocus(),
                          decoration: InputDecoration(
                            hintText: "이름을 입력하세요",
                            filled: true,
                            fillColor: const Color(0xFFF4F6F8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),

                        const Spacer(),

                        // ===============================
                        // Save Button (Full Width)
                        // - 입력 중이면 숨김
                        // ===============================
                        if (!editingName)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: widget.onSave,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: widget.primaryBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Text(
                                "저장",
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
