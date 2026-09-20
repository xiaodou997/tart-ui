import Foundation
import Testing
@testable import TartKit

struct CommandActionTests {
  @Test("simple Tart command stays readable")
  func simpleCommand() {
    let action = CommandAction(arguments: ["clone", "ghcr.io/org/image:latest", "dev"])
    #expect(action.command == "tart clone ghcr.io/org/image:latest dev")
  }

  @Test("shell-sensitive arguments are quoted")
  func quotedCommand() {
    let action = CommandAction(arguments: ["run", "dev vm", "--dir=work:/Users/me/My Project:ro"])
    #expect(action.command == "tart run 'dev vm' '--dir=work:/Users/me/My Project:ro'")
  }

  @Test("single quotes are escaped")
  func singleQuote() {
    let action = CommandAction(arguments: ["run", "it's here"])
    #expect(action.command == "tart run 'it'\\''s here'")
  }
}
