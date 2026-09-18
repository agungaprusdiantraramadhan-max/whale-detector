import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WhaleDetectorApp());
}

class WhaleDetectorApp extends StatelessWidget {
  const WhaleDetectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Binance Microstructure Detector',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121418),
        cardColor: const Color(0xFF1E2329),
        colorScheme: const ColorScheme.dark(primary: Color(0xFFFCD535)),
      ),
      home: const DetectorHomePage(),
    );
  }
}

class SignalHistory {
  final String type;
  final double price;
  final double bair;
  final DateTime time;

  SignalHistory({required this.type, required this.price, required this.bair, required this.time});
}

class DetectorHomePage extends StatefulWidget {
  const DetectorHomePage({super.key});

  @override
  State<DetectorHomePage> createState() => _DetectorHomePageState();
}

class _DetectorHomePageState extends State<DetectorHomePage> {
  // Token universe: RWA, AI/DePIN, Layer-2 di Binance
  final List<String> _watchList = ['PENDLEUSDT', 'RENDERUSDT', 'ARBUSDT', 'OPUSDT', 'NEARUSDT'];
  String _selectedSymbol = 'PENDLEUSDT';

  WebSocketChannel? _channel;
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  double _currentPrice = 0.0;
  double _bair = 0.0;
  double _bidDepthVolume = 0.0;
  double _askDepthVolume = 0.0;
  String _currentSignal = "SCANNING";
  final List<SignalHistory> _signals = [];

  // Parameter Posisi & Risiko ($100 Modal)
  double _entryReferencePrice = 0.0;
  bool _inPosition = false;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _connectWebSocket();
  }

  void _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(initializationSettings);
  }

  void _triggerPushNotification(String title, String body) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'whale_channel',
      'Whale Alerts',
      channelDescription: 'Deteksi Akumulasi Microstructure',
      importance: Importance.max,
      priority: Priority.high,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    await _notificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      platformChannelSpecifics,
    );
  }

  void _connectWebSocket() {
    _channel?.sink.close();
    final streamUrl =
        'wss://stream.binance.com:9443/ws/${_selectedSymbol.toLowerCase()}@depth20@100ms';
    _channel = WebSocketChannel.connect(Uri.parse(streamUrl));

    _channel!.stream.listen((message) {
      final data = jsonDecode(message);
      _processOrderBook(data);
    }, onError: (error) {
      setState(() => _currentSignal = "WS ERROR");
    });
  }

  void _processOrderBook(Map<String, dynamic> data) {
    final List bids = data['bids'] ?? [];
    final List asks = data['asks'] ?? [];

    if (bids.isEmpty || asks.isEmpty) return;

    final double bestBid = double.parse(bids[0][0]);
    final double bestAsk = double.parse(asks[0][0]);
    final double midPrice = (bestBid + bestAsk) / 2.0;

    // Filter kedalaman 2%
    double bidDepthUSD = 0.0;
    for (var bid in bids) {
      double p = double.parse(bid[0]);
      double q = double.parse(bid[1]);
      if (p >= midPrice * 0.98) {
        bidDepthUSD += (p * q);
      }
    }

    double askDepthUSD = 0.0;
    for (var ask in asks) {
      double p = double.parse(ask[0]);
      double q = double.parse(ask[1]);
      if (p <= midPrice * 1.02) {
        askDepthUSD += (p * q);
      }
    }

    // Kalkulasi BAIR (Bid-Ask Imbalance Ratio)
    double imbalance = (bidDepthUSD - askDepthUSD) / (bidDepthUSD + askDepthUSD);

    setState(() {
      _currentPrice = midPrice;
      _bidDepthVolume = bidDepthUSD;
      _askDepthVolume = askDepthUSD;
      _bair = imbalance;

      // Logika Sinyal Akumulasi & Eksekusi
      if (!_inPosition && _bair >= 0.40) {
        _currentSignal = "STRONG BUY (ICEBERG ACCUMULATION)";
        _entryReferencePrice = _currentPrice;
        _inPosition = true;
        _signals.insert(0, SignalHistory(type: 'BUY ENTRY', price: _currentPrice, bair: _bair, time: DateTime.now()));
        _triggerPushNotification(
          'BUY SIGNAL: $_selectedSymbol',
          'Akumulasi Whale Terdeteksi! BAIR: +${(_bair * 100).toStringAsFixed(1)}% di harga \$${_currentPrice.toStringAsFixed(4)}',
        );
      } else if (_inPosition) {
        // Target Profit 1: R:R 1:2.5 (Stop Loss 10%, Target +25%)
        double targetPrice = _entryReferencePrice * 1.25;
        double stopLossPrice = _entryReferencePrice * 0.90;

        if (_currentPrice >= targetPrice || _bair <= -0.35) {
          _currentSignal = "SELL / TAKE PROFIT";
          _inPosition = false;
          _signals.insert(0, SignalHistory(type: 'SELL / TP', price: _currentPrice, bair: _bair, time: DateTime.now()));
          _triggerPushNotification(
            'TAKE PROFIT: $_selectedSymbol',
            'Sinyal Exit Terpicu! Distribusi terdeteksi di harga \$${_currentPrice.toStringAsFixed(4)}',
          );
        } else if (_currentPrice <= stopLossPrice) {
          _currentSignal = "STOP LOSS TRIGGERED";
          _inPosition = false;
          _signals.insert(0, SignalHistory(type: 'STOP LOSS', price: _currentPrice, bair: _bair, time: DateTime.now()));
        }
      }
    });
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color signalColor = Colors.grey;
    if (_currentSignal.contains("BUY")) signalColor = Colors.greenAccent;
    if (_currentSignal.contains("SELL") || _currentSignal.contains("STOP")) signalColor = Colors.redAccent;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Binance Microstructure Bot'),
        backgroundColor: const Color(0xFF1E2329),
        actions: [
          DropdownButton<String>(
            value: _selectedSymbol,
            dropdownColor: const Color(0xFF1E2329),
            underline: const SizedBox(),
            items: _watchList.map((String s) {
              return DropdownMenuItem<String>(value: s, child: Text(s, style: const TextStyle(color: Colors.white)));
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedSymbol = val;
                  _inPosition = false;
                  _currentSignal = "SCANNING";
                });
                _connectWebSocket();
              }
            },
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(_selectedSymbol, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(
                      '\$${_currentPrice.toStringAsFixed(4)}',
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Color(0xFFFCD535)),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: signalColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: signalColor),
                      ),
                      child: Text(
                        _currentSignal,
                        style: TextStyle(color: signalColor, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Metrik Order Book Realtime
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFF1E2329), borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("BAIR Index (2%)", style: TextStyle(color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          '${(_bair * 100).toStringAsFixed(2)}%',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _bair >= 0.40 ? Colors.greenAccent : (_bair <= -0.35 ? Colors.redAccent : Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFF1E2329), borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Bid Depth (\$)", style: TextStyle(color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text('\$${(_bidDepthVolume / 1000).toStringAsFixed(1)}K', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("Riwayat Sinyal & Eksekusi", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _signals.length,
                itemBuilder: (context, index) {
                  final s = _signals[index];
                  final isBuy = s.type.contains("BUY");
                  return Card(
                    color: const Color(0xFF181A20),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(isBuy ? Icons.arrow_upward : Icons.arrow_downward, color: isBuy ? Colors.greenAccent : Colors.redAccent),
                      title: Text('${s.type} @ \$${s.price.toStringAsFixed(4)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('BAIR: ${(s.bair * 100).toStringAsFixed(1)}% | ${s.time.hour}:${s.time.minute}:${s.time.second}'),
                    ),
                  );
                },
              ),
            )
          ],
        ),
      ),
    );
  }
}
