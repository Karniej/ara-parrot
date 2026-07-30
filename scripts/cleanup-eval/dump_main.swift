// Driver for dump-prompts.sh. Compiled together with fresh copies of the
// real prompt sources (TranscriptPrompt, CleanupIntensity, Mode,
// ModeRegistry), so the dumped prompts are byte-exact what the daemon sends —
// never a reconstruction. Writes:
//
//   prompt_<intensity>.txt          — the default mode (the measured matrix)
//   prompt_<intensity>_<mode>.txt   — email / chat / code compositions
//
// The eval reads any prompt_*.txt it finds and keys per-intensity checker
// expectations on the first underscore-separated token of the name.
import Foundation

let dir = CommandLine.arguments[1]
let modes = ModeRegistry.builtIns.filter { $0.usesLLM }
for intensity in [CleanupIntensity.light, .medium, .high] {
    for mode in modes {
        let stamped = mode.applying(cleanup: intensity)
        let text = TranscriptPrompt.instructions(for: stamped)
        let suffix = mode.id == "default" ? "" : "_\(mode.id)"
        let path = dir + "/prompt_\(intensity.rawValue)\(suffix).txt"
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
