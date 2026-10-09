-- The schema sqlite_checked_more.goose reads with sqlite::schema_file.
create table items(
    id integer primary key,
    name text not null,
    color text not null,
    qty integer not null,
    code text not null
) strict;
