import DatabaseCommandLine
import DatabaseFDBCommandLine
import Darwin

@main
struct DatabaseFDBEntryPoint {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let status = await InterruptibleCommand.run {
            await DatabaseFDBApplication().run(arguments: arguments)
        }
        if status != 0 {
            exit(status)
        }
    }
}
