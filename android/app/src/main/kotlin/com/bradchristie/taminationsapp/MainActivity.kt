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
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
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

    //  静音门限(VAD):持续监听模式下,只有达到人声能量的
    //  音频才喂识别器,静音/环境噪音一律喂零。凌晨卧室噪音
    //  曾被持续识别成 "Rollaway",此门限从声学入口根治。
    //  阈值标定:对麦克风讲话约 -10~-25dB,环境噪音通常 <-40dB
    private const val VAD_OPEN_DB = -35.0    //  开门(高于此能量视为有人发声)
    private const val VAD_CLOSE_DB = -42.0   //  关门(滞回下限,防止能量抖动反复开关)
    private const val VAD_HANG_MS = 500L     //  低于关门阈值持续此时长才关门(保留自然句尾)
    private const val VAD_MIN_SPEECH_MS = 200L  //  开门累计不足此时长视为噪声,丢弃其结果
  }

  private var micThread: Thread? = null

  @Volatile
  private var micRunning = false

  private val mainHandler = Handler(Looper.getMainLooper())

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        .setMethodCallHandler { call, result ->
          Log.i(TAG, "chan: ${call.method}")
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
            "dartAlive" -> {
              Log.i(TAG, "probe: dart alive (channel round-trip ok)")
              result.success(true)
            }
            "checkMusicActive" -> {
              val am = getSystemService(AUDIO_SERVICE) as AudioManager
              result.success(am.isMusicActive)
            }
            "startSpeechCapture" -> {
              stopMicMonitor()
              startSpeechCapture(result)
            }
            "stopSpeechCapture" -> { stopSpeechCapture(); result.success(null) }
            "voskInit" -> voskInit(result)
            "voskStart" -> voskStart(call, result)
            "voskStop" -> { voskStop(); result.success(null) }
            "voskFinal" -> voskFinal(result)
            "voskFlush" -> voskFlush(result)
            else -> result.notImplemented()
          }
        }
    Log.i(TAG, "channel ready (taminations/music)")
  }

  override fun onDestroy() {
    stopMicMonitor()
    stopPlaybackWatch()
    voskFeed = false
    stopSpeechCapture()
    super.onDestroy()
  }

  //  向 Dart 侧推送事件:
  //  music_detected / bpm / music_stopped / playback_started / playback_stopped / error
  private fun sendEvent(type: String, value: Int? = null) {
    val engine = flutterEngine ?: return
    val args = HashMap<String, Any>()
    args["type"] = type
    if (value != null) args["value"] = value
    Log.d(TAG, "event -> $type")
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
        //  80Hz 二阶高通(仅静音门限开启时使用):滤除次声/直流/
        //  低频隆隆声,只保留人耳可听频带(16k 采样本身已不含
        //  >8kHz 超声成分)。PTT 采样不滤波,保持与已录记号一致
        var hpX1 = 0.0; var hpX2 = 0.0; var hpY1 = 0.0; var hpY2 = 0.0
        while (speechRunning) {
          val n = record.read(chunk, 0, chunk.size)
          if (n <= 0) break
          //  软件增益 x3(约+9.5dB):过高会削波失真致识别失败
          val gain = 3.0f
          val gate = voskGate
          val bytes = ByteArray(n * 2)
          var sumSq = 0.0
          for (i in 0 until n) {
            val v: Int = if (gate) {
              //  高通后增益
              val x = chunk[i] / 32768.0
              val y = 0.97802838 * x - 1.95605675 * hpX1 +
                  0.97802838 * hpX2 + 1.95561181 * hpY1 - 0.97779590 * hpY2
              hpX2 = hpX1; hpX1 = x; hpY2 = hpY1; hpY1 = y
              (y * 32768.0 * gain).toInt()
            } else {
              (chunk[i] * gain).toInt()
            }
            var vo = v
            if (consonantBoost) {
              //  两分频:低频x1.0(不压——短促元音躯干曾更瘦,
              //  tep取样难) + 高频x2.8(s已听得见,全靠它)
              val x = vo.toDouble()
              consLp += 0.445 * (x - consLp)
              vo = (consLp + 2.8 * (x - consLp)).roundToInt()
            }
            val cl = if (vo > 32767) 32767 else if (vo < -32768) -32768 else vo
            bytes[i * 2] = (cl and 0xff).toByte()
            bytes[i * 2 + 1] = ((cl shr 8) and 0xff).toByte()
            val d = cl / 32768.0
            sumSq += d * d
          }
          //  静音门限(自适应底噪):静音期跟踪底噪,开门=底噪
          //  +12dB,关门=底噪+5dB——固定-42曾在底噪-40的房间
          //  永远关不上闸门,噪音持续进解码器
          if (gate) {
            val chunkMs = n * 1000L / 16000
            val db = if (sumSq > 0) 20 * log10(sqrt(sumSq / n)) else -100.0
            //  噪声抑制加强(用户:冰箱空调房间仍出dive thru):
            //  开门=底噪+20dB(约为喊口令音量的一半),原+12太松
            val openT0 = noiseFloorDb + 8.0 + noiseSuppressRatio * 20.0
            if (db < openT0 - 2.0) {
              noiseFloorDb = 0.9 * noiseFloorDb + 0.1 * db
              if (noiseFloorDb < -60.0) noiseFloorDb = -60.0
              if (noiseFloorDb > -25.0) noiseFloorDb = -25.0
            }
            //  看门狗:闸门开着且db悬在滞回带累计1.5秒=底噪
            //  估低,快速上贴(与Dart分段机同款)
            val dzLow = noiseFloorDb + 5.0
            if (vadOpen && db >= dzLow && db < noiseFloorDb + 12.0) {
              deadZoneMs += 100
              if (deadZoneMs >= 1500) {
                noiseFloorDb = db - 5.0
                if (noiseFloorDb < -60.0) noiseFloorDb = -60.0
                if (noiseFloorDb > -25.0) noiseFloorDb = -25.0
                deadZoneMs = 0
                Log.i(TAG, "vad floor snapped to $noiseFloorDb")
              }
            } else {
              deadZoneMs = 0
            }
            val openT = noiseFloorDb + 8.0 + noiseSuppressRatio * 20.0
            val closeT = noiseFloorDb + (8.0 + noiseSuppressRatio * 20.0) * 0.45
            if (!vadOpen) {
              if (db > openT) {
                vadOpen = true; vadSpeechMs = 0; vadQuietMs = 0
                Log.i(TAG, "vad: OPEN (db=${"%.1f".format(db)})")
              }
            } else {
              vadSpeechMs += chunkMs
              if (db < closeT) {
                vadQuietMs += chunkMs
                if (vadQuietMs >= VAD_HANG_MS) {
                  vadLastUtteranceMs = vadSpeechMs
                  vadOpen = false
                  Log.i(TAG, "vad: CLOSE (utterance=${vadSpeechMs}ms)")
                }
              } else vadQuietMs = 0
            }
          }
          val rec = voskRecognizer
          if (voskFeed && rec != null) {
            val gateClosed = gate && !vadOpen
            val feed: ByteArray = if (gateClosed) ByteArray(n * 2) else bytes

            //  ============ 整段识别模式 ============
            //  闸门开=缓存音频(不实时喂识别器)
            //  闸门关+2秒静音=整段批量识别
            if (wholeUtteranceMode && gate) {
                if (vadOpen) {
                    //  闸门开:缓存真实音频
                    if (!bufferActive) {
                        bufferActive = true
                        speechBuffer.clear()
                        Log.i(TAG, "WU: buffer start")
                    }
                    for (i in 0 until n) {
                        //  从bytes还原short(bytes是处理后的)
                        val lo = bytes[i * 2].toInt() and 0xff
                        val hi = bytes[i * 2 + 1].toInt()
                        speechBuffer.add(((hi shl 8) or lo).toShort())
                    }
                    if (speechBuffer.size > 16000 * 10) {
                        //  超10秒:强制结束(防内存溢出)
                        Log.w(TAG, "WU: buffer overflow, force end")
                        bufferEndAt = System.currentTimeMillis()
                    }
                } else if (bufferActive) {
                    //  闸门关:等待静音确认后批量识别
                    if (bufferEndAt == 0L) {
                        bufferEndAt = System.currentTimeMillis()
                    }
                    val silent = System.currentTimeMillis() - bufferEndAt
                    if (silent >= 2000) {
                        //  静音满2秒:整段识别
                        bufferActive = false
                        bufferEndAt = 0
                        val total = speechBuffer.size
                        if (total > 16000 / 5) {  //  至少0.2秒
                            Log.i(TAG, "WU: recognizing $total samples")
                            val bufBytes = ByteArray(total * 2)
                            for (i in 0 until total) {
                                val sv = speechBuffer[i].toInt()
                                bufBytes[i * 2] = (sv and 0xff).toByte()
                                bufBytes[i * 2 + 1] = ((sv shr 8) and 0xff).toByte()
                            }
                            //  交给识别器整段识别
                            synchronized(voskLock) {
                                val rec = voskRecognizer
                                if (rec != null) {
                                    try {
                                        rec.acceptWaveForm(bufBytes, bufBytes.size)
                                        val json = rec.finalResult
                                        if (json != null) {
                                            mainHandler.post {
                                                sendEvent("vosk_final", json)
                                            }
                                        }
                                    } catch (e: Exception) {
                                        Log.e(TAG, "WU: recognize failed", e)
                                    }
                                }
                            }
                        } else {
                            Log.i(TAG, "WU: too short ($total), discard")
                        }
                        speechBuffer.clear()
                    }
                }
                //  整段模式:跳过实时喂识别器
                sendBytes("speech_audio", ByteArray(0))
                continue
            }
            //  ============ 整段模式结束,以下为原有实时识别 ============
            //  离线识别:音频直接喂 Vosk,结果推给 Dart,不发音频流
            var finalJson: String? = null
            var partialJson: String? = null
            synchronized(voskLock) {
              try {
                if (rec.acceptWaveForm(feed, feed.size))
                  finalJson = rec.result
                else
                  partialJson = rec.partialResult
              } catch (e: Exception) {
                Log.e(TAG, "vosk: acceptWaveForm failed", e)
                voskFeed = false
              }
            }
            if (finalJson != null) {
              //  太短的"话音"=噪声误开门,其结果丢弃
              val speechMs = if (vadOpen) vadSpeechMs else vadLastUtteranceMs
              if (!gate || speechMs >= VAD_MIN_SPEECH_MS)
                sendEvent("vosk_final", finalJson)
              else
                Log.i(TAG, "vad: final dropped (speech=${speechMs}ms)")
            } else if (partialJson != null && !gateClosed) {
              //  静音期(喂零)的空 partial 不发送
              sendEvent("vosk_partial", partialJson)
            }
          } else {
            //  云端引擎:音频推给 Dart 转发
            sendBytes("speech_audio", bytes)
          }
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

  // ------------------------------------------------ Vosk 离线语音识别
  //  模型打包在 assets/vosk-model-en-us(英文小模型,约 40MB),
  //  首次使用时解包到内部存储再加载,之后直接复用本地文件。
  //  识别在语音采集线程内完成(音频不出原生层),结果以
  //  vosk_final / vosk_partial 事件推给 Dart;云端引擎
  //  (讯飞)才需要把音频流转发到 Dart。

  private var voskModel: Model? = null

  //  识别器按会话创建;引用保留到下次会话替换,避免
  //  使用中被释放(采集线程与主线程经 voskLock 互斥访问)
  @Volatile
  private var voskRecognizer: Recognizer? = null

  @Volatile
  private var voskFeed = false

  //  本会话是否启用静音门限(持续监听开,PTT采样关——按下即刻意语音,
  //  且保持采样音频与已录记号声学一致)
  @Volatile
  private var voskGate = false

  //  静音门限状态(采集线程更新,voskStart 重置)
  @Volatile private var vadOpen = false
  @Volatile private var vadSpeechMs = 0L
  @Volatile private var vadQuietMs = 0L
  @Volatile private var vadLastUtteranceMs = 0L
  //  自适应底噪(dB):静音期慢速跟踪
  @Volatile private var noiseFloorDb = -45.0
  //  辅音助听器开关+分频器状态(一阶低通1500Hz@16k)
  @Volatile private var consonantBoost = false
  @Volatile private var noiseSuppressRatio = 0.4

  //  ============ 整段识别模式(用户设计:闸门控制边界) ============
  //  闸门开=开始缓存音频,闸门关+静音=结束缓存,
  //  整段一次性交给全新识别器(绕过vosk断句器碎片化)
  private var speechBuffer = ArrayList<Short>(16000 * 10)  // 最多10秒
  @Volatile private var bufferActive = false
  @Volatile private var wholeUtteranceMode = false
  private var bufferEndAt = 0L
  private var consLp = 0.0
  private var deadZoneMs = 0

  //  加载去重:Dart 侧可能有多个提供者实例并发请求初始化
  @Volatile
  private var voskLoading = false

  private val voskLock = Any()

  private fun voskInit(result: MethodChannel.Result) {
    if (voskModel != null) { result.success(true); return }
    val shouldLoad = synchronized(voskLock) {
      when {
        voskModel != null -> false       //  已就绪(锁内复查)
        voskLoading -> null              //  已有加载在进行
        else -> { voskLoading = true; true }
      }
    }
    when (shouldLoad) {
      true -> thread(name = "vosk-init") {
        try {
          val dir = File(filesDir, "vosk-model-en-us")
          //  模型版本标记:换装新模型(0.22-lgraph,204MB)后
          //  版本号提升,旧缓存自动作废重解
          val marker = File(filesDir, "vosk-model-en-us.ready2")
          if (!marker.exists()) {
            dir.deleteRecursively()
            File(filesDir, "vosk-model-en-us.ready").delete()
            copyAssets("vosk-model-en-us", dir)
            marker.createNewFile()
            Log.i(TAG, "vosk: model unpacked to ${dir.absolutePath}")
          }
          val model = Model(dir.absolutePath)
          synchronized(voskLock) { voskModel = model }
          Log.i(TAG, "vosk: model loaded")
          mainHandler.post { result.success(true) }
        } catch (e: Exception) {
          Log.e(TAG, "vosk: init failed", e)
          mainHandler.post { result.error("vosk_init", e.message, null) }
        } finally {
          voskLoading = false
        }
      }
      false -> result.success(true)
      null -> {
        //  等待进行中的加载完成后答复(最多 60 秒)
        thread(name = "vosk-init-wait") {
          var waited = 0
          while (voskModel == null && waited < 60000) {
            try { Thread.sleep(500) } catch (_: InterruptedException) {}
            waited += 500
          }
          mainHandler.post {
            if (voskModel != null) result.success(true)
            else result.error("vosk_init", "model load failed", null)
          }
        }
      }
    }
  }

  //  递归解包 assets 目录到本地文件(文件与空目录靠 list 区分)
  private fun copyAssets(path: String, out: File) {
    val children = assets.list(path) ?: emptyArray()
    if (children.isEmpty()) {
      out.parentFile?.mkdirs()
      out.outputStream().use { assets.open(path).copyTo(it) }
    } else {
      out.mkdirs()
      for (name in children) copyAssets("$path/$name", File(out, name))
    }
  }

  private fun voskStart(call: MethodCall, result: MethodChannel.Result) {
    val model = voskModel
    if (model == null) {
      result.error("vosk_no_model", "model not initialized", null)
      return
    }
    //  口令词表(JSON 单词数组):限定解码词汇,提高口音容错
    val grammar = call.argument<String>("grammar")
    //  静音门限开关(持续监听传 true,PTT 采样传 false)
    val gate = call.argument<Boolean>("gate") ?: false
    //  辅音助听器(用户设想:开头辅音赋予更高决策权,减少
    //  元音确定权):两分频,高频段(辅音)提升,低频段(元音+
    //  冰箱嗡嗡)略压——喂识别器之前生效,录音喊令同条件
    val consonant = call.argument<Boolean>("consonant") ?: false
    synchronized(voskLock) {
      try {
        val rec = if (grammar != null && grammar.length > 2)
            Recognizer(model, 16000f, grammar)
        else
            Recognizer(model, 16000f)
        //  一次给出多个候选:由 Dart 侧挑选与表内口令最接近的
        try { rec.setMaxAlternatives(15) } catch (_: Exception) {}
        voskRecognizer = rec
        voskFeed = true
        voskGate = gate
        consonantBoost = consonant
        wholeUtteranceMode = (call.argument<Boolean>("wholeUtterance") ?: false)
        noiseSuppressRatio = (call.argument<Double>("noiseSuppress") ?: 0.4)
        vadOpen = false; vadSpeechMs = 0; vadQuietMs = 0; vadLastUtteranceMs = 0
        if (grammar != null) Log.i(TAG, "vosk: grammar set (${grammar.length} bytes)")
        Log.i(TAG, "vosk: gate=${if (gate) "on" else "off"}")
      } catch (e: Exception) {
        Log.e(TAG, "vosk: start failed", e)
        result.error("vosk_start", e.message, null)
        return
      }
    }
    Log.i(TAG, "vosk: recognition started")
    //  复用语音采集线程(16k),采集循环会直接喂识别器
    if (speechRunning) result.success(null) else startSpeechCapture(result)
  }

  //  停止识别,不回收剩余内容(取消/关闭场景)
  private fun voskStop() {
    synchronized(voskLock) { voskFeed = false }
    stopSpeechCapture()
  }

  //  停止识别并把剩余语音收尾成最终结果返回(采样抬起场景)。
  //  先喂 0.6 秒静音:端点检测需要静音尾帧才能把最后一个词
  //  完整收尾,否则多词口令的尾部会被截掉
  private fun voskFinal(result: MethodChannel.Result) {
    var json: String? = null
    synchronized(voskLock) {
      val rec = voskRecognizer
      if (rec != null) {
        try {
          val silence = ByteArray(16000 * 6 / 10)   //  0.6s @16kHz
          rec.acceptWaveForm(silence, silence.size)
          json = rec.finalResult
        } catch (e: Exception) {
          Log.e(TAG, "vosk: final failed", e)
        }
      }
      voskFeed = false
    }
    stopSpeechCapture()
    result.success(json)
  }

  //  冲刷:喂静音取finalResult但**不停会话**(麦克风命令
  //  完成时用——与圆钮松手冲刷同工,流式final与冲刷结果
  //  可能不同:extend流式"the",冲刷后"extend")
  private fun voskFlush(result: MethodChannel.Result) {
    var json: String? = null
    synchronized(voskLock) {
      val rec = voskRecognizer
      if (rec != null) {
        try {
          val silence = ByteArray(16000 * 6 / 10)   //  0.6s @16kHz
          rec.acceptWaveForm(silence, silence.size)
          json = rec.finalResult
        } catch (e: Exception) {
          Log.e(TAG, "vosk: flush failed", e)
        }
      }
    }
    result.success(json)
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

  //  文本事件(Vosk 识别结果 JSON 等)
  private fun sendEvent(type: String, text: String) {
    val engine = flutterEngine ?: return
    val args = HashMap<String, Any>()
    args["type"] = type
    args["text"] = text
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
