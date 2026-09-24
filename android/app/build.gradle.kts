plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.chaquo.python")
}

// Keep in sync with ios/scripts/bootstrap.sh
val ytdlpVersion = "2026.8.19"
val ejsVersion = "0.8.0"

android {
    namespace = "com.natan.ytdlp"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.natan.ytdlp"
        minSdk = 29          // MediaStore RELATIVE_PATH (saving to Movies/ and Music/)
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            // R8 drops the unused parts of Compose and the icon set (~45 MB of code)
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Sideload-friendly: signed with the debug key unless you configure your own
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures { compose = true }

    // One APK per CPU type (Chaquopy needs ndk.abiFilters, which rules out ABI splits):
    // phones use arm64; x86 is for Intel-based emulators
    flavorDimensions += "abi"
    productFlavors {
        create("arm64") {
            dimension = "abi"
            ndk { abiFilters += "arm64-v8a" }
        }
        create("x86") {
            dimension = "abi"
            ndk { abiFilters += "x86_64" }
        }
    }

    // Compressed native libraries: a smaller APK to download and sideload
    packaging { jniLibs { useLegacyPackaging = true } }

    externalNativeBuild {
        cmake { path = file("src/main/cpp/CMakeLists.txt") }
    }
    ndkVersion = "27.2.12479018"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

chaquopy {
    defaultConfig {
        version = "3.14"
        pip {
            install("yt-dlp==$ytdlpVersion")
            install("yt-dlp-ejs==$ejsVersion")
            install("certifi")
        }
    }
    sourceSets {
        getByName("main") {
            // The bridge shared with the iOS app
            srcDir("../../shared/pybridge")
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.javascriptengine:javascriptengine:1.1.1")
    implementation("androidx.concurrent:concurrent-futures-ktx:1.3.0")
    implementation("io.coil-kt.coil3:coil-compose:3.6.3")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.3")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
}
