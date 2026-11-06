// NeuG through its addon for Node.js: an in-memory database, the extensions it is given
// loaded by name, a graph and a two-hop question, and a wrong query that must throw.
'use strict';
const assert = require('node:assert/strict');
const { Database } = require('neug');

const db = new Database({ databasePath: '', mode: 'w' });
const conn = db.connect();

for (const name of process.argv.slice(2)) {
  conn.execute(`LOAD ${name}`);
  console.log(`loaded ${name}`);
}

conn.execute('CREATE NODE TABLE person(id INT64, name STRING, age INT32, PRIMARY KEY(id));');
conn.execute('CREATE REL TABLE knows(FROM person TO person);');
conn.execute("CREATE (:person {id: 1, name: 'Alice', age: 30});");
conn.execute("CREATE (:person {id: 2, name: 'Bob', age: 25});");
conn.execute("CREATE (:person {id: 3, name: 'Carol', age: 41});");
conn.execute('MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);');
conn.execute('MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);');

// an INT64 comes back as a BigInt
const people = [...conn.execute('MATCH (n:person) RETURN n.id, n.name, n.age ORDER BY n.id;')];
assert.equal(people.length, 3);
assert.equal(people[0][0], 1n);
assert.equal(people[0][1], 'Alice');
assert.equal(people[2][1], 'Carol');

const friends = [
  ...conn.execute(
    'MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) RETURN c.name;'
  ),
];
assert.equal(friends.length, 1);
assert.equal(friends[0][0], 'Carol');
console.log(`friend of a friend of Alice: ${friends[0][0]}`);

assert.throws(() => conn.execute('MATCH (n:no_such_table) RETURN n;'));
console.log('a wrong query throws');

conn.close();
db.close();
console.log('neug nodejs OK');
