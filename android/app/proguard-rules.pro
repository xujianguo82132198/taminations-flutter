# Vosk 离线识别依赖 JNA:其 native 代码按名字访问
# com.sun.jna.Pointer 的字段,R8 混淆/收缩会破坏对等字段
# 查找(UnsatisfiedLinkError: Can't obtain peer field ID),
# 必须整体保留 JNA 与 Vosk 的类/成员
-keep class com.sun.jna.** { *; }
-keepclassmembers class com.sun.jna.** { *; }
-dontwarn com.sun.jna.**

-keep class org.vosk.** { *; }
-keepclassmembers class org.vosk.** { *; }
-dontwarn org.vosk.**
