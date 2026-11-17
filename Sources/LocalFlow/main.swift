import AppKit

// ggml loads an extra backend library from this variable; the app only uses the plug-ins in its own bundle.
unsetenv("GGML_BACKEND_PATH")

let args = CommandLine.arguments
if args.count >= 4, args[1] == "--verify-model" {
    CLI.runVerify(kind: args[2], path: args[3])
}
if args.count >= 3, args[1] == "--polish" {
    CLI.runPolish(text: args[2])
}
if args.count >= 3, args[1] == "--transcribe" {
    CLI.run(arguments: Array(args.dropFirst(2)))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
