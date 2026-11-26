#!/bin/bash
# Build raw libraries + C CLI bridge; link SDK FTFFmpeg.swift in the consuming target.
# Usage: bash /path/to/ffmpeg-build-xcframework.sh [/path/to/ffmpeg-source]
# Modes: --package-only, --check-cli-source (syntax only), --test-cli (macOS + Simulator).
# Default source: current directory (must contain configure and libavcodec/).
# Output: <source>/build-xcframework/{xcframeworks/FFmpeg.xcframework,bin/ffmpeg}; no Swift source is generated.
# Environment: BUILD_ROOT, JOBS, MIN_IOS_VERSION, MIN_MACOS_VERSION; optional tests: CLI_SWIFT_SOURCE, CLI_SWIFT_TEST_SOURCE.
# Requires Python 3 and Apple libclang. CLI_TEST_SIMULATOR_UDID defaults to booted in --test-cli.
# Upstream checkout/libav sources stay unchanged; adapted CLI copies are generated under work/.
set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,9p' "$0"
    exit 0
fi
MODE=build
case "${1:-}" in
    --package-only) MODE=package; shift ;;
    --check-cli-source) MODE=check; shift ;;
    --test-cli) MODE=test; shift ;;
esac
PACKAGE_ONLY=0
[[ "$MODE" == build ]] || PACKAGE_ONLY=1
[[ $# -le 1 && "${1:-}" != -* ]] || die "Usage: bash $0 [--package-only|--check-cli-source|--test-cli] [/path/to/ffmpeg-source]"

SOURCE_DIR=$(cd "${1:-.}" && pwd -P)
[[ -x "$SOURCE_DIR/configure" && -d "$SOURCE_DIR/libavcodec" ]] ||
    die "Run from the FFmpeg source directory, or pass its path as the first argument."
[[ "$(uname -s)" == "Darwin" ]] || die "This script requires macOS and Xcode."

# Use separate build directories so each target gets its own config.h and objects.
# An already configured source tree prevents FFmpeg's out-of-tree builds.
if [[ "$PACKAGE_ONLY" == 0 ]] &&
    [[ -f "$SOURCE_DIR/config.h" || -f "$SOURCE_DIR/ffbuild/config.mak" ]]; then
    die "Source tree is already configured. Run 'make distclean' there before using this script."
fi

for tool in xcrun xcodebuild make lipo ar libtool sysctl cmp python3; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' ||
    die "Python 3.9 or newer is required."

BUILD_ROOT=${BUILD_ROOT:-"$SOURCE_DIR/build-xcframework"}
mkdir -p "$BUILD_ROOT"
BUILD_ROOT=$(cd "$BUILD_ROOT" && pwd -P)
[[ "$BUILD_ROOT" != "/" && "$BUILD_ROOT" != "$SOURCE_DIR" ]] ||
    die "BUILD_ROOT must be a dedicated output directory."
XC_DIR="$BUILD_ROOT/xcframeworks"
mkdir -p "$XC_DIR"

MIN_IOS_VERSION=${MIN_IOS_VERSION:-13.0}
# Use the same deployment target for both macOS slices.
MIN_MACOS_VERSION=${MIN_MACOS_VERSION:-11.0}
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer."

LIBS=(libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale)
IOS_DIR="$BUILD_ROOT/ios"
SIM_DIR="$BUILD_ROOT/ios-simulator-arm64"
MACARM64_DIR="$BUILD_ROOT/macos-arm64"
MACX86_64_DIR="$BUILD_ROOT/macos-x86_64"
MACUNIVERSAL_DIR="$BUILD_ROOT/macos-universal"

IOS_SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SYSROOT=$(xcrun --sdk iphonesimulator --show-sdk-path)
MACOS_SYSROOT=$(xcrun --sdk macosx --show-sdk-path)
CLANG=$(xcrun --find clang)
AR=$(xcrun --find ar)
RANLIB=$(xcrun --find ranlib)
# Swift is needed only to test the separately supplied client adapter.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
CLI_SWIFT_SOURCE=${CLI_SWIFT_SOURCE:-"$SCRIPT_DIR/../../Sources/API/FTFFmpeg.swift"}
CLI_SWIFT_TEST_SOURCE=${CLI_SWIFT_TEST_SOURCE:-"$SCRIPT_DIR/../../../Tests/FFmpeg/FTFFmpegSmokeTests.swift"}
LIBCLANG_PATH="$(dirname "$(dirname "$CLANG")")/lib/libclang.dylib"
[[ -r "$LIBCLANG_PATH" ]] || die "Apple libclang is missing: $LIBCLANG_PATH"
python3 - "$LIBCLANG_PATH" <<'FTCLI_TOOLCHAIN_CHECK'
import ctypes
import sys
library = ctypes.CDLL(sys.argv[1])
for name in ('clang_Cursor_getVarDeclInitializer', 'clang_Cursor_getStorageClass',
             'clang_getCursorUSR', 'clang_getCanonicalType', 'clang_getArraySize'):
    if not hasattr(library, name):
        raise SystemExit('Apple libclang is missing a required API: ' + name)
FTCLI_TOOLCHAIN_CHECK

COMMON_FLAGS=(
    --enable-cross-compile --target-os=darwin
    --enable-static --disable-shared --enable-pic
    --disable-programs --disable-doc --disable-debug
    --enable-gpl
    --disable-audiotoolbox --disable-d3d11va --disable-dxva2
    # Avoid detecting Homebrew/host libraries that are unavailable on iOS.
    --disable-autodetect --enable-videotoolbox
    # Always include native HTTPS/HLS on every Apple target, including encrypted HLS.
    --enable-network --enable-securetransport
    --enable-demuxer=hls --enable-protocol=http,https,tcp,tls,crypto
)

# Older FFmpeg releases contain libpostproc; newer ones have removed it.
CONFIGURE_HELP=$("$SOURCE_DIR/configure" --help)
if [[ "$CONFIGURE_HELP" == *"--disable-postproc"* ]]; then
    COMMON_FLAGS+=(--disable-postproc)
fi

# C frontend/bridge generation is standalone. Client Swift sources stay outside
# the framework and are used only when explicitly compiling the runtime tests.
generate_cli() {
    python3 - "$SOURCE_DIR" "$BUILD_ROOT/work/$1" "$2" "$CLANG" "$3" <<'FTCLI_PY'
import ctypes as C
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

PUBLIC_HEADER = r'''#ifndef FT_FFMPEG_CLI_H
#define FT_FFMPEG_CLI_H
#ifdef __cplusplus
extern "C" {
#endif
/* Noninteractive, in-process upstream CLI. Each call owns independent state.
 * argc includes argv[0] ("ffmpeg"). Do not share output paths across calls.
 * Link the SDK FTFFmpeg.swift adapter in the same target for CLI support.
 * Returns the upstream CLI status; nonzero means failure.
 */
int ft_ffmpeg_execute(int argc, char **argv);
int ffmpeg(int argc, char **argv);
#ifdef __cplusplus
}
#endif
#endif
'''
RUNTIME_HEADER = r'''#ifndef FTCLI_RUNTIME_H
#define FTCLI_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <pthread.h>
#include <stdio.h>
#include "libavcodec/avcodec.h"
typedef struct FTCLISession FTCLISession;
typedef struct FTCLIBinding { FTCLISession *previous; } FTCLIBinding;
void *ftcli_lookup(unsigned key);
void *ftcli_storage(unsigned key, const void *initial, size_t size, size_t alignment);
FTCLISession *ftcli_current(void);
FTCLIBinding ftcli_bind(FTCLISession *session);
FTCLIBinding ftcli_bind_codec(AVCodecContext *context);
void ftcli_unbind(FTCLIBinding *binding);
AVCodecContext *ftcli_codec_alloc(const AVCodec *codec);
void ftcli_codec_free(AVCodecContext **context);
void ftcli_devices_register(void);
int ftcli_network_init(void);
int ftcli_network_deinit(void);
int ftcli_codec_open(AVCodecContext *, const AVCodec *, AVDictionary **);
int ftcli_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
void ftcli_log(void *, int, const char *, ...);
void ftcli_log_set_level(int);
int ftcli_log_get_level(void);
void ftcli_log_set_flags(int);
int ftcli_log_get_flags(void);
void ftcli_log_set_callback(void (*callback)(void *, int, const char *, va_list));
int ftcli_setvbuf(FILE *, char *, int, size_t);
char *ftcli_getenv(const char *name);
_Noreturn void ftcli_exit(int code);
/* Swift-owned state and policy; opaque pointers keep FFmpeg types in C. */
void *ftcli_swift_state_create(uint32_t);
void *ftcli_swift_state_retain(void *);
void ftcli_swift_state_release(void *);
void *ftcli_swift_state_lookup(void *, uint32_t);
void *ftcli_swift_state_storage(void *, uint32_t, const void *, size_t, size_t);
void ftcli_swift_worker_started(void *);
void ftcli_swift_worker_finished(void *);
void ftcli_swift_wait_for_workers(void *);
void ftcli_swift_codec_register(void *, void *);
void ftcli_swift_codec_update(void *, void *);
void *ftcli_swift_codec_session(void *, void *);
void *ftcli_swift_codec_token(void *);
void ftcli_swift_codec_forget(void *);
int32_t ftcli_swift_validate(int32_t, char **);
int ftcli_engine_main(int, char **);
int ft_ffmpeg_execute(int, char **);
int ffmpeg(int, char **);
#endif
'''
RUNTIME_SOURCE = r'''#include "ftcli_runtime.h"
#include <assert.h>
#include <errno.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include "libavdevice/avdevice.h"
#include "libavformat/avformat.h"

// C owns only native ABI details: TLS, setjmp, varargs and pthread trampolines.
// Session storage, worker accounting, codec ownership and policy live in Swift.
struct FTCLISession {
    void *state;
    int log_level, log_flags;
    void (*log_callback)(void *, int, const char *, va_list);
    pthread_t owner;
    jmp_buf escape;
    int exit_code;
};
static _Thread_local FTCLISession *current;
static pthread_once_t devices_once = PTHREAD_ONCE_INIT;
static pthread_once_t network_once = PTHREAD_ONCE_INIT;
static int network_status;
static void register_devices(void) { avdevice_register_all(); }
static void initialize_network(void) { network_status = avformat_network_init(); }
void ftcli_devices_register(void) { pthread_once(&devices_once, register_devices); }
int ftcli_network_init(void) { pthread_once(&network_once, initialize_network); return network_status; }
int ftcli_network_deinit(void) { return 0; } /* process-lifetime initialization */

FTCLISession *ftcli_current(void) { return current; }
FTCLIBinding ftcli_bind(FTCLISession *session) {
    FTCLIBinding previous = { current };
    current = session;
    return previous;
}
void ftcli_unbind(FTCLIBinding *binding) { current = binding->previous; }
static FTCLISession *required_session(void) { assert(current); return current; }
void *ftcli_lookup(unsigned key) {
    return ftcli_swift_state_lookup(required_session()->state, key);
}
void *ftcli_storage(unsigned key, const void *initial, size_t size, size_t alignment) {
    void *value = ftcli_swift_state_storage(required_session()->state, key, initial, size, alignment);
    if (!value) ftcli_exit(ENOMEM);
    return value;
}

typedef struct FTCLIThread {
    FTCLISession *session;
    void *state; /* separately retained until the cleanup trampoline returns */
    void *(*function)(void *);
    void *argument;
} FTCLIThread;
static void thread_complete(void *opaque) {
    FTCLIThread *thread = opaque;
    void *state = thread->state;
    current = NULL;
    free(thread);
    ftcli_swift_worker_finished(state);
    ftcli_swift_state_release(state);
}
static void *thread_start(void *opaque) {
    FTCLIThread *thread = opaque;
    void *result;
    current = thread->session;
    pthread_cleanup_push(thread_complete, thread);
    result = thread->function(thread->argument);
    pthread_cleanup_pop(1);
    return result;
}
int ftcli_pthread_create(pthread_t *thread, const pthread_attr_t *attributes,
                        void *(*function)(void *), void *argument) {
    FTCLISession *session = required_session();
    FTCLIThread *start = malloc(sizeof(*start));
    if (!start) return ENOMEM;
    void *state = ftcli_swift_state_retain(session->state);
    *start = (FTCLIThread){ session, state, function, argument };
    ftcli_swift_worker_started(state);
    int error = pthread_create(thread, attributes, thread_start, start);
    if (error) {
        ftcli_swift_worker_finished(state);
        ftcli_swift_state_release(state);
        free(start);
    }
    return error;
}

AVCodecContext *ftcli_codec_alloc(const AVCodec *codec) {
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (context) ftcli_swift_codec_register(context, required_session());
    return context;
}
int ftcli_codec_open(AVCodecContext *context, const AVCodec *codec, AVDictionary **options) {
    ftcli_swift_codec_update(context, context->opaque);
    return avcodec_open2(context, codec, options);
}
void ftcli_codec_free(AVCodecContext **context) {
    void *token = ftcli_swift_codec_token(context ? *context : NULL);
    avcodec_free_context(context);
    ftcli_swift_codec_forget(token);
}
FTCLIBinding ftcli_bind_codec(AVCodecContext *context) {
    FTCLISession *session = ftcli_swift_codec_session(context, context->opaque);
    return ftcli_bind(session ? session : current);
}

void ftcli_log(void *context, int level, const char *format, ...) {
    FTCLISession *session = required_session();
    if (level > session->log_level) return;
    va_list args;
    va_start(args, format);
    (session->log_callback ? session->log_callback : av_log_default_callback)(context, level, format, args);
    va_end(args);
}
void ftcli_log_set_level(int value) { required_session()->log_level = value; }
int ftcli_log_get_level(void) { return required_session()->log_level; }
void ftcli_log_set_flags(int value) { required_session()->log_flags = value; }
int ftcli_log_get_flags(void) { return required_session()->log_flags; }
void ftcli_log_set_callback(void (*value)(void *, int, const char *, va_list)) {
    required_session()->log_callback = value;
}
int ftcli_setvbuf(FILE *stream, char *buffer, int mode, size_t size) { return 0; }
char *ftcli_getenv(const char *name) { return !strcmp(name, "FFREPORT") ? NULL : getenv(name); }
_Noreturn void ftcli_exit(int code) {
    FTCLISession *session = required_session();
    assert(pthread_equal(pthread_self(), session->owner));
    session->exit_code = code ? code : 1;
    longjmp(session->escape, 1);
}

int ft_ffmpeg_execute(int argc, char **argv) {
    int result = ftcli_swift_validate(argc, argv);
    if (result) return result;
    FTCLISession *session = calloc(1, sizeof(*session));
    if (!session) return -ENOMEM;
    session->state = ftcli_swift_state_create(@SLOT_COUNT@);
    if (!session->state) { free(session); return -ENOMEM; }
    session->owner = pthread_self();
    session->log_level = av_log_get_level();
    session->log_flags = av_log_get_flags();
    FTCLIBinding previous = ftcli_bind(session);
    if (!setjmp(session->escape)) result = ftcli_engine_main(argc, argv);
    else result = session->exit_code;
    ftcli_swift_wait_for_workers(session->state);
    ftcli_unbind(&previous);
    ftcli_swift_state_release(session->state);
    free(session);
    return result;
}
int ffmpeg(int argc, char **argv) { return ft_ffmpeg_execute(argc, argv); }
'''

# Uses Apple's libclang to identify declarations and references, rather than
# maintaining a list of upstream globals or editing upstream files in place.
source, work, prefix, clang, mode = sys.argv[1:6]
source, work, prefix = map(lambda p: Path(p).resolve(), (source, work, prefix))
stage = Path(sys.argv[6]).resolve() if len(sys.argv) > 6 else work / 'ftcli-session'
stage.mkdir(exist_ok=True)
metadata = stage / 'metadata.mk'
metadata.write_text(".PHONY: ftcli-metadata\nftcli-metadata:\n\t@printf '%s\\n' '$(CPPFLAGS)' '$(CFLAGS)' '$(sort $(OBJS-ffmpeg))'\n")
printed = subprocess.check_output(['make', '-n', '--no-print-directory', 'CONFIG_FFMPEG=yes', '-f', 'Makefile', '-f', str(metadata), 'ftcli-metadata'], cwd=work, text=True).splitlines()
commands = [shlex.split(line) for line in printed if line.startswith('printf ')]
rows = commands[-1][2:] if len(commands) == 1 else []
if len(rows) != 3 or not rows[2].strip():
    raise SystemExit('Cannot obtain upstream FFmpeg CLI object manifest. Full build with --enable-ffmpeg is required.')
flags = shlex.split(rows[0]) + shlex.split(rows[1])
objects = shlex.split(rows[2])
paths = []
for obj in objects:
    relative = Path(obj).with_suffix('.c')
    candidates = [work / relative, source / relative]
    candidate = next((p for p in candidates if p.is_file()), None)
    if candidate is None or not str(relative).startswith('fftools/'):
        raise SystemExit('Missing/unsupported upstream CLI compilation unit: ' + obj + '. Run a full build to generate fftools resources before --check-cli-source; if it persists, this upstream manifest needs review.')
    paths.append(candidate.resolve())

toolchain = Path(clang).resolve().parent.parent
library = C.CDLL(str(toolchain / 'lib/libclang.dylib'))
class CXString(C.Structure):
    _fields_ = [('data', C.c_void_p), ('flags', C.c_uint)]
class Cursor(C.Structure):
    _fields_ = [('kind', C.c_uint), ('xdata', C.c_int), ('data', C.c_void_p * 3)]
class Location(C.Structure):
    _fields_ = [('ptr', C.c_void_p * 2), ('value', C.c_uint)]
class Range(C.Structure):
    _fields_ = [('ptr', C.c_void_p * 2), ('begin', C.c_uint), ('end', C.c_uint)]
class Type(C.Structure):
    _fields_ = [('kind', C.c_uint), ('data', C.c_void_p * 2)]
def api(name, result, *arguments):
    function = getattr(library, name)
    function.restype, function.argtypes = result, list(arguments)
    return function
get_string = api('clang_getCString', C.c_char_p, CXString)
dispose_string = api('clang_disposeString', None, CXString)
def string(value):
    result = get_string(value)
    text = result.decode() if result else ''
    dispose_string(value)
    return text
spelling = api('clang_getCursorSpelling', CXString, Cursor)
usr = api('clang_getCursorUSR', CXString, Cursor)
parent = api('clang_getCursorSemanticParent', Cursor, Cursor)
storage = api('clang_Cursor_getStorageClass', C.c_uint, Cursor)
linkage = api('clang_getCursorLinkage', C.c_uint, Cursor)
definition = api('clang_isCursorDefinition', C.c_uint, Cursor)
referenced = api('clang_getCursorReferenced', Cursor, Cursor)
cursor_type = api('clang_getCursorType', Type, Cursor)
canonical_type = api('clang_getCanonicalType', Type, Type)
const_type = api('clang_isConstQualifiedType', C.c_uint, Type)
array_element = api('clang_getArrayElementType', Type, Type)
array_size = api('clang_getArraySize', C.c_longlong, Type)
initializer = api('clang_Cursor_getVarDeclInitializer', Cursor, Cursor)
is_null = api('clang_Cursor_isNull', C.c_int, Cursor)
extent = api('clang_getCursorExtent', Range, Cursor)
range_start = api('clang_getRangeStart', Location, Range)
range_end = api('clang_getRangeEnd', Location, Range)
cursor_location = api('clang_getCursorLocation', Location, Cursor)
get_location = api('clang_getSpellingLocation', None, Location, C.POINTER(C.c_void_p), C.POINTER(C.c_uint), C.POINTER(C.c_uint), C.POINTER(C.c_uint))
file_name = api('clang_getFileName', CXString, C.c_void_p)
def location(value):
    file = C.c_void_p()
    offset = C.c_uint()
    get_location(value, C.byref(file), None, None, C.byref(offset))
    return (Path(string(file_name(file))).resolve(), offset.value) if file.value else (None, 0)
def bounds(cursor):
    value = extent(cursor)
    start, begin = location(range_start(value))
    end_file, end = location(range_end(value))
    if start != end_file:
        raise RuntimeError('Cross-file source extent is unsupported')
    return start, begin, end
def owned(path):
    return path and any(path.is_relative_to(root / 'fftools') for root in (source, work))
def relative(path):
    for root in (work, source):
        if path.is_relative_to(root):
            return path.relative_to(root)
    raise RuntimeError('Unexpected source path: ' + str(path))
def mutable(type):
    while type.kind in (112, 114, 115, 116):
        type = array_element(type)
    return not const_type(type)
create_index = api('clang_createIndex', C.c_void_p, C.c_int, C.c_int)
parse = api('clang_parseTranslationUnit', C.c_void_p, C.c_void_p, C.c_char_p, C.POINTER(C.c_char_p), C.c_int, C.c_void_p, C.c_uint, C.c_uint)
root_cursor = api('clang_getTranslationUnitCursor', Cursor, C.c_void_p)
diagnostic_count = api('clang_getNumDiagnostics', C.c_uint, C.c_void_p)
diagnostic_at = api('clang_getDiagnostic', C.c_void_p, C.c_void_p, C.c_uint)
severity = api('clang_getDiagnosticSeverity', C.c_uint, C.c_void_p)
diagnostic_text = api('clang_formatDiagnostic', CXString, C.c_void_p, C.c_uint)
dispose_diagnostic = api('clang_disposeDiagnostic', None, C.c_void_p)
dispose_tu = api('clang_disposeTranslationUnit', None, C.c_void_p)
visitor_type = C.CFUNCTYPE(C.c_uint, Cursor, Cursor, C.c_void_p)
visit_children = api('clang_visitChildren', C.c_uint, Cursor, visitor_type, C.c_void_p)
variables, references, functions = {}, {}, {}
macros = {}
templates = []
units = []
errors = []
index = create_index(0, 0)
arguments = ['-I' + str(work), '-I' + str(source), *flags]
encoded_arguments = (C.c_char_p * len(arguments))(*[p.encode() for p in arguments])
for path in paths:
    unit = parse(index, str(path).encode(), encoded_arguments, len(arguments), None, 0, 1)
    if not unit:
        raise SystemExit('libclang could not parse ' + str(path))
    units.append(unit)
    for i in range(diagnostic_count(unit)):
        diagnostic = diagnostic_at(unit, i)
        if severity(diagnostic) >= 3:
            errors.append(string(diagnostic_text(diagnostic, 0)))
        dispose_diagnostic(diagnostic)
    def walk(cursor, enclosing, unused):
        try:
            path, offset = location(cursor_location(cursor))
            if not owned(path):
                return 1
            name = string(spelling(cursor))
            if cursor.kind == 501:  # MacroDefinition
                macros.setdefault(name, set()).add(bounds(cursor))
            elif cursor.kind == 9:  # VarDecl
                local = parent(cursor).kind == 8
                if not local or storage(cursor) == 3:  # static locals
                    key = string(usr(cursor))
                    entry = variables.setdefault(key, {'name': name, 'declarations': {}, 'mutable': mutable(cursor_type(cursor)), 'local': local})
                    file, begin, end = bounds(cursor)
                    entry['declarations'][str(file) + ':' + str(begin)] = (file, begin, end, linkage(cursor))
                    if definition(cursor) or (file.suffix == '.c' and storage(cursor) != 2):
                        init = initializer(cursor)
                        entry['definition'] = (file, begin, end)
                        entry['name_offset'] = offset
                        entry['array_size'] = array_size(cursor_type(cursor))
                        entry['type_kind'] = canonical_type(cursor_type(cursor)).kind
                        entry['initializer'] = bounds(init) if not is_null(init) else None
                        templates.append((file, begin, end, key))
            elif cursor.kind == 101:  # DeclRefExpr
                target = referenced(cursor)
                target_path, unused_offset = location(cursor_location(target))
                if target.kind == 9 and owned(target_path):
                    key = string(usr(target))
                    references[(path, offset, name)] = key
                elif target.kind == 8:
                    references.setdefault((path, offset, name), 'function:' + name)
            elif cursor.kind == 8 and definition(cursor):
                functions[(path, name)] = (offset, cursor)
            return 2
        except Exception as error:
            errors.append(str(error))
            return 0
    visitor = visitor_type(walk)
    visit_children(root_cursor(unit), visitor, None)
if errors:
    raise SystemExit('CLI source compatibility check failed:\n' + '\n'.join(dict.fromkeys(errors)))
used_variables = set(references.values())
selected = {key for key, value in variables.items() if key in used_variables and (value['mutable'] or value['name'] == 'int_cb')}
# Read-only option tables contain addresses of mutable globals. They must also
# be constructed per session, including when upstream adds a new option table.
while True:
    added = set()
    for file, begin, end, owner in templates:
        if any(path == file and begin <= offset < end and target in selected for (path, offset, name), target in references.items()):
            added.add(owner)
    if added <= selected:
        break
    selected |= added
selected = sorted(selected)
for key in selected:
    if 'definition' not in variables[key]:
        raise SystemExit('No CLI definition found for session variable ' + variables[key]['name'])
    if variables[key]['definition'][0].suffix != '.c' and not variables[key]['local']:
        raise SystemExit('Mutable definitions in CLI headers need review: ' + variables[key]['name'])
for required in ['main', 'ffmpeg_cleanup', 'term_init', 'term_exit', 'decode_interrupt_cb']:
    if not any(name == required and path.name == 'ffmpeg.c' for path, name in functions):
        raise SystemExit('Unsupported CLI lifecycle: missing ' + required)

for required in ['get_format', 'get_buffer']:
    if not any(name == required and path.name == 'ffmpeg_dec.c' for path, name in functions):
        raise SystemExit('Codec callback lifecycle needs review: missing ' + required)

contents = {}
def data(path):
    if path not in contents:
        contents[path] = path.read_bytes()
    return contents[path]
edits = {}
def edit(path, begin, end, replacement):
    item = (begin, end)
    existing = edits.setdefault(path, {}).get(item)
    if existing is not None and existing != replacement:
        raise RuntimeError('Conflicting source edits in ' + str(path))
    edits[path][item] = replacement
# Embedding may never terminate or replace the application process. A new
# upstream exit path needs an explicit lifecycle port instead of a silent shim.
for (path, offset, name), target in references.items():
    if target in ('function:fork', 'function:execve', 'function:posix_spawn', 'function:system', 'function:_exit'):
        raise SystemExit('Unsupported process operation in CLI: ' + name)
    if target == 'function:exit':
        matching = [cursor for (file, function), (unused_offset, cursor) in functions.items()
                    if file == path and function == 'sigterm_handler']
        if not matching or not any(bounds(cursor)[1] <= offset < bounds(cursor)[2] for cursor in matching):
            raise SystemExit('New CLI process-exit lifecycle needs review: ' + str(path))
ids = {key: i for i, key in enumerate(selected)}
def getter(key):
    return 'ftcli_state_' + str(ids[key])
def transformed_initializer(key):
    value = variables[key]
    if not value['initializer']:
        return '0' if value['type_kind'] == 177 else '{0}'
    path, begin, end = value['initializer']
    output = data(path)[begin:end]
    for (file, offset, name), target in sorted(references.items(), key=lambda pair: pair[0][1], reverse=True):
        if file == path and begin <= offset < end and target in ids and data(path)[offset:offset+len(name)] == name.encode():
            output = output[:offset-begin] + reference(target).encode() + output[offset-begin+len(name):]
    return output.decode()
def reference(key):
    value = variables[key]
    if not value['local']:
        return '(*' + getter(key) + '())'
    name = value['name']
    # Function-local static variables retain their original compile-time
    # initializer as an immutable template, with session-owned writable storage.
    return '(*(__typeof__(' + name + ') *)ftcli_storage(' + str(ids[key]) + ', (const void *)&' + name + ', sizeof(' + name + '), _Alignof(__typeof__(' + name + '))))'
hooks = {
    'pthread_create': 'ftcli_pthread_create',
    'avdevice_register_all': 'ftcli_devices_register',
    'avformat_network_init': 'ftcli_network_init', 'avformat_network_deinit': 'ftcli_network_deinit',
    'av_log': 'ftcli_log', 'av_log_set_level': 'ftcli_log_set_level',
    'av_log_get_level': 'ftcli_log_get_level', 'av_log_set_flags': 'ftcli_log_set_flags',
    'av_log_get_flags': 'ftcli_log_get_flags', 'av_log_set_callback': 'ftcli_log_set_callback',
    'setvbuf': 'ftcli_setvbuf', 'exit': 'ftcli_exit',
    'getenv': 'ftcli_getenv',
    'avcodec_open2': 'ftcli_codec_open',
    'avcodec_alloc_context3': 'ftcli_codec_alloc', 'avcodec_free_context': 'ftcli_codec_free',
}
for (path, offset, name), key in references.items():
    replacement = reference(key) if key in ids else None
    if replacement is None:
        continue
    if any(file == path and begin <= offset < end for file, begin, end, unused in templates):
        continue
    if data(path)[offset:offset+len(name)] != name.encode():
        invocation = re.match(rb'[A-Za-z_]\w*', data(path)[offset:])
        macro_name = invocation.group().decode() if invocation else ''
        candidates = list(macros.get(macro_name, []))
        local = [item for item in candidates if item[0] == path and item[1] < offset]
        if local:
            candidates = [max(local, key=lambda item: item[1])]
        if len(candidates) != 1:
            raise SystemExit('Ambiguous macro reference needs review: ' + str(path) + ':' + name)
        file, begin, end = candidates[0]
        text = data(file)[begin:end].decode()
        parameters = re.match(r'[A-Za-z_]\w*\(([^)]*)\)', text)
        if parameters and name in re.findall(r'[A-Za-z_]\w*', parameters.group(1)):
            raise SystemExit('Macro argument location needs review: ' + macro_name + ':' + name)
        tokens = re.finditer(r'''/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_]\w*''', text, re.S)
        positions = [match.start() for match in tokens if match.group() == name and not re.search(r'(?:\.|->)\s*$', text[:match.start()])]
        if not positions:
            raise SystemExit('Cannot resolve global inside macro: ' + macro_name + ':' + name)
        for position in positions:
            edit(file, begin + position, begin + position + len(name), replacement)
    else:
        edit(path, offset, offset + len(name), replacement)
tails = {}
for key in selected:
    value = variables[key]
    if value['local']:
        if value['initializer']:
            file, begin, end = value['initializer']
            if any(path == file and begin <= offset < end and target in ids for (path, offset, name), target in references.items()):
                raise SystemExit('Session-dependent function-local initializer needs review: ' + value['name'])
        continue
    name, function = value['name'], getter(key)
    # The original definition is retained only for its declared type. Its
    # initializer is evaluated inside the per-session accessor instead.
    if value['initializer']:
        init_file, init_begin, init_end = value['initializer']
        edit(init_file, init_begin, init_end, '0' if value['type_kind'] == 177 else '{0}')
        array_count = value['array_size']
        if array_count >= 0:
            file, begin, end = value['definition']
            suffix = data(file)[value['name_offset'] + len(name):init_begin]
            unbounded = re.match(rb'\s*\[\s*\]', suffix)
            if unbounded:
                position = value['name_offset'] + len(name)
                edit(file, position, position + unbounded.end(), '[' + str(array_count) + ']')
    for file, begin, end, link in value['declarations'].values():
        after = data(file).index(b';', end) + 1
        qualifier = 'static ' if link == 2 else ''
        prototype = '\n' + qualifier + '__typeof__(' + name + ') *' + function + '(void);\n'
        old = edits.setdefault(file, {}).get((after, after), '')
        if prototype not in old:
            edits[file][(after, after)] = old + prototype
    file = value['definition'][0]
    internal = any(link == 2 for unused_file, unused_begin, unused_end, link in value['declarations'].values())
    init = transformed_initializer(key)
    if name == 'stdin_interaction':
        init = '0'
    if name == 'int_cb':
        init = '{ decode_interrupt_cb, ftcli_current() }'
    body = ('\n' + ('static ' if internal else '') + '__typeof__(' + name + ') *' + function + '(void) {\n'
            '    void *p = ftcli_lookup(' + str(ids[key]) + ');\n'
            '    if (p) return p;\n'
            '    __typeof__(' + name + ') initial = ' + init + ';\n'
            '    return ftcli_storage(' + str(ids[key]) + ', (const void *)&initial, sizeof(initial), _Alignof(__typeof__(initial)));\n}\n')
    tails.setdefault(file, []).append(body)
for (path, name), (offset, cursor) in functions.items():
    children = []
    callback = visitor_type(lambda child, enclosing, unused: (children.append(child), 1)[1])
    visit_children(cursor, callback, None)
    body = next((child for child in children if child.kind == 202), None)
    if path.name == 'ffmpeg.c' and name in ('term_init', 'term_exit'):
        file, begin, end = bounds(body)
        edit(file, begin, end, '{ /* Embedded CLI never owns process terminal or signals. */ }')
        # Remove edits wholly contained in the replaced function body.
        for interval in list(edits[file]):
            if interval != (begin, end) and begin <= interval[0] and interval[1] <= end:
                del edits[file][interval]
    elif path.name == 'ffmpeg.c' and name == 'main':
        edit(path, offset, offset + 4, 'ftcli_engine_main')
    elif path.name == 'ffmpeg.c' and name == 'decode_interrupt_cb':
        file, begin, end = bounds(body)
        argument = string(spelling(next(child for child in children if child.kind == 10)))
        edit(file, begin + 1, begin + 1, '\nFTCLIBinding ft_binding __attribute__((cleanup(ftcli_unbind))) = ftcli_bind(' + argument + ');\n')
    elif path.name == 'ffmpeg_dec.c' and name in ('get_format', 'get_buffer'):
        parameters = [child for child in children if child.kind == 10]
        argument = string(spelling(parameters[0]))
        file, begin, end = bounds(body)
        edit(file, begin + 1, begin + 1, '\nFTCLIBinding ft_binding __attribute__((cleanup(ftcli_unbind))) = ftcli_bind_codec(' + argument + ');\n')

generated = stage / 'source'
if generated.exists():
    shutil.rmtree(generated)
shutil.copytree(source / 'fftools', generated / 'fftools')
if (work / 'fftools').exists():
    for path in (work / 'fftools').rglob('*'):
        if path.is_file() and path.suffix in ('.c', '.h'):
            target = generated / path.relative_to(work)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
for path in set(edits) | set(tails):
    output = data(path)
    previous = len(output) + 1
    for (begin, end), replacement in sorted(edits.get(path, {}).items(), reverse=True):
        if end > previous:
            raise SystemExit('Overlapping transformations require review: ' + str(path))
        output = output[:begin] + replacement.encode() + output[end:]
        previous = begin
    target = generated / relative(path)
    target.write_bytes(b'#include "ftcli_runtime.h"\n' + output + ''.join(tails.get(path, [])).encode())
(generated / 'ftcli_runtime.h').write_text(RUNTIME_HEADER)
(generated / 'ftcli_runtime.c').write_text(RUNTIME_SOURCE.replace('@SLOT_COUNT@', str(len(ids))))
compile_flags = ['-I' + str(generated), '-I' + str(work), '-I' + str(source), *flags]
# Load original API declarations before introducing aliases. Defining these
# names with -D before system headers can accidentally inherit Darwin asm
# aliases and bypass the runtime wrappers (notably pthread_create).
hook_header = generated / 'ftcli_hooks.h'
hook_header.write_text('''#ifndef FTCLI_HOOKS_H
#define FTCLI_HOOKS_H
#include "config.h"
#include <stdlib.h>
#include "ftcli_runtime.h"
#include "libavutil/log.h"
#include "libavformat/avformat.h"
#include "libavdevice/avdevice.h"
''' + ''.join('#define ' + name + ' ' + replacement + '\n' for name, replacement in hooks.items()) + '#endif\n')
hook_flags = ['-include', str(hook_header)]
generated_paths = [generated / relative(path) for path in paths] + [generated / 'ftcli_runtime.c']
for path in generated_paths:
    subprocess.run([clang, *compile_flags, *(hook_flags if path.name != 'ftcli_runtime.c' else []), '-fsyntax-only', str(path)], cwd=work, check=True)
print('CLI session source syntax passed:', len(ids), 'session variables,', len(paths), 'upstream compilation units')
if mode != 'check':
    output_objects = []
    for i, path in enumerate(generated_paths):
        output = stage / ('engine-' + str(i) + '.o')
        subprocess.run([clang, *compile_flags, *(hook_flags if path.name != 'ftcli_runtime.c' else []), '-c', str(path), '-o', str(output)], cwd=work, check=True)
        output_objects.append(str(output))
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(prefix / 'lib/libFFmpegCLI.a'), *output_objects], check=True)
    (prefix / 'include/ffmpeg_cli.h').write_text(PUBLIC_HEADER)
for unit in units:
    dispose_tu(unit)
FTCLI_PY
}

run_cli_tests() {
    [[ -f "$CLI_SWIFT_SOURCE" && -f "$CLI_SWIFT_TEST_SOURCE" ]] ||
        die "Tests need client Swift files. Set CLI_SWIFT_SOURCE and CLI_SWIFT_TEST_SOURCE to their paths; the build script does not generate Swift."
    mkdir -p "$BUILD_ROOT/tests"
    local SWIFTC
    SWIFTC=$(xcrun --find swiftc)
    local TEST_FLAGS=(-lz -lbz2 -liconv -lc++)
    local FRAMEWORK
    for FRAMEWORK in Foundation CoreFoundation AVFoundation CoreMedia CoreVideo AudioToolbox VideoToolbox Security Accelerate Metal; do
        TEST_FLAGS+=(-framework "$FRAMEWORK")
    done
    [[ -f "$MACUNIVERSAL_DIR/libFFmpeg.a" && -f "$MACUNIVERSAL_DIR/FFmpeg-headers/ffmpeg_cli.h" ]] ||
        die "CLI-enabled combined macOS library is missing. Run a full build first."
    "$SWIFTC" -parse-as-library -swift-version 5 -sdk "$MACOS_SYSROOT" \
        -target "$(uname -m)-apple-macos$MIN_MACOS_VERSION" \
        -module-cache-path "$BUILD_ROOT/tests/swift-module-cache-macos" \
        -I "$MACUNIVERSAL_DIR/FFmpeg-headers" "$CLI_SWIFT_SOURCE" \
        "$CLI_SWIFT_TEST_SOURCE" "$MACUNIVERSAL_DIR/libFFmpeg.a" \
        "${TEST_FLAGS[@]}" -o "$BUILD_ROOT/tests/cli-smoke-macos"
    if ! "$BUILD_ROOT/tests/cli-smoke-macos" > "$BUILD_ROOT/tests/macos.log" 2>&1; then
        tail -n 60 "$BUILD_ROOT/tests/macos.log" >&2
        die "Embedded CLI regression failed. See $BUILD_ROOT/tests/macos.log; XCFramework was not replaced."
    fi
    tail -n 1 "$BUILD_ROOT/tests/macos.log"
    if [[ "${1:-}" == yes ]]; then
        local SIMULATOR=${CLI_TEST_SIMULATOR_UDID:-booted}
        [[ -f "$SIM_DIR/libFFmpeg.a" ]] || die "Combined Simulator library is missing."
        "$SWIFTC" -parse-as-library -swift-version 5 -sdk "$SIM_SYSROOT" \
            -target "arm64-apple-ios$MIN_IOS_VERSION-simulator" \
            -module-cache-path "$BUILD_ROOT/tests/swift-module-cache-simulator" \
            -I "$SIM_DIR/FFmpeg-headers" "$CLI_SWIFT_SOURCE" \
            "$CLI_SWIFT_TEST_SOURCE" "$SIM_DIR/libFFmpeg.a" \
            "${TEST_FLAGS[@]}" -o "$BUILD_ROOT/tests/cli-smoke-simulator"
        if ! xcrun simctl spawn "$SIMULATOR" "$BUILD_ROOT/tests/cli-smoke-simulator" > "$BUILD_ROOT/tests/simulator.log" 2>&1; then
            tail -n 60 "$BUILD_ROOT/tests/simulator.log" >&2
            die "Simulator embedded CLI regression failed. See $BUILD_ROOT/tests/simulator.log."
        fi
        tail -n 1 "$BUILD_ROOT/tests/simulator.log"
    fi
}

build_platform() (
    local PLATFORM=$1 ARCH=$2 SYSROOT=$3 TARGET=$4 PREFIX=$5
    local WORK_DIR="$BUILD_ROOT/work/$PLATFORM"
    local EXTRA_FLAGS=()

    # Build upstream fftools normally, then build the generated CLI frontend
    # separately. libav sources and their objects are never rewritten/replaced.
    EXTRA_FLAGS+=(--enable-ffmpeg)

    # Keep x86 assembly when NASM is installed; otherwise allow a portable build.
    if [[ "$ARCH" == "x86_64" ]] && ! command -v nasm >/dev/null 2>&1; then
        echo "NASM not found: disabling x86 assembly for $PLATFORM."
        EXTRA_FLAGS+=(--disable-x86asm)
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    # Use FFmpeg's own clean target, including its generated source link.
    # SRC_LINK may be recorded as ./src by an earlier configure invocation.
    [[ ! -f Makefile ]] || make distclean SRC_LINK=src
    # Installed headers and CLI archives from an older upstream checkout must
    # not survive into the new target's package.
    rm -rf "$PREFIX"
    echo "Building FFmpeg for $PLATFORM ($TARGET)..."
    "$SOURCE_DIR/configure" \
        "${COMMON_FLAGS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        --prefix="$PREFIX" --arch="$ARCH" \
        --cc="$CLANG" --ar="$AR" --ranlib="$RANLIB" \
        --sysroot="$SYSROOT" \
        --extra-cflags="-arch $ARCH -target $TARGET" \
        --extra-ldflags="-arch $ARCH -target $TARGET"
    # Configure may disable a component whose dependencies are unavailable.
    # Fail before compiling/packaging a library that cannot open HTTPS sources.
    local FEATURE
    for FEATURE in CONFIG_SECURETRANSPORT CONFIG_NETWORK; do
        grep -qx "#define $FEATURE 1" config.h ||
            die "$PLATFORM: missing $FEATURE; inspect ffbuild/config.log."
    done
    for FEATURE in CONFIG_HTTP_PROTOCOL CONFIG_HTTPS_PROTOCOL CONFIG_TLS_PROTOCOL CONFIG_TCP_PROTOCOL CONFIG_CRYPTO_PROTOCOL CONFIG_HLS_DEMUXER; do
        grep -qx "#define $FEATURE 1" config_components.h ||
            die "$PLATFORM: missing $FEATURE; inspect ffbuild/config.log."
    done
    grep -qx '#define CONFIG_FFMPEG 1' config.h ||
        die "$PLATFORM: FFmpeg CLI was not enabled; inspect ffbuild/config.log."
    make -j"$JOBS"
    make install

    # All seven libraries are required; missing output must stop the build.
    local LIB
    for LIB in "${LIBS[@]}"; do
        [[ -f "$PREFIX/lib/$LIB.a" && -d "$PREFIX/include/$LIB" ]] ||
            die "Missing $LIB library or headers for $PLATFORM."
        lipo "$PREFIX/lib/$LIB.a" -verify_arch "$ARCH"
    done
    [[ -x "$PREFIX/bin/ffmpeg" ]] || die "Missing FFmpeg executable for $PLATFORM."
    lipo "$PREFIX/bin/ffmpeg" -verify_arch "$ARCH"
    generate_cli "$PLATFORM" "$PREFIX" build
    lipo "$PREFIX/lib/libFFmpegCLI.a" -verify_arch "$ARCH"
)

if [[ "$MODE" == check ]]; then
    generate_cli ios "$IOS_DIR" check
    generate_cli ios-simulator-arm64 "$SIM_DIR" check
    generate_cli macos-arm64 "$MACARM64_DIR" check
    generate_cli macos-x86_64 "$MACX86_64_DIR" check
    exit 0
elif [[ "$MODE" == test ]]; then
    run_cli_tests yes
    exit 0
fi

if [[ "$PACKAGE_ONLY" == 0 ]]; then
    build_platform ios arm64 "$IOS_SYSROOT" "arm64-apple-ios$MIN_IOS_VERSION" "$IOS_DIR"
    build_platform ios-simulator-arm64 arm64 "$SIM_SYSROOT" \
        "arm64-apple-ios$MIN_IOS_VERSION-simulator" "$SIM_DIR"
    build_platform macos-arm64 arm64 "$MACOS_SYSROOT" \
        "arm64-apple-macos$MIN_MACOS_VERSION" "$MACARM64_DIR"
    build_platform macos-x86_64 x86_64 "$MACOS_SYSROOT" \
        "x86_64-apple-macos$MIN_MACOS_VERSION" "$MACX86_64_DIR"
else
    echo "Repackaging existing libraries and CLI; FFmpeg compilation is skipped."
fi

for CLI_PREFIX in "$IOS_DIR" "$SIM_DIR" "$MACARM64_DIR" "$MACX86_64_DIR"; do
    [[ -f "$CLI_PREFIX/lib/libFFmpegCLI.a" && -f "$CLI_PREFIX/include/ffmpeg_cli.h" ]] ||
        die "Missing embedded CLI in $CLI_PREFIX. Run a full build with this script, without --package-only."
    if xcrun nm -g -U "$CLI_PREFIX/lib/libFFmpegCLI.a" | grep -E '[[:space:]]_ftcli_swift_state_create$' >/dev/null; then
        die "Old CLI archive contains compiled Swift. Run a full build; Swift must be supplied by the consuming target."
    fi
    if ! xcrun nm -g "$CLI_PREFIX/lib/libFFmpegCLI.a" | grep -E '[[:space:]]U[[:space:]]+_ftcli_swift_state_create$' >/dev/null; then
        die "CLI archive does not use the external Swift adapter. Run a full build with this script."
    fi
done

# Check before replacing any packaged output. Old library-only builds need a
# full rebuild to produce the upstream macOS command-line executables.
for CLI_DIR in "$MACARM64_DIR" "$MACX86_64_DIR"; do
    [[ -x "$CLI_DIR/bin/ffmpeg" ]] ||
        die "Missing $CLI_DIR/bin/ffmpeg. Run a full build without --package-only to build the macOS CLI."
done
lipo "$MACARM64_DIR/bin/ffmpeg" -verify_arch arm64
lipo "$MACX86_64_DIR/bin/ffmpeg" -verify_arch x86_64


# Merge intact upstream static archives using Apple's packaging tool.
# Keep the installed libav*/libsw* header layout so C includes remain valid.
create_combined_library() {
    local SRC=$1
    shift
    local LIB ARCH
    local ARCHIVES=()
    local INCLUDE_DIR="$SRC/FFmpeg-headers"
    [[ -f "$SRC/lib/libFFmpegCLI.a" && -f "$SRC/include/ffmpeg_cli.h" ]] ||
        die "CLI archive/header missing in $SRC. A full build with this script is required."
    for ARCH in "$@"; do
        lipo "$SRC/lib/libFFmpegCLI.a" -verify_arch "$ARCH"
    done
    ARCHIVES+=("$SRC/lib/libFFmpegCLI.a")
    for LIB in "${LIBS[@]}"; do
        [[ -f "$SRC/lib/$LIB.a" && -f "$SRC/include/$LIB/${LIB#lib}.h" ]] ||
            die "Missing $LIB library or headers in $SRC."
        for ARCH in "$@"; do
            lipo "$SRC/lib/$LIB.a" -verify_arch "$ARCH"
        done
        ARCHIVES+=("$SRC/lib/$LIB.a")
    done

    rm -rf "$INCLUDE_DIR"
    mkdir -p "$INCLUDE_DIR"
    cp "$SRC/include/ffmpeg_cli.h" "$INCLUDE_DIR/ffmpeg_cli.h"
    # Capability only: no source-version hash and no generated Swift code.
    cat > "$INCLUDE_DIR/ffmpeg_swift_client.h" <<'FTCLI_CLIENT_HEADER'
#ifndef FT_FFMPEG_SWIFT_CLIENT_H
#define FT_FFMPEG_SWIFT_CLIENT_H
#define FT_FFMPEG_EXTERNAL_SWIFT_RUNTIME 1
#endif
FTCLI_CLIENT_HEADER
    for LIB in "${LIBS[@]}"; do
        cp -R "$SRC/include/$LIB" "$INCLUDE_DIR/$LIB"
    done
    # Name only the main public headers; optional GPU backend headers may
    # require third-party SDKs that are not part of this Apple build.
    cat > "$INCLUDE_DIR/module.modulemap" <<'EOF'
module FFmpeg {
    header "ffmpeg_cli.h"
    header "libavcodec/avcodec.h"
    header "libavdevice/avdevice.h"
    header "libavfilter/avfilter.h"
    header "libavformat/avformat.h"
    header "libavutil/avutil.h"
    header "libswresample/swresample.h"
    header "libswscale/swscale.h"
    export *

    explicit module imgutils {
        header "libavutil/imgutils.h"
        export *
    }
    explicit module error {
        header "libavutil/error.h"
        export *
    }
}
EOF
    cat >> "$INCLUDE_DIR/module.modulemap" <<'FTCLI_CLIENT_MODULE'

module FFmpegExternalSwiftRuntime {
    header "ffmpeg_swift_client.h"
    export *
}
FTCLI_CLIENT_MODULE
    xcrun libtool -static -o "$SRC/libFFmpeg.a" "${ARCHIVES[@]}"
    for ARCH in "$@"; do
        lipo "$SRC/libFFmpeg.a" -verify_arch "$ARCH"
    done
}

mkdir -p "$MACUNIVERSAL_DIR/lib" "$MACUNIVERSAL_DIR/include"
for LIB in "${LIBS[@]}"; do
    # Both architectures must expose exactly the same installed headers.
    for HEADER_PATH in "$MACARM64_DIR/include/$LIB/"*.h; do
        cmp -s "$HEADER_PATH" "$MACX86_64_DIR/include/$LIB/${HEADER_PATH##*/}" ||
            die "macOS headers differ across architectures: $HEADER_PATH"
    done
    for HEADER_PATH in "$MACX86_64_DIR/include/$LIB/"*.h; do
        cmp -s "$HEADER_PATH" "$MACARM64_DIR/include/$LIB/${HEADER_PATH##*/}" ||
            die "macOS headers differ across architectures: $HEADER_PATH"
    done
    rm -rf "$MACUNIVERSAL_DIR/include/$LIB"
    cp -R "$MACARM64_DIR/include/$LIB" "$MACUNIVERSAL_DIR/include/$LIB"
    lipo "$MACARM64_DIR/lib/$LIB.a" -verify_arch arm64
    lipo "$MACX86_64_DIR/lib/$LIB.a" -verify_arch x86_64
    lipo -create "$MACARM64_DIR/lib/$LIB.a" "$MACX86_64_DIR/lib/$LIB.a" \
        -output "$MACUNIVERSAL_DIR/lib/$LIB.a"
done

cmp -s "$MACARM64_DIR/include/ffmpeg_cli.h" "$MACX86_64_DIR/include/ffmpeg_cli.h" ||
    die "macOS CLI public headers differ across architectures."
cp "$MACARM64_DIR/include/ffmpeg_cli.h" "$MACUNIVERSAL_DIR/include/ffmpeg_cli.h"
lipo -create "$MACARM64_DIR/lib/libFFmpegCLI.a" "$MACX86_64_DIR/lib/libFFmpegCLI.a"     -output "$MACUNIVERSAL_DIR/lib/libFFmpegCLI.a"

create_combined_library "$IOS_DIR" arm64
create_combined_library "$SIM_DIR" arm64
create_combined_library "$MACUNIVERSAL_DIR" arm64 x86_64

# Refuse to package a CLI whose in-process/reentrant tests fail on the host.
if [[ -f "$CLI_SWIFT_SOURCE" && -f "$CLI_SWIFT_TEST_SOURCE" ]]; then
    run_cli_tests "${CLI_TEST_SIMULATOR_UDID:+yes}"
else
    echo "CLI runtime tests were not run: provide external CLI_SWIFT_SOURCE and CLI_SWIFT_TEST_SOURCE."
    echo "Run --test-cli with those files before using this framework in an app."
fi

STAGED_XC=$(mktemp -d "$XC_DIR/.ffmpeg-package.XXXXXX")
trap 'rm -rf "$STAGED_XC"' EXIT
xcodebuild -create-xcframework \
    -library "$IOS_DIR/libFFmpeg.a" -headers "$IOS_DIR/FFmpeg-headers" \
    -library "$SIM_DIR/libFFmpeg.a" -headers "$SIM_DIR/FFmpeg-headers" \
    -library "$MACUNIVERSAL_DIR/libFFmpeg.a" -headers "$MACUNIVERSAL_DIR/FFmpeg-headers" \
    -output "$STAGED_XC/FFmpeg.xcframework"
rm -rf "$XC_DIR/FFmpeg.xcframework"
mv "$STAGED_XC/FFmpeg.xcframework" "$XC_DIR/FFmpeg.xcframework"

mkdir -p "$BUILD_ROOT/bin"
lipo -create "$MACARM64_DIR/bin/ffmpeg" "$MACX86_64_DIR/bin/ffmpeg" \
    -output "$BUILD_ROOT/bin/ffmpeg"
chmod +x "$BUILD_ROOT/bin/ffmpeg"
lipo "$BUILD_ROOT/bin/ffmpeg" -verify_arch arm64 x86_64

echo "Done. Combined FFmpeg XCFramework is available in: $XC_DIR/FFmpeg.xcframework"
echo "Upstream macOS FFmpeg CLI (arm64+x86_64): $BUILD_ROOT/bin/ffmpeg"
echo "C-only CLI framework complete. Compile your SDK FTFFmpeg.swift in the consuming target."
echo "Run --test-cli with a booted arm64 Simulator before replacing TPFFmpeg in an iOS app."
