// The graphql module on one thread: schema loading and its errors, request
// parsing and validation, execution with fragments, directives, variables,
// abstract types, null propagation and field errors, and introspection.
import std;
import graphql;

struct Pet { name: u8[..16], kind: i64, age: i64, friend: i64 }    // kind 0 dog, 1 cat
var pets: Pet[>..] = [];
var counter: i64 = 0;

enum Obj { Query, Mutation, Dog { i: i64 }, Cat { i: i64 } }

fn pet(i: i64) -> Obj { if pets[i].kind == 0 { Obj.Dog { i: i } } else { Obj.Cat { i: i } } }

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("pets") { r.list() { for p, i in pets { r.object(pet(i)); } }; }
    else if f.is("pet") {
        let id = f.string("id");
        let k, ok = parse_int(id);
        if ok && k >= 0 && k < pets.len { r.object(pet(k)); } else { r.none(); }
    }
    else if f.is("strict") { r.list() { for p, i in pets { if p.age > 3 { r.object(pet(i)); } else { r.none(); } } }; }
    else if f.is("grid") { r.list() { for y in 2 { r.list() { for x in 3 { r.int(y * 3 + x); } }; } }; }
    else if f.is("search") {
        let filter = f.arg("filter");
        let kind = filter.member("kind").string();
        let min_age = filter.member("minAge").int();
        r.list() {
            for p, i in pets { if p.age >= min_age && ((kind == "DOG") == (p.kind == 0)) { r.object(pet(i)); } }
        };
    }
    else if f.is("sum") { var t = 0; f.arg("xs").each() { t += it.int(); }; r.int(t); }
    else if f.is("echo") { if f.has("s") { r.string(f.string("s")); } else { r.none(); } }
    else if f.is("now") { r.json("{\"t\":1}"); }
    else if f.is("broken") { r.error("the database is on fire"); }
    else if f.is("big") { r.int(5000000000); }
    else if f.is("ratio") { r.float(f.float("x") / 2.0); }
    else if f.is("version") { r.string(f.parent_type()); }
}

fn resolve(o: Obj.Mutation, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("increment") { counter += f.int("by"); r.int(counter); }
}

fn resolve(o: Obj.Dog, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let p = pets[o.i];
    if f.is("id") { r.int(o.i); }
    else if f.is("name") { r.string(p.name); }
    else if f.is("age") { r.int(p.age); }
    else if f.is("barks") { r.boolean(true); }
    else if f.is("kind") { r.enum_value("DOG"); }
    else if f.is("mustHave") { r.none(); }
    else if f.is("friend") { if p.friend >= 0 { r.object(pet(p.friend)); } else { r.none(); } }
}

fn resolve(o: Obj.Cat, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let p = pets[o.i];
    if f.is("id") { r.int(o.i); }
    else if f.is("name") { r.string(p.name); }
    else if f.is("age") { r.int(p.age); }
    else if f.is("lives") { r.int(9); }
    else if f.is("kind") { r.string("CAT"); }
    else if f.is("mustHave") { r.int(1); }
    else if f.is("friend") { if p.friend >= 0 { r.object(pet(p.friend)); } else { r.none(); } }
}

fn type_of(o: Obj) -> const u8[:] {
    match o { Dog => "Dog", Cat => "Cat", Mutation => "Mutation", _ => "Query" }
}

fn run(q: const u8[:]) {
    var out: u8[>..] = [];
    let root = if graphql::is_mutation(q) { Obj.Mutation } else { Obj.Query };
    graphql::execute(q, root, out, type_of) { o, f, r => resolve(o, f, r) };
    print(out);
}

let SDL = """
    "When something happened."
    scalar Time
    enum Kind { DOG CAT FISH @deprecated(reason: "no fish") }
    interface Pet { id: ID!, name: String!, age: Int!, kind: Kind!, mustHave: Int!, friend: Pet }
    type Dog implements Pet {
      id: ID!, name: String!, age: Int!, kind: Kind!, mustHave: Int!, friend: Pet
      barks: Boolean!
    }
    type Cat implements Pet {
      id: ID!, name: String!, age: Int!, kind: Kind!, mustHave: Int!, friend: Pet
      lives: Int! @deprecated
    }
    union Any = Dog | Cat
    input Filter { kind: Kind!, minAge: Int = 0 }
    type Query {
      pets: [Pet!]!
      pet(id: ID!): Pet
      strict: [Pet!]
      grid: [[Int!]!]!
      search(filter: Filter!): [Any!]!
      sum(xs: [Int!]!): Int!
      echo(s: String): String
      now: Time
      broken: String
      big: Int
      ratio(x: Float!): Float
      version: String
    }
    type Mutation { increment(by: Int = 1): Int! }
    """;

fn main() {
    // Schemas that do not load say why.
    print(graphql::load_schema("type Query { a: Nope }"));
    print(graphql::load_schema("type Query { a: Int"));
    print(graphql::load_schema("type Foo { a: Int }"));
    print(graphql::load_schema("type Query { a: Int } union U = Query | Int"));
    print(graphql::load_schema("type Query { a(x: Query): Int }"));
    print(graphql::load_schema("type Query { a: Int } type Query { b: Int }"));
    print(graphql::load_schema("type Query { a: I } interface I { x: Int, y: Int } type T implements I { x: Int }"));

    let e = graphql::load_schema(SDL);
    assert(e.len == 0);
    pets.push(Pet { name: "rex", kind: 0, age: 5, friend: 1 });
    pets.push(Pet { name: "tom", kind: 1, age: 2, friend: -1 });
    pets.push(Pet { name: "fido \"jr\"", kind: 0, age: 1, friend: 0 });

    print("-- execution");
    run("{ pets { __typename name ... on Dog { barks } ... on Cat { lives } } }");
    run("{ pet(id: 1) { name friend { name } } p: pet(id: \"9\") { name } }");
    run("{ strict { name } }");
    run("{ grid }");
    run("{ search(filter: {kind: CAT}) { ... on Cat { name lives } } }");
    run("{\"query\":\"query($f: Filter!) { search(filter: $f) { __typename } }\",\"variables\":{\"f\":{\"kind\":\"DOG\",\"minAge\":3}}}");
    run("{ sum(xs: [1, 2, 3]) one: sum(xs: 4) }");
    run("query($s: String = \"hi\") { a: echo(s: $s) b: echo c: echo(s: null) }");
    run("{ now broken big ratio(x: 3) }");
    run("{ pets { name mustHave } }");
    run("{ pets { name ...N } } fragment N on Pet { name age } ");
    run("{ pets { name @include(if: false) a: age @skip(if: false) } }");
    run("query A { version } query B { version: big }");
    run("{\"query\":\"query A { version } query B { b: version }\",\"operationName\":\"B\"}");
    run("mutation { a: increment b: increment(by: 10) }");
    run("{ pet(id: 2) { name friend { name friend { name } } } }");

    print("-- request errors");
    run("{ pets { nope } }");
    run("{ pets }");
    run("{ pets { name { x } } }");
    run("{ pet { name } }");
    run("{ pet(id: 1, id: 2, x: 3) { name } }");
    run("query($id: ID!) { pet(id: $id) { name } }");
    run("query($id: Int) { pet(id: $id) { name } }");
    run("query($k: Kind!) { pets { name } }");
    run("{ search(filter: {kind: ROBOT}) { __typename } }");
    run("{ search(filter: {minAge: 1}) { __typename } }");
    run("{\"query\":\"query($f: Filter!) { search(filter: $f) { __typename } }\",\"variables\":{\"f\":{\"kind\":\"FISHY\"}}}");
    run("{ pets { ...F } } fragment F on Pet { friend { ...F } }");
    run("{ pets { ...Missing ... on Query { version } } }");
    run("{ pets { name @foo } }");
    run("{ pets { name } } fragment Unused on Dog { name }");
    run("query Q($x: Int) { pets { name } } query { pets { name } }");
    run("query A { version } query B { version }");
    run("{\"query\":\"query A { version }\",\"operationName\":\"C\"}");
    run("subscription { pets { name } }");
    run("{ pets { name ");
    run("{ \"a\" }");
    run("{\"variables\": {}}");
    run("{ pets { name } } # trailing comment");

    print("-- introspection");
    run("{ __type(name: \"Cat\") { name kind fields { name type { kind name ofType { name } } } } }");
    run("{ __type(name: \"Cat\") { fields(includeDeprecated: true) { name isDeprecated deprecationReason } interfaces { name } } }");
    run("{ __type(name: \"Kind\") { enumValues { name } all: enumValues(includeDeprecated: true) { name deprecationReason } } }");
    run("{ __type(name: \"Pet\") { kind possibleTypes { name } } any: __type(name: \"Any\") { possibleTypes { name } } }");
    run("{ __type(name: \"Filter\") { inputFields { name defaultValue type { name kind ofType { name } } } } }");
    run("{ __type(name: \"Time\") { description } nope: __type(name: \"Nope\") { name } }");
    run("{ __schema { queryType { name } mutationType { name } types { name } } }");
    run("{ __schema { directives { name locations args { name defaultValue } } } }");
}
