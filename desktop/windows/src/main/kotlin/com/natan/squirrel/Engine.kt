package com.natan.squirrel

import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.BufferedWriter
import java.io.IOException

class EngineException(message: String, val cancelled: Boolean = false) : Exception(message)

/**
 * The download engine: the shared yt-dlp bridge in a bundled Python process
 * (desktop/host/squirrel_host.py), started on first use.
 *
 * Requests and replies are single JSON lines matched by id, so `progress`
 * is answered while a `download` is still running.
 */
object Engine {
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()
    private var process: Process? = null
    private var input: BufferedWriter? = null
    private var nextId = 0
    private val pending = HashMap<Int, CompletableDeferred<JsonObject>>()

    /** Runs `squirrel_host.cmd_<command>(args)` and returns its reply. */
    suspend fun call(command: String, args: JsonObject = JsonObject(emptyMap())): JsonObject {
        val reply = CompletableDeferred<JsonObject>()
        synchronized(lock) {
            try {
                launchIfNeeded()
                val id = ++nextId
                pending[id] = reply
                val request = buildJsonObject {
                    put("id", id)
                    put("cmd", command)
                    put("args", args)
                }
                try {
                    input!!.apply { write(request.toString()); newLine(); flush() }
                } catch (e: IOException) {
                    pending.remove(id)
                    throw EngineException("The download engine stopped unexpectedly")
                }
            } catch (e: Exception) {
                reply.completeExceptionally(e)
            }
        }
        val result = reply.await()
        if (result.bool("ok") != true) {
            throw EngineException(result.string("error") ?: "Unknown error", result.bool("cancelled") == true)
        }
        return result
    }

    /** Stops the engine; the next call starts a fresh one (e.g. with a new yt-dlp). */
    fun restart() = synchronized(lock) {
        process?.let { it.destroy(); stopped(it) }
    }

    private fun launchIfNeeded() {
        if (process?.isAlive == true) return
        val command = Paths.engineCommand
        if (!java.io.File(command.first()).exists()) {
            throw EngineException("The download engine is missing (${Paths.runtime}). Reinstall Squirrel.")
        }
        val started = ProcessBuilder(command)
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        process = started
        input = started.outputStream.bufferedWriter(Charsets.UTF_8)
        Thread({ read(started) }, "engine-reader").apply { isDaemon = true }.start()
    }

    private fun read(started: Process) {
        started.inputStream.bufferedReader(Charsets.UTF_8).useLines { lines ->
            for (line in lines) {
                val reply = runCatching { json.parseToJsonElement(line) as JsonObject }.getOrNull() ?: continue
                val id = reply["id"]?.jsonPrimitive?.intOrNull ?: continue
                synchronized(lock) { pending.remove(id) }?.complete(reply)
            }
        }
        synchronized(lock) { stopped(started) }
    }

    /** Fails what was waiting on `ended`, unless a restart already replaced it. */
    private fun stopped(ended: Process) {
        if (process !== ended) return
        process = null
        input = null
        val waiting = pending.values.toList()
        pending.clear()
        waiting.forEach { it.completeExceptionally(EngineException("The download engine stopped unexpectedly")) }
    }
}

fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()
fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
fun jsonOf(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.associate { (k, v) -> k to v.toJson() })

private fun Any?.toJson(): JsonElement = when (this) {
    null -> kotlinx.serialization.json.JsonNull
    is JsonElement -> this
    is String -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    is Boolean -> JsonPrimitive(this)
    is List<*> -> kotlinx.serialization.json.JsonArray(map { it.toJson() })
    else -> JsonPrimitive(toString())
}
