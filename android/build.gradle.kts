plugins {
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.4.20" apply false
    // Chaquopy 17 supports AGP up to 9.2 and Python 3.10-3.14
    id("com.chaquo.python") version "17.0.0" apply false
}
