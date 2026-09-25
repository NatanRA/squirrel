package com.natan.squirrel

import java.io.File

/**
 * Registers the engine with browsers so the Squirrel extension can reach it
 * (native messaging). Rewritten on every launch, so it follows the app if it
 * moves. Keep the ids in sync with extension/manifest.json.
 */
object NativeMessaging {
    const val HOST_NAME = "com.natan.squirrel"
    /** From the public key in extension/manifest.json */
    val chromeExtensionIds = listOf("hdacmehgeiecekdneiggfemjeolmdfbc")
    const val FIREFOX_EXTENSION_ID = "squirrel@extension"

    /** Registry keys (under HKCU\Software) where each browser looks for hosts. */
    private val windowsKeys = listOf(
        "Google\\Chrome" to false,
        "Chromium" to false,
        "Microsoft\\Edge" to false,
        "BraveSoftware\\Brave-Browser" to false,
        "Vivaldi" to false,
        "Mozilla" to true,
    )

    /** Linux (development): each browser's config folder, relative to home. */
    private val linuxFolders = listOf(
        ".config/google-chrome" to false,
        ".config/chromium" to false,
        ".config/microsoft-edge" to false,
        ".config/BraveSoftware/Brave-Browser" to false,
        ".mozilla" to true,
    )

    fun register() {
        if (!Paths.hostLauncher.exists()) return
        val chrome = manifest(firefox = false)
        val firefox = manifest(firefox = true)
        runCatching {
            if (isWindows) {
                val folder = File(Paths.data, "native-messaging").apply { mkdirs() }
                val chromeFile = File(folder, "$HOST_NAME.chrome.json").apply { writeText(chrome) }
                val firefoxFile = File(folder, "$HOST_NAME.firefox.json").apply { writeText(firefox) }
                for ((key, isFirefox) in windowsKeys) {
                    val path = (if (isFirefox) firefoxFile else chromeFile).path
                    ProcessBuilder("reg", "add", "HKCU\\Software\\$key\\NativeMessagingHosts\\$HOST_NAME",
                        "/ve", "/t", "REG_SZ", "/d", path, "/f")
                        .redirectErrorStream(true).start().waitFor()
                }
            } else if (!isMac) {
                val home = File(System.getProperty("user.home"))
                for ((folder, isFirefox) in linuxFolders) {
                    val profile = File(home, folder)
                    if (!profile.isDirectory) continue
                    val hosts = File(profile, if (isFirefox) "native-messaging-hosts" else "NativeMessagingHosts").apply { mkdirs() }
                    File(hosts, "$HOST_NAME.json").writeText(if (isFirefox) firefox else chrome)
                }
            }
        }
    }

    private fun manifest(firefox: Boolean): String {
        val allowed = if (firefox) "allowed_extensions" to listOf(FIREFOX_EXTENSION_ID)
        else "allowed_origins" to chromeExtensionIds.map { "chrome-extension://$it/" }
        return jsonOf(
            "name" to HOST_NAME,
            "description" to "Squirrel downloads",
            "path" to Paths.hostLauncher.absolutePath,
            "type" to "stdio",
            allowed,
        ).toString()
    }
}
