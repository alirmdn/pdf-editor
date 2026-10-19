// The C interface of PDF Editor's Rust engine (crates/mobile/src/lib.rs).
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PEEngine PEEngine;

/// An engine whose files live under `root`; `models` (may be NULL) is the OCR models folder.
/// NULL when `root` can't be used.
PEEngine *_Nullable pe_engine_new(const char *_Nonnull root, const char *_Nullable models);

/// Run an automation tool with JSON arguments. Returns JSON {"ok":true,"result":[...]} or
/// {"ok":false,"error":"..."}; free it with pe_string_free.
char *_Nullable pe_call(PEEngine *_Nullable engine, const char *_Nonnull tool, const char *_Nullable args_json);

void pe_string_free(char *_Nullable s);
void pe_engine_free(PEEngine *_Nullable engine);

#ifdef __cplusplus
}
#endif
