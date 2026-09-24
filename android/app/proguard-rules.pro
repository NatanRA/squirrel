# Called from Python by name (app/src/main/python/_host.py)
-keep class com.natan.ytdlp.python.JsEngine { public static *** run(java.lang.String); }

# JNI entry point in cpp/jni_remux.c: Java_com_natan_ytdlp_Remuxer_remux
-keep class com.natan.ytdlp.Remuxer { native <methods>; }
