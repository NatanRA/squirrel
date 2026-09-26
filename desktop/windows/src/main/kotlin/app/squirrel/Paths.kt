package app.squirrel

import java.io.File

val isWindows = System.getProperty("os.name").startsWith("Windows")
val isMac = System.getProperty("os.name").startsWith("Mac")

/** Folders shared with the engine (see squirrel_host.py's _data_dir). */
object Paths {
    private val home = File(System.getProperty("user.home"))

    val data: File = System.getenv("SQUIRREL_DATA_DIR")?.let(::File) ?: when {
        isWindows -> File(System.getenv("APPDATA") ?: "$home/AppData/Roaming", "Squirrel")
        isMac -> File(home, "Library/Application Support/Squirrel")
        else -> File(System.getenv("XDG_DATA_HOME") ?: "$home/.local/share", "Squirrel")
    }
    val library = File(data, "library.json")
    val settings = File(data, "settings.json")
    val preferences = File(data, "preferences.json")
    val defaultDownloads = File(home, "Downloads/Squirrel")

    /** The engine shipped as app resources (desktop/scripts/build_runtime.sh). */
    val runtime: File = System.getenv("SQUIRREL_RUNTIME")?.let(::File)
        ?: File(System.getProperty("compose.application.resources.dir") ?: "resources", "runtime")

    /** What browsers launch for the extension (a .bat, which Chrome and Firefox both accept). */
    val hostLauncher: File = File(runtime, if (isWindows) "squirrel-host.bat" else "squirrel-host")

    /** The app starts Python directly: no batch file, so no console window. */
    val engineCommand: List<String>
        get() = if (isWindows) {
            listOf(File(runtime, "python/pythonw.exe").path, "-I", "-X", "utf8", File(runtime, "app/squirrel_host.py").path, "--stdio")
        } else {
            listOf(hostLauncher.path, "--stdio")
        }
}
