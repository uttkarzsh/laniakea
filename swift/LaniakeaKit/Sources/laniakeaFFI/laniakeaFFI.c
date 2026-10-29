// Intentionally empty. SwiftPM/Xcode link a C target's object file into the app, so a
// target made only of a header needs one translation unit (without it the app link
// step fails: "Build input file cannot be found: .../laniakeaFFI.o").
#include "laniakeaFFI.h"
