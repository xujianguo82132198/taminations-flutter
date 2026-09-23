package com.bradchristie.taminationsapp

import android.app.Instrumentation
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {

  //  自动化测试通道:以
  //  am start ... --ez tam_auto_music true
  //  启动时,Flutter 就绪后发送 auto_music 事件,
  //  Dart 侧等同按下"音乐节拍"按钮(免按键远程自测)
  private fun maybeAutoTrigger(intent: android.content.Intent?) {
    if (intent?.getBooleanExtra("tam_auto_music", false) == true) {
      mainHandler.postDelayed({
        Log.i(TAG, "auto trigger: auto_music")
        sendEvent("auto_music")
      }, 2000)
    }
    if (intent?.getBooleanExtra("tam_auto_voice", false) == true) {
      //  自动语音测试:采样 8 秒(配合外部播音验证识别链路)
      mainHandler.postDelayed({
        Log.i(TAG, "auto trigger: auto_voice")
        sendEvent("auto_voice")
      }, 2000)
      mainHandler.postDelayed({
        Log.i(TAG, "auto trigger: auto_voice_end")
        sendEvent("auto_voice_end")
      }, 10000)
    }
  }

  override fun onCreate(savedInstanceState: android.os.Bundle?) {
    super.onCreate(savedInstanceState)
    maybeAutoTrigger(intent)
  }

  override fun onNewIntent(intent: android.content.Intent) {
    super.onNewIntent(intent)
    maybeAutoTrigger(intent)
  }

  companion object {
    private const val TAG = "TamMusic"
    private const val CHANNEL = "taminations/music"

    //  音乐开始判定:连续 5 个 100ms 窗(0.5 秒)RMS 高于此值
    //  (高于一般环境噪声 ~0.01,低于正常外放音乐 ~0.05+)
    private const val START_RMS = 0.03

    //  音乐停止判定:连续 20 个 100ms 窗(2 秒)RMS 低于此值
    private const val STOP_RMS = 0.015

    //  节拍分析窗口时长(更长窗口对真实音乐更稳)
    private const val DETECT_MS = 12000
  }

  private var micThread: Thread? = null

  @Volatile
  private var micRunning = false

  private val mainHandler = Handler(Looper.getMainLooper())

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        .setMethodCallHandler { call, result ->
          when (call.method) {
            "startMicMonitor" -> {
              //  互斥:先停语音采集,避免双 AudioRecord 抢占失败
              stopSpeechCapture()
              startMicMonitor(result)
            }
            "stopMicMonitor" -> { stopMicMonitor(); result.success(null) }
            "startPlaybackWatch" -> startPlaybackWatch(result)
            "stopPlaybackWatch" -> { stopPlaybackWatch(); result.success(null) }
            "sendEnterKey" -> { sendEnterKey(); result.success(null) }
            "startSpeechCapture" -> {
              stopMicMonitor()
              startSpeechCapture(result)
            }
            "stopSpeechCapture" -> { stopSpeechCapture(); result.success(null) }
            else -> result.notImplemented()
          }
        }
  }

  override fun onDestroy() {
    stopMicMonitor()
    stopPlaybackWatch()
    super.onDestroy()
  }

  //  向 Dart 侧推送事件:
  //  music_detected / bpm / music_stopped / playback_started / playback_stopped / error
  private fun sendEvent(type: String, value: Int? = null) {
    val engine = flutterEngine ?: return
    val args = HashMap<String, Any>()
    args["type"] = type
    if (value != null) args["value"] = value
    mainHandler.post {
      MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
          .invokeMethod("event", args)
    }
  }

  // ---------------------------------------------------------------- 麦克风监测

  @Suppress("MissingPermission")  //  应用已因语音识别持有 RECORD_AUDIO 权限
  private fun startMicMonitor(result: MethodChannel.Result) {
    if (micRunning) { result.success(null); return }
    val sampleRate = 44100
    val minBuf = AudioRecord.getMinBufferSize(sampleRate,
        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
    if (minBuf <= 0) {
      Log.e(TAG, "mic monitor: minBuf=$minBuf unavailable")
      sendEvent("error"); result.error("no_mic", "AudioRecord unavailable", null); return
    }
    val record = try {
      AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate,
          AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
          maxOf(minBuf, sampleRate * 2))  //  2 秒缓冲
    } catch (e: Exception) {
      Log.e(TAG, "mic monitor: AudioRecord ctor failed", e)
      sendEvent("error"); result.error("no_mic", e.message, null); return
    }
    if (record.state != AudioRecord.STATE_INITIALIZED) {
      Log.e(TAG, "mic monitor: init failed state=${record.state}")
      record.release(); sendEvent("error")
      result.error("no_mic", "AudioRecord init failed", null); return
    }
    Log.i(TAG, "mic monitor: started 44.1k")
    micRunning = true
    micThread = thread(name = "taminations-music-monitor") {
      try {
        record.startRecording()
        val chunk = ShortArray(sampleRate / 10)  //  100ms
        var loudWindows = 0
        var quietWindows = 0
        var phase = "waiting"  //  waiting -> detecting -> monitoring
        var detectSamples = 0
        val analysis = ArrayList<ShortArray>()
        while (micRunning) {
          val n = record.read(chunk, 0, chunk.size)
          if (n <= 0) break
          val rms = rmsOf(chunk, n)
          Log.d(TAG, "phase=$phase rms=$rms")
          when (phase) {
            "waiting" -> {
              if (rms > START_RMS) loudWindows++ else loudWindows = 0
              if (loudWindows >= 5) {
                phase = "detecting"
                analysis.clear(); detectSamples = 0; quietWindows = 0
                sendEvent("music_detected")
              }
            }
            "detecting" -> {
              analysis.add(chunk.copyOf(n))
              detectSamples += n
              if (detectSamples >= sampleRate * DETECT_MS / 1000) {
                val bpm = analyzeBpm(analysis, sampleRate)
                if (bpm != null) {
                  sendEvent("bpm", bpm)
                  phase = "monitoring"
                  quietWindows = 0
                } else {
                  //  节拍不明显(比如纯人声/噪声),换下一个窗口继续尝试
                  analysis.clear(); detectSamples = 0
                }
              }
            }
            "monitoring" -> {
              if (rms < STOP_RMS) quietWindows++ else quietWindows = 0
              if (quietWindows >= 20) {
                sendEvent("music_stopped")
                phase = "waiting"
                loudWindows = 0
              }
            }
          }
        }
      } catch (e: Exception) {
        Log.e(TAG, "mic monitor failed", e)
        sendEvent("error")
      } finally {
        try { record.stop() } catch (_: Exception) {}
        record.release()
      }
    }
    result.success(null)
  }

  private fun stopMicMonitor() {
    micRunning = false
    micThread?.let { t ->
      t.interrupt()
      micThread = null
    }
  }

  private fun rmsOf(buf: ShortArray, n: Int): Double {
    var sum = 0.0
    for (i in 0 until n) {
      val v = buf[i] / 32768.0
      sum += v * v
    }
    return sqrt(sum / max(1, n))
  }

  //  节拍检测:频谱通量(spectral flux)onset 包络 + 归一化自相关。
  //  频谱通量对真实音乐(贝斯/和声/混响)远比能量差分稳,
  //  自相关对伪峰/漏检有较好容忍,再加倍频校正与常见节拍区间偏好。
  private fun analyzeBpm(chunks: List<ShortArray>, sampleRate: Int): Int? {
    val total = chunks.sumOf { it.size }
    if (total < sampleRate * 6) return null  //  至少 6 秒数据
    val buf = ShortArray(total)
    var pos = 0
    for (c in chunks) { c.copyInto(buf, pos); pos += c.size }

    //  降采样到 ~22050Hz,降低 FFT 开销
    val dsRate = sampleRate / 2
    val dsLen = total / 2
    val ds = FloatArray(dsLen)
    for (i in 0 until dsLen)
      ds[i] = ((buf[i * 2] + buf[i * 2 + 1]) / 65536.0).toFloat()

    //  分帧:512 点窗(23ms),256 点 hop(11.6ms),Hann 加窗
    val fftSize = 512
    val hopSize = 256
    val frames = (dsLen - fftSize) / hopSize
    if (frames < 300) return null
    val window = FloatArray(fftSize) { i ->
      (0.5 * (1.0 - kotlin.math.cos(2.0 * Math.PI * i / (fftSize - 1)))).toFloat()
    }
    val fft = Fft(fftSize)
    val bins = fftSize / 2
    val flux = DoubleArray(frames)
    var prevMag = DoubleArray(bins)
    val re = FloatArray(fftSize)
    val im = FloatArray(fftSize)
    for (f in 0 until frames) {
      val off = f * hopSize
      for (i in 0 until fftSize)
        re[i] = ds[off + i] * window[i]
      im.fill(0f)
      fft.transform(re, im)
      var sum = 0.0
      for (b in 0 until bins) {
        val mag = kotlin.math.sqrt((re[b] * re[b] + im[b] * im[b]).toDouble())
        val d = mag - prevMag[b]
        if (d > 0) sum += d
        prevMag[b] = mag
      }
      flux[f] = sum
    }
    //  包络归一化 + 去均值 + 3 帧滑动平滑(突出 60-180BPM 的节拍带)
    var maxF = 0.0
    for (v in flux) maxF = max(maxF, v)
    if (maxF < 1e-9) return null
    val onset = DoubleArray(frames)
    for (i in flux.indices)
      flux[i] /= maxF
    for (i in 2 until frames)
      onset[i] = (flux[i - 2] + flux[i - 1] + flux[i]) / 3.0
    val mean = onset.average()
    var energy = 0.0
    for (i in onset.indices) {
      onset[i] -= mean
      energy += onset[i] * onset[i]
    }
    if (energy < 1e-9) return null

    val frameMs = hopSize * 1000.0 / dsRate  //  ~11.61ms

    fun autoCorr(lag: Int): Double {
      var sum = 0.0
      val n = frames - lag
      for (i in 0 until n)
        sum += onset[i] * onset[i + lag]
      return sum / n
    }
    //  在自相关滞后网格(整帧,~11.6ms)上直接寻峰:
    //  BPM 60..180 对应周期 1000..333ms,即 lag 86..29
    val lagMin = (60000.0 / (180 * frameMs)).roundToInt().coerceAtLeast(10)
    val lagMax = (60000.0 / (60 * frameMs)).roundToInt()
      .coerceAtMost(frames / 2 - 1)
    var bestLag = -1
    var bestScore = 0.0
    for (lag in lagMin..lagMax) {
      val r = autoCorr(lag)
      if (r > bestScore) { bestScore = r; bestLag = lag }
    }
    if (bestLag < 0 || bestScore <= 0) return null
    //  抛物线插值把峰位细化到亚帧精度(±0.3 BPM 级),
    //  消除整帧网格的量化误差(如 125 被测成 122)
    val rm = autoCorr(bestLag - 1)
    val r0 = bestScore
    val rp = autoCorr(bestLag + 1)
    val denom = rm - 2 * r0 + rp
    val delta = if (denom < 0)
        (0.5 * (rm - rp) / denom).coerceIn(-1.0, 1.0) else 0.0
    val refinedLag = bestLag + delta
    val refinedBpm = 60000.0 / (refinedLag * frameMs)

    //  倍频校正:1/2、2、2/3、3/2 倍候选中相关不低于 0.8 倍峰值的,
    //  优先落在 100-160 的常见舞蹈音乐节拍区间
    fun corrAt(bpmVal: Double): Double {
      val lag = (60000.0 / (bpmVal * frameMs)).roundToInt()
      if (lag < lagMin - 2 || lag > lagMax + 2) return 0.0
      return autoCorr(lag)
    }
    val candidates = mutableListOf(refinedBpm)
    for (mul in listOf(0.5, 2.0, 2.0 / 3.0, 1.5)) {
      val c = refinedBpm * mul
      if (c in 60.0..180.0 && corrAt(c) > bestScore * 0.8)
        candidates.add(c)
    }
    val chosen = candidates.minByOrNull {
      if (it in 100.0..160.0) kotlin.math.abs(it - 128.0)
      else 1000.0 + kotlin.math.abs(it - 128.0)
    } ?: refinedBpm
    val result = chosen.roundToInt()
    Log.d(TAG, "bpm analysis: lag=$bestLag refined=${refinedBpm.roundToInt()} "
        + "chosen=$result score=$bestScore")
    return result
  }

  //  紧凑迭代式 radix-2 FFT
  private class Fft(val n: Int) {
    private val levels = Integer.numberOfTrailingZeros(n)
    private val cosTable = FloatArray(n / 2) {
      kotlin.math.cos(2.0 * Math.PI * it / n).toFloat()
    }
    private val sinTable = FloatArray(n / 2) {
      kotlin.math.sin(2.0 * Math.PI * it / n).toFloat()
    }

    fun transform(re: FloatArray, im: FloatArray) {
      //  位反转重排
      for (i in 0 until n) {
        val j = Integer.reverse(i) ushr (32 - levels)
        if (j > i) {
          var t = re[i]; re[i] = re[j]; re[j] = t
          t = im[i]; im[i] = im[j]; im[j] = t
        }
      }
      //  蝶形
      var size = 2
      while (size <= n) {
        val half = size / 2
        val tablestep = n / size
        var i = 0
        while (i < n) {
          var k = 0
          for (j in i until i + half) {
            val l = j + half
            val tpre = re[l] * cosTable[k] + im[l] * sinTable[k]
            val tpim = -re[l] * sinTable[k] + im[l] * cosTable[k]
            re[l] = re[j] - tpre
            im[l] = im[j] - tpim
            re[j] += tpre
            im[j] += tpim
            k += tablestep
          }
          i += size
        }
        size *= 2
      }
    }
  }

  // ------------------------------------------------------- 同机音乐播放监测

  //  语音识别期间麦克风被占用,改用 AudioManager.isMusicActive 轮询
  //  监测音乐停止/重播。仅适用于音乐在本机播放的场景
  //  (本应用自身不播放音频,不会误报)。
  private var playbackPolling = false
  private var lastMusicActive = false
  private val playbackHandler = Handler(Looper.getMainLooper())

  private fun startPlaybackWatch(result: MethodChannel.Result) {
    if (playbackPolling) { result.success(null); return }
    val am = getSystemService(AUDIO_SERVICE) as AudioManager
    playbackPolling = true
    lastMusicActive = am.isMusicActive
    //  立即上报当前状态,然后每 500ms 轮询,状态变化时通知 Dart
    sendEvent(if (lastMusicActive) "playback_started" else "playback_stopped")
    val poller = object : Runnable {
      override fun run() {
        if (!playbackPolling) return
        val active = am.isMusicActive
        if (active != lastMusicActive) {
          lastMusicActive = active
          sendEvent(if (active) "playback_started" else "playback_stopped")
        }
        playbackHandler.postDelayed(this, 500)
      }
    }
    playbackHandler.post(poller)
    result.success(null)
  }

  private fun stopPlaybackWatch() {
    playbackPolling = false
    playbackHandler.removeCallbacksAndMessages(null)
  }

  // ------------------------------------------------ 语音采集(供讯飞识别)
  //  record 插件在本机采集为静音,而原生 AudioRecord(音乐监测
  //  同款路径)采集正常。这里直接用原生采集,重采样到 16k 后
  //  推给 Dart 侧喂给讯飞,并周期上报振幅(dB)。
  private var speechThread: Thread? = null

  @Volatile
  private var speechRunning = false

  @Suppress("MissingPermission")
  private fun makeRecord(source: Int, sampleRate: Int,
      minBuf: Int): AudioRecord? = try {
    val r = AudioRecord(source, sampleRate,
        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        maxOf(minBuf, sampleRate * 2))
    if (r.state == AudioRecord.STATE_INITIALIZED) r else {
      r.release(); null
    }
  } catch (e: Exception) { null }

  @Suppress("MissingPermission")
  private fun startSpeechCapture(result: MethodChannel.Result) {
    if (speechRunning) { result.success(null); return }
    //  直接以 16kHz 采集(语音识别标准采样率,设备原生支持)。
    //  不做 44.1k 重采样——线性插值无抗混叠低通,高频折叠会
    //  严重劣化识别准确率
    val sampleRate = 16000
    val minBuf = AudioRecord.getMinBufferSize(sampleRate,
        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
    if (minBuf <= 0) { result.error("no_mic", "AudioRecord unavailable", null); return }
    //  VOICE_RECOGNITION 源:为语音识别优化,多数设备自带
    //  增益与降噪;部分设备若不可用则退回 MIC
    var source = MediaRecorder.AudioSource.VOICE_RECOGNITION
    var record = makeRecord(source, sampleRate, minBuf)
    if (record == null) {
      source = MediaRecorder.AudioSource.MIC
      record = makeRecord(source, sampleRate, minBuf)
    }
    if (record == null) {
      result.error("no_mic", "AudioRecord init failed", null); return
    }
    if (record.state != AudioRecord.STATE_INITIALIZED) {
      record.release(); result.error("no_mic", "init failed", null); return
    }
    speechRunning = true
    speechThread = thread(name = "taminations-speech-capture") {
      try {
        record.startRecording()
        //  每块 1280 样本 = 80ms = 2560 字节
        val chunk = ShortArray(1280)
        var ampFrames = 0
        var ampSumSq = 0.0
        var ampLastAt = System.currentTimeMillis()
        while (speechRunning) {
          val n = record.read(chunk, 0, chunk.size)
          if (n <= 0) break
          //  软件增益 x6(约+15dB):部分设备采集增益过低,
          //  讯飞听不清;放大并防截幅
          val gain = 6.0f
          val bytes = ByteArray(n * 2)
          var sumSq = 0.0
          for (i in 0 until n) {
            var v = (chunk[i] * gain).toInt()
            if (v > 32767) v = 32767 else if (v < -32768) v = -32768
            bytes[i * 2] = (v and 0xff).toByte()
            bytes[i * 2 + 1] = ((v shr 8) and 0xff).toByte()
            val d = v / 32768.0
            sumSq += d * d
          }
          sendBytes("speech_audio", bytes)
          ampSumSq += sumSq
          ampFrames += n
          val now = System.currentTimeMillis()
          if (now - ampLastAt >= 100 && ampFrames > 0) {
            val rms = sqrt(ampSumSq / ampFrames)
            val db = if (rms > 0) 20 * log10(rms) else -100.0
            sendEvent("speech_amplitude", db)
            ampFrames = 0; ampSumSq = 0.0; ampLastAt = now
          }
        }
      } catch (e: Exception) {
        Log.e(TAG, "speech capture failed", e)
        sendEvent("speech_error")
      } finally {
        try { record.stop() } catch (_: Exception) {}
        record.release()
      }
    }
    result.success(null)
  }

  private fun stopSpeechCapture() {
    speechRunning = false
    speechThread?.interrupt()
    speechThread = null
  }

  //  Double 值事件(振幅等)
  private fun sendEvent(type: String, value: Double) {
    val engine = flutterEngine ?: return
    val args = HashMap<String, Any>()
    args["type"] = type
    args["value"] = value
    mainHandler.post {
      MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
          .invokeMethod("event", args)
    }
  }

  private fun sendBytes(type: String, data: ByteArray) {
    val engine = flutterEngine ?: return
    val args = HashMap<String, Any>()
    args["type"] = type
    args["data"] = data
    mainHandler.post {
      MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
          .invokeMethod("event", args)
    }
  }

  //  向本应用注入一个回车键事件(语音识别输出完成后发送,
  //  与手动键入后按回车的行为保持一致)
  private fun sendEnterKey() {
    try {
      val inst = Instrumentation()
      inst.sendKeyDownUpSync(KeyEvent.KEYCODE_ENTER)
      Log.d(TAG, "enter key sent")
    } catch (e: Exception) {
      //  部分系统禁止应用注入按键事件,忽略即可
      Log.e(TAG, "sendEnterKey failed", e)
    }
  }

}
