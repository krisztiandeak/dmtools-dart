/// CommonJS `require()` loader — JS bootstrap prelude for [QuickjsRuntime].
///
/// Dart port of the Java `JobJavaScriptBridge` module loader
/// (`RequireProxy` / `loadModule` / `resolveModulePath` /
/// `setCurrentScriptDirectory`, dmtools-core
/// `job/JobJavaScriptBridge.java`).
///
/// The FFI host functions marshal results through JSON, so a host-side
/// `require` could never return module exports containing functions. The
/// loader therefore lives entirely in JS: it reads module sources through
/// the host-private `__loaderReadHost` primitive, which it captures into
/// its closure on install and deletes from `globalThis` (direct host IO,
/// Java `loadJavaScriptCode` parity — deliberately not the sandboxed
/// `file_read`, whose containment would block pack-internal modules,
/// gh-369; the closure capture keeps the uncontained read unreachable
/// from agent code) and evaluates them with `eval()`, so real JS objects
/// (functions included) flow between modules.
///
/// Semantics ported 1:1 from Java:
/// - `./x` / `../x` resolve against the current script directory, which is
///   saved/restored around each module eval (`try`/`finally`) and updated to
///   the module's own directory first, so relative requires inside modules
///   resolve correctly.
/// - Module cache is keyed by resolved path; a placeholder object is cached
///   **before** eval so circular requires terminate, and is replaced by the
///   real exports afterwards.
/// - Module code runs wrapped exactly like Java:
///   `(function() { var module = { exports: {} }; var exports =
///   module.exports; <CODE> return module.exports; })()`.
/// - On load failure the cache entry is removed and
///   `Failed to require module: <path>` is thrown; the cause message keeps
///   the Java `JavaScript file not found` substring visible.
/// - `require()` argument validation:
///   `require() expects exactly one argument (module path)`.
///
/// Known deviation: Java's `loadModule` re-enters `loadJavaScriptCode`, so a
/// require argument that is itself a URL fetches remotely; the JS prelude
/// has no synchronous fetch host function and only reads files.
library;

import 'package:quickjs_runtime/quickjs_runtime.dart';

/// Installs `globalThis.require` and `globalThis.__setScriptDirectory` on
/// [runtime].
///
/// Must run before the user script is evaluated. The bootstrap captures
/// the `__loaderReadHost` host function into its closure and deletes the
/// global, so it must run AFTER the host functions are registered.
void installRequireLoader(QuickjsRuntime runtime) {
  runtime.eval(_requireLoaderBootstrap, filename: '<require_loader>');
}

/// The loader bootstrap evaluated on the runtime.
///
/// State (`currentScriptDirectory`, `moduleCache`) lives in the closure, so
/// repeated installs each get a fresh cache — matching the Java bridge,
/// whose cache is cleared on `close()`.
const String _requireLoaderBootstrap = '''
(function() {
    // Capture the host read primitive and remove its global: after this
    // IIFE runs, __loaderReadHost is reachable ONLY through require()
    // (gh-369 review: a lingering global let agent scripts bypass the
    // gh-365 file containment with one direct call).
    var loaderReadHost = globalThis.__loaderReadHost;
    delete globalThis.__loaderReadHost;
    function unwrapHostError(result) {
        if (result !== null && result !== undefined &&
                typeof result === 'object' &&
                result.__jsError !== undefined) {
            throw new Error(result.__jsError);
        }
        return result;
    }
    function loaderFileRead(path) {
        return unwrapHostError(loaderReadHost(path));
    }

    var currentScriptDirectory = '';
    var moduleCache = {};
    var loadedModules = [];

    function scriptDirOf(path) {
        if (typeof path !== 'string' || path.indexOf('/') === -1) {
            return '';
        }
        var lastSlash = path.lastIndexOf('/');
        return lastSlash > 0 ? path.substring(0, lastSlash) : '';
    }

    function normalizePath(path) {
        var absolute = path.charAt(0) === '/';
        var segments = path.split('/');
        var out = [];
        for (var i = 0; i < segments.length; i++) {
            var segment = segments[i];
            if (segment === '' || segment === '.') continue;
            if (segment === '..') {
                if (out.length > 0 && out[out.length - 1] !== '..') {
                    out.pop();
                } else if (!absolute) {
                    out.push('..');
                }
                continue;
            }
            out.push(segment);
        }
        var joined = out.join('/');
        return absolute ? '/' + joined : joined;
    }

    function resolveModulePath(modulePath) {
        if (modulePath.indexOf('./') === 0 ||
                modulePath.indexOf('../') === 0) {
            if (currentScriptDirectory) {
                return normalizePath(
                    currentScriptDirectory + '/' + modulePath);
            }
        }
        return modulePath;
    }

    function readModuleCode(resolvedPath) {
        // Host-private direct read captured in this closure (Java
        // loadJavaScriptCode parity) — NOT the sandboxed file_read:
        // module sources are host-trusted loader input, so packs under
        // ~/.dmtools load regardless of the working-dir containment
        // (gh-369).
        var content = loaderFileRead(resolvedPath);
        if (content === null || content === undefined) {
            throw new Error('JavaScript file not found in resources or ' +
                'filesystem: ' + resolvedPath);
        }
        return content;
    }

    function wrapModuleCode(code) {
        return '(function() { var module = { exports: {} }; ' +
            'var exports = module.exports;\\n' + code +
            '\\nreturn module.exports; })()';
    }

    function loadModule(modulePath) {
        var resolvedPath = resolveModulePath(modulePath);
        if (Object.prototype.hasOwnProperty.call(
                moduleCache, resolvedPath)) {
            return moduleCache[resolvedPath];
        }
        var savedScriptDirectory = currentScriptDirectory;
        // Placeholder cached before eval: circular requires get it and
        // terminate instead of recursing (Java loadModule parity).
        var placeholder = {};
        moduleCache[resolvedPath] = placeholder;
        try {
            currentScriptDirectory = scriptDirOf(resolvedPath);
            var moduleCode = readModuleCode(resolvedPath);
            loadedModules.push({
                code: moduleCode,
                dir: currentScriptDirectory
            });
            var moduleExports =
                eval(wrapModuleCode(moduleCode));
            moduleCache[resolvedPath] = moduleExports;
            return moduleExports;
        } catch (e) {
            delete moduleCache[resolvedPath];
            var cause = (e && e.message) ? e.message : String(e);
            throw new Error('Failed to require module: ' + modulePath +
                ' (' + cause + ')');
        } finally {
            currentScriptDirectory = savedScriptDirectory;
        }
    }

    globalThis.require = function(modulePath) {
        if (arguments.length !== 1) {
            throw new Error(
                'require() expects exactly one argument (module path)');
        }
        return loadModule(modulePath);
    };

    globalThis.__setScriptDirectory = function(path) {
        currentScriptDirectory = scriptDirOf(path);
    };

    // Read-only accessor for the host: the require base of the module
    // currently being evaluated (gh-409). The async pool uses it so a
    // dispatched function re-evaluates against its declaring module's
    // directory rather than the entry script's.
    globalThis.__jsrScriptDirectory = function() {
        return currentScriptDirectory;
    };

    // Require base of the module whose source contains [fnSource] (the
    // text of a dispatched function). Searches the loaded modules newest
    // first; falls back to the live directory when no module matches
    // (e.g. a function declared in the entry script).
    globalThis.__jsrDirForSource = function(fnSource) {
        if (typeof fnSource !== 'string' || fnSource.length === 0) {
            return currentScriptDirectory;
        }
        for (var i = loadedModules.length - 1; i >= 0; i--) {
            if (loadedModules[i].code.indexOf(fnSource) !== -1) {
                return loadedModules[i].dir;
            }
        }
        return currentScriptDirectory;
    };
})();
''';
