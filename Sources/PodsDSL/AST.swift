/// Syntax tree for the supported Ruby subset.
indirect enum Node {
    case literal(Value)
    case string([InterpolatedPart])
    case array([Node])
    case hash([(key: Node, value: Node)])
    case range(Node, Node, exclusive: Bool)
    case variable(String)
    case instanceVariable(String)
    case constant(path: [String])
    case selfReference
    /// `receiver.name(args) { block }`; a `nil` receiver means an implicit `self` call.
    case call(receiver: Node?, name: String, arguments: [Argument], block: BlockNode?, safeNavigation: Bool)
    case index(Node, [Node])
    case assign(target: Node, value: Node)
    /// `a ||= b`, `a += b`, ...
    case opAssign(target: Node, op: String, value: Node)
    case binary(op: String, Node, Node)
    case not(Node)
    case and(Node, Node)
    case or(Node, Node)
    case ternary(Node, Node, Node)
    case conditional(branches: [(condition: Node, body: [Node])], elseBody: [Node]?)
    case caseWhen(subject: Node?, whens: [(values: [Node], body: [Node])], elseBody: [Node]?)
    case whileLoop(condition: Node, body: [Node], negated: Bool)
    case def(name: String, parameters: [String], body: [Node])
    case begin(body: [Node], rescue: [Node]?, ensure: [Node]?)
    case returnValue(Node?)
    case lambda(BlockNode)
    /// Source position marker wrapping a statement, used for error messages.
    case located(line: Int, Node)
}

enum InterpolatedPart {
    case text(String)
    case code([Node])
}

enum Argument {
    case positional(Node)
    case splat(Node)
    /// `key: value` or `:key => value`; consecutive pairs form a trailing hash.
    case pair(key: Node, value: Node)
    /// `&block`
    case blockPass(Node)
}

struct BlockNode {
    let parameters: [String]
    let body: [Node]
}
