import 'dart:core';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 通話サンプル（映像・音声）
import 'src/call_sample/call_sample.dart';
// データチャネル通信（テキストなど）
import 'src/call_sample/data_channel_sample.dart';
import 'src/route_item.dart';

// アプリ起動
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  
  // 匿名認証（テスト用）
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await FirebaseAuth.instance.signInAnonymously();
      debugPrint('匿名認証成功');
    }
  } catch (e) {
    debugPrint('認証エラー: $e');
  }
  
  runApp(new MyApp());
}

// StatefulWidget（状態を持つアプリ）
class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

// ダイアログのボタン結果
enum DialogDemoAction {
  cancel,
  connect,
}

class _MyAppState extends State<MyApp> {
  // 画面に表示するメニュー項目
  List<RouteItem> items = [];

  // 接続先サーバのアドレス
  String _server = '';

  // ローカル保存用（前回のサーバを記憶）
  late SharedPreferences _prefs;

  // DataChannelを使うかどうか
  bool _datachannel = false;

  // LeaderかFollowerか
  bool _isLeader = false;

  @override
  initState() {
    super.initState();
    _initData();   // 保存データ読み込み
    _initItems();  // メニュー作成
  }

  // メニュー1行分のUI
  _buildRow(context, item) {
    return ListBody(children: <Widget>[
      ListTile(
        title: Text(item.title),
        onTap: () => item.push(context), // タップで処理実行
        trailing: Icon(Icons.arrow_right),
      ),
      Divider()
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
          appBar: AppBar(
            title: Text('Flutter-WebRTC example'),
          ),
          // メニュー一覧表示
          body: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(0.0),
              itemCount: items.length,
              itemBuilder: (context, i) {
                return _buildRow(context, items[i]);
              })),
    );
  }

  // SharedPreferencesからサーバアドレス取得
  _initData() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      // 保存されてなければデフォルト値
      _server = _prefs.getString('server') ?? 'demo.cloudwebrtc.com';
    });
  }

  // ダイアログ表示（接続確認）
  void showDemoDialog<T>(
      {required BuildContext context, required Widget child}) {
    showDialog<T>(
      context: context,
      builder: (BuildContext context) => child,
    ).then<void>((T? value) {
      // ダイアログが閉じた後の処理
      if (value != null) {
        if (value == DialogDemoAction.connect) {
          // サーバアドレス保存
          _prefs.setString('server', _server);

          // 次の画面へ遷移
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (BuildContext context) => _datachannel
                      // DataChannelモード
                      ? DataChannelSample(
                          host: _server,
                          isLeader: _isLeader,
                        )
                      // 通常の通話モード
                      : CallSample(host: _server)));
        }
      }
    });
  }

  // サーバアドレス入力ダイアログ
  _showAddressDialog(context) {
    showDemoDialog<DialogDemoAction>(
        context: context,
        child: AlertDialog(
            title: const Text('Enter server address:'),
            content: TextField(
              onChanged: (String text) {
                setState(() {
                  _server = text; // 入力された値を保存
                });
              },
              decoration: InputDecoration(
                hintText: _server,
              ),
              textAlign: TextAlign.center,
            ),
            actions: <Widget>[
              // キャンセル
              TextButton(
                  child: const Text('CANCEL'),
                  onPressed: () {
                    Navigator.pop(context, DialogDemoAction.cancel);
                  }),
              // 接続
              TextButton(
                  child: const Text('CONNECT'),
                  onPressed: () {
                    Navigator.pop(context, DialogDemoAction.connect);
                  })
            ]));
  }

  // メニュー項目の定義
  _initItems() {
    items = <RouteItem>[
      RouteItem(
        title: 'Leader (1 → 多)',
        subtitle: 'Leader mode: connect to multiple followers',
        push: (BuildContext context) {
          _datachannel = true;   // DataChannel使用
          _isLeader = true;      // Leaderモード
          _showAddressDialog(context);
        },
      ),
      RouteItem(
        title: 'Follower',
        subtitle: 'Follower mode: connect to leader',
        push: (BuildContext context) {
          _datachannel = true;   // DataChannel使用
          _isLeader = false;     // Followerモード
          _showAddressDialog(context);
        },
      ),
    ];
  }
}
