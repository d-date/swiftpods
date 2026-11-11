import Foundation
import PodsCore
@testable import PodsDSL
import Testing

/// Records every call made on it, to observe how manifests are interpreted.
final class Recorder: DSLObject {
    var calls: [(name: String, arguments: [Value])] = []
    var dslTypeName: String { "Recorder" }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        calls.append((name, call.arguments))
        if let block = call.block { try call.interpreter.call(block, [.object(self)]) }
        return .object(self)
    }
}

private func evaluate(_ source: String, environment: [String: String] = [:]) throws -> (Value, Recorder, Interpreter) {
    let recorder = Recorder()
    let interpreter = Interpreter(file: "Test", directory: URL(fileURLWithPath: "/tmp"), environment: environment)
    let result = try interpreter.evaluate(source, self: .object(recorder))
    return (result, recorder, interpreter)
}

struct InterpreterTests {
    @Test func podfileStyleCommandCalls() throws {
        let (_, recorder, _) = try evaluate("""
        source 'https://cdn.cocoapods.org/'
        platform :ios, '15.0'
        use_frameworks! :linkage => :static

        target 'App' do
          pod 'Alamofire', '~> 5.9'
          pod 'MyKit', path: '../MyKit'
          pod 'Nuke', :git => 'https://github.com/kean/Nuke.git', :tag => '12.0.0'
        end
        """)
        let names = recorder.calls.map(\.name)
        #expect(names == ["source", "platform", "use_frameworks!", "target", "pod", "pod", "pod"])
        #expect(recorder.calls[1].arguments == [.symbol("ios"), .string("15.0")])
        #expect(recorder.calls[2].arguments == [.hash([(.symbol("linkage"), .symbol("static"))])])
        #expect(recorder.calls[5].arguments == [.string("MyKit"), .hash([(.symbol("path"), .string("../MyKit"))])])
        #expect(recorder.calls[6].arguments[1] == .hash([
            (.symbol("git"), .string("https://github.com/kean/Nuke.git")),
            (.symbol("tag"), .string("12.0.0")),
        ]))
    }

    @Test func podspecStyleAttributeAssignment() throws {
        let (_, recorder, _) = try evaluate("""
        Spec.new do |s|
          s.name         = "Foo"
          s.version      = "1.2.0"
          s.summary      = 'Short'
          s.description  = <<-DESC
            A longer description.
          DESC
          s.source       = { :git => "https://x/Foo.git", :tag => "v#{s.version}" }
          s.ios.deployment_target = '12.0'
          s.subspec 'Core' do |core|
            core.source_files = 'Sources/Core/**/*.swift'
            core.dependency 'Bar', '~> 1.0'
          end
        end
        """.replacingOccurrences(of: "Spec.new", with: "spec_new"))
        let names = recorder.calls.map(\.name)
        #expect(names.contains("name="))
        #expect(names.contains("description="))
        #expect(names.contains("ios"))
        #expect(names.contains("deployment_target="))
        #expect(names.contains("subspec"))
        #expect(names.contains("dependency"))
        let description = try #require(recorder.calls.first { $0.name == "description=" })
        #expect(description.arguments == [.string("    A longer description.\n")])
    }

    @Test func squigglyHeredocStripsIndentation() throws {
        let (result, _, _) = try evaluate("""
        x = <<~EOS
            line one
              line two
          EOS
        x
        """)
        #expect(result == .string("line one\n  line two\n"))
    }

    @Test func localsMethodsAndControlFlow() throws {
        let (result, recorder, _) = try evaluate("""
        def shared_pods
          pod 'A'
          pod 'B'
        end
        version = '1.0'
        targets = %w[App Widget]
        targets.each do |name|
          target name do
            shared_pods
          end
        end
        version == '1.0' ? "yes #{version}" : 'no'
        """)
        #expect(result == .string("yes 1.0"))
        #expect(recorder.calls.map(\.name) == ["target", "pod", "pod", "target", "pod", "pod"])
        #expect(recorder.calls[3].arguments == [.string("Widget")])
    }

    @Test func conditionalsAndEnv() throws {
        let (result, recorder, _) = try evaluate("""
        if ENV['CI'] == 'true'
          pod 'OnCI'
        elsif ENV.fetch('LOCAL', 'no') == 'yes'
          pod 'Local'
        else
          pod 'Default'
        end
        pod 'Debug' unless ENV['CI']
        ENV['CI']
        """, environment: ["CI": "true"])
        #expect(recorder.calls.map(\.name) == ["pod"])
        #expect(recorder.calls[0].arguments == [.string("OnCI")])
        #expect(result == .string("true"))
    }

    @Test func mutationOfCollectionsWritesBack() throws {
        let (result, _, _) = try evaluate("""
        list = []
        list << 'a'
        list.push('b')
        h = { :a => 1 }
        h[:b] = 2
        h.merge!(c: 3)
        [list.join(','), h.keys.map(&:to_s).join(','), h.size]
        """)
        #expect(result == .array([.string("a,b"), .string("a,b,c"), .int(3)]))
    }

    @Test func stringHelpers() throws {
        let (result, _, _) = try evaluate("""
        ['  x  '.strip, 'a-b-c'.split('-').length, 'Hello'.gsub('l', 'L'), 'v1.2'.sub(/^v/, ''), "%s-%s" % ['a', 'b'], 'abc'.start_with?('a')]
        """)
        #expect(result == .array([.string("x"), .int(3), .string("HeLLo"), .string("1.2"), .string("a-b"), .bool(true)]))
    }

    @Test func leadingDotChainsAndMultilineHashes() throws {
        let (result, _, _) = try evaluate("""
        h = {
          'a' => 1,
          'b' => 2,
        }
        h
          .keys
          .join('+')
        """)
        #expect(result == .string("a+b"))
    }

    @Test func reportsLineNumbersForErrors() {
        #expect(throws: DSLError("Undefined method or variable 'oops' for NilClass", file: "Test", line: 2)) {
            let interpreter = Interpreter(file: "Test", directory: URL(fileURLWithPath: "/tmp"), environment: [:])
            try interpreter.evaluate("x = 1\noops 1\n", self: .nil)
        }
    }

    @Test func refusesShellCommands() {
        #expect(throws: DSLError.self) {
            _ = try evaluate("system('rm -rf /')")
        }
    }

    @Test func caseWhenAndRanges() throws {
        let (result, _, _) = try evaluate("""
        x = 5
        case x
        when 1..3 then 'low'
        when 4..6 then 'mid'
        else 'high'
        end
        """)
        #expect(result == .string("mid"))
    }

    @Test func valueToJSONKeepsOrder() throws {
        let (result, _, _) = try evaluate("{ :git => 'u', :tag => '1', 'n' => [1, true, nil] }")
        #expect(result.json.serialized(pretty: false) == #"{"git":"u","tag":"1","n":[1,true,null]}"#)
    }
}

struct JSONTests {
    @Test func roundTripPreservesKeyOrder() throws {
        let text = #"{"z":1,"a":{"y":"é\n","b":[1.5,false,null]}}"#
        let json = try JSON(parsing: text)
        #expect(json.serialized(pretty: false) == #"{"z":1,"a":{"y":"é\n","b":[1.5,false,null]}}"#)
        #expect(json["a"]?["y"]?.string == "é\n")
    }
}
