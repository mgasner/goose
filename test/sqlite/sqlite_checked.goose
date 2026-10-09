// Checked SQL: a schema as migrations, statements prepared by the compiler
// against it, rows read into structs the program declares and into one the
// compiler generates, named parameters bound from a struct, NULL through
// Nullable fields, a struct-typed one<T> and each<T>, and the schema applied
// at open with the database checked against what the program was compiled for.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(
        id integer primary key, name text not null,
        email text, score real not null default 0) strict;
    """, """
    create table posts(
        id integer primary key, user_id integer not null references users(id),
        title text not null, body text) strict;
    """);

let users_above = sqlite::statement(SCHEMA, "select id, name, email, score from users where score > ? order by id");
let user_by_id = sqlite::statement(SCHEMA, "select id, name, email, score from users where id = ?");
let add_user = sqlite::statement(SCHEMA, "insert into users(name, email, score) values (:name, :email, :score) returning id");
let add_post = sqlite::statement(SCHEMA, "insert into posts(user_id, title, body) values (?, ?, ?)");
let post_counts = sqlite::statement(SCHEMA, """
    select u.name as "name!", count(p.id) as "posts: integer!", max(p.title) as "latest: text"
    from users u left join posts p on p.user_id = u.id group by u.id order by u.id
    """);
let names = sqlite::statement(SCHEMA, "select name from users order by name");
let total = sqlite::statement(SCHEMA, "select total(score) as \"total: real!\" from users");

struct User { id: i64, name: u8[], email: sqlite::Nullable<u8[]>, score: f64 }
struct NewUser { name: u8[], email: sqlite::Nullable<u8[]>, score: f64 }
type PostCount = sqlite::row_type(post_counts);
// Fields in any order, a narrower integer, a limited array, and one with a
// default that no column fills.
struct Brief { score: f32, name: u8[..16], id: i32, note: u8[] = "-" }
let briefs = sqlite::statement(SCHEMA, "select name, id, score from users order by id");

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    print("open ", ok, ", schema version ", sqlite::user_version(db));

    let alice, a1 = sqlite::one<i64>(db, add_user, NewUser { name: "alice", email: sqlite::none<u8[]>(), score: 9.25 });
    var bob = NewUser { name: "bob", email: sqlite::some("bob@example.com"), score: 7.0 };
    let bobid, a2 = sqlite::one<i64>(db, add_user, bob);
    sqlite::exec(db, add_user, NewUser { name: "carol", email: sqlite::some("c@example.com"), score: 1.5 });
    print("ids ", alice, " ", bobid);
    sqlite::exec(db, add_post, alice, "hello", "first post");
    sqlite::exec(db, add_post, alice, "again", sqlite::Null {});
    sqlite::exec(db, add_post, bobid, "bob's", "hi");

    let users, ran = sqlite::rows<User>(db, users_above, 5.0);
    print("rows ", ran);
    for u in users {
        print("  ", u.id, " ", u.name, " ", if u.email.has { u.email.v } else { "(no email)" }, " ", u.score);
    }

    let u, found = sqlite::one<User>(db, user_by_id, 2);
    print("one: ", found, " ", u.name);
    let nobody, found2 = sqlite::one<User>(db, user_by_id, 99);
    print("none: ", found2, " [", nobody.name, "] ", nobody.email.has);

    let counts, ran2 = sqlite::rows<PostCount>(db, post_counts);
    for c in counts {
        print("  ", c.name, ": ", c.posts, " posts, latest ", if c.latest.has { c.latest.v } else { "-" });
    }

    sqlite::each<Brief>(db, briefs) { b => print("  brief ", b.id, " ", b.name, " ", b.score, " ", b.note); };
    var seen = 0;
    sqlite::each<u8[]>(db, names) { seen += it.len; };
    print("name bytes ", seen);
    let t, tf = sqlite::one<f64>(db, total);
    print("total ", t, " ", tf);

    // The unchecked forms take a checked statement too, with its parameters checked.
    let n, f = sqlite::scalar_int(db, user_by_id, 1);
    print("scalar ", n);
    sqlite::each(db, users_above, 8.0) { r => print("  each ", sqlite::text(r, 1)); };
    sqlite::close(db);
}
