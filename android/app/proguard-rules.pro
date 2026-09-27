# Called from Python by name (app/src/main/python/_host.py)
-keep class app.squirrel.python.JsEngine { public static *** run(java.lang.String); }

# JNI entry points in cpp/jni_remux.c: Java_app_squirrel_Remuxer_remux and _convertToMp3
-keep class app.squirrel.Remuxer { native <methods>; }
