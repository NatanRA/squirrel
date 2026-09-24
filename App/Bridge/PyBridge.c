#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include "PyBridge.h"

static pybridge_js_runner_t js_runner = NULL;
static PyObject *bridge_module = NULL;

void pybridge_set_js_runner(pybridge_js_runner_t runner) {
    js_runner = runner;
}

#pragma mark - _iosbridge module (Python -> app)

static PyObject *iosbridge_run_js(PyObject *self, PyObject *args) {
    const char *code;
    if (!PyArg_ParseTuple(args, "s", &code)) {
        return NULL;
    }
    if (js_runner == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "JavaScript runner not configured");
        return NULL;
    }

    char *out = NULL;
    int is_error = 0;
    // JavaScriptCore can take a couple of seconds; let other Python threads run.
    Py_BEGIN_ALLOW_THREADS
    out = js_runner(code, &is_error);
    Py_END_ALLOW_THREADS

    if (out == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "JavaScript runner returned no output");
        return NULL;
    }
    PyObject *result = NULL;
    if (is_error) {
        PyErr_SetString(PyExc_RuntimeError, out);
    } else {
        result = PyUnicode_FromString(out);
    }
    free(out);
    return result;
}

static PyMethodDef iosbridge_methods[] = {
    {"run_js", iosbridge_run_js, METH_VARARGS, "Evaluate JavaScript with JavaScriptCore and return console output."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef iosbridge_module = {
    PyModuleDef_HEAD_INIT, "_iosbridge", NULL, -1, iosbridge_methods,
};

static PyObject *PyInit_iosbridge(void) {
    return PyModule_Create(&iosbridge_module);
}

#pragma mark - Interpreter lifecycle (app -> Python)

static char *error_json(const char *message) {
    PyObject *json = PyImport_ImportModule("json");
    PyObject *dumped = NULL;
    if (json) {
        PyObject *msg = PyUnicode_FromString(message);
        dumped = PyObject_CallMethod(json, "dumps", "{s:O,s:O}", "ok", Py_False, "error", msg);
        Py_XDECREF(msg);
        Py_DECREF(json);
    }
    char *result = NULL;
    if (dumped) {
        result = strdup(PyUnicode_AsUTF8(dumped));
        Py_DECREF(dumped);
    } else {
        PyErr_Clear();
        result = strdup("{\"ok\": false, \"error\": \"Internal bridge error\"}");
    }
    return result;
}

/// Formats and clears the pending Python exception as a malloc'd string.
static char *take_exception_message(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (exc == NULL) {
        return strdup("Unknown Python error");
    }
    PyObject *str = PyObject_Str(exc);
    const char *utf8 = str ? PyUnicode_AsUTF8(str) : NULL;
    char *message = strdup(utf8 ? utf8 : "Unprintable Python error");
    Py_XDECREF(str);
    PyErr_Clear();

    // Also dump the traceback to the system log for debugging.
    PyErr_SetRaisedException(exc);
    PyErr_Print();
    return message;
}

char *pybridge_initialize(const char *resource_path) {
    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;
    char path[4096];

    if (PyImport_AppendInittab("_iosbridge", PyInit_iosbridge) == -1) {
        return strdup("Could not register _iosbridge module");
    }

    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        return strdup(status.err_msg ? status.err_msg : "Py_PreInitialize failed");
    }

    PyConfig_InitIsolatedConfig(&config);
    config.use_system_logger = 1;
    config.buffered_stdio = 0;
    config.write_bytecode = 0;  // the app bundle is read-only
    config.install_signal_handlers = 0;

    snprintf(path, sizeof(path), "%s/python", resource_path);
    status = PyConfig_SetBytesString(&config, &config.home, path);
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return strdup(status.err_msg ? status.err_msg : "Py_InitializeFromConfig failed");
    }

    // app_packages is a site dir (honours .pth files); PythonApp holds our bridge.
    char *error = NULL;
    snprintf(path, sizeof(path), "%s/app_packages", resource_path);
    PyObject *site = PyImport_ImportModule("site");
    PyObject *added = site ? PyObject_CallMethod(site, "addsitedir", "s", path) : NULL;
    Py_XDECREF(added);
    Py_XDECREF(site);
    if (added == NULL) {
        error = take_exception_message();
    }

    if (error == NULL) {
        snprintf(path, sizeof(path), "%s/PythonApp", resource_path);
        PyObject *sys_path = PySys_GetObject("path");  // borrowed
        PyObject *app_path = PyUnicode_FromString(path);
        if (sys_path == NULL || app_path == NULL || PyList_Insert(sys_path, 0, app_path) != 0) {
            error = take_exception_message();
        }
        Py_XDECREF(app_path);
    }

    if (error == NULL) {
        bridge_module = PyImport_ImportModule("ytdl_bridge");
        if (bridge_module == NULL) {
            error = take_exception_message();
        }
    }

    // Release the GIL so pybridge_call can acquire it from any thread.
    PyEval_SaveThread();
    return error;
}

char *pybridge_call(const char *function, const char *json_arg) {
    if (bridge_module == NULL) {
        return strdup("{\"ok\": false, \"error\": \"Python is not initialized\"}");
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    char *result = NULL;
    PyObject *value = PyObject_CallMethod(bridge_module, function, "s", json_arg);
    if (value != NULL && PyUnicode_Check(value)) {
        const char *utf8 = PyUnicode_AsUTF8(value);
        result = utf8 ? strdup(utf8) : NULL;
    }
    if (result == NULL) {
        char *message = PyErr_Occurred() ? take_exception_message() : strdup("Bridge function returned a non-string");
        result = error_json(message);
        free(message);
    }
    Py_XDECREF(value);
    PyGILState_Release(gil);
    return result;
}
