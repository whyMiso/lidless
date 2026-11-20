import Foundation
import LidlessCore

// Read-only SMC explorer. Intentionally has no write commands: all writes go through the
// privileged helper so that restore-on-exit is always guaranteed.
let args = CommandLine.arguments.dropFirst()
if args.contains("-h") || args.contains("--help") {
    print("""
    usage: lidless-smc [--read-only] [--all]
      --read-only  print fan and temperature keys (default; nothing is ever written)
      --all        additionally dump every SMC key with type and decoded value
                   (contains hardware identifiers such as the battery serial — don't post it publicly)
    """)
    exit(0)
}
exit(SMCReport.run(all: args.contains("--all")))
