# Called from Python by name (app/src/main/python/_host.py)
-keep class app.squirrel.python.JsEngine { public static *** run(java.lang.String); }

# JNI entry point in cpp/jni_remux.c: Java_app_squirrel_Remuxer_remux
-keep class app.squirrel.Remuxer { native <methods>; }
