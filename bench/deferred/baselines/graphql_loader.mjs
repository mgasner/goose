// The graphql_loader request in graphql-js, two ways, with the same data,
// backend cost model and response as goose/graphql_loader.goose
// (bench/deferred/README.md):
//
//   node graphql_loader.mjs <naive|dataloader> <books> <call_ns> <reps>
//     -> the first response, then: ns_per_request backend_calls_per_request
//
// naive       resolvers load a row at a time through a per-request cache;
// dataloader  one DataLoader per table per request, as its documentation
//             recommends: one batch call per table per tick.
// Each request is parsed, validated and executed, as the Goose library does.
import { buildSchema, graphql } from 'graphql';
import DataLoader from 'dataloader';

const [mode, nbooksArg, callNsArg, repsArg] = process.argv.slice(2);
const nbooks = Number(nbooksArg), callNs = BigInt(callNsArg), reps = Number(repsArg);

const nauthors = Math.max(1, Math.floor(nbooks / 4));
const countryRows = Array.from({ length: 16 }, (_, i) => `C${i}`);
const authorRows = Array.from({ length: nauthors }, (_, i) => ({ name: `author${i}`, country: (i * 5) % 16 }));
const bookRows = Array.from({ length: nbooks }, (_, i) => ({ title: `book${i}`, author: (i * 7) % nauthors }));

let calls = 0;
function spin() {
  if (callNs <= 0n) return;
  const until = process.hrtime.bigint() + callNs;
  while (process.hrtime.bigint() < until) {}
}
function fetchAuthors(ids) { calls++; spin(); return ids.map((i) => authorRows[i]); }
function fetchCountries(ids) { calls++; spin(); return ids.map((i) => countryRows[i]); }

const schema = buildSchema(`
  type Query { books: [Book!]! }
  type Book { title: String!, authorName: String!, authorCountry: String! }
`);

function naiveContext() {
  const authors = new Map(), countries = new Map();
  const author = (a) => { if (!authors.has(a)) authors.set(a, fetchAuthors([a])[0]); return authors.get(a); };
  const country = (c) => { if (!countries.has(c)) countries.set(c, fetchCountries([c])[0]); return countries.get(c); };
  return {
    authorName: (b) => author(b.author).name,
    authorCountry: (b) => country(author(b.author).country),
  };
}

function loaderContext() {
  const authors = new DataLoader(async (keys) => fetchAuthors(keys));
  const countries = new DataLoader(async (keys) => fetchCountries(keys));
  return {
    authorName: (b) => authors.load(b.author).then((a) => a.name),
    authorCountry: (b) => authors.load(b.author).then((a) => countries.load(a.country)),
  };
}

class Book {
  constructor(row, ctx) { this.row = row; this.ctx = ctx; }
  title() { return this.row.title; }
  authorName() { return this.ctx.authorName(this.row); }
  authorCountry() { return this.ctx.authorCountry(this.row); }
}

const query = '{ books { title authorName authorCountry } }';

async function request() {
  const ctx = mode === 'naive' ? naiveContext() : loaderContext();
  const rootValue = { books: () => bookRows.map((r) => new Book(r, ctx)) };
  const result = await graphql({ schema, source: query, rootValue });
  return JSON.stringify(result);
}

const first = await request();
console.log(first);
for (let k = 0; k < Math.min(reps, 10); k++) await request();
calls = 0;
const t0 = process.hrtime.bigint();
for (let k = 0; k < reps; k++) await request();
const t1 = process.hrtime.bigint();
console.log(`${(t1 - t0) / BigInt(reps)} ${Math.floor(calls / reps)}`);
