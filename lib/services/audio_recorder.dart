import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Cross-platform PTT capture. start() opens the OS mic and buffers raw
/// PCM16 chunks in memory; stop() returns the buffered audio wrapped in
/// a WAV header (no file I/O, no path_provider, no kIsWeb branching).
///
/// PCM16 mono @ 16kHz = 32 KB/sec — a 60-second hold (server's hard cap)
/// is ~1.9 MB, comfortably under the 10 MB body limit. We give up
/// bandwidth for simplicity; an Opus/AAC path can land later if size
/// becomes a real cost.
///
/// Format string for the STT endpoint is always 'wav' from this service.
class AudioRecorderService {
  AudioRecorderService({AudioRecorder? recorder})
      : _r = recorder ?? AudioRecorder();

  final AudioRecorder _r;

  static const int _sampleRate = 16000;
  static const int _channels = 1;
  static const RecordConfig _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: _sampleRate,
    numChannels: _channels,
  );

  StreamSubscription<Uint8List>? _sub;
  final List<int> _buffer = [];
  bool _recording = false;

  /// Format string to send alongside the audio in the /speech/stt/transcribe
  /// multipart body.
  String get format => 'wav';

  /// Returns true if recording started successfully, false on permission
  /// denial. Throws on platform errors (mic in use by another app, etc).
  Future<bool> start() async {
    if (_recording) return true;
    if (!await _r.hasPermission()) return false;
    _buffer.clear();
    final stream = await _r.startStream(_config);
    _sub = stream.listen(_buffer.addAll);
    _recording = true;
    return true;
  }

  /// Stops recording and returns the captured audio as a WAV blob, or
  /// null if nothing was buffered (zero-length press, permission revoked
  /// mid-hold, etc).
  Future<Uint8List?> stop() async {
    if (!_recording) return null;
    _recording = false;
    try {
      await _r.stop();
    } catch (_) {
      // recorder may already be in a stopped state; ignore.
    }
    await _sub?.cancel();
    _sub = null;
    if (_buffer.isEmpty) return null;
    final pcm = Uint8List.fromList(_buffer);
    _buffer.clear();
    return _wrapWav(pcm);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _r.dispose();
  }

  /// Wraps raw PCM16 little-endian bytes in a minimal 44-byte WAV/RIFF
  /// header. Channels + sample rate match the recorder's [_config].
  static Uint8List _wrapWav(Uint8List pcm) {
    const bitsPerSample = 16;
    final byteRate = _sampleRate * _channels * (bitsPerSample ~/ 8);
    final blockAlign = _channels * (bitsPerSample ~/ 8);
    final dataLen = pcm.length;
    final chunkSize = 36 + dataLen;

    final out = Uint8List(44 + dataLen);
    final view = ByteData.view(out.buffer);

    // 'RIFF'
    view.setUint8(0, 0x52);
    view.setUint8(1, 0x49);
    view.setUint8(2, 0x46);
    view.setUint8(3, 0x46);
    view.setUint32(4, chunkSize, Endian.little);
    // 'WAVE'
    view.setUint8(8, 0x57);
    view.setUint8(9, 0x41);
    view.setUint8(10, 0x56);
    view.setUint8(11, 0x45);
    // 'fmt '
    view.setUint8(12, 0x66);
    view.setUint8(13, 0x6d);
    view.setUint8(14, 0x74);
    view.setUint8(15, 0x20);
    view.setUint32(16, 16, Endian.little); // subchunk1 size
    view.setUint16(20, 1, Endian.little); // PCM format
    view.setUint16(22, _channels, Endian.little);
    view.setUint32(24, _sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);
    // 'data'
    view.setUint8(36, 0x64);
    view.setUint8(37, 0x61);
    view.setUint8(38, 0x74);
    view.setUint8(39, 0x61);
    view.setUint32(40, dataLen, Endian.little);

    out.setRange(44, 44 + dataLen, pcm);
    return out;
  }
}
