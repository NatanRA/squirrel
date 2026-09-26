import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.4.20"
    kotlin("plugin.compose") version "2.4.20"
    kotlin("plugin.serialization") version "2.4.20"
    id("org.jetbrains.compose") version "1.12.1"
}

// Set by scripts/release.sh from the release tag; MSI versions need three numbers
val appVersion = (findProperty("appVersion") as String?) ?: "1.0.0"

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    // The few icons not in core are in ui/Icons.kt: the extended set is ~36 MB
    implementation("org.jetbrains.compose.material:material-icons-core:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("io.coil-kt.coil3:coil-compose:3.6.3")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.3")
}

// The download engine (desktop/scripts/build_runtime.sh) is shipped as app
// resources: <install dir>/app/resources/runtime
val runtimeTarget = when {
    System.getProperty("os.name").startsWith("Windows") -> "windows-x86_64"
    System.getProperty("os.name").startsWith("Mac") ->
        if (System.getProperty("os.arch") == "aarch64") "macos-arm64" else "macos-x86_64"
    else -> "linux-x86_64"
}
val resourcesOs = runtimeTarget.substringBefore('-')
val runtimeDir = rootDir.resolve("../build/runtime-$runtimeTarget")
val stageRuntime by tasks.registering(Sync::class) {
    from(runtimeDir)
    into(layout.buildDirectory.dir("app-resources/$resourcesOs/runtime"))
}
tasks.matching { it.name == "prepareAppResources" }.configureEach {
    dependsOn(stageRuntime)
    // Here rather than in stageRuntime, which Gradle skips when the folder is missing
    doFirst {
        check(runtimeDir.resolve("app/squirrel_host.py").isFile) {
            "Missing $runtimeDir. Run desktop/scripts/build_runtime.sh $runtimeTarget first."
        }
    }
}

compose.desktop {
    application {
        mainClass = "app.squirrel.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Msi)
            packageName = "Squirrel"
            packageVersion = appVersion
            description = "Download videos and audio with yt-dlp"
            vendor = "Squirrel"
            appResourcesRootDir.set(layout.buildDirectory.dir("app-resources"))
            modules("java.naming", "jdk.unsupported")
            // The MSI itself is packaged by .github/workflows/windows.yml, with these same options
            // plus packaging/ (installer artwork); packageMsi still works for local builds
            windows {
                iconFile.set(project.file("icon.ico"))
                menu = true
                menuGroup = "Squirrel"
                shortcut = true
                // Installs into %LOCALAPPDATA%, so no admin prompt and the engine can update itself
                perUserInstall = true
                // Keep constant: lets new versions upgrade existing installs
                upgradeUuid = "6f1d8f0e-3f7b-4a55-9c0e-5b8f2f4e1a7d"
            }
        }
    }
}
