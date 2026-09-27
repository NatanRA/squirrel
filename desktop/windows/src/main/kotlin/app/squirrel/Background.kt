package app.squirrel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import javax.swing.SwingUtilities
import kotlin.concurrent.thread

/**
 * Keep running when the window is closed (Settings): Squirrel stays in the notification area by
 * the clock, so downloads carry on, and its icon there opens the window again or quits.
 */
object Background {
    private const val KEEP_RUNNING = "keepRunning"

    var keepRunning by mutableStateOf(Preferences[KEEP_RUNNING] != "false")
        private set

    /** Whether the main window is showing; closing it only hides it while [keepRunning] is on */
    var windowVisible by mutableStateOf(true)

    /** Bumped to bring the window to the front */
    var raiseRequests by mutableStateOf(0)
        private set

    /** A link from the browser extension that the main screen hasn't loaded yet */
    var pendingLink by mutableStateOf<String?>(null)

    fun updateKeepRunning(value: Boolean) {
        keepRunning = value
        Preferences[KEEP_RUNNING] = value.toString()
    }

    fun showWindow() {
        windowVisible = true
        raiseRequests++
    }

    /** Shows the window and loads [link] there, as if it had been pasted. */
    fun open(link: String) {
        // Only web links: any program on this computer can send one (see SingleInstance)
        if (Regex("^https?://\\S+$").matches(link)) pendingLink = link
        showWindow()
    }
}

/**
 * One Squirrel at a time: opening it again (Start menu, desktop shortcut) while it runs in the
 * background shows the running one's window instead of starting a second copy. The browser
 * extension hands links over the same way (squirrel_host.py sends "open <url>").
 */
object SingleInstance {
    private const val PORT = 47913  // on localhost only
    private var server: ServerSocket? = null

    /** False when another Squirrel is running; it's been asked to show its window, and [link] if there's one. */
    fun claim(link: String? = null): Boolean {
        val loopback = InetAddress.getLoopbackAddress()
        val listening = try {
            ServerSocket(PORT, 8, loopback)
        } catch (e: IOException) {
            // Taken, most likely by Squirrel: ask it to come forward. If nothing answers, the port
            // belongs to something else, so just run.
            val message = if (link != null) "open $link\n" else "show\n"
            val asked = runCatching { Socket(loopback, PORT).use { it.getOutputStream().write(message.toByteArray()) } }
            return asked.isFailure
        }
        server = listening
        thread(isDaemon = true, name = "single-instance") {
            while (true) {
                val client = runCatching { listening.accept() }.getOrNull() ?: break
                client.use {
                    // One line per connection; don't let a silent one block the next
                    it.soTimeout = 2000
                    val line = runCatching { it.getInputStream().bufferedReader().readLine() }.getOrNull().orEmpty()
                    when {
                        line == "show" -> SwingUtilities.invokeLater { Background.showWindow() }
                        line.startsWith("open ") -> {
                            val url = line.removePrefix("open ").trim()
                            SwingUtilities.invokeLater { Background.open(url) }
                        }
                    }
                }
            }
        }
        return true
    }
}
