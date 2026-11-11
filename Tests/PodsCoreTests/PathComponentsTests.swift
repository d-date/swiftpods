import PodsCore
import Testing

@Suite struct PathComponentsTests {
    @Test(arguments: [
        ("a/b.txt", "b.txt"), ("a/b/", "b"), ("b", "b"), ("/", "/"), ("", ""), ("/a", "a"),
    ])
    func lastPathComponent(path: String, expected: String) {
        #expect(path.lastPathComponent == expected)
    }

    @Test(arguments: [
        ("a/b.txt", "a"), ("b.txt", ""), ("/a", "/"), ("/", "/"), ("a/b/c/", "a/b"), ("a//b", "a"), ("", ""),
    ])
    func deletingLastPathComponent(path: String, expected: String) {
        #expect(path.deletingLastPathComponent == expected)
    }

    @Test(arguments: [
        ("a/b.tar.gz", "gz"), ("Foo.framework/", "framework"), (".gitignore", ""), ("a.b/c", ""), ("c", ""),
    ])
    func pathExtension(path: String, expected: String) {
        #expect(path.pathExtension == expected)
    }

    @Test(arguments: [
        ("a/libFoo.a", "a/libFoo"), ("Foo.framework", "Foo"), ("a.b/c", "a.b/c"), (".gitignore", ".gitignore"),
    ])
    func deletingPathExtension(path: String, expected: String) {
        #expect(path.deletingPathExtension == expected)
    }
}
