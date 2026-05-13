// Include the full C API first (config types, function declarations, etc.)
#import "sherpa-onnx/c-api/c-api.h"

// Swift cannot import opaque C structs (forward declarations only).
// Provide empty struct bodies so Swift can see these types.
// This does NOT affect the ABI — the library allocates these internally,
// and Swift only ever holds pointers to them.
struct SherpaOnnxOfflineRecognizer { char _opaque; };
struct SherpaOnnxOfflineStream { char _opaque; };
struct SherpaOnnxOnlineRecognizer { char _opaque; };
struct SherpaOnnxOnlineStream { char _opaque; };
struct SherpaOnnxOfflinePunctuation { char _opaque; };
