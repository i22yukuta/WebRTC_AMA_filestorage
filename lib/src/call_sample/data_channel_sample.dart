import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart'; // UI関連
import 'dart:core'; // 基本機能
import 'signaling.dart'; // WebRTCシグナリング処理
import 'package:flutter_webrtc/flutter_webrtc.dart'; // WebRTC機能
import 'package:record/record.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';

const String _storageBucket = 'gs://webrtc-for-ama-49bf3.firebasestorage.app';

class DataChannelSample extends StatefulWidget {
  static String tag = 'call_sample'; // 画面識別用タグ
  final String host; // シグナリングサーバのアドレス
  final bool isLeader; // LeaderかFollowerかのフラグ

  DataChannelSample({required this.host, required this.isLeader}); // コンストラクタ

  @override
  _DataChannelSampleState createState() => _DataChannelSampleState();
}

class _DataChannelSampleState extends State<DataChannelSample> {
  Future<void> _initAuth() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      await FirebaseAuth.instance.signInAnonymously();
      debugPrint("匿名ログイン成功");
    } else {
      debugPrint("既にログイン済み: ${user.uid}");
    }
  }

  Signaling? _signaling; // シグナリング管理
  List<dynamic> _peers = []; // 接続可能なピア一覧
  String? _selfId; // 自分のID

  bool _inCalling = false; // 通話中かどうか
  bool _ready = false; // 次の画面へ進む準備

  Map<String, RTCDataChannel> _dataChannels = {}; // 各ピアとのDataChannel
  Map<String, bool> _connectedPeers = {}; // 接続済みピア管理

  Session? _session; // 現在のセッション
  var _text = ''; // 受信した文字列
  bool _waitAccept = false; // 承認待ちフラグ

  TextEditingController _controller = TextEditingController(); // 入力欄
  final _recorder = AudioRecorder();
  String? _recordPath;
  String _uploadStatus = '';
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();

    _initAuth();

    if (widget.isLeader) {
      _startAsLeader(); // Leaderとして開始
    } else {
      _startAsFollower(); // Followerとして開始
    }
  }

  @override
  void deactivate() {
    super.deactivate();
    _signaling?.close(); // 終了時に接続を閉じる
    _recorder.dispose();
  }

  void _connect(BuildContext context) async {
    _signaling ??= Signaling(widget.host, context)..connect(); // サーバ接続

    _signaling?.onDataChannelMessage = (_, dc, RTCDataChannelMessage data) {
      if (!data.isBinary) {
        // 👇 Leaderは何もしない（超重要）
        if (!widget.isLeader) {
          if (data.text == "START") {
            startRecording();
          } else if (data.text == "STOP") {
            stopRecording();
          }
        }

        // 表示はそのまま残す
        setState(() {
          _text = data.text;
        });
      }
    };

    _signaling?.onDataChannel = (session, channel) {
      _dataChannels[session.sid] = channel; // DataChannel保存

      setState(() {
        _inCalling = true; // 通信開始

        if (widget.isLeader) {
          String peerId = session.pid; // ピアID取得
          _connectedPeers[peerId] = true; // 接続済みにする
        } else {
          _ready = true; // Followerは準備OK
        }
      });
    };

    _signaling?.onCallStateChange = (Session session, CallState state) async {
      switch (state) {
        case CallState.CallStateNew:
          setState(() {
            _session = session; // セッション保存

            // 🔥 ここで紐付け（重要）
            if (widget.isLeader) {}
          });
          break;

        case CallState.CallStateConnected:
          setState(() {
            _inCalling = true; // 接続完了
          });
          break;

        case CallState.CallStateBye:
          setState(() {
            _inCalling = false; // 通話終了
            _session = null;
            _text = ''; // 受信文字クリア
          });
          break;

        case CallState.CallStateInvite:
          break;

        case CallState.CallStateRinging:
          _accept(); // 着信時に自動応答
          break;
      }
    };

    _signaling?.onPeersUpdate = (event) {
      setState(() {
        _selfId = event['self']; // 自分のID更新
        _peers = event['peers']; // ピア一覧更新
      });
    };
  }

  void connectToAllPeers() async {
    for (var peer in _peers) {
      var peerId = peer['id'];

      if (peerId != _selfId) {
        _signaling?.invite(peerId, 'data', false); // 全員に接続要求
      }
    }
  }

  void sendToAll(String message) {
    _dataChannels.forEach((id, channel) {
      channel.send(
          RTCDataChannelMessage(message)); // 全員にメッセージ送信（←ここがSTART/STOP送信になる）
    });
  }

  void _startAsLeader() {
    _connect(context); // Leaderも接続処理は同じ
  }

  void _startAsFollower() {
    _connect(context); // Followerも接続処理は同じ
  }

  _invitePeer(context, peerId) async {
    if (!widget.isLeader) return; // Leaderのみ実行

    if (peerId != _selfId) {
      _signaling?.invite(peerId, 'data', false); // 個別接続
    }
  }

  _accept() {
    if (_session != null) {
      _signaling?.accept(_session!.sid, 'data'); // 接続受け入れ
    }
  }

  _buildRow(context, peer) {
    var self = (peer['id'] == _selfId); // 自分かどうか判定

    return ListTile(
      title: Text(
          self ? "${peer['name']} (You)" : "${peer['name']} (${peer['id']})"),
      trailing: ElevatedButton(
        onPressed: widget.isLeader
            ? () => _invitePeer(context, peer['id']) // Leaderのみ接続ボタン有効
            : null,
        child: Text(
          _connectedPeers[peer['id']] == true
              ? "Connected"
              : "Connect", // 接続状態表示
        ),
      ),
    );
  }

  void _setUploadStatus(String message) {
    if (!mounted) return;
    setState(() {
      _uploadStatus = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("WebRTC (${_selfId ?? ""})"), // 自分のID表示
      ),
      body: !_ready
          ? Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: _peers.length,
                    itemBuilder: (context, i) {
                      return _buildRow(context, _peers[i]); // ピア一覧表示
                    },
                  ),
                ),
                if (widget.isLeader)
                  ElevatedButton(
                    onPressed: connectToAllPeers,
                    child: Text("Connect All"), // 全員接続
                  ),
                if (widget.isLeader)
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _ready = true; // 次の画面へ
                      });
                    },
                    child: Text("Next"),
                  ),
              ],
            )
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Received: $_text"), // 受信した文字列表示
                  if (_uploadStatus.isNotEmpty) Text(_uploadStatus),
                  if (_isUploading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: CircularProgressIndicator(),
                    ),

                  TextField(
                    controller: _controller,
                    decoration: InputDecoration(hintText: "メッセージ入力"), // 入力欄
                  ),

                  SizedBox(height: 20),

                  ElevatedButton(
                    onPressed: () {
                      sendToAll("START"); // 入力した文字を送信
                    },
                    child: Text("開始"),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      sendToAll("STOP"); // 入力した文字を送信
                    },
                    child: Text("停止"),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> startRecording() async {
    if (widget.isLeader) return;

    // 権限チェック
    if (await _recorder.hasPermission()) {
      final dir = await getApplicationDocumentsDirectory();

      _recordPath =
          '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.wav'; //ここを変更

      /*await _recorder.start(
        const RecordConfig(),
        path: _recordPath!,
      );*/
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav, // ←これが最重要
          sampleRate: 44100,
          bitRate: 128000,
        ),
        path: _recordPath!,
      );

      _setUploadStatus("録音開始: $_recordPath");
      debugPrint("録音開始: $_recordPath");
    } else {
      _setUploadStatus("マイク権限がありません");
    }
  }

  Future<void> stopRecording() async {
    if (widget.isLeader) return;

    final path = await _recorder.stop();
    _setUploadStatus("録音終了: ${path ?? '保存失敗'}");
    debugPrint("録音終了: $path");

    if (path != null) {
      await uploadToFirebase(path);
    }
  }

  Future<void> uploadToFirebase(String path) async {
    // 認証確認
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _setUploadStatus("エラー: ユーザーが認証されていません");
      debugPrint("アップロード失敗: 認証されていないユーザー");
      return;
    }

    final file = File(path);

    if (!await file.exists()) {
      _setUploadStatus("録音ファイルが見つかりません: $path");
      return;
    }

    if (mounted) {
      setState(() {
        _isUploading = true;
      });
    }

    final fileName =
        'audio_${DateTime.now().millisecondsSinceEpoch}.wav'; //ここを変更
    final storage = FirebaseStorage.instanceFor(bucket: _storageBucket);
    final ref = storage.ref().child('recordings/$fileName');

    try {
      final snapshot = await ref.putFile(
        file,
        SettableMetadata(contentType: 'audio/wav'), //ここを変更
      );
      _setUploadStatus(
        "アップロード完了: ${snapshot.ref.bucket}/${snapshot.ref.fullPath}",
      );
      debugPrint(
        "アップロード完了: ${snapshot.ref.bucket}/${snapshot.ref.fullPath}",
      );
    } on FirebaseException catch (e) {
      _setUploadStatus(
        "Firebase保存失敗: ${e.code}${e.message != null ? ' / ${e.message}' : ''}",
      );
      debugPrint("Firebase保存失敗: ${e.code} ${e.message}");
    } catch (e) {
      _setUploadStatus("アップロード失敗: $e");
      debugPrint("アップロード失敗: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }
}
