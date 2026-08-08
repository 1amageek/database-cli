import DatabaseCommandLine
import Darwin

@main
struct DatabaseCLIEntryPoint {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let status = await InterruptibleCommand.run(
            cancelOperationOnInterrupt: arguments.first != "shell"
        ) {
            await DatabaseCLIApplication().run(arguments: arguments)
        }
        if status != 0 {
            exit(status)
        }
    }
}
