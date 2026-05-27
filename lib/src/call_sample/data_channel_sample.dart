import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart'; // UI関連
import 'dart:core'; // 基本機能
import 'signaling.dart'; // WebRTCシグナリング処理
import 'package:flutter_webrtc/flutter_webrtc.dart'; // WebRTC機能
import 'package:record/record.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'dart:async';
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

  bool _ready = false; // 次の画面へ進む準備

  Map<String, RTCDataChannel> _dataChannels = {}; // 各ピアとのDataChannel
  Map<String, bool> _connectedPeers = {}; // 接続済みピア管理
  Map<String, int> _peerNumbers = {}; // 各Followerへの番号割り当て
  int _nextFollowerNumber = 1; // 次に割り当てる番号
  int? _assignedNumber; // Follower側の自分の番号
  bool _startRequested = false; // START受信済み
  Timer? _playbackTimer; // 再生予約タイマー
  Timer? _recordingStartTimer; // 録音開始予約タイマー
  DateTime? _recordStartReceivedAt; // record_start受信時刻
  DateTime? _stopReceivedAt; // STOP受信時刻
  DateTime? _recordingStartedAt; // 録音開始基準時刻
  late ap.AudioPlayer _audioPlayer;

  Session? _session; // 現在のセッション
  var _text = ''; // 受信した文字列

  TextEditingController _controller = TextEditingController(); // 入力欄
  final _recorder = AudioRecorder();
  final _warmupRecorder = AudioRecorder();
  Directory? _documentsDirectory;
  bool _hasRecordPermission = false;
  bool _recorderWarmedUp = false;
  String? _recordPath;
  String _uploadStatus = '';
  String _timingLog = '';
  bool _isUploading = false;
  StreamSubscription<RecordState>? _recorderStateSubscription;

  @override
  void initState() {
    super.initState();
    _audioPlayer = ap.AudioPlayer();
    unawaited(_configureAudioPlayer());
    _recorderStateSubscription = _recorder.onStateChanged().listen((state) {
      debugPrint('Recorder state changed: $state');
    });

    _initAuth();

    if (widget.isLeader) {
      _startAsLeader(); // Leaderとして開始
    } else {
      unawaited(_prepareRecordingResources());
      _startAsFollower(); // Followerとして開始
    }
  }

  Future<void> _prepareRecordingResources() async {
    try {
      _hasRecordPermission = await _recorder.hasPermission();
      _documentsDirectory = await getApplicationDocumentsDirectory();
      debugPrint(
        '録音事前準備完了: permission=$_hasRecordPermission dir=${_documentsDirectory?.path}',
      );
      await _warmUpRecorder();
    } catch (e) {
      debugPrint('録音事前準備エラー: $e');
    }
  }

  RecordConfig _recordConfig() {
    return const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 44100,
      bitRate: 128000,
    );
  }

  Future<void> _warmUpRecorder() async {
    if (widget.isLeader || !_hasRecordPermission || _documentsDirectory == null) {
      return;
    }
    if (_recorderWarmedUp) {
      return;
    }

    final warmupPath =
        '${_documentsDirectory!.path}/warmup_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      debugPrint('録音ウォームアップ開始');
      await _warmupRecorder.start(_recordConfig(), path: warmupPath);
      await _warmupRecorder.cancel();
      _recorderWarmedUp = true;
      debugPrint('録音ウォームアップ完了');
    } catch (e) {
      debugPrint('録音ウォームアップ失敗: $e');
    }
  }

  Future<void> _configureAudioPlayer() async {
    try {
      await _audioPlayer.setAudioContext(
        ap.AudioContext(
          android: const ap.AudioContextAndroid(
            isSpeakerphoneOn: true,
            audioMode: ap.AndroidAudioMode.normal,
            stayAwake: false,
            contentType: ap.AndroidContentType.sonification,
            usageType: ap.AndroidUsageType.media,
            audioFocus: ap.AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: ap.AudioContextIOS(
            category: ap.AVAudioSessionCategory.playAndRecord,
            options: {
              ap.AVAudioSessionOptions.defaultToSpeaker,
              ap.AVAudioSessionOptions.mixWithOthers,
            },
          ),
        ),
      );
    } catch (e) {
      debugPrint('AudioPlayer設定エラー: $e');
    }
  }

  @override
  void deactivate() {
    super.deactivate();
    _playbackTimer?.cancel();
    _recordingStartTimer?.cancel();
    _signaling?.close(); // 終了時に接続を閉じる
    _audioPlayer.dispose();
    _recorder.dispose();
    _warmupRecorder.dispose();
    _recorderStateSubscription?.cancel();
  }

  void _connect(BuildContext context) async {
    _signaling ??= Signaling(widget.host, context)..connect(); // サーバ接続

    _signaling?.onDataChannelMessage = (_, dc, RTCDataChannelMessage data) async {
      if (!data.isBinary) {
        if (!widget.isLeader) {
          if (data.text.startsWith('ASSIGN:')) {
            final parts = data.text.split(':');
            if (parts.length == 2) {
              final number = int.tryParse(parts[1]);
              if (number != null) {
                setState(() {
                  _assignedNumber = number;
                  _text = 'Assigned number: $_assignedNumber';
                });
                debugPrint('ASSIGN受信: $_assignedNumber');
                _playAudioWithDelay();
              }
            }
          } else if (data.text == 'record_start') {
            _recordStartReceivedAt = DateTime.now();
            debugPrint('record_start受信');
            debugPrint('record_start受信時刻: $_recordStartReceivedAt');
            _setTimingLog('record_start受信時刻: $_recordStartReceivedAt');
            _startRequested = true;
            await _scheduleRecordingStart();
          } else if (data.text == 'STOP') {
            debugPrint('STOP受信');
            _stopReceivedAt = DateTime.now();
            debugPrint('STOP受信時刻: $_stopReceivedAt');
            _appendTimingLog('STOP受信時刻: $_stopReceivedAt');
            _startRequested = false;
            stopRecording();
            _cancelScheduledPlayback();
          }
        }

        if (!data.text.startsWith('ASSIGN:')) {
          setState(() {
            _text = data.text;
          });
        }
      }
    };

    _signaling?.onDataChannel = (session, channel) {
      _dataChannels[session.sid] = channel; // DataChannel保存

      if (widget.isLeader) {
        _setupLeaderAssignment(session, channel);
      }

      setState(() {
        if (widget.isLeader) {
          final peerId = session.pid; // ピアID取得
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
          break;

        case CallState.CallStateBye:
          setState(() {
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

  void _setupLeaderAssignment(Session session, RTCDataChannel channel) {
    final peerId = session.pid;
    _peerNumbers.putIfAbsent(peerId, () => _nextFollowerNumber++);

    Future<void> sendAssignment() async {
      final number = _peerNumbers[peerId];
      if (number == null) return;
      try {
        await channel.send(RTCDataChannelMessage('ASSIGN:$number'));
        debugPrint('ASSIGN送信: peer=$peerId number=$number');
      } catch (e) {
        debugPrint('ASSIGN送信失敗: peer=$peerId error=$e');
      }
    }

    channel.onDataChannelState = (state) {
      debugPrint('DataChannel state: peer=$peerId state=$state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        sendAssignment();
      }
    };

    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      sendAssignment();
    }
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

  Future<void> _scheduleRecordingStart() async {
    _recordingStartTimer?.cancel();
    const delay = Duration(seconds: 3);
    _setUploadStatus('録音予約: 3秒後に開始');
    debugPrint('録音予約: 3秒後に開始');
    _recordingStartTimer = Timer(delay, () async {
      await startRecording();
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

    final numberLabel = _peerNumbers.containsKey(peer['id'])
        ? ' #${_peerNumbers[peer['id']]}'
        : '';

    return ListTile(
      title: Text(self
          ? "${peer['name']} (You)"
          : "${peer['name']} (${peer['id']})$numberLabel"),
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

  void _setTimingLog(String message) {
    if (!mounted) return;
    setState(() {
      _timingLog = message;
    });
  }

  void _appendTimingLog(String message) {
    if (!mounted) return;
    setState(() {
      _timingLog = _timingLog.isEmpty ? message : '$_timingLog\n$message';
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
                  if (!widget.isLeader && _assignedNumber != null)
                    Text('Your number: $_assignedNumber'),
                  Text("Received: $_text"), // 受信した文字列表示
                  if (_uploadStatus.isNotEmpty) Text(_uploadStatus),
                  if (_timingLog.isNotEmpty) Text(_timingLog),
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
                      sendToAll("record_start");
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

    if (!_hasRecordPermission) {
      _hasRecordPermission = await _recorder.hasPermission();
    }
    _documentsDirectory ??= await getApplicationDocumentsDirectory();
    if (!_recorderWarmedUp) {
      await _warmUpRecorder();
    }

    // 権限チェック
    if (_hasRecordPermission && _documentsDirectory != null) {
      _recordPath =
          '${_documentsDirectory!.path}/audio_${DateTime.now().millisecondsSinceEpoch}.wav'; //ここを変更

      /*await _recorder.start(
        const RecordConfig(),
        path: _recordPath!,
      );*/
      await _recorder.start(_recordConfig(), path: _recordPath!);

      _recordingStartedAt = DateTime.now();
      _setUploadStatus("録音開始: $_recordPath");
      debugPrint("録音開始: $_recordPath");
      debugPrint('録音開始時刻: $_recordingStartedAt');
      if (_recordStartReceivedAt != null) {
        final lag = _recordingStartedAt!.difference(_recordStartReceivedAt!);
        debugPrint(
          'record_start受信から録音開始まで: ${lag.inMilliseconds}ms',
        );
        _setTimingLog(
          'record_start受信: $_recordStartReceivedAt\n'
          '録音開始: $_recordingStartedAt\n'
          '差分: ${lag.inMilliseconds}ms',
        );
      } else {
        _setTimingLog('録音開始: $_recordingStartedAt');
      }
      _playAudioWithDelay();
    } else {
      _setUploadStatus("録音準備に失敗しました");
    }
  }

  Future<void> stopRecording() async {
    if (widget.isLeader) return;

    _recordingStartTimer?.cancel();
    _recordingStartTimer = null;
    final wasRecording = await _recorder.isRecording();
    final wasPaused = await _recorder.isPaused();
    debugPrint('stopRecording呼び出し: isRecording=$wasRecording isPaused=$wasPaused');
    if (!wasRecording) {
      _appendTimingLog('録音停止スキップ: recorderがrecord状態ではありません');
      _setUploadStatus('録音停止スキップ: recorderが停止済みです');
      return;
    }
    final path = await _recorder.stop();
    final recordingStoppedAt = DateTime.now();
    debugPrint('録音終了時刻: $recordingStoppedAt');
    if (_stopReceivedAt != null) {
      final lag = recordingStoppedAt.difference(_stopReceivedAt!);
      debugPrint('STOP受信から録音終了まで: ${lag.inMilliseconds}ms');
      _appendTimingLog(
        '録音終了: $recordingStoppedAt\n'
        'STOPから終了まで: ${lag.inMilliseconds}ms',
      );
    } else {
      _appendTimingLog('録音終了: $recordingStoppedAt');
    }
    _recordStartReceivedAt = null;
    _stopReceivedAt = null;
    _recordingStartedAt = null;
    _setUploadStatus("録音終了: ${path ?? '保存失敗'}");
    debugPrint("録音終了: $path");

    if (path != null) {
      await uploadToFirebase(path);
    }
    _recorderWarmedUp = false;
    unawaited(_warmUpRecorder());
  }

  void _playAudioWithDelay() {
    if (!_startRequested) {
      debugPrint('再生予約待機: record_start未受信');
      return;
    }
    if (_assignedNumber == null) {
      _setUploadStatus('再生予約待機: 番号未設定');
      debugPrint('再生予約待機: 番号未設定');
      return;
    }
    if (_recordingStartedAt == null) {
      _setUploadStatus('再生予約待機: 録音未開始');
      debugPrint('再生予約待機: 録音未開始');
      return;
    }
    _schedulePlayback();
  }

  void _schedulePlayback() {
    _playbackTimer?.cancel();
    final scheduledAt = _recordingStartedAt!.add(
      Duration(seconds: (3 * _assignedNumber!) - 2),
    );
    final delay = scheduledAt.difference(DateTime.now());

    if (!delay.isNegative && delay != Duration.zero) {
      _setUploadStatus(
        '再生予約: 録音開始から${(3 * _assignedNumber!) - 2}秒後に再生',
      );
      debugPrint('再生予約: number=$_assignedNumber delay=${delay.inMilliseconds}ms');
      _playbackTimer = Timer(delay, () {
        _playCharp();
      });
      return;
    }

    _setUploadStatus(
      '再生予約: 録音開始から${(3 * _assignedNumber!) - 2}秒のため即時再生',
    );
    debugPrint('再生予約: number=$_assignedNumber 即時再生');
    Future<void>(() => _playCharp());
  }

  void _cancelScheduledPlayback() {
    _recordingStartTimer?.cancel();
    _recordingStartTimer = null;
    if (_playbackTimer != null) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      _setUploadStatus('再生予約をキャンセルしました');
    }
    _startRequested = false;
    _audioPlayer.stop();
  }

  Future<void> _playCharp() async {
    try {
      final wasRecordingBeforePlay = await _recorder.isRecording();
      final wasPausedBeforePlay = await _recorder.isPaused();
      debugPrint(
        'charp再生直前: isRecording=$wasRecordingBeforePlay isPaused=$wasPausedBeforePlay assigned=$_assignedNumber',
      );
      await _audioPlayer.stop();
      await _audioPlayer.play(ap.AssetSource('charp.wav'));
      _setUploadStatus('再生開始: charp.wav');
      debugPrint('charp.wav を再生開始');
      Future<void>.delayed(const Duration(milliseconds: 300), () async {
        final isRecordingAfterPlay = await _recorder.isRecording();
        final isPausedAfterPlay = await _recorder.isPaused();
        debugPrint(
          'charp再生後: isRecording=$isRecordingAfterPlay isPaused=$isPausedAfterPlay assigned=$_assignedNumber',
        ); 
        if (_startRequested && isPausedAfterPlay) {
          try {
            await _recorder.resume();
            debugPrint('charp再生後に録音resume実行');
            _appendTimingLog('charp再生後に録音resume');
          } catch (e) {
            debugPrint('charp再生後resume失敗: $e');
            _appendTimingLog('charp再生後resume失敗: $e');
          }
        }
      });
    } catch (e) {
      _setUploadStatus('再生エラー: $e');
      debugPrint('再生エラー: $e');
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