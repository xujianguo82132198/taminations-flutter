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
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {

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
            "startMicMonitor" -> startMicMonitor(result)
            "stopMicMonitor" -> { stopMicMonitor(); result.success(null) }
            "startPlaybackWatch" -> startPlaybackWatch(result)
            "stopPlaybackWatch" -> { stopPlaybackWatch(); result.success(null) }
            "sendEnterKey" -> { sendEnterKey(); result.success(null) }
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
    if (minBuf <= 0) { sendEvent("error"); result.error("no_mic", "AudioRecord unavailable", null); return }
    val record = try {
      AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate,
          AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
          maxOf(minBuf, sampleRate * 2))  //  2 秒缓冲
    } catch (e: Exception) {
      sendEvent("error"); result.error("no_mic", e.message, null); return
    }
    if (record.state != AudioRecord.STATE_INITIALIZED) {
      record.release(); sendEvent("error")
      result.error("no_mic", "AudioRecord init failed", null); return
    }
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
