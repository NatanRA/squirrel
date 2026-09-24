#ifndef PyBridge_h
#define PyBridge_h

/// Runs a JavaScript program and returns everything it printed with console.log.
/// On failure, sets *is_error to 1 and returns the error message instead.
/// The returned string must be allocated with malloc; the bridge frees it.
typedef char *_Nullable (*pybridge_js_runner_t)(const char *_Nonnull code, int *_Nonnull is_error);

/// Must be called before pybridge_initialize.
void pybridge_set_js_runner(pybridge_js_runner_t _Nonnull runner);

/// Starts the interpreter and imports the `ytdl_bridge` module.
/// Returns NULL on success, or a malloc'd error message.
char *_Nullable pybridge_initialize(const char *_Nonnull resource_path);

/// Calls `ytdl_bridge.<function>(json_arg)`; safe to call from any thread.
/// Returns a malloc'd JSON string the caller must free().
char *_Nonnull pybridge_call(const char *_Nonnull function, const char *_Nonnull json_arg);

#endif
